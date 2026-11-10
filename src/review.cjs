'use strict';

// Review is a separate, local transaction: preparing or previewing never
// publishes a final image and never sends commands to PhotoCraft.
const fs = require('node:fs/promises');
const { constants: fsConstants } = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { setImmediate: yieldNow } = require('node:timers/promises');
const { processFile, optionsChecked, cancelled, requireWorkSpace } = require('./processor.cjs');
const { decodeTiff, decodeTiffForWork, encodeTiff } = require('./tiff.cjs');
const { checkedStrokes, applyStrokes } = require('./brush.cjs');
const { buildFrameProtection, protectionFromGeometry } = require('./frame-guard.cjs');
const { runImageCodec } = require('./image-codec.cjs');
const { workRootOverride, defaultWorkRoot, legacyWorkRoot } = require('./workspace.cjs');
const version = require('./version.cjs');

const SCHEMA = 'photocraft-film-dust-review';
const MAX_RUNS = 2_000_000;
const MAX_REGIONS = 20_000;
const RUN_MAGIC = Buffer.from('FDRUNS01');
const DETECTION_KINDS = ['dust', 'scratches', 'fibers', 'patches'];
const fail = message => { throw new Error(message); };
const sha256 = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const inside = (root, filename) => {
  const rel = path.relative(root, filename);
  return rel !== '' && rel !== '..' && !rel.startsWith('..' + path.sep) && !path.isAbsolute(rel);
};

function defaultCacheRoot() {
  return path.join(workRootOverride() || defaultWorkRoot(), 'reviews');
}

async function cacheLocation(root, create = false) {
  const resolved = path.resolve(root || defaultCacheRoot());
  if (create) await fs.mkdir(resolved, { recursive: true, mode: 0o700 });
  return fs.realpath(resolved);
}

async function signingKey(root, create = false) {
  const filename = path.join(root, '.review-signing-key');
  if (create) {
    try { await fs.writeFile(filename, crypto.randomBytes(32), { flag: 'wx', mode: 0o600 }); }
    catch (error) { if (error.code !== 'EEXIST') throw error; }
  }
  const stat = await fs.lstat(filename);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size !== 32) fail('审核凭证无效，请重新分析照片。');
  return fs.readFile(filename);
}

function signature(record, key) { return crypto.createHmac('sha256', key).update(JSON.stringify(record)).digest('hex'); }
async function saveRecord(filename, record, key) {
  const temp = filename + '.' + crypto.randomUUID();
  try {
    await fs.writeFile(temp, JSON.stringify({ record, signature: signature(record, key) }) + '\n', { flag: 'wx', mode: 0o600 });
    await fs.rename(temp, filename);
  } finally { await fs.rm(temp, { force: true }).catch(() => {}); }
}

class RunStore {
  constructor() { this.length = 0; this.capacity = 1024; this.x0 = new Uint32Array(this.capacity); this.x1 = new Uint32Array(this.capacity); this.y = new Uint32Array(this.capacity); this.parent = new Uint32Array(this.capacity); }
  push(y, x0, x1) {
    if (this.length >= MAX_RUNS) fail('检测区域过于复杂，请降低灵敏度后重新分析。');
    if (this.length === this.capacity) {
      this.capacity = Math.min(MAX_RUNS, this.capacity * 2);
      for (const field of ['x0', 'x1', 'y', 'parent']) { const next = new Uint32Array(this.capacity); next.set(this[field]); this[field] = next; }
    }
    const id = this.length++;
    this.y[id] = y; this.x0[id] = x0; this.x1[id] = x1; this.parent[id] = id;
    return id;
  }
  find(id) { let root = id; while (this.parent[root] !== root) root = this.parent[root]; while (this.parent[id] !== id) { const next = this.parent[id]; this.parent[id] = root; id = next; } return root; }
  union(a, b) { const x = this.find(a), y = this.find(b); if (x !== y) this.parent[Math.max(x, y)] = Math.min(x, y); }
}

function connectedRegions(mask) {
  const { width: W, height: H, data } = mask;
  if (mask.channels !== 1 || !Number.isSafeInteger(W) || !Number.isSafeInteger(H) || W < 1 || H < 1 || data.length !== W * H) fail('灰尘蒙版无效。');
  const store = new RunStore();
  let prevStart = 0, prevEnd = 0;
  for (let y = 0; y < H; y++) {
    const currentStart = store.length;
    let prior = prevStart;
    for (let x = 0; x < W;) {
      if (!data[y * W + x]) { x++; continue; }
      const x0 = x++;
      while (x < W && data[y * W + x]) x++;
      const id = store.push(y, x0, x);
      // Eight-connected components: diagonal neighbours belong together.
      while (prior < prevEnd && store.x1[prior] < x0) prior++;
      for (let p = prior; p < prevEnd && store.x0[p] <= x; p++) store.union(id, p);
    }
    prevStart = currentStart; prevEnd = store.length;
  }
  const groups = new Map();
  for (let r = 0; r < store.length; r++) {
    const root = store.find(r);
    if (!groups.has(root)) {
      if (groups.size >= MAX_REGIONS) fail('灰尘点位过多，请降低灵敏度后重新分析。');
      groups.set(root, { id: groups.size + 1, x: W, y: H, x1: 0, y1: 0, pixels: 0 });
    }
    const g = groups.get(root);
    g.x = Math.min(g.x, store.x0[r]); g.y = Math.min(g.y, store.y[r]);
    g.x1 = Math.max(g.x1, store.x1[r]); g.y1 = Math.max(g.y1, store.y[r] + 1);
    g.pixels += store.x1[r] - store.x0[r];
  }
  const regions = [...groups.values()].map(g => ({ id: g.id, x: g.x, y: g.y, width: g.x1 - g.x, height: g.y1 - g.y, pixels: g.pixels }));
  if (Buffer.byteLength(JSON.stringify(regions)) > 1_500_000) fail('灰尘点位数据过多，请降低灵敏度后重新分析。');
  const runs = Buffer.alloc(24 + store.length * 16);
  RUN_MAGIC.copy(runs); runs.writeUInt32LE(store.length, 8); runs.writeUInt32LE(W, 12); runs.writeUInt32LE(H, 16); runs.writeUInt32LE(regions.length, 20);
  for (let r = 0; r < store.length; r++) {
    const at = 24 + r * 16;
    runs.writeUInt32LE(groups.get(store.find(r)).id, at); runs.writeUInt32LE(store.y[r], at + 4);
    runs.writeUInt32LE(store.x0[r], at + 8); runs.writeUInt32LE(store.x1[r], at + 12);
  }
  return { regions, runs };
}

async function makeAsset(job, filename, digest) {
  const actual = await fs.realpath(filename);
  if (!inside(job, actual)) fail('审核交换文件超出工作目录。');
  const stat = await fs.stat(actual);
  if (!stat.isFile() || stat.size > 2_000_000_000) fail('审核交换文件无效。');
  if (digest) {
    if (stat.size !== digest.size) fail('审核交换文件写入不完整。');
    return { path: path.relative(job, actual), ...digest };
  }
  const hash = crypto.createHash('sha256');
  for await (const chunk of require('node:fs').createReadStream(actual)) hash.update(chunk);
  return { path: path.relative(job, actual), size: stat.size, sha256: hash.digest('hex') };
}

function publicReview(record, job, settings = record.detectionSettings) {
  const full = key => path.join(job, record.assets[key].path);
  const baseline = settings?.sensitivity ?? 1;
  const thresholds = { dust: settings?.dustSensitivity ?? baseline, fibers: settings?.fiberSensitivity ?? baseline,
    scratches: settings?.scratchSensitivity ?? 1, patches: settings?.patchSensitivity ?? 1,
    curl: settings?.fiberCurl ?? 1, softness: settings?.fiberSoftness ?? 1,
    keepRebate: settings?.keepRebate ? 1 : 0 };
  return { id: record.id, sourceName: record.sourceName, sourcePath: full('source'), cleanedPath: full('cleaned'), maskPath: full('mask'),
    width: record.width, height: record.height, depth: record.depth, regions: record.regions, runsPath: full('runs'),
    context: record.context, stats: record.stats, outputRoot: record.outputRoot, thresholds, rebateBakedIn: thresholds.keepRebate === 1 };
}

async function prepareReview({ inputPath, sourceName, outputRoot, context = 'file', host = null, cacheRoot,
  preparedResult = null, expectedSource = null, options = {} } = {}) {
  if (!['file', 'photocraft'].includes(context)) fail('未知的审核来源。');
  if (!inputPath || !outputRoot) fail('请选择输入文件和结果保存目录。');
  if (sourceName !== undefined && typeof sourceName !== 'string') fail('照片名称无效。');
  const detectionSettings = optionsChecked(options);
  const displayName = Array.from(path.basename(sourceName ?? inputPath).replace(/[\p{Cc}\p{Cf}]/gu, '')).slice(0, 255).join('') || 'scan.tiff';
  const root = await cacheLocation(cacheRoot, true), key = await signingKey(root, true);
  if (context === 'photocraft') {
    if (!host?.workDir || !host.snapshot || !Number.isInteger(host.snapshot.index)) fail('缺少 PhotoCraft 原始文档快照。');
    const hostRoot = await fs.realpath(host.workDir);
    if (!inside(hostRoot, root)) fail('PhotoCraft 审核缓存必须位于授权交换目录内。');
    host = { workDir: hostRoot, snapshot: host.snapshot };
  } else host = null;
  const id = crypto.randomUUID(), job = path.join(root, id);
  await fs.mkdir(job, { mode: 0o700 });
  try {
    cancelled(options.signal);
    const sourcePath = path.join(job, 'source.tiff');
    const stat = await fs.stat(inputPath);
    if (!stat.isFile() || stat.size < 8 || stat.size > 2_000_000_000) fail('请选择小于 2GB 的有效 TIFF 或 JPEG 文件。');
    // APFS can freeze a copy-on-write snapshot without copying the whole TIFF.
    // Node falls back to an independent copy on other file systems.
    const jpeg = /\.jpe?g$/i.test(inputPath);
    const snapshot = jpeg ? path.join(job, 'input.jpg') : sourcePath;
    await fs.copyFile(inputPath, snapshot, fsConstants.COPYFILE_EXCL | fsConstants.COPYFILE_FICLONE);
    if (jpeg) {
      await fs.chmod(snapshot, 0o600);
      await runImageCodec(['import-jpeg', snapshot, sourcePath], options.signal);
      await fs.unlink(snapshot);
    }
    await fs.chmod(sourcePath, 0o600);
    let candidate;
    if (preparedResult) {
      // Internal adoption avoids rerunning a large scan already processed by
      // this application. No CLI flag or manifest can supply this shortcut.
      const folder = await fs.mkdtemp(path.join(job, 'candidate-'));
      const copied = {};
      for (const name of ['cleaned', 'mask', 'report']) {
        const filename = preparedResult.paths?.[name];
        if (typeof filename !== 'string') fail('已有分析结果不完整。');
        const item = await fs.stat(filename);
        if (!item.isFile() || item.size < 1 || item.size > 2_000_000_000) fail('已有分析文件无效。');
        copied[name] = path.join(folder, name === 'report' ? 'report.json' : name + '.tiff');
        await fs.copyFile(filename, copied[name], require('node:fs').constants.COPYFILE_EXCL);
        await fs.chmod(copied[name], 0o600);
      }
      candidate = { ...preparedResult, outputDir: folder, paths: copied };
    } else candidate = await processFile(sourcePath, job, options, { captureReview: true });
    cancelled(options.signal);
    const captured = preparedResult ? null : candidate.reviewData;
    const mask = captured?.mask ?? decodeTiff(await fs.readFile(candidate.paths.mask));
    const { regions, runs } = connectedRegions(mask);
    const report = captured ?? JSON.parse(await fs.readFile(candidate.paths.report, 'utf8'));
    const attributed = attributeRegions({ regions, width: mask.width, height: mask.height }, runs, report.marks);
    const runsPath = path.join(job, 'regions-runs.bin');
    await fs.writeFile(runsPath, runs, { flag: 'wx', mode: 0o600 });
    const imageInfo = report.image;
    if (preparedResult) {
      const images = [];
      for (const filename of [sourcePath, candidate.paths.cleaned]) {
        const image = decodeTiff(await fs.readFile(filename));
        if (image.width !== mask.width || image.height !== mask.height || image.depth !== imageInfo?.depth || image.channels !== imageInfo?.channels) fail('已有分析结果与原始快照尺寸或位深不一致。');
        images.push(image);
      }
      if (!Buffer.from(images[0].icc || []).equals(Buffer.from(images[1].icc || []))) fail('已有分析结果的颜色描述与原始快照不一致。');
      // An adopted result must be for this exact frozen original, not simply a
      // different photograph having the same dimensions.
      for (let pixel = 0; pixel < mask.data.length; pixel++) if (!mask.data[pixel]) {
        for (let c = 0; c < images[0].channels; c++) {
          const index = pixel * images[0].channels + c;
          if (images[0].data[index] !== images[1].data[index]) fail('已有分析结果与原始快照不匹配，请重新分析。');
        }
      }
    }
    const assets = {};
    const assetFiles = { source: sourcePath, cleaned: candidate.paths.cleaned, mask: candidate.paths.mask, report: candidate.paths.report, runs: runsPath };
    if (captured?.digests.fibreMap && candidate.paths.fibreMap) assetFiles.fibreMap = candidate.paths.fibreMap;
    for (const [name, filename] of Object.entries(assetFiles)) {
      const digest = name === 'runs' ? { size: runs.length, sha256: sha256(runs) } : captured?.digests[name];
      assets[name] = await makeAsset(job, filename, digest);
      cancelled(options.signal);
    }
    if (expectedSource && (assets.source.size !== expectedSource.size || assets.source.sha256 !== expectedSource.sha256)) {
      fail('审核图像已被修改，请重新分析。');
    }
    const record = { schema: SCHEMA, version: 1, id, status: 'ready', createdAt: new Date().toISOString(),
      context, host, outputRoot: path.resolve(outputRoot), sourceName: displayName,
      width: mask.width, height: mask.height, depth: imageInfo.depth, channels: imageInfo.channels,
      regions: attributed, regionKindsVersion: 1, stats: candidate.stats, detectionSettings, assets,
      ...(captured && { rebateGeometry: captured.rebateGeometry }) };
    const reviewPath = path.join(job, 'review.json');
    await saveRecord(reviewPath, record, key);
    return { reviewPath, review: publicReview(record, job) };
  } catch (error) { await fs.rm(job, { recursive: true, force: true }); throw error; }
}

async function readReview(reviewPath, options = {}) {
  const actual = await fs.realpath(reviewPath);
  const explicitRoot = options.cacheRoot || workRootOverride();
  const roots = [options.cacheRoot || defaultCacheRoot()];
  if (!explicitRoot) roots.push(path.join(legacyWorkRoot(), 'reviews'));
  let root;
  for (const candidate of roots) {
    try {
      const resolved = await cacheLocation(candidate);
      if (/^[0-9a-f-]{36}[\/]review\.json$/i.test(path.relative(resolved, actual)) && inside(resolved, actual)) {
        root = resolved;
        break;
      }
    } catch (error) {
      if (explicitRoot || error.code !== 'ENOENT') throw error;
    }
  }
  if (!root) fail('审核文件不属于本工具的缓存目录。');
  const key = await signingKey(root);
  const stat = await fs.stat(actual);
  if (!stat.isFile() || stat.size > 16 * 1024 * 1024) fail('审核文件无效。');
  let envelope;
  try { envelope = JSON.parse(await fs.readFile(actual, 'utf8')); } catch { fail('审核文件损坏，请重新分析。'); }
  const { record, signature: signed } = envelope;
  if (!record || typeof signed !== 'string' || !/^[0-9a-f]{64}$/.test(signed)) fail('审核签名无效，请重新分析。');
  const expected = signature(record, key);
  if (!crypto.timingSafeEqual(Buffer.from(signed, 'hex'), Buffer.from(expected, 'hex'))) fail('审核文件已被修改，请重新分析。');
  if (record.schema !== SCHEMA || record.version !== 1 || path.basename(path.dirname(actual)) !== record.id || !['file', 'photocraft'].includes(record.context)) fail('不支持此审核文件。');
  const revising = options.reviseExport === true;
  if (revising && record.context !== 'file') fail('仅文件审核可以修订已导出的结果。');
  const recheckingFile = options.redetect === true && record.context === 'file';
  if (record.status !== 'ready' && !((revising || recheckingFile) && record.status === 'confirmed')) {
    fail(record.status === 'confirmed' ? '此预览已经确认，不能重复应用。' : '此预览正在确认，请稍后检查结果。');
  }
  if (record.context === 'photocraft') {
    const hostRoot = await fs.realpath(record.host.workDir);
    if (!inside(hostRoot, root)) fail('PhotoCraft 审核缓存不在原授权目录内。');
  }
  return { root, key, record, job: path.dirname(actual), reviewPath: actual };
}

async function reviewAssetPath(loaded, name) {
  const asset = loaded.record.assets[name];
  if (!asset || typeof asset.path !== 'string' || path.isAbsolute(asset.path)) fail('审核文件引用无效。');
  const filename = await fs.realpath(path.join(loaded.job, asset.path));
  if (!inside(loaded.job, filename)) fail('审核文件引用超出工作目录。');
  const stat = await fs.stat(filename);
  if (!stat.isFile() || stat.size !== asset.size || stat.size > 2_000_000_000) fail('审核图像已被修改，请重新分析。');
  return filename;
}

async function verifiedAsset(loaded, name) {
  const filename = await reviewAssetPath(loaded, name);
  const data = await fs.readFile(filename);
  if (sha256(data) !== loaded.record.assets[name].sha256) fail('审核图像已被修改，请重新分析。');
  return data;
}

async function originalDetectionSettings(loaded, report) {
  if (loaded.record.detectionSettings) return optionsChecked(loaded.record.detectionSettings);
  report ??= JSON.parse((await verifiedAsset(loaded, 'report')).toString('utf8'));
  return optionsChecked(report.settings ?? { detect: loaded.record.stats?.detection_types });
}

async function inspectReview(reviewPath, options = {}) {
  const loaded = await readReview(reviewPath, { cacheRoot: options.cacheRoot });
  for (const name of ['source', 'cleaned', 'mask', 'report', 'runs']) {
    const expected = loaded.record.assets[name];
    if (!expected || typeof expected.path !== 'string' || path.isAbsolute(expected.path)) fail('审核文件引用无效。');
    const actual = await makeAsset(loaded.job, path.join(loaded.job, expected.path));
    if (actual.path !== expected.path || actual.size !== expected.size || actual.sha256 !== expected.sha256) fail('审核图像已被修改，请重新分析。');
    cancelled(options.signal);
  }
  const record = loaded.record;
  const needsKinds = record.regionKindsVersion !== 1;
  const report = needsKinds || !record.detectionSettings ? JSON.parse((await verifiedAsset(loaded, 'report')).toString('utf8')) : undefined;
  const settings = record.detectionSettings ?? await originalDetectionSettings(loaded, report);
  const regions = needsKinds && record.regions.length && Array.isArray(report?.marks) && report.marks.length ?
    attributeRegions(record, await verifiedAsset(loaded, 'runs'), report.marks) : record.regions;
  cancelled(options.signal);
  return { reviewPath: loaded.reviewPath, review: publicReview({ ...record, regions }, loaded.job, settings) };
}

function checkedEdits(record, edits = {}) {
  if (!edits || typeof edits !== 'object' || Array.isArray(edits) || Object.keys(edits).some(k => k !== 'excludedRegions' && k !== 'strokes')) fail('审核修改格式无效。');
  const input = edits.excludedRegions ?? [];
  if (!Array.isArray(input) || input.length > record.regions.length) fail('排除点位列表无效。');
  const allowed = new Set(record.regions.map(r => r.id)), excluded = new Set();
  for (const id of input) {
    if (!Number.isInteger(id) || !allowed.has(id)) fail('排除列表包含未知灰尘点位。');
    excluded.add(id);
  }
  return { excludedRegions: [...excluded].sort((a, b) => a - b), strokes: checkedStrokes(edits.strokes ?? [], record) };
}

function runCount(runs, record) {
  if (!runs.subarray(0, 8).equals(RUN_MAGIC) || runs.length < 24 || runs.readUInt32LE(12) !== record.width ||
      runs.readUInt32LE(16) !== record.height || runs.readUInt32LE(20) !== record.regions.length) fail('审核点位索引损坏。');
  const count = runs.readUInt32LE(8);
  if (count > MAX_RUNS || runs.length !== 24 + count * 16) fail('审核点位索引长度无效。');
  return count;
}

function detectionKind(mark) {
  if (mark?.verdict !== 'defect') return undefined;
  if (mark.kind === 'scratch') return 'scratches';
  if (mark.kind === 'patch') return 'patches';
  if (mark.kind === 'hair/fibre' || mark.fibre === 'patch' || mark.fibreDisc === true) return 'fibers';
  if (['dust', 'speck', 'soft'].includes(mark.kind)) return 'dust';
  return undefined;
}

function attributeRegions(record, runs, marks) {
  if (!record.regions.length || !Array.isArray(marks) || !marks.length) return record.regions;
  const count = runCount(runs, record);
  const kinds = new Map();
  const row = index => runs.readUInt32LE(28 + 16 * index);
  for (const mark of marks) {
    const kind = detectionKind(mark);
    if (!kind || ![mark.x0, mark.y0, mark.x1, mark.y1].every(Number.isFinite)) continue;
    const x0 = Math.max(0, Math.floor(mark.x0)), y0 = Math.max(0, Math.floor(mark.y0));
    // Detector reports include both exclusive and inclusive upper coordinates.
    const x1 = Math.min(record.width, Math.floor(mark.x1) + 1), y1 = Math.min(record.height, Math.floor(mark.y1) + 1);
    if (x0 >= x1 || y0 >= y1) continue;
    let first = 0, end = count;
    while (first < end) {
      const middle = (first + end) >>> 1;
      if (row(middle) < y0) first = middle + 1;
      else end = middle;
    }
    const overlaps = new Map();
    let total = 0, best = 0, winner;
    for (let i = first; i < count && row(i) < y1; i++) {
      const at = 24 + 16 * i;
      const pixels = Math.min(x1, runs.readUInt32LE(at + 12)) - Math.max(x0, runs.readUInt32LE(at + 8));
      if (pixels <= 0) continue;
      const id = runs.readUInt32LE(at);
      const hits = (overlaps.get(id) ?? 0) + pixels;
      overlaps.set(id, hits);
      total += pixels;
      if (hits > best) { best = hits; winner = id; }
    }
    // Require a clear majority of the mask pixels inside the mark and a
    // material share of its reported area. A neighbouring spot inside a
    // mostly empty bounding box is not sufficient evidence of provenance.
    const minimum = Number.isFinite(mark.area) ? Math.max(1, Math.ceil(mark.area * 0.2)) : 1;
    if (best < minimum || best * 2 <= total) continue;
    if (!kinds.has(winner)) kinds.set(winner, new Set());
    kinds.get(winner).add(kind);
  }
  return record.regions.map(region => {
    const labels = kinds.get(region.id);
    return labels ? { ...region, kinds: DETECTION_KINDS.filter(kind => labels.has(kind)) } : region;
  });
}

async function remapExclusions(previous, next, ids, signal) {
  if (!ids.length) return [];
  const excluded = new Set(ids);
  const oldRuns = await verifiedAsset(previous, 'runs');
  const newRuns = await verifiedAsset(next, 'runs');
  const oldEnd = 24 + 16 * runCount(oldRuns, previous.record);
  const newEnd = 24 + 16 * runCount(newRuns, next.record);
  const overlap = new Map();
  let oldAt = 24, newAt = 24, checked = 0;
  while (oldAt < oldEnd && newAt < newEnd) {
    if (checked++ % 4096 === 0) { cancelled(signal); await yieldNow(); }
    const oldID = oldRuns.readUInt32LE(oldAt);
    const oldY = oldRuns.readUInt32LE(oldAt + 4), newY = newRuns.readUInt32LE(newAt + 4);
    const oldRight = oldRuns.readUInt32LE(oldAt + 12), newRight = newRuns.readUInt32LE(newAt + 12);
    if (oldY === newY && excluded.has(oldID)) {
      const left = Math.max(oldRuns.readUInt32LE(oldAt + 8), newRuns.readUInt32LE(newAt + 8));
      const pixels = Math.min(oldRight, newRight) - left;
      if (pixels > 0) {
        const newID = newRuns.readUInt32LE(newAt);
        if (!overlap.has(oldID)) overlap.set(oldID, new Map());
        const matches = overlap.get(oldID);
        matches.set(newID, (matches.get(newID) ?? 0) + pixels);
      }
    }
    if (oldY < newY || (oldY === newY && oldRight <= newRight)) oldAt += 16;
    if (newY < oldY || (oldY === newY && newRight <= oldRight)) newAt += 16;
  }
  // A match must cover most of both components. A small old exclusion cannot
  // hide an unrelated new correction when their components merge.
  const mapped = [];
  for (const [oldID, matches] of overlap) {
    for (const [newID, pixels] of matches) {
      if (2 * pixels > previous.record.regions[oldID - 1].pixels &&
          2 * pixels > next.record.regions[newID - 1].pixels) mapped.push(newID);
    }
  }
  return mapped.sort((a, b) => a - b);
}

async function redetectReview(reviewPath, edits = {}, { dustSensitivity, fiberSensitivity, scratchSensitivity,
  patchSensitivity = 1, fiberCurl = 1, fiberSoftness = 1, keepRebate = false, ...options } = {}) {
  if (typeof keepRebate !== 'boolean') fail('保留片边选项无效。');
  const targets = [dustSensitivity, fiberSensitivity, scratchSensitivity, patchSensitivity, fiberCurl, fiberSoftness];
  if (targets.some(value => !Number.isFinite(value) || value < 0.5 || value > 2)) {
    fail('重新检测的灵敏度必须在 0.5 到 2 之间。');
  }
  const previous = await readReview(reviewPath, { cacheRoot: options.cacheRoot, redetect: true });
  const { excludedRegions, strokes } = checkedEdits(previous.record, edits);
  const { polarity, sensitivity, detect } = await originalDetectionSettings(previous);
  const settings = {
    ...options, polarity, sensitivity, detect,
    ...(dustSensitivity === sensitivity ? {} : { dustSensitivity }),
    ...(fiberSensitivity === sensitivity ? {} : { fiberSensitivity }),
    ...(scratchSensitivity === 1 ? {} : { scratchSensitivity }),
    ...(patchSensitivity === 1 ? {} : { patchSensitivity }),
    ...(fiberCurl === 1 ? {} : { fiberCurl }),
    ...(fiberSoftness === 1 ? {} : { fiberSoftness }),
  };
  const { sourceName, outputRoot, context, host, assets } = previous.record;
  const inputPath = await reviewAssetPath(previous, 'source');
  const result = await prepareReview({ inputPath, sourceName, outputRoot, context, host, cacheRoot: previous.root,
    expectedSource: assets.source, options: settings });
  try {
    cancelled(options.signal);
    const next = await readReview(result.reviewPath, { cacheRoot: previous.root });
    const exclusions = await remapExclusions(previous, next, excludedRegions, options.signal);
    const preview = exclusions.length || strokes.length || keepRebate ? await renderReviewPreview(result.reviewPath,
      { excludedRegions: exclusions, strokes }, { cacheRoot: previous.root, signal: options.signal, keepRebate }) : undefined;
    cancelled(options.signal);
    return { ...result, excludedRegions: exclusions, preview, unmatchedExclusions: excludedRegions.length - exclusions.length };
  } catch (error) {
    await fs.rm(path.dirname(result.reviewPath), { recursive: true, force: true });
    throw error;
  }
}

async function recompose(loaded, edits, options = {}) {
  const { record } = loaded;
  if (options.keepRebate !== undefined && typeof options.keepRebate !== 'boolean') fail('保留片边选项无效。');
  if (options.keepRebate === false && record.detectionSettings?.keepRebate) fail('旧检测结果已应用片边保护。请重新检测一次后再切换。');
  const { excludedRegions, strokes } = checkedEdits(record, edits), excluded = new Set(excludedRegions);
  const source = await decodeTiffForWork(await verifiedAsset(loaded, 'source'), options);
  const candidate = decodeTiff(await verifiedAsset(loaded, 'cleaned'));
  const originalMask = decodeTiff(await verifiedAsset(loaded, 'mask'));
  const runs = await verifiedAsset(loaded, 'runs');
  for (const image of [source, candidate]) {
    if (image.width !== record.width || image.height !== record.height || image.channels !== record.channels || image.depth !== record.depth) fail('审核图像尺寸或位深已改变。');
  }
  const count = runCount(runs, record);
  // Fit old caches on demand; new reviews already have the frame geometry.
  const rebate = options.keepRebate ? (Object.hasOwn(record, 'rebateGeometry') ?
    protectionFromGeometry(record.rebateGeometry, record.width, record.height) :
    buildFrameProtection(source.data, record.width, record.height, source.channels, { relaxed: true })) : null;
  const insideRebateBoundary = rebate ? new Uint8Array(record.regions.length + 1) : null;
  // The signed candidate already contains original pixels outside the
  // detected mask. Patch its private decode in place to avoid another
  // full-resolution allocation for each brush preview.
  const data = candidate.data, mask = originalMask.data;
  let changedPixels = 0, acceptedPixels = 0, rebatePixels = 0;
  for (let r = 0; r < count; r++) {
    const at = 24 + r * 16, id = runs.readUInt32LE(at), y = runs.readUInt32LE(at + 4), x0 = runs.readUInt32LE(at + 8), x1 = runs.readUInt32LE(at + 12);
    if (id < 1 || id > record.regions.length || y >= record.height || x0 >= x1 || x1 > record.width) fail('审核点位坐标无效。');
    const keepRegion = !excluded.has(id);
    for (let x = x0; x < x1; x++) {
      const pixel = y * record.width + x;
      if (!mask[pixel]) fail('审核点位不在灰尘蒙版中。');
      const protectedPixel = rebate?.protects(pixel);
      if (protectedPixel) rebatePixels++;
      else if (insideRebateBoundary) insideRebateBoundary[id] = 1;
      const keep = keepRegion && !protectedPixel;
      mask[pixel] = keep ? 65535 : 0;
      if (keep) acceptedPixels++;
      let changed = false;
      for (let c = 0; c < source.channels; c++) {
        const index = pixel * source.channels + c;
        if (!keep) data[index] = source.data[index];
        if (data[index] !== source.data[index]) changed = true;
      }
      if (changed) changedPixels++;
    }
    if (r % 1024 === 0) { cancelled(options.signal); await yieldNow(); }
  }
  const { changedDelta, addedPixels, restoredPixels } = strokes.length ?
    await applyStrokes(source, data, mask, strokes, options.signal) : { changedDelta: 0, addedPixels: 0, restoredPixels: 0 };
  cancelled(options.signal);
  const protectedRegions = insideRebateBoundary ? record.regions.filter(region => !insideRebateBoundary[region.id]).map(region => region.id) : [];
  const retainedRegions = record.regions.length - excluded.size - protectedRegions.filter(id => !excluded.has(id)).length;
  return { cleaned: { ...source, data }, mask: { ...originalMask, data: mask }, excludedRegions,
    retainedRegions, protectedRegions, rebate, rebatePixels, changedPixels: changedPixels + changedDelta,
    acceptedPixels: acceptedPixels + addedPixels - restoredPixels, manualStrokes: strokes.length, addedPixels, restoredPixels };
}

async function writeStage(loaded, composed, prefix, options) {
  cancelled(options.signal);
  await requireWorkSpace(loaded.job, composed.cleaned);
  const stage = await fs.mkdtemp(path.join(loaded.job, prefix));
  const paths = { cleaned: path.join(stage, 'cleaned.tiff'), mask: path.join(stage, 'dust-mask.tiff'), report: path.join(stage, 'report.json') };
  try {
    await fs.writeFile(paths.cleaned, encodeTiff(composed.cleaned), { flag: 'wx', mode: 0o600 });
    cancelled(options.signal);
    await fs.writeFile(paths.mask, encodeTiff(composed.mask), { flag: 'wx', mode: 0o600 });
    const originalReport = JSON.parse((await verifiedAsset(loaded, 'report')).toString('utf8'));
    const stats = { ...loaded.record.stats, changed_pixels: composed.changedPixels, healed_pixels: composed.acceptedPixels,
      review_regions: loaded.record.regions.length, excluded_regions: composed.excludedRegions.length, retained_regions: composed.retainedRegions,
      manual_strokes: composed.manualStrokes, added_pixels: composed.addedPixels, restored_pixels: composed.restoredPixels,
      rebate_protected_pixels: composed.rebatePixels };
    const confirmed = prefix.startsWith('confirmed');
    await fs.writeFile(paths.report, JSON.stringify({ ...originalReport, version, stats,
      review: { id: loaded.record.id, excludedRegions: composed.excludedRegions, retainedRegions: composed.retainedRegions, confirmed,
        ...(confirmed && { format: options.format }) } }, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
    cancelled(options.signal);
    return { outputDir: stage, paths, stats, changed: composed.changedPixels > 0 };
  } catch (error) { await fs.rm(stage, { recursive: true, force: true }); throw error; }
}

async function renderReviewPreview(reviewPath, edits = {}, options = {}) {
  const loaded = await readReview(reviewPath, options);
  const composed = await recompose(loaded, edits, options);
  const result = await writeStage(loaded, composed, 'preview-', options);
  return { cleanedPath: result.paths.cleaned, maskPath: result.paths.mask, excludedRegions: composed.excludedRegions,
    retainedRegions: composed.retainedRegions, protectedRegions: composed.protectedRegions, changed: result.changed, stats: result.stats };
}

// [Claude 2026-11-08] Training pack: everything a FibreNet retrain needs from one exported
// photo, written beside it as "<name>-PN-training/". The layers say exactly what the
// detector proposed, what the user took back, and what the user painted in or erased, so
// a retrain no longer guesses them from a before/after difference or needs the app's cache.
const TRAINING_LABELS = ['clean', 'test', 'category', 'note'];
function checkedTrainingLabels(labels) {
  if (labels === undefined || labels === null) return {};
  if (typeof labels !== 'object' || Array.isArray(labels) || Object.keys(labels).some(k => !TRAINING_LABELS.includes(k))) fail('训练标签格式无效。');
  const out = {};
  for (const k of ['clean', 'test']) if (labels[k] !== undefined) {
    if (typeof labels[k] !== 'boolean') fail('训练标签格式无效。');
    out[k] = labels[k];
  }
  for (const k of ['category', 'note']) if (labels[k] !== undefined) {
    if (typeof labels[k] !== 'string' || labels[k].length > 200) fail('训练标签格式无效。');
    out[k] = labels[k];
  }
  return out;
}

async function writeTrainingPack(loaded, composed, folder, labels, options, progress) {
  const { signal } = options;
  const { record } = loaded, W = record.width, H = record.height, N = W * H;
  const auto = decodeTiff(await verifiedAsset(loaded, 'mask'));
  const runs = await verifiedAsset(loaded, 'runs');
  const sourceBytes = await verifiedAsset(loaded, 'source'), source = await decodeTiffForWork(sourceBytes, options);
  const prob = record.assets.fibreMap ? await verifiedAsset(loaded, 'fibreMap') : null;
  const excluded = new Set(composed.excludedRegions);
  const finalMask = composed.mask.data;
  const layer = () => new Uint16Array(N);
  const undone = layer(), added = layer(), erased = layer(), autoLayer = layer();
  const owner = new Uint32Array(N);
  const count = runCount(runs, record);
  for (let r = 0; r < count; r++) {
    const at = 24 + r * 16, id = runs.readUInt32LE(at), y = runs.readUInt32LE(at + 4);
    for (let x = runs.readUInt32LE(at + 8), x1 = runs.readUInt32LE(at + 12); x < x1; x++) owner[y * W + x] = id;
    if (r % 4096 === 0) { cancelled(signal); await yieldNow(); }
  }
  const protectedRegions = new Set(composed.protectedRegions);
  const regions = new Map(record.regions.map(r => [r.id, { ...r, kept: !excluded.has(r.id) && !protectedRegions.has(r.id), probMax: 0, probSum: 0, n: 0 }]));
  let changedOutside = 0, finalPixels = 0;
  const C = source.channels;
  for (let p = 0; p < N; p++) {
    // A frame protection choice is not a manual negative example.
    const isAuto = auto.data[p] > 0 && (!composed.rebate?.protects(p) || excluded.has(owner[p])), isFinal = finalMask[p] > 0;
    if (isAuto) autoLayer[p] = 65535;
    if (isFinal) finalPixels++;
    if (isAuto && !isFinal) (excluded.has(owner[p]) ? undone : erased)[p] = 65535;
    if (!isAuto && isFinal) added[p] = 65535;
    if (!isFinal) {
      for (let c = 0; c < C; c++) if (composed.cleaned.data[p * C + c] !== source.data[p * C + c]) { changedOutside++; break; }
    }
    if (prob && owner[p]) {
      const g = regions.get(owner[p]);
      if (g) { const v = prob[p]; g.probSum += v; g.n++; if (v > g.probMax) g.probMax = v; }
    }
    if (p % 4_000_000 === 0) { cancelled(signal); await yieldNow(); }
  }
  const sum = a => { let n = 0; for (let i = 0; i < a.length; i++) if (a[i]) n++; return n; };
  const grey = data => encodeTiff({ width: W, height: H, channels: 1, depth: 16, data });
  // The layers are mostly empty: gzip turns each 100 MB 16-bit mask into well under 1 MB.
  progress(0.88, '正在压缩训练数据包');
  const gz = bytes => require('node:zlib').gzipSync(bytes, { level: 6 });
  const files = {
    'source.tiff': sourceBytes, 'mask-auto.tiff.gz': gz(grey(autoLayer)), 'mask-undone.tiff.gz': gz(grey(undone)),
    'mask-added.tiff.gz': gz(grey(added)), 'mask-erased.tiff.gz': gz(grey(erased)), 'mask-final.tiff.gz': gz(grey(finalMask)),
  };
  if (prob) files['fibre-map.u8.gz'] = gz(prob);
  for (const [name, bytes] of Object.entries(files)) {
    await fs.writeFile(path.join(folder, name), bytes, { flag: 'wx' });
    cancelled(signal); await yieldNow();
  }
  const report = JSON.parse((await verifiedAsset(loaded, 'report')).toString('utf8'));
  const marks = (report.marks ?? []).filter(m => m?.verdict === 'defect').map(m => ({
    kind: m.kind, x0: m.x0, y0: m.y0, x1: m.x1, y1: m.y1, area: m.area, learned: m.learned === true || undefined, fibre: m.fibre }));
  const pack = {
    schema: 'pureneg-training-pack', version: 1, app: version, createdAt: new Date().toISOString(),
    sourceName: record.sourceName, width: W, height: H, depth: record.depth, channels: record.channels,
    sourceSha256: record.assets.source.sha256, detectionSettings: record.detectionSettings ?? null,
    labels, timings: report.stats?.timings ?? null,
    checks: { sameSizeAsExport: composed.cleaned.width === W && composed.cleaned.height === H,
      changedOutsideMask: changedOutside, usable: changedOutside === 0 },
    pixels: { auto: sum(autoLayer), undone: sum(undone), erased: sum(erased), added: sum(added), final: finalPixels },
    strokes: composed.manualStrokes,
    fibreMap: prob ? { file: 'fibre-map.u8.gz', format: 'gzip of uint8, row-major, width x height, 0-255 = probability' } : null,
    regions: [...regions.values()].map(({ probSum, n, probMax, ...g }) => ({ ...g,
      ...(prob && n ? { probMean: Math.round(probSum / n), probMax } : {}) })),
    marks,
    layers: { 'mask-auto.tiff.gz': '软件自动识别要修的地方', 'mask-undone.tiff.gz': '用户撤销的自动修复（不是缺陷）',
      'mask-erased.tiff.gz': '用户用橡皮擦去的自动修复', 'mask-added.tiff.gz': '用户用画笔补修的（模型漏掉的）',
      'mask-final.tiff.gz': '最终修复范围（16 位灰度 TIFF，gzip 压缩）', 'source.tiff': '原始扫描（未修）' },
  };
  await fs.writeFile(path.join(folder, 'pack.json'), JSON.stringify(pack, null, 2) + '\n', { flag: 'wx' });
  return { folder, usable: pack.checks.usable };
}

function checkedExportSettings(settings, format) {
  if (settings === undefined || settings === null) return [];
  if (typeof settings !== 'object' || Array.isArray(settings)) fail('导出设置格式无效。');
  const allowed = { space: ['keep', 'srgb', 'p3', 'adobergb'], depth: ['keep', '8', '16'], compression: ['none', 'lzw'] };
  const out = [];
  for (const [key, value] of Object.entries(settings)) {
    if (key === 'quality') {
      if (!Number.isFinite(value) || value < 0.5 || value > 1) fail('JPEG 质量必须在 0.5 到 1 之间。');
      if (format === 'jpeg' && value !== 0.95) out.push('quality=' + value);
      continue;
    }
    if (!allowed[key] || !allowed[key].includes(String(value))) fail('导出设置格式无效。');
    if (key === 'depth' && (format === 'jpeg' || value === 'keep')) continue;
    if (key === 'compression' && (format !== 'tiff' || value === 'none')) continue;
    if (key === 'space' && value === 'keep') continue;
    out.push(key + '=' + value);
  }
  return out;
}

async function confirmReview(reviewPath, edits = {}, options = {}) {
  const format = options.format ?? 'tiff';
  if (!['tiff', 'jpeg', 'png'].includes(format)) fail('请选择 TIFF、JPEG 或 PNG 导出。');
  const loaded = await readReview(reviewPath, options), lockPath = path.join(loaded.job, 'confirm.lock');
  if (loaded.record.context === 'photocraft' && format !== 'tiff') fail('导回 PhotoCraft 需要 TIFF。');
  if (options.outputRoot !== undefined) {
    if (loaded.record.context !== 'file') fail('仅文件审核可以在确认时更改保存位置。');
    if (typeof options.outputRoot !== 'string' || !options.outputRoot || options.outputRoot.includes('\0')) fail('请选择有效的结果保存目录。');
  }
  if (options.includeMask !== undefined &&
      (loaded.record.context !== 'file' || typeof options.includeMask !== 'boolean')) fail('仅文件审核可以选择是否导出蒙版。');
  if (options.trainingPack !== undefined && (typeof options.trainingPack !== 'boolean' || options.includeMask === undefined)) fail('仅应用导出可以附带训练数据包。');
  const trainingLabels = checkedTrainingLabels(options.trainingLabels);
  // [Claude 2026-11-09] Export settings (app exports): colour space, bit depth, TIFF compression,
  // JPEG quality. All "keep" (the default) writes the photo exactly as before.
  const exportSettings = checkedExportSettings(options.exportSettings, format);
  const progress = (fraction, message) => options.onProgress?.({ fraction, message });
  let trainingPack;
  let lock;
  try { lock = await fs.open(lockPath, 'wx', 0o600); }
  catch (error) { if (error.code === 'EEXIST') fail('此预览正在确认，请勿重复应用。'); throw error; }
  let ownedOutputDir = null, ownedTrainingFolder = null, stage = null, previous = null;
  const written = [];
  try {
    // Another process could have completed confirmation between initial read
    // and lock acquisition; re-read the signed state under the lock.
    const current = await readReview(reviewPath, options);
    const composed = await recompose(current, edits, options);
    await saveRecord(current.reviewPath, { ...current.record, status: 'confirming' }, current.key);
    previous = current;
    progress(0.28, '正在生成导出图像');
    stage = await writeStage(current, composed, 'confirmed-', { ...options, format });
    // An explicit mask choice is the standalone app's photo export.
    // Without that choice, keep the established CLI/PhotoCraft sidecars.
    const exportPaths = options.includeMask === undefined ? { ...stage.paths } : { cleaned: stage.paths.cleaned };
    if (options.includeMask === true) exportPaths.mask = stage.paths.mask;
    if (format !== 'tiff' || exportSettings.length) {
      exportPaths.cleaned = path.join(stage.outputDir, format === 'jpeg' ? 'cleaned.jpg' : format === 'png' ? 'cleaned.png' : 'exported.tiff');
      progress(0.55, '正在转换导出格式或色彩');
      await runImageCodec(['export', stage.paths.cleaned, exportPaths.cleaned, format, ...exportSettings], options.signal);
    }
    progress(0.67, '正在写入照片文件');
    const destination = options.outputRoot === undefined ? current.record.outputRoot : path.resolve(options.outputRoot);
    await fs.mkdir(destination, { recursive: true });
    const paths = {};
    if (options.includeMask === undefined) {
      // CLI and PhotoCraft: a folder of their own with the established sidecar names.
      ownedOutputDir = await fs.mkdtemp(path.join(destination, 'PURENeg-reviewed-'));
      for (const [name, filename] of Object.entries(exportPaths)) {
        cancelled(options.signal);
        paths[name] = path.join(ownedOutputDir, path.basename(filename));
        await fs.copyFile(filename, paths[name], fsConstants.COPYFILE_EXCL);
      }
    } else {
      // [Claude 2026-11-08] The app's photo export goes straight into the chosen folder,
      // named after the scan: "scan-PN.jpg" (and "scan-PN-mask.tiff"), so a batch of many
      // frames is one folder of photos rather than a folder per photo. A name already taken
      // gets a number: "scan-PN-2.jpg".
      const stem = path.basename(current.record.sourceName || 'scan').replace(/\.[^.]*$/, '') || 'scan';
      const ext = path.extname(exportPaths.cleaned);
      const names = n => {
        const base = stem + '-PN' + (n > 1 ? '-' + n : '');
        return { cleaned: base + ext, mask: base + '-mask.tiff', trainingPack: base + '-training' };
      };
      const requested = Object.keys(exportPaths);
      if (options.trainingPack) requested.push('trainingPack');
      let n = 1;
      for (;; n++) {
        const candidates = names(n);
        const taken = await Promise.all(requested.map(name =>
          fs.lstat(path.join(destination, candidates[name])).then(() => true, error => {
            if (error.code === 'ENOENT') return false;
            throw error;
          })));
        if (!taken.some(Boolean)) break;
        if (n > 9999) fail('导出文件名已被占用。');
      }
      const chosen = names(n);
      for (const [name, filename] of Object.entries(exportPaths)) {
        cancelled(options.signal);
        paths[name] = path.join(destination, chosen[name]);
        await fs.copyFile(filename, paths[name], fsConstants.COPYFILE_EXCL);
        written.push(paths[name]);
      }
      if (options.trainingPack) {
        // Never costs the user the photo itself: a pack that cannot be written is
        // reported, and the exported photo stays.
        cancelled(options.signal);
        const folder = path.join(destination, chosen.trainingPack);
        try {
          await fs.mkdir(folder);
          ownedTrainingFolder = folder;
          progress(0.78, '正在生成训练数据包');
          trainingPack = await writeTrainingPack(current, composed, folder, trainingLabels, options, progress);
          paths.trainingPack = folder;
        } catch (error) {
          if (error?.name === 'AbortError') throw error;
          if (ownedTrainingFolder) {
            await fs.rm(ownedTrainingFolder, { recursive: true, force: true }).catch(() => {});
            ownedTrainingFolder = null;
          }
          trainingPack = { error: error.message };
        }
      }
    }
    progress(0.94, '正在完成导出');
    cancelled(options.signal);
    const result = { outputDir: ownedOutputDir ?? destination, paths, format, stats: stage.stats, changed: stage.changed, trainingPack,
      excludedRegions: composed.excludedRegions, retainedRegions: composed.retainedRegions, protectedRegions: composed.protectedRegions,
      context: current.record.context, host: current.record.host, stagedPaths: stage.paths };
    await saveRecord(current.reviewPath, { ...current.record, status: 'confirmed', confirmedAt: new Date().toISOString(), result }, current.key);
    return result;
  } catch (error) {
    for (const file of written) await fs.rm(file, { force: true }).catch(() => {});
    if (ownedOutputDir) await fs.rm(ownedOutputDir, { recursive: true, force: true }).catch(() => {});
    if (ownedTrainingFolder) await fs.rm(ownedTrainingFolder, { recursive: true, force: true }).catch(() => {});
    if (stage) await fs.rm(stage.outputDir, { recursive: true, force: true }).catch(() => {});
    // Restore the state read under the lock, including any earlier export.
    if (previous) await saveRecord(previous.reviewPath, previous.record, previous.key).catch(() => {});
    throw error;
  } finally { await lock.close(); await fs.rm(lockPath, { force: true }); }
}

module.exports = { prepareReview, inspectReview, redetectReview, renderReviewPreview, confirmReview, connectedRegions, defaultCacheRoot };
