'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { setImmediate: yieldNow } = require('node:timers/promises');
const { cleanScan, doubtful } = require('../vendor/film-dust/engine/pipeline');
const scale = require('../vendor/film-dust/engine/scale');
const { healLarge } = require('../vendor/film-dust/engine/bigheal');
const { subtractFull } = require('../vendor/film-dust/engine/discs');
const native = require('../vendor/film-dust/engine/native');
const { buildFrameProtection } = require('./frame-guard.cjs');
const { protectSceneStructures } = require('./structure-guard.cjs');
const UPSTREAM = require('../vendor/film-dust/UPSTREAM.json');
const DEFECT_TYPES = ['dust', 'scratches', 'fibers'];
const AVAILABLE_DEFECT_TYPES = [...DEFECT_TYPES, 'patches'];
// [Claude 2026-11-09] fiberCurl / fiberSoftness: how curled and how soft or wide a line may be
// and still be taken for a fibre (1 = the tested defaults; 0.5 to 2 like the sensitivities).
const SENSITIVITY_OPTIONS = ['dustSensitivity', 'fiberSensitivity', 'scratchSensitivity', 'patchSensitivity', 'fiberCurl', 'fiberSoftness'];

function cancelled(signal) {
  if (signal?.aborted) {
    const error = new Error('处理已取消，原始文件未修改。');
    error.name = 'AbortError';
    throw error;
  }
}

function optionsChecked(options) {
  const polarity = options.polarity ?? 'auto';
  const sensitivity = options.sensitivity ?? 1;
  const selection = options.detect ?? DEFECT_TYPES;
  const detect = typeof selection === 'string' ? selection.split(',') : selection;
  if (!['auto', 'bright', 'dark'].includes(polarity)) throw new Error('灰尘类型必须是 auto、bright 或 dark。');
  const overrides = {};
  for (const key of SENSITIVITY_OPTIONS) {
    if (options[key] !== undefined) overrides[key] = options[key];
  }
  if ([sensitivity, ...Object.values(overrides)].some(value => !Number.isFinite(value) || value < 0.5 || value > 2)) {
    throw new Error('灵敏度必须在 0.5 到 2 之间。');
  }
  if (!Array.isArray(detect) || !detect.length || new Set(detect).size !== detect.length || detect.some(kind => !AVAILABLE_DEFECT_TYPES.includes(kind))) {
    throw new Error('至少选择一项识别类型：dust、scratches、fibers、patches。');
  }
  if (options.keepRebate !== undefined && typeof options.keepRebate !== 'boolean') throw new Error('保留片边选项无效。');
  return { polarity, sensitivity, ...overrides, ...(options.keepRebate ? { keepRebate: true } : {}),
    detect: AVAILABLE_DEFECT_TYPES.filter(kind => detect.includes(kind)) };
}

function checkImage(image) {
  const { width, height, channels, depth, data } = image;
  const colorChannels = image.colorChannels ?? (image.alpha ? channels - 1 : channels);
  if (!Number.isSafeInteger(width) || !Number.isSafeInteger(height) || width < 1 || height < 1 || width * height > 300_000_000) throw new Error('图像尺寸无效或超过 300MP。');
  if (![8, 16].includes(depth) || ![1, 3].includes(colorChannels) || channels !== colorChannels + (image.alpha ? 1 : 0)) throw new Error('首版支持 8/16 位 RGB 或灰度 TIFF。');
  if (!(data instanceof Uint16Array) || data.length !== width * height * channels) throw new Error('像素数据长度与图像尺寸不符。');
  if (image.alpha) {
    // A duplicate translucent repair layer would change composited opacity, even
    // when its RGB samples match. Reject it rather than alter transparency.
    for (let i = channels - 1; i < data.length; i += channels) {
      if (data[i] !== 65535) throw new Error('首版仅处理不透明扫描件；请先在 PhotoCraft 中将透明背景合并，再导出 TIFF。');
    }
  }
  return colorChannels;
}

function stageText(text) {
  const labels = [
    ['measuring the grain', '分析胶片颗粒'], ['looking for white dust', '查找白色灰尘'],
    ['looking for black dust', '查找黑色灰尘'], ['looking for out-of-focus dust', '查找失焦灰尘'],
    ['looking for faint soft dust', '查找柔和灰斑'], ['healing', '修补灰尘'],
  ];
  const label = labels.find(([prefix]) => String(text).startsWith(prefix));
  return label ? label[1] + (String(text).includes('pass 2') ? ' · 第二遍' : '') : '分析与修补';
}

function colorCopy(image, C) {
  if (C === image.channels) return image.data;
  const out = new Uint16Array(image.width * image.height * C);
  for (let i = 0; i < image.width * image.height; i++) {
    for (let c = 0; c < C; c++) out[i * C + c] = image.data[i * image.channels + c];
  }
  return out;
}

function boxFrom(src, W, C, x0, y0, x1, y1) {
  const out = new Uint16Array((x1 - x0) * (y1 - y0) * C);
  for (let y = y0; y < y1; y++) out.set(src.subarray((y * W + x0) * C, (y * W + x1) * C), (y - y0) * (x1 - x0) * C);
  return out;
}

function putBox(dst, W, C, x0, y0, x1, y1, values) {
  const row = (x1 - x0) * C;
  for (let y = y0; y < y1; y++) dst.set(values.subarray((y - y0) * row, (y - y0 + 1) * row), (y * W + x0) * C);
}

// The original final mask is part of the rendering contract: low-level soft
// disc subtraction also changes samples below its visible-mask threshold.
function composeMasked(original, repaired, mask, C, { out = Uint16Array.from(original.data), maskData, frame } = {}) {
  let changedPixels = 0, framePixels = 0, maskedPixels = 0;
  for (let i = 0; i < mask.length; i++) {
    if (!mask[i]) continue;
    if (frame?.protects(i)) {
      mask[i] = 0;
      framePixels++;
      continue;
    }
    if (maskData) maskData[i] = 65535;
    maskedPixels++;
    let changed = false;
    for (let c = 0; c < C; c++) {
      const value = repaired[i * C + c];
      if (out[i * original.channels + c] !== value) changed = true;
      out[i * original.channels + c] = value;
    }
    if (changed) changedPixels++;
  }
  return { data: out, changedPixels, framePixels, maskedPixels };
}

// [Claude 2026-11-08] A catchlight is a small, round, bright speck on a dark ground, which
// by itself is exactly what dust looks like (the learned model rated the ones users erased
// 0.78-0.99). Repairs inside an eye found by eyesIn are taken back; dust that really lies
// in an eye is rare and left to the brush. Returns the pixels taken back from the mask.
function protectEyes(mask, width, height, marks, eyes) {
  // [Claude 2026-11-09] Only compact repairs are taken back: a catchlight is a small round
  // speck inside the eye. A repair that is long and thin, or runs out of the eye, is a fibre
  // crossing it and stays repaired.
  let pixels = 0;
  for (const { x, y, r } of eyes || []) {
    if (![x, y, r].every(Number.isFinite) || r <= 0) continue;
    const reach = Math.ceil(3 * r);
    const wx0 = Math.max(0, Math.floor(x - reach)), wx1 = Math.min(width - 1, Math.ceil(x + reach));
    const wy0 = Math.max(0, Math.floor(y - reach)), wy1 = Math.min(height - 1, Math.ceil(y + reach));
    const ww = wx1 - wx0 + 1, wh = wy1 - wy0 + 1;
    const seen = new Uint8Array(ww * wh);
    const inEye = (qx, qy) => (qx - x) ** 2 + (qy - y) ** 2 <= r * r;
    for (let sy = wy0; sy <= wy1; sy++) for (let sx = wx0; sx <= wx1; sx++) {
      const start = (sy - wy0) * ww + (sx - wx0);
      if (seen[start] || !mask[sy * width + sx] || !inEye(sx, sy)) continue;
      // The repair this pixel belongs to, within the window around the eye.
      const stack = [start], piece = [];
      seen[start] = 1;
      let bx0 = sx, bx1 = sx, by0 = sy, by1 = sy, leaves = false;
      while (stack.length) {
        const i = stack.pop(), qx = wx0 + (i % ww), qy = wy0 + ((i / ww) | 0);
        piece.push(qy * width + qx);
        if (!inEye(qx, qy)) leaves = true;
        if (qx < bx0) bx0 = qx; if (qx > bx1) bx1 = qx; if (qy < by0) by0 = qy; if (qy > by1) by1 = qy;
        if (qx === wx0 || qx === wx1 || qy === wy0 || qy === wy1) leaves = true;
        for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
          const nx = qx + dx, ny = qy + dy;
          if (nx < wx0 || nx > wx1 || ny < wy0 || ny > wy1) continue;
          const j = (ny - wy0) * ww + (nx - wx0);
          if (!seen[j] && mask[ny * width + nx]) { seen[j] = 1; stack.push(j); }
        }
      }
      const long = Math.max(bx1 - bx0, by1 - by0) + 1, short = Math.min(bx1 - bx0, by1 - by0) + 1;
      if (leaves || long > 3 * short + 2) continue;   // a fibre crossing the eye
      for (const index of piece) { mask[index] = 0; pixels++; }
    }
    for (const mark of marks) {
      if (mark.verdict !== 'defect' || (mark.cx - x) ** 2 + (mark.cy - y) ** 2 > r * r) continue;
      if (mark.area > Math.PI * r * r) continue;   // A fibre crossing the eye keeps the rest of its repair.
      if (mark.kind === 'hair/fibre' && mark.length && mark.length > 2 * r) continue;
      mark.verdict = 'keep-photo';
      mark.why = 'a catchlight in an eye';
    }
  }
  return pixels;
}

// [Claude 2026-11-08] The eyes in a scan, from macOS Vision through the image codec. None
// where the codec is missing (tests, an unbuilt checkout), too old, or finds no face.
async function eyesIn(inputPath, signal) {
  if (process.platform !== 'darwin') return [];
  const { runImageCodec } = require('./image-codec.cjs');
  const dir = await fs.mkdtemp(path.join(require('node:os').tmpdir(), 'pureneg-eyes-'));
  try {
    const output = path.join(dir, 'eyes.json');
    await runImageCodec(['eyes', inputPath, output], signal);
    const eyes = JSON.parse(await fs.readFile(output, 'utf8'));
    return Array.isArray(eyes) ? eyes.filter(eye => [eye?.x, eye?.y, eye?.r].every(Number.isFinite)) : [];
  } catch (error) {
    if (error?.name === 'AbortError') throw error;
    return [];
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
}

// [Claude 2026-11-08] The learned dust/fibre map (one byte per pixel, 0-255) from the
// FibreNet model through the image codec. Null where the codec or the model is missing;
// the fibre tracer then finds its starting points by its own ridge detector alone.
async function fibreMapIn(inputPath, signal) {
  if (process.platform !== 'darwin') return null;
  const { runImageCodec } = require('./image-codec.cjs');
  const dir = await fs.mkdtemp(path.join(require('node:os').tmpdir(), 'pureneg-fibremap-'));
  try {
    const output = path.join(dir, 'map.u8');
    await runImageCodec(['fibremap', inputPath, output], signal);
    return new Uint8Array(await fs.readFile(output));
  } catch (error) {
    if (error?.name === 'AbortError') throw error;
    return null;
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
}

function keepFrameMarks(marks, frame, width, height) {
  for (const mark of marks) {
    if (mark.verdict !== 'defect') continue;
    const x0 = Math.max(0, Math.floor(mark.x0)), x1 = Math.min(width - 1, Math.ceil(mark.x1) - 1);
    const y0 = Math.max(0, Math.floor(mark.y0)), y1 = Math.min(height - 1, Math.ceil(mark.y1) - 1);
    if (x0 > x1 || y0 > y1 || ![y0 * width + x0, y0 * width + x1, y1 * width + x0, y1 * width + x1].every(frame.protects)) continue;
    mark.verdict = 'keep-photo';
    mark.why = 'inside the verified film rebate';
  }
}

async function processScan(image, options = {}, { reuseInput = false, captureReview = false, modelInputs } = {}) {
  const settings = optionsChecked(options);
  const detectDust = settings.detect.includes('dust'), detectFibers = settings.detect.includes('fibers');
  const detectUpstream = detectDust || detectFibers;
  const C = checkImage(image), W = image.width, H = image.height;
  const wantsPatches = settings.detect.includes('patches') && settings.polarity !== 'dark';
  const detectPatches = wantsPatches && options.fibreMap?.length === W * H;
  let lastProgress = 0;
  const onProgress = (event) => {
    lastProgress = Math.max(lastProgress, Math.min(1, Math.max(0, event.fraction)));
    options.onProgress?.({ ...event, fraction: lastProgress });
  };
  const tick = async () => { cancelled(options.signal); await yieldNow(); cancelled(options.signal); };
  cancelled(options.signal);
  const t0 = performance.now();
  const colors = colorCopy(image, C);
  const frame = buildFrameProtection(colors, W, H, C, { relaxed: settings.keepRebate === true });
  const rebate = captureReview && (settings.keepRebate ? frame : buildFrameProtection(colors, W, H, C, { relaxed: true }));
  // The low-memory mode also uses the existing tiled full-resolution repair
  // path on large scans that ordinarily run the detector at full resolution.
  const factor = options.conserveMemory && W * H > 64_000_000 ? 2 : 1;
  const detectorFactor = Math.max(factor, scale.workingFactor(W, H));
  const k = (detectUpstream || detectPatches) && Math.min(W, H) >= detectorFactor ? detectorFactor : 1;
  const Wd = Math.floor(W / k), Hd = Math.floor(H / k);
  let work;
  if (k === 1) work = Uint16Array.from(colors);
  else {
    work = new Uint16Array(Wd * Hd * C);
    scale.averageStrip(colors, W, H, C, k, work, Wd, 0, false);
  }
  onProgress({ fraction: 0.05, message: '读取完成，开始分析扫描件' });
  const analysis = (detectUpstream || detectPatches) ? await cleanScan(work, Wd, Hd, C, {
    polarity: settings.polarity, sensitivity: settings.sensitivity,
    dustSensitivity: detectDust ? settings.dustSensitivity : undefined,
    fiberSensitivity: detectFibers ? settings.fiberSensitivity : undefined,
    detectDust: detectDust || !detectUpstream, detectFibers, heal: detectUpstream, softPath: detectUpstream, scanMp: W * H / 1e6,
  }, {
    tick,
    progress: (fraction, message) => onProgress({ fraction: 0.05 + fraction * (k > 1 ? 0.7 : 0.85), message: stageText(message) }),
  }) : null;
  const result = detectUpstream ? analysis : { mask: new Uint8Array(W * H), marks: [], stats: { healed: 0, healed_pixels: 0, hairs: 0, soft: 0, by_kind: {} } };
  await tick();
  let repaired = k > 1 ? Uint16Array.from(colors) : work;
  let mask = result.mask;
  if (k > 1 && detectUpstream) {
    const bumps = result.discBumps || [];
    const io = {
      read: async (x0, y0, x1, y1) => {
        await tick();
        const tile = boxFrom(colors, W, C, x0, y0, x1, y1);
        if (bumps.length) subtractFull(tile, x0, y0, x1, y1, C, k, bumps);
        return tile;
      },
      write: async (x0, y0, x1, y1, values) => { putBox(repaired, W, C, x0, y0, x1, y1, values); await tick(); },
    };
    for (const bump of bumps) {
      const x0 = bump.x0 * k, y0 = bump.y0 * k;
      const x1 = Math.min(W, (bump.x0 + bump.w) * k), y1 = Math.min(H, (bump.y0 + bump.h) * k);
      await io.write(x0, y0, x1, y1, await io.read(x0, y0, x1, y1));
    }
    await healLarge(result.healMask || result.mask, result.outside, Wd, Hd, k, W, H, C, io, {
      tick, progress: (fraction) => onProgress({ fraction: 0.75 + 0.15 * fraction, message: '按原始分辨率修补' }),
    });
    mask = scale.enlargeMask(result.mask, Wd, Hd, k, W, H);
  }
  cancelled(options.signal);
  // The upstream pass only needs the original pixels. Its output order and
  // all model-dependent refinement are the same when inference runs beside it.
  if (modelInputs) options = { ...options, ...await modelInputs };
  cancelled(options.signal);
  const marks = scale.enlargeMarks(result.marks, k);
  const extraStats = { by_kind: { ...result.stats.by_kind }, healed: result.stats.healed, healed_pixels: result.stats.healed_pixels, detection_types: settings.detect };
  if (detectFibers) {
    const { enhanceFibers } = require('./fibers.cjs');
    onProgress({ fraction: 0.9, message: '追踪断续的毛发与纤维' });
    const extra = await enhanceFibers({ original: colors, repaired, mask, W, H, C, marks,
      polarity: settings.polarity, sensitivity: settings.fiberSensitivity, frame, tick,
      curl: settings.fiberCurl ?? 1, softness: settings.fiberSoftness ?? 1,
      probability: options.fibreMap?.length === W * H ? options.fibreMap : null });
    extraStats.learned_fibre_map = options.fibreMap?.length === W * H;
    extraStats.enhanced_fibers = extra.marks.length;
    extraStats.enhanced_fiber_pixels = extra.pixels;
    extraStats.healed += extra.marks.length;
    extraStats.healed_pixels += extra.pixels;
    if (extra.marks.length) {
      extraStats.hairs = result.stats.hairs + extra.marks.length;
      extraStats.by_kind['hair/fibre'] = extraStats.hairs;
      marks.push(...extra.marks);
    }
  }
  if (settings.detect.includes('scratches')) {
    const { detectScratches, healScratches } = require('./scratches.cjs');
    onProgress({ fraction: 0.90, message: '沿原图搜索连续细划痕' });
    const polarity = settings.polarity === 'auto' && result.stats.polarity?.length === 1 ?
      result.stats.polarity[0] : settings.polarity;
    const lines = await detectScratches(colors, W, H, C, polarity, tick, frame, settings.scratchSensitivity);
    const extra = await healScratches(lines, repaired, mask, W, H, C, tick);
    extraStats.enhanced_scratches = extra.marks.length;
    extraStats.enhanced_scratch_pixels = extra.pixels;
    marks.push(...extra.marks);
    extraStats.healed += extra.marks.length;
    extraStats.healed_pixels += extra.pixels;
    if (extra.marks.length) extraStats.by_kind.scratch = extra.marks.length;
  }
  if (wantsPatches && options.fibreMap?.length === W * H) {
    const { repairPatches } = require('./patches.cjs');
    onProgress({ fraction: 0.91, message: '检查亮色斑块' });
    const extra = await repairPatches({ original: colors, repaired, mask, W, H, C,
      candidates: detectUpstream ? marks : scale.enlargeMarks(analysis.marks, k),
      probability: options.fibreMap, eyes: options.eyes, frame, sensitivity: settings.patchSensitivity ?? 1, tick });
    marks.push(...extra.marks);
    extraStats.healed += extra.marks.length;
    extraStats.healed_pixels += extra.pixels;
    if (extra.marks.length) extraStats.by_kind.patch = extra.marks.length;
  }
  cancelled(options.signal);
  const structurePixels = protectSceneStructures(mask, W, H, marks);
  const eyePixels = protectEyes(mask, W, H, marks, options.eyes);
  const maskData = new Uint16Array(mask.length);
  // Only processFile owns its decoded input. Finish all detection on the
  // original before reusing it for the final, masked TIFF.
  const composed = composeMasked(image, repaired, mask, C, { out: reuseInput ? image.data : undefined, maskData, frame });
  let reviewDoubtful = scale.enlargeMarks(result.doubtful || [], k);
  if (structurePixels || eyePixels || composed.framePixels) {
    if (composed.framePixels) keepFrameMarks(marks, frame, W, H);
    const accepted = marks.filter(mark => mark.verdict === 'defect');
    extraStats.by_kind = {};
    for (const mark of accepted) extraStats.by_kind[mark.kind] = (extraStats.by_kind[mark.kind] || 0) + 1;
    extraStats.healed = accepted.length;
    extraStats.left_alone = marks.filter(mark => mark.verdict === 'keep-photo').length;
    extraStats.healed_pixels = composed.maskedPixels;
    extraStats.hairs = extraStats.by_kind['hair/fibre'] || 0;
    extraStats.enhanced_fibers = accepted.filter(mark => mark.id === -3).length;
    extraStats.enhanced_fiber_pixels = accepted.filter(mark => mark.id === -3).reduce((sum, mark) => sum + mark.area, 0);
    reviewDoubtful = doubtful(marks);
    extraStats.doubtful = reviewDoubtful.length;
    extraStats.protected_frame_pixels = composed.framePixels;
    extraStats.protected_scene_pixels = structurePixels;
    extraStats.protected_eye_pixels = eyePixels;
  }
  extraStats.eyes_found = options.eyes?.length || 0;
  const stats = { ...result.stats, ...extraStats, changed_pixels: composed.changedPixels, total_seconds: Math.round((performance.now() - t0) / 100) / 10,
    working_factor: k, native: native.available(), subject_protection: false };
  onProgress({ fraction: 0.92, message: '生成修复图像和灰尘蒙版' });
  return {
    cleaned: { ...image, data: composed.data },
    mask: { width: W, height: H, channels: 1, colorChannels: 1, alpha: false, depth: 8, data: maskData, icc: null },
    stats, changed: composed.changedPixels > 0,
    marks,
    doubtful: reviewDoubtful,
    ...(captureReview && { rebateGeometry: rebate ? { edges: rebate.edges, margin: rebate.margin } : null }),
  };
}

function fingerprint(bytes) {
  return { size: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') };
}

async function processFile(inputPath, outputRoot, options = {}, { captureReview = false } = {}) {
  const { decodeTiff, decodeTiffForWork, encodeTiff } = require('./tiff.cjs');
  const settings = optionsChecked(options);
  cancelled(options.signal);
  const input = path.resolve(inputPath), output = path.resolve(outputRoot);
  const stat = await fs.stat(input);
  if (!stat.isFile() || stat.size < 8 || stat.size > 2_000_000_000) throw new Error('请选择小于 2GB 的有效 TIFF 扫描文件。');
  options.onProgress?.({ fraction: 0.01, message: '读取 TIFF 扫描件' });
  // Found while the TIFF decodes; handled here so a cancel during decoding is not unhandled.
  // [Claude 2026-11-08] Seconds spent in each step, kept in the report (stats.timings) so a
  // slow start - detection sitting at 0% - can be traced to the step that held it.
  const timings = {}, began = performance.now();
  const since = start => Math.round((performance.now() - start) / 100) / 10;
  const timed = (promise, key) => promise.then(value => { timings[key] = since(began); return value; });
  const eyes = timed(options.eyes === undefined ? eyesIn(input, options.signal) : Promise.resolve(options.eyes), 'eyes_seconds');
  eyes.catch(() => {});
  const fibreMap = timed(options.fibreMap === undefined ? fibreMapIn(input, options.signal) : Promise.resolve(options.fibreMap), 'fibre_map_seconds');
  const models = Promise.all([eyes, fibreMap]).then(([eyes, fibreMap]) => {
    timings.models_ready_seconds = since(began);
    return { eyes, fibreMap };
  });
  models.catch(() => {});
  const digests = captureReview ? {} : null;
  let image;
  {
    const bytes = await fs.readFile(input);
    if (digests) digests.source = fingerprint(bytes);
    image = options.tiffWorkers > 1 ? await decodeTiffForWork(bytes, options) : decodeTiff(bytes);
  }
  timings.decode_seconds = since(began);
  await fs.mkdir(output, { recursive: true });
  await requireWorkSpace(output, image);
  const overlap = options.overlapModels && !options.conserveMemory &&
    settings.detect.some(kind => kind === 'dust' || kind === 'fibers');
  if (!overlap) {
    const waitingForEyes = () => timings.eyes_seconds === undefined;
    const waitingForFibres = () => timings.fibre_map_seconds === undefined;
    if (waitingForEyes() && waitingForFibres()) {
      options.onProgress?.({ fraction: 0.02, message: '正在准备眼部保护和纤维检测模型' });
      await Promise.race([eyes, fibreMap]);
    }
    if (waitingForEyes()) {
      options.onProgress?.({ fraction: 0.03, message: '正在定位眼部高光' });
    } else if (waitingForFibres()) {
      options.onProgress?.({ fraction: 0.03, message: '正在生成纤维检测图' });
    }
  }
  const scanOptions = overlap ? options : { ...options, ...await models };
  const detectStart = performance.now();
  const result = await processScan(image, scanOptions, { reuseInput: true, captureReview, modelInputs: overlap ? models : null });
  timings.detect_seconds = since(detectStart);
  const { fibreMap: map } = await models;
  result.stats = { ...result.stats, timings };
  cancelled(options.signal);
  const stem = path.basename(input).replace(/\.(tiff?|TIF{1,2})$/i, '').replace(/[^\p{L}\p{N}._ -]/gu, '_').slice(0, 100) || 'scan';
  const dir = await fs.mkdtemp(path.join(output, stem + '-dust-'));
  const paths = { cleaned: path.join(dir, 'cleaned.tiff'), mask: path.join(dir, 'dust-mask.tiff'), report: path.join(dir, 'report.json') };
  const writeAsset = async (name, bytes) => {
    if (digests) digests[name] = fingerprint(bytes);
    await fs.writeFile(paths[name], bytes, { flag: 'wx' });
  };
  try {
    await writeAsset('cleaned', encodeTiff(result.cleaned));
    cancelled(options.signal);
    await writeAsset('mask', encodeTiff(result.mask));
    // Kept for a review so its training pack can give each repair the model's own score.
    if (digests && map?.length === image.width * image.height) {
      paths.fibreMap = path.join(dir, 'fibre-map.u8');
      await writeAsset('fibreMap', Buffer.from(map.buffer, map.byteOffset, map.byteLength));
    }
    const report = { version: require('./version.cjs'), upstream: UPSTREAM, source: input,
      image: { width: image.width, height: image.height, depth: image.depth, channels: image.channels, embedded_icc: Boolean(image.icc) },
      settings: optionsChecked(options), stats: result.stats, changed: result.changed,
      notes: ['未使用 Photoshop 的主体选择遮罩。', '修复结果经最终蒙版合成；蒙版外像素保持输入数值。'],
      marks: result.marks, doubtful: result.doubtful };
    await writeAsset('report', Buffer.from(JSON.stringify(report, null, 2) + '\n'));
    cancelled(options.signal);
    const output = { outputDir: dir, paths, stats: result.stats, changed: result.changed };
    if (digests) output.reviewData = { mask: result.mask, image: report.image, marks: result.marks, digests, rebateGeometry: result.rebateGeometry };
    return output;
  } catch (error) {
    await fs.rm(dir, { recursive: true, force: true });
    throw error;
  }
}

async function requireWorkSpace(directory, image) {
  const { bavail, bsize } = await fs.statfs(directory, { bigint: true });
  const bytes = BigInt(image.width * image.height * (image.channels * image.depth / 8 + 1));
  if (bavail * bsize < bytes + 128n * 1024n * 1024n) {
    throw new Error('磁盘空间不足，无法写入修复图和蒙版。请释放缓存空间后重试。');
  }
}

module.exports = { processScan, processFile, composeMasked, optionsChecked, checkImage, cancelled, requireWorkSpace };
