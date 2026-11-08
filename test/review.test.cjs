'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const { encodeTiff, decodeTiff } = require('../src/tiff.cjs');
const { prepareReview, inspectReview, redetectReview, renderReviewPreview, confirmReview, connectedRegions } = require('../src/review.cjs');

async function caseFiles(t, { empty = false, brush = false } = {}) {
  const dir = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'pureneg-review-')));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const cacheRoot = path.join(dir, 'private', 'reviews'), outputRoot = path.join(dir, 'published');
  const width = brush ? 320 : 5, height = brush ? 60 : 5;
  const data = new Uint16Array(width * height * 3).fill(10000);
  const source = { width, height, channels: 3, colorChannels: 3, depth: 16, data, icc: Buffer.from('opaque-profile-bytes') };
  const maskData = new Uint16Array(width * height);
  if (brush) {
    maskData[30 * width + 40] = maskData[30 * width + 45] = 65535;
    for (const x of [254, 255, 256, 257]) data.fill(60000, (30 * width + x) * 3, (30 * width + x + 1) * 3);
  } else if (!empty) for (let y = 0; y < 5; y++) for (let x = 0; x < 5; x++) if (x === 0 || y === 0 || x === 4 || y === 4 || (x === 2 && y === 2)) maskData[y * 5 + x] = 65535;
  const candidate = { ...source, data: Uint16Array.from(data, (value, i) => maskData[Math.floor(i / 3)] ? 20000 : value) };
  const filenames = { cleaned: path.join(dir, 'candidate.tiff'), mask: path.join(dir, 'mask.tiff'), report: path.join(dir, 'report.json') };
  const inputPath = path.join(dir, 'source.tiff');
  await fs.writeFile(inputPath, encodeTiff(source));
  await fs.writeFile(filenames.cleaned, encodeTiff(candidate));
  await fs.writeFile(filenames.mask, encodeTiff({ width, height, channels: 1, colorChannels: 1, depth: 8, data: maskData }));
  await fs.writeFile(filenames.report, JSON.stringify({ version: '0.1.0', image: { width, height, depth: 16, channels: 3 }, stats: { healed: empty ? 0 : 2 } }));
  const preparedResult = { paths: filenames, stats: { healed: empty ? 0 : 2, changed_pixels: empty ? 0 : 17 }, changed: !empty };
  return { dir, cacheRoot, outputRoot, inputPath, source, maskData, preparedResult };
}

async function prepared(t, settings = {}) {
  const fixture = await caseFiles(t, settings);
  const review = await prepareReview({ ...fixture, context: 'file' });
  return { ...fixture, ...review };
}

test('run components join diagonals and keep nested bounding boxes separate', () => {
  const mask = { width: 3, height: 3, channels: 1, data: new Uint16Array([65535,0,0,0,65535,0,0,0,65535]) };
  const result = connectedRegions(mask);
  assert.equal(result.regions.length, 1);
  assert.equal(result.regions[0].pixels, 3);
  const nested = new Uint16Array(25);
  for (let y = 0; y < 5; y++) for (let x = 0; x < 5; x++) if (x === 0 || y === 0 || x === 4 || y === 4 || (x === 2 && y === 2)) nested[y * 5 + x] = 65535;
  const rings = connectedRegions({ width: 5, height: 5, channels: 1, data: nested });
  assert.deepEqual(rings.regions.map(r => [r.id, r.x, r.y, r.width, r.height, r.pixels]), [[1,0,0,5,5,16],[2,2,2,1,1,1]]);
});

test('accepted detector marks label matching mask components, including mixed components', async t => {
  const fixture = await caseFiles(t);
  const reportPath = fixture.preparedResult.paths.report;
  const report = JSON.parse(await fs.readFile(reportPath, 'utf8'));
  report.marks = [
    { kind: 'scratch', verdict: 'defect', x0: 0, y0: 0, x1: 4, y1: 4, area: 16 },
    { kind: 'speck', verdict: 'defect', x0: 0, y0: 4, x1: 0, y1: 4, area: 1 },
    { kind: 'soft', fibreDisc: true, verdict: 'defect', x0: 2, y0: 2, x1: 2, y1: 2, area: 1 },
    { kind: 'dust', verdict: 'keep-photo', x0: 2, y0: 2, x1: 2, y1: 2, area: 1 },
    { kind: 'hair/fibre', verdict: 'defect', x0: 0, y0: 0, x1: 0, y1: 0, area: 50 },
  ];
  await fs.writeFile(reportPath, JSON.stringify(report));
  const { review, reviewPath } = await prepareReview(fixture);
  assert.deepEqual(review.regions.map(region => region.kinds), [['dust', 'scratches'], ['fibers']]);
  assert.equal(path.dirname(review.runsPath), path.dirname(reviewPath));
  assert.equal((await fs.readFile(review.runsPath)).subarray(0, 8).toString(), 'FDRUNS01');
  assert.deepEqual((await inspectReview(reviewPath, { cacheRoot: fixture.cacheRoot })).review.regions, review.regions);
});

test('preparation freezes its own original, produces review data, and publishes nothing', async t => {
  const item = await prepared(t);
  assert.equal(item.review.regions.length, 2);
  assert.equal(item.review.sourceName, 'source.tiff');
  assert.notEqual(item.review.sourcePath, item.inputPath);
  assert.ok(item.review.sourcePath.startsWith(item.cacheRoot + path.sep));
  assert.deepEqual(await fs.readFile(item.review.sourcePath), await fs.readFile(item.inputPath));
  await assert.rejects(fs.access(item.outputRoot), { code: 'ENOENT' });
  assert.equal(Object.hasOwn(item.review.regions[0], 'runs'), false);
  const mode = (await fs.stat(item.reviewPath)).mode & 0o777;
  assert.equal(mode, 0o600);
  const inspected = await inspectReview(item.reviewPath, { cacheRoot: item.cacheRoot });
  assert.deepEqual(inspected, { reviewPath: item.reviewPath, review: item.review });
});

test('new reviews use the PURENeg cache and older reviews retain their original signing root', async t => {
  const { cacheRoot: unused, ...fixture } = await caseFiles(t);
  t.mock.method(os, 'homedir', () => fixture.dir);
  for (const name of ['PURENEG_HOME', 'PHOTOCRAFT_FILMDUST_HOME']) {
    const previous = process.env[name];
    delete process.env[name];
    t.after(() => { if (previous !== undefined) process.env[name] = previous; });
  }
  const support = process.platform === 'darwin' ? ['Library', 'Application Support'] : ['.local', 'share'];
  const currentRoot = path.join(fixture.dir, ...support, 'PURENeg', 'reviews');
  const legacyRoot = path.join(fixture.dir, ...support, 'PhotoCraft Film Dust', 'reviews');
  const current = await prepareReview(fixture);
  const legacy = await prepareReview({ ...fixture, cacheRoot: legacyRoot });
  assert.equal(path.dirname(path.dirname(current.reviewPath)), currentRoot);
  assert.deepEqual(await inspectReview(legacy.reviewPath), legacy);
  await assert.rejects(inspectReview(legacy.reviewPath, { cacheRoot: currentRoot }), /缓存目录/);
  const published = await confirmReview(legacy.reviewPath);
  assert.match(path.basename(published.outputDir), /^PURENeg-reviewed-/);
  assert.equal(path.dirname(path.dirname(legacy.reviewPath)), legacyRoot);
});

test('preview exclusion restores exact component pixels despite overlapping region boxes', async t => {
  const item = await prepared(t);
  const result = await renderReviewPreview(item.reviewPath, { excludedRegions: [1] }, { cacheRoot: item.cacheRoot });
  const clean = decodeTiff(await fs.readFile(result.cleanedPath)), mask = decodeTiff(await fs.readFile(result.maskPath));
  assert.equal(clean.data[(2 * 5 + 2) * 3], 20000, 'inner component must remain repaired');
  for (let p = 0; p < 25; p++) if (p !== 12) {
    assert.equal(mask.data[p], 0);
    for (let c = 0; c < 3; c++) assert.equal(clean.data[p * 3 + c], 10000);
  }
  assert.equal(mask.data[12], 65535);
  assert.equal(result.retainedRegions, 1);
  const second = await renderReviewPreview(item.reviewPath, { excludedRegions: [] }, { cacheRoot: item.cacheRoot });
  assert.notEqual(second.cleanedPath, result.cleanedPath, 'ImageIO cannot see a file being overwritten');
  await assert.rejects(fs.access(item.outputRoot), { code: 'ENOENT' });
});

test('confirmation publishes only accepted pixels and prevents duplicate confirmation', async t => {
  const item = await prepared(t);
  const result = await confirmReview(item.reviewPath, { excludedRegions: [2] }, { cacheRoot: item.cacheRoot });
  assert.equal(result.context, 'file');
  assert.equal(result.host, null);
  assert.equal(result.retainedRegions, 1);
  assert.equal(result.stats.excluded_regions, 1);
  assert.ok(result.outputDir.startsWith(item.outputRoot + path.sep));
  assert.match(path.basename(result.outputDir), /^PURENeg-reviewed-/);
  assert.ok(result.stagedPaths.cleaned.startsWith(item.cacheRoot + path.sep));
  const clean = decodeTiff(await fs.readFile(result.paths.cleaned)), mask = decodeTiff(await fs.readFile(result.paths.mask));
  assert.equal(clean.data[12 * 3], 10000);
  assert.equal(mask.data[12], 0);
  assert.equal(clean.data[0], 20000);
  assert.deepEqual(clean.icc, item.source.icc);
  const report = JSON.parse(await fs.readFile(result.paths.report, 'utf8'));
  assert.equal(report.review.confirmed, true);
  assert.deepEqual(report.review.excludedRegions, [2]);
  await assert.rejects(confirmReview(item.reviewPath, {}, { cacheRoot: item.cacheRoot }), /已经确认/);
  await assert.rejects(renderReviewPreview(item.reviewPath, {}, { cacheRoot: item.cacheRoot }), /已经确认/);
});

test('manual strokes recover false detections and heal missed dust across a tile boundary', async t => {
  const item = await prepared(t, { brush: true });
  const options = { cacheRoot: item.cacheRoot };
  const edits = { strokes: [
    { kind: 'erase', radius: 2, points: [[40, 30]] },
    { kind: 'add', radius: 2, points: [[253, 30], [259, 30]] },
    { kind: 'erase', radius: 1, points: [[251, 30]] },
  ] };
  const p = (x, y) => y * item.source.width + x;
  await assert.rejects(renderReviewPreview(item.reviewPath, { strokes: [{ kind: 'add', radius: 3, points: [[320, 5]] }] }, options), /超出原图/);
  const preview = await renderReviewPreview(item.reviewPath, edits, options);
  const clean = decodeTiff(await fs.readFile(preview.cleanedPath)), mask = decodeTiff(await fs.readFile(preview.maskPath));
  assert.equal(clean.data[p(40, 30) * 3], 10000, 'eraser restores the original exact sample');
  assert.equal(clean.data[p(45, 30) * 3], 20000, 'eraser leaves nearby automatic repair alone');
  assert.equal(mask.data[p(252, 30)], 0, 'last eraser overrides the earlier add');
  assert.equal(clean.data[p(252, 30) * 3], 10000);
  for (const x of [254, 255, 256, 257]) {
    assert.equal(mask.data[p(x, 30)], 65535, 'sparse mouse samples produce a connected stroke');
    assert.ok(clean.data[p(x, 30) * 3] < 12000, 'missed dust is healed on both sides of the tile edge');
  }
  let changed = 0;
  for (let i = 0; i < mask.data.length; i++) {
    const from = i * 3;
    const differs = [0, 1, 2].some(c => clean.data[from + c] !== item.source.data[from + c]);
    if (differs) { assert.equal(mask.data[i], 65535); changed++; }
  }
  assert.equal(preview.stats.changed_pixels, changed);
  assert.equal(preview.stats.restored_pixels, 1);
  assert.equal(preview.stats.manual_strokes, 3);
  const confirmed = await confirmReview(item.reviewPath, edits, options);
  assert.deepEqual(await fs.readFile(confirmed.paths.cleaned), await fs.readFile(preview.cleanedPath));
  assert.deepEqual(await fs.readFile(confirmed.paths.mask), await fs.readFile(preview.maskPath));
  assert.deepEqual(clean.icc, item.source.icc);
});

test('redetection from a confirmed file remaps changed region IDs and previews retained strokes', async t => {
  const { dir, inputPath, outputRoot, cacheRoot } = await caseFiles(t);
  const width = 656, height = 440, data = new Uint16Array(width * height);
  let seed = 129763;
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    let value = 23000 + 3 * y + ((seed >>> 24) - 128);
    if (x >= 56 && x < 561 && Math.abs(y - (71 + Math.round(x / 170))) <= 1) value += 580;
    data[y * width + x] = value;
  }
  const spot = 165 * width + 350;
  data[spot] = 60000;
  await fs.writeFile(inputPath, encodeTiff({ width, height, channels: 1, colorChannels: 1, depth: 16, data }));
  const parameters = { inputPath, outputRoot, cacheRoot, sourceName: 'Frame from Photoshop',
    options: { polarity: 'bright', detect: ['scratches'], sensitivity: 1.4 } };
  const baseline = await prepareReview(parameters);
  assert.equal(baseline.review.regions.length, 1);
  assert.deepEqual(baseline.review.regions[0].kinds, ['scratches']);
  assert.deepEqual(baseline.review.thresholds, { dust: 1.4, fibers: 1.4, scratches: 1 });
  const mask = decodeTiff(await fs.readFile(baseline.review.maskPath));
  mask.data[10 * width + 10] = 65535; // A preceding component that the new scan will remove.
  const oldMask = path.join(dir, 'old-mask.tiff');
  await fs.writeFile(oldMask, encodeTiff(mask));
  const report = path.join(path.dirname(baseline.review.cleanedPath), 'report.json');
  const old = await prepareReview({ ...parameters, preparedResult: { stats: baseline.review.stats,
    paths: { cleaned: baseline.review.cleanedPath, mask: oldMask, report } } });
  assert.deepEqual(old.review.regions.map(region => region.id), [1, 2]);
  // Older versions kept the detection settings only in the signed report asset.
  const { record } = JSON.parse(await fs.readFile(old.reviewPath, 'utf8'));
  delete record.detectionSettings;
  delete record.regionKindsVersion;
  for (const region of record.regions) delete region.kinds;
  const key = await fs.readFile(path.join(cacheRoot, '.review-signing-key'));
  const signature = crypto.createHmac('sha256', key).update(JSON.stringify(record)).digest('hex');
  const legacy = JSON.stringify({ record, signature });
  await fs.writeFile(old.reviewPath, legacy);
  const inspected = (await inspectReview(old.reviewPath, { cacheRoot })).review;
  assert.deepEqual(inspected.thresholds, baseline.review.thresholds);
  assert.deepEqual(inspected.regions.map(region => region.kinds), [undefined, ['scratches']]);
  assert.equal(await fs.readFile(old.reviewPath, 'utf8'), legacy);
  const first = await confirmReview(old.reviewPath, {}, { cacheRoot });
  const firstExport = await fs.readFile(first.paths.cleaned);
  const previousRecord = await fs.readFile(old.reviewPath);
  const strokes = [{ kind: 'add', radius: 2, points: [[350, 165]] }];
  const edits = { excludedRegions: [1, 2], strokes };
  const initialJobs = (await fs.readdir(cacheRoot)).sort();
  const controller = new AbortController();
  await assert.rejects(redetectReview(old.reviewPath, edits, { cacheRoot, signal: controller.signal,
    dustSensitivity: 1.8, fiberSensitivity: 1.4, scratchSensitivity: 1, onProgress: () => controller.abort() }), { name: 'AbortError' });
  assert.deepEqual((await fs.readdir(cacheRoot)).sort(), initialJobs);
  assert.deepEqual(await fs.readFile(old.reviewPath), previousRecord);
  const editsPath = path.join(dir, 'edit-input.json');
  await fs.writeFile(editsPath, JSON.stringify(edits));
  const { stdout } = await promisify(execFile)(process.execPath, [path.resolve(__dirname, '../src/cli.cjs'), 'redetect',
    '--review', old.reviewPath, '--work-dir', path.dirname(cacheRoot), '--edits', editsPath,
    '--dust-sensitivity', '1.8', '--fiber-sensitivity', '1.4', '--scratch-sensitivity', '1']);
  const result = stdout.trim().split('\n').map(line => JSON.parse(line)).at(-1);
  assert.equal(result.type, 'redetected');
  assert.notEqual(result.reviewPath, old.reviewPath);
  assert.deepEqual(result.review.thresholds, { dust: 1.8, fibers: 1.4, scratches: 1 });
  assert.deepEqual(result.review.regions[0].kinds, ['scratches']);
  assert.deepEqual(result.review.stats.detection_types, ['scratches']);
  assert.equal(result.review.sourceName, parameters.sourceName);
  assert.equal(result.review.outputRoot, outputRoot);
  assert.deepEqual(await fs.readFile(result.review.sourcePath), await fs.readFile(old.review.sourcePath));
  assert.deepEqual(result.excludedRegions, [1]);
  assert.equal(result.unmatchedExclusions, 1);
  assert.equal(result.preview.stats.manual_strokes, 1);
  assert.equal(decodeTiff(await fs.readFile(result.preview.maskPath)).data[spot], 65535);
  assert.equal(decodeTiff(await fs.readFile(result.preview.cleanedPath)).data[spot] < 25000, true);
  const next = await confirmReview(result.reviewPath, { excludedRegions: result.excludedRegions, strokes }, { cacheRoot });
  assert.deepEqual(await fs.readFile(next.paths.cleaned), await fs.readFile(result.preview.cleanedPath));
  assert.deepEqual(await fs.readFile(old.reviewPath), previousRecord);
  assert.deepEqual(await fs.readFile(first.paths.cleaned), firstExport);
});

test('file export can be revised from signed originals without overwriting the previous version', async t => {
  const item = await prepared(t, { brush: true });
  const firstEdits = { strokes: [{ kind: 'erase', radius: 2, points: [[40, 30]] }] };
  const first = await confirmReview(item.reviewPath, firstEdits, { cacheRoot: item.cacheRoot });
  const firstFile = await fs.readFile(first.paths.cleaned);
  const firstManifest = await fs.readFile(item.reviewPath);
  const edits = { strokes: [...firstEdits.strokes, { kind: 'add', radius: 2, points: [[253, 30], [259, 30]] }] };
  const reviseOptions = { cacheRoot: item.cacheRoot, reviseExport: true };
  const preview = await renderReviewPreview(item.reviewPath, edits, reviseOptions);
  const previewBytes = await fs.readFile(preview.cleanedPath);
  const clean = decodeTiff(previewBytes);
  const at = x => (30 * item.source.width + x) * 3;
  assert.equal(clean.data[at(40)], 10000, 'keep the earlier eraser stroke');
  assert.equal(clean.data[at(45)], 20000, 'keep the nearby automatic repair');
  assert.equal(decodeTiff(firstFile).data[at(255)], 60000, 'the original export retains the missed dust');
  assert.ok(clean.data[at(255)] < 12000, 'heal the missed dust in the revised export');

  const invalid = path.join(item.dir, 'not a folder');
  await fs.writeFile(invalid, 'leave this file alone');
  const jobDir = path.dirname(item.reviewPath);
  const jobFiles = (await fs.readdir(jobDir)).sort();
  await assert.rejects(confirmReview(item.reviewPath, edits, { ...reviseOptions, outputRoot: invalid }), { code: 'EEXIST' });
  assert.deepEqual(await fs.readFile(item.reviewPath), firstManifest);
  assert.deepEqual((await fs.readdir(jobDir)).sort(), jobFiles);
  assert.deepEqual(await fs.readFile(first.stagedPaths.cleaned), firstFile);
  await assert.rejects(inspectReview(item.reviewPath, reviseOptions), /已经确认/);

  const editsPath = path.join(item.dir, 'new-edits.json');
  await fs.writeFile(editsPath, JSON.stringify(edits));
  const { stdout } = await promisify(execFile)(process.execPath, [path.join(__dirname, '../src/cli.cjs'), 'confirm',
    '--review', item.reviewPath, '--edits', editsPath, '--work-dir', path.dirname(item.cacheRoot), '--mask', 'no', '--revise-export']);
  const result = JSON.parse(stdout.trim().split('\n').at(-1));
  assert.equal(result.type, 'result');
  assert.equal(path.basename(result.paths.cleaned), 'source-PN.tiff');
  assert.deepEqual(Object.keys(result.paths), ['cleaned']);
  const stage = path.dirname(result.reviewPreview.cleanedPath);
  assert.equal(path.dirname(stage), jobDir);
  assert.match(path.basename(stage), /^confirmed-/);
  assert.equal(result.reviewPreview.maskPath, path.join(stage, 'dust-mask.tiff'));
  assert.deepEqual(await fs.readFile(result.paths.cleaned), previewBytes);
  assert.deepEqual(await fs.readFile(result.reviewPreview.cleanedPath), previewBytes);
  assert.deepEqual(await fs.readFile(result.reviewPreview.maskPath), await fs.readFile(preview.maskPath));
  assert.deepEqual(await fs.readFile(first.paths.cleaned), firstFile);
  assert.deepEqual(await fs.readFile(first.stagedPaths.cleaned), firstFile);
  await assert.rejects(confirmReview(item.reviewPath, {}, { cacheRoot: item.cacheRoot }), /已经确认/);
});

test('excluding every region is an unchanged result that must not be imported', async t => {
  const item = await prepared(t);
  const result = await confirmReview(item.reviewPath, { excludedRegions: [1,2] }, { cacheRoot: item.cacheRoot });
  assert.equal(result.changed, false);
  assert.equal(result.retainedRegions, 0);
  assert.equal(result.stats.changed_pixels, 0);
  const clean = decodeTiff(await fs.readFile(result.paths.cleaned));
  assert.deepEqual(clean.data, item.source.data);
});

test('standalone confirmation uses the chosen folder and can retry after a destination failure', async t => {
  const item = await prepared(t);
  const invalid = path.join(item.dir, 'not a folder');
  await fs.writeFile(invalid, 'leave this file alone');
  await assert.rejects(confirmReview(item.reviewPath, {}, { cacheRoot: item.cacheRoot, outputRoot: invalid }), { code: 'EEXIST' });
  assert.equal(await fs.readFile(invalid, 'utf8'), 'leave this file alone');
  await inspectReview(item.reviewPath, { cacheRoot: item.cacheRoot });

  const chosen = path.join(item.dir, '最后选的目录');
  const result = await confirmReview(item.reviewPath, {}, { cacheRoot: item.cacheRoot, outputRoot: chosen });
  assert.equal(path.dirname(result.outputDir), chosen);
  assert.equal(path.dirname(result.paths.cleaned), result.outputDir);
  assert.deepEqual((await fs.readdir(result.outputDir)).sort(), ['cleaned.tiff', 'dust-mask.tiff', 'report.json']);
  await assert.rejects(fs.access(item.outputRoot), { code: 'ENOENT' });
  await assert.rejects(confirmReview(item.reviewPath, {}, { cacheRoot: item.cacheRoot, outputRoot: item.outputRoot }), /已经确认/);
});

test('explicit mask choice exports a single photo by default or adds only the requested mask', async t => {
  for (const includeMask of [false, true]) {
    const item = await prepared(t);
    const result = await confirmReview(item.reviewPath, {}, { cacheRoot: item.cacheRoot, includeMask });
    assert.deepEqual((await fs.readdir(result.outputDir)).sort(),
      includeMask ? ['source-PN-mask.tiff', 'source-PN.tiff'] : ['source-PN.tiff']);
    assert.equal(Object.hasOwn(result.paths, 'mask'), includeMask);
  }
});

test('app exports share one folder and never overwrite: a taken name gets a number', async t => {
  const chosen = path.join(os.tmpdir(), 'pureneg-flat-' + process.pid + '-' + Date.now());
  t.after(() => fs.rm(chosen, { recursive: true, force: true }));
  const names = [];
  for (let i = 0; i < 2; i++) {
    const item = await prepared(t);
    const result = await confirmReview(item.reviewPath, {}, { cacheRoot: item.cacheRoot, outputRoot: chosen, includeMask: true });
    assert.equal(result.outputDir, chosen);
    names.push(path.basename(result.paths.cleaned), path.basename(result.paths.mask));
  }
  assert.deepEqual(names, ['source-PN.tiff', 'source-PN-mask.tiff', 'source-PN-2.tiff', 'source-PN-2-mask.tiff']);
  assert.deepEqual((await fs.readdir(chosen)).sort(), [...names].sort());
});

test('unknown or non-integer region ids fail without consuming review', async t => {
  const item = await prepared(t);
  await assert.rejects(confirmReview(item.reviewPath, { excludedRegions: [3] }, { cacheRoot: item.cacheRoot }), /未知/);
  await assert.rejects(renderReviewPreview(item.reviewPath, { excludedRegions: ['1'] }, { cacheRoot: item.cacheRoot }), /未知/);
  const result = await confirmReview(item.reviewPath, {}, { cacheRoot: item.cacheRoot });
  assert.equal(result.retainedRegions, 2);
});

test('changes to the user original do not change a frozen review', async t => {
  const item = await prepared(t);
  await fs.writeFile(item.inputPath, Buffer.from('changed by another program'));
  const result = await renderReviewPreview(item.reviewPath, { excludedRegions: [1,2] }, { cacheRoot: item.cacheRoot });
  assert.deepEqual(decodeTiff(await fs.readFile(result.cleanedPath)).data, item.source.data);
});

test('altered cached source or manifest is rejected before publication', async t => {
  const item = await prepared(t);
  const bytes = await fs.readFile(item.review.sourcePath); bytes[bytes.length - 1] ^= 1;
  await fs.writeFile(item.review.sourcePath, bytes);
  await assert.rejects(confirmReview(item.reviewPath, {}, { cacheRoot: item.cacheRoot }), /图像已被修改/);
  await assert.rejects(fs.access(item.outputRoot), { code: 'ENOENT' });
  const another = await prepared(t);
  const manifest = JSON.parse(await fs.readFile(another.reviewPath, 'utf8'));
  manifest.record.outputRoot = path.join(another.dir, 'injected-output');
  await fs.writeFile(another.reviewPath, JSON.stringify(manifest));
  await assert.rejects(confirmReview(another.reviewPath, {}, { cacheRoot: another.cacheRoot }), /审核文件已被修改/);
});

test('a review from another root and a fabricated unsigned manifest cannot be confirmed', async t => {
  const item = await prepared(t);
  const otherRoot = path.join(item.dir, 'elsewhere');
  await fs.mkdir(otherRoot);
  await fs.writeFile(path.join(otherRoot, '.review-signing-key'), Buffer.alloc(32, 1));
  await assert.rejects(confirmReview(item.reviewPath, {}, { cacheRoot: otherRoot }), /不属于/);
  const envelope = JSON.parse(await fs.readFile(item.reviewPath, 'utf8'));
  delete envelope.signature;
  await fs.writeFile(item.reviewPath, JSON.stringify(envelope));
  await assert.rejects(confirmReview(item.reviewPath, {}, { cacheRoot: item.cacheRoot }), /签名无效/);
});

test('simultaneous confirmation publishes once and never reopens a confirmed review', async t => {
  const item = await prepared(t);
  const results = await Promise.allSettled([
    confirmReview(item.reviewPath, {}, { cacheRoot: item.cacheRoot }),
    confirmReview(item.reviewPath, {}, { cacheRoot: item.cacheRoot }),
  ]);
  assert.equal(results.filter(r => r.status === 'fulfilled').length, 1);
  assert.equal((await fs.readdir(item.outputRoot)).length, 1);
  await assert.rejects(confirmReview(item.reviewPath, {}, { cacheRoot: item.cacheRoot }), /已经确认/);
});

test('PhotoCraft review stays inside its authorized root and does not import by itself', async t => {
  const fixture = await caseFiles(t);
  const host = { workDir: path.dirname(fixture.cacheRoot), snapshot: { index: 3, width: 5, height: 5, depth: 16, mode: 'rgb' } };
  await fs.mkdir(host.workDir, { recursive: true });
  const pending = await prepareReview({ ...fixture, context: 'photocraft', host, options: { detect: ['scratches'] } });
  const reviseOptions = { cacheRoot: fixture.cacheRoot, reviseExport: true };
  await assert.rejects(renderReviewPreview(pending.reviewPath, {}, reviseOptions), /仅文件审核/);
  await assert.rejects(confirmReview(pending.reviewPath, {}, reviseOptions), /仅文件审核/);
  const next = await redetectReview(pending.reviewPath, {}, { cacheRoot: fixture.cacheRoot,
    dustSensitivity: 1, fiberSensitivity: 1, scratchSensitivity: 1 });
  assert.notEqual(next.reviewPath, pending.reviewPath);
  assert.equal(next.review.context, 'photocraft');
  assert.ok(next.reviewPath.startsWith(host.workDir + path.sep));
  assert.deepEqual(await inspectReview(pending.reviewPath, { cacheRoot: fixture.cacheRoot }), pending);
  const result = await confirmReview(next.reviewPath, {}, { cacheRoot: fixture.cacheRoot });
  assert.deepEqual(result.host, host);
  assert.equal(result.context, 'photocraft');
  assert.ok(result.stagedPaths.cleaned.startsWith(host.workDir + path.sep));
  await assert.rejects(confirmReview(next.reviewPath, {}, { cacheRoot: fixture.cacheRoot }), /已经确认/);
});

test('no-dust review and cancelled preview preserve the reviewable source', async t => {
  const item = await prepared(t, { empty: true });
  assert.deepEqual(item.review.regions, []);
  const controller = new AbortController(); controller.abort();
  await assert.rejects(renderReviewPreview(item.reviewPath, {}, { cacheRoot: item.cacheRoot, signal: controller.signal }), { name: 'AbortError' });
  const result = await confirmReview(item.reviewPath, {}, { cacheRoot: item.cacheRoot });
  assert.equal(result.changed, false);
  assert.equal(result.retainedRegions, 0);
});

test('ordinary preparation executes the complete engine without a prepared-result shortcut', { timeout: 30000 }, async t => {
  const fixture = await caseFiles(t, { empty: true });
  const data = new Uint16Array(128 * 96 * 3).fill(24000);
  await fs.writeFile(fixture.inputPath, encodeTiff({ width: 128, height: 96, depth: 16, channels: 3, colorChannels: 3, data }));
  const pending = await prepareReview({ inputPath: fixture.inputPath, outputRoot: fixture.outputRoot, cacheRoot: fixture.cacheRoot, options: { polarity: 'bright' } });
  assert.equal(pending.review.width, 128);
  assert.equal(pending.review.height, 96);
  assert.equal(pending.review.regions.length, 0);
  await assert.rejects(fs.access(fixture.outputRoot), { code: 'ENOENT' });
});

test('adoption rejects another same-sized photograph and removes the incomplete review', async t => {
  const fixture = await caseFiles(t);
  const wrong = { ...fixture.source, data: Uint16Array.from(fixture.source.data, value => value + 1234) };
  await fs.writeFile(fixture.preparedResult.paths.cleaned, encodeTiff(wrong));
  await assert.rejects(prepareReview({ ...fixture }), /原始快照不匹配/);
  assert.deepEqual((await fs.readdir(fixture.cacheRoot)).filter(name => !name.startsWith('.')), []);
  await assert.rejects(fs.access(fixture.outputRoot), { code: 'ENOENT' });
});

test('review display name is explicit, bounded and free of control characters', async t => {
  const fixture = await caseFiles(t);
  const pending = await prepareReview({ ...fixture, sourceName: '../\n真实扫描件.tiff' });
  assert.equal(pending.review.sourceName, '真实扫描件.tiff');
});
