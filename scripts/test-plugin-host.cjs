'use strict';

// Runs against a dedicated PhotoCraft control session only. Never discovers or
// attaches to the user's normal PhotoCraft window. Generated documents are closed
// individually; the session's pre-existing documents and settings are left alone.
const fs = require('node:fs/promises');
const path = require('node:path');
const assert = require('node:assert/strict');
const { performance } = require('node:perf_hooks');
const { ensureSession } = require('../src/photocraft.cjs');
const { encodeTiff, decodeTiff } = require('../src/tiff.cjs');

const PLUGIN_ID = 'org.filmdust.local';
const DEFAULT_PLUGIN = path.resolve(__dirname, '../dist/plugin/film-dust-local.wasm');
const DEFAULT_PARAMS = { polarity: 'bright', sensitivity: 1, maxSize: 8, strength: 1, preview: 'repair' };

async function loadModule(filename = DEFAULT_PLUGIN) {
  const bytes = await fs.readFile(filename);
  const module = await WebAssembly.compile(bytes);
  assert.deepEqual(WebAssembly.Module.imports(module), [], 'PhotoCraft ABI v1 rejects all imports');
  return { bytes, module };
}

async function inspectModule(module) {
  const { exports: e } = await WebAssembly.instantiate(module, {});
  for (const key of ['memory', 'pc_abi_version', 'pc_manifest', 'pc_alloc', 'pc_filter']) assert.ok(e[key], `missing ${key}`);
  assert.equal(e.pc_abi_version(), 1);
  const packed = BigInt.asUintN(64, e.pc_manifest());
  const ptr = Number(packed & 0xffffffffn), length = Number(packed >> 32n);
  assert.ok(length > 0 && length <= 65536);
  const manifest = JSON.parse(Buffer.from(e.memory.buffer, ptr, length).toString('utf8'));
  assert.equal(manifest.id, PLUGIN_ID);
  return manifest;
}

async function runWasm(module, image, params = {}, format) {
  const { exports: e } = await WebAssembly.instantiate(module, {});
  const samples = image.data instanceof Float32Array ? image.data : Float32Array.from(image.data, x => x / 65535);
  const text = Buffer.from(JSON.stringify({ ...DEFAULT_PARAMS, ...params }));
  const ptr = e.pc_alloc(samples.byteLength), pp = e.pc_alloc(text.length);
  assert.ok(ptr && pp, 'plugin allocation failed');
  new Float32Array(e.memory.buffer, ptr, samples.length).set(samples);
  new Uint8Array(e.memory.buffer, pp, text.length).set(text);
  const mode = image.channels <= 2 ? 1 : 3;
  const alpha = image.channels === 2 || image.channels === 4;
  const code = format ?? ((image.depth || 16) | (alpha ? 1 << 8 : 0) | mode << 16);
  const started = performance.now();
  const rc = e.pc_filter(ptr, samples.byteLength, image.width, image.height, image.channels, code, pp, text.length);
  return { rc, data: new Float32Array(new Float32Array(e.memory.buffer, ptr, samples.length)), ms: performance.now() - started };
}

function fixture(width = 1152, height = 768, channels = 4, depth = 16, polarity = 'bright') {
  const data = new Uint16Array(width * height * channels);
  const colors = channels <= 2 ? 1 : 3, alpha = channels === 2 || channels === 4;
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    const k = (y * width + x) * channels;
    // Low-amplitude deterministic grain with a slow gradient; it is independent
    // of image dimensions, so padded whole/band comparisons use the same pixels.
    const grain = (((x * 37 + y * 19) % 97) - 48) * 2;
    for (let c = 0; c < colors; c++) data[k + c] = 22000 + c * 1700 + Math.floor(x / 17) + Math.floor(y / 19) + grain;
    if (alpha) data[k + colors] = 42000 + ((x * 11 + y * 5) % 23000);
  }
  const points = [[128, 128], [Math.min(width - 40, 1000), 255], [Math.min(width - 40, 1024), 256],
    [Math.floor(width * .75), Math.floor(height * .7)]].filter(([x, y]) => x > 4 && y > 4 && x < width - 4 && y < height - 4);
  // Semi-transparent edges are deliberately protected by the filter. Keep the
  // repair/donor neighborhoods opaque, with varying alpha everywhere else.
  if (alpha) for (const [cx, cy] of points) {
    for (let y = Math.max(0, cy - 64); y <= Math.min(height - 1, cy + 64); y++) {
      for (let x = Math.max(0, cx - 64); x <= Math.min(width - 1, cx + 64); x++) data[(y * width + x) * channels + colors] = 65535;
    }
  }
  for (const [cx, cy] of points) for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) {
    if (dx * dx + dy * dy > 4) continue;
    const k = ((cy + dy) * width + cx + dx) * channels;
    for (let c = 0; c < colors; c++) data[k + c] = polarity === 'dark' ? 2000 : 61000;
  }
  if (depth === 8) for (let i = 0; i < data.length; i++) data[i] = Math.round(data[i] / 257) * 257;
  return { width, height, channels, colorChannels: colors, alpha, depth, data, points };
}

function assertLocalized(original, result, radius = 12) {
  assert.equal(result.channels, original.channels);
  assert.equal(result.depth, original.depth);
  let changed = 0;
  for (let y = 0; y < original.height; y++) for (let x = 0; x < original.width; x++) {
    const k = (y * original.width + x) * original.channels;
    const near = original.points.some(([cx, cy]) => Math.abs(x - cx) <= radius && Math.abs(y - cy) <= radius);
    for (let c = 0; c < original.channels; c++) {
      if (original.alpha && c === original.channels - 1) assert.equal(result.data[k + c], original.data[k + c], 'alpha changed');
      else if (result.data[k + c] !== original.data[k + c]) {
        changed++;
        assert.ok(near, `non-dust sample changed at ${x},${y},${c}`);
      }
    }
  }
  assert.ok(changed > 0, 'fixture dust was not repaired');
  return changed;
}

async function runHostTests(options = {}) {
  const workDir = path.resolve(options.workDir || path.join(__dirname, '../../.plugin-host-work'));
  // launch:false is intentional: the caller must explicitly prepare a dedicated
  // test session. No fallback attaches to another application's control port.
  const { client, session } = await ensureSession({ workDir, launch: false });
  client.timeoutMs = 65000;
  const originalStatus = await client.status();
  const originalIndex = originalStatus.session?.active;
  const { bytes, module } = await loadModule(options.plugin);
  const manifest = await inspectModule(module);
  const installed = await client.execute('plugin.install', { data: bytes.toString('base64') });
  const listed = await client.execute('plugin.list');
  assert.ok(listed.plugins.some(p => p.id === PLUGIN_ID), 'host did not list the plugin');
  const directory = await fs.mkdtemp(path.join(workDir, 'plugin-test-'));
  const report = { plugin: manifest, pluginBytes: bytes.length, sessionPid: session.pid,
    tests: [], startedAt: new Date().toISOString() };

  async function withImage(name, image, body) {
    const input = path.join(directory, `${name}.tiff`);
    await fs.writeFile(input, encodeTiff(image, { compression: 'deflate' }));
    await client.request('app.open', { path: input });
    const snapshot = await client.getActiveDocument();
    const save = async suffix => {
      const filename = path.join(directory, `${name}-${suffix}.tiff`);
      await client.request('app.save', { path: filename, tiffLayers: false, tiffCompression: 'none', tiffTransparency: true });
      return decodeTiff(await fs.readFile(filename));
    };
    try { return await body({ image, snapshot, save }); }
    finally {
      await client.execute('file.close', { document: snapshot.index, save: 'discard' });
      if (Number.isInteger(originalIndex) && originalIndex >= 0) await client.execute('document.activate', { document: originalIndex });
    }
  }

  for (const channels of [1, 4]) await withImage(`depth16-c${channels}`, fixture(1152, 768, channels), async ({ image, save }) => {
    const before = await save('before');
    assert.deepEqual(before.data, image.data, 'host TIFF baseline changed samples before the filter');
    const started = performance.now();
    await client.execute('plugin.run', { id: PLUGIN_ID, params: DEFAULT_PARAMS });
    const elapsedMs = performance.now() - started;
    const after = await save('after');
    const changedSamples = assertLocalized(image, after);
    report.tests.push({ name: `host-16bit-${channels}channels-locality-alpha`, elapsedMs, changedSamples,
      iccPreserved: !before.icc || before.icc.equals(after.icc) });
    assert.ok(!before.icc || before.icc.equals(after.icc), 'ICC changed');
    await client.execute('edit.undo');
    const undone = await save('undo');
    assert.deepEqual(undone.data, before.data, 'one undo did not restore all source samples');
  });

  await withImage('selection', fixture(512, 384, 1), async ({ image, save }) => {
    const before = await save('before');
    await client.execute('select.rect', { x: 0, y: 0, width: 256, height: 384, antiAlias: false });
    await client.execute('plugin.run', { id: PLUGIN_ID, params: DEFAULT_PARAMS });
    const after = await save('after');
    const at = (img, x, y) => img.data[y * img.width + x];
    assert.ok(at(after, 128, 128) < at(before, 128, 128), 'selected dust was not repaired');
    for (let y = 0; y < image.height; y++) for (let x = 256; x < image.width; x++) assert.equal(at(after, x, y), at(before, x, y), 'filter changed outside selection');
    report.tests.push({ name: 'host-selection-coverage', passed: true });
  });

  await withImage('smart-filter', fixture(320, 320, 1), async ({ save }) => {
    const before = await save('before');
    await client.execute('layer.smartObjects.convertToSmartObject');
    await client.execute('plugin.run', { id: PLUGIN_ID, params: DEFAULT_PARAMS });
    const after = await save('after');
    const at = (img, x, y) => img.data[y * img.width + x];
    assert.ok(at(after, 128, 128) < at(before, 128, 128), 'smart filter did not repair dust');
    await client.execute('layer.smartFilter.setVisible', { index: 0, visible: false });
    const hidden = await save('hidden');
    assert.deepEqual(hidden.data, before.data, 'disabling smart filter did not restore source');
    report.tests.push({ name: 'host-smart-filter-toggle', passed: true });
  });

  if (options.benchmark !== false) await withImage('24mp', fixture(6000, 4000, 3), async ({ save }) => {
    const started = performance.now();
    await client.execute('plugin.run', { id: PLUGIN_ID, params: DEFAULT_PARAMS });
    const elapsedMs = performance.now() - started;
    const after = await save('after');
    assert.ok(after.data[(128 * 6000 + 128) * 3] < 61000, '24 MP dust was not repaired');
    report.tests.push({ name: 'host-24mp-rgb16', elapsedMs, pixels: 24_000_000 });
  });

  await withImage('menu-dialog', fixture(96, 96, 1), async () => {
    const menu = await client.request('ui.menu.invoke', { id: `plugin.filter.${PLUGIN_ID}` });
    if (menu?.dialog !== undefined) await client.request('ui.dialog.cancel', { dialog: menu.dialog });
    report.tests.push({ name: 'host-generated-parameter-dialog', dialogOpened: menu?.dialog !== undefined });
    assert.ok(menu?.dialog !== undefined, 'plugin menu did not open parameter dialog');
  });
  report.finishedAt = new Date().toISOString();
  await fs.writeFile(path.join(directory, 'report.json'), JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify({ reportPath: path.join(directory, 'report.json'), ...report }, null, 2));
  return report;
}

async function runManualRecoveryTest(options = {}) {
  const workDir = path.resolve(options.workDir || path.join(__dirname, '../../.plugin-host-work'));
  const { client } = await ensureSession({ workDir, launch: false });
  const directory = await fs.mkdtemp(path.join(workDir, 'manual-test-'));
  const original = fixture(512, 384, 1);
  const cleaned = { ...original, data: new Uint16Array(original.data) };
  const mask = { width: original.width, height: original.height, channels: 1, depth: 8,
    alpha: false, data: new Uint16Array(original.width * original.height) };
  for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) {
    if (dx * dx + dy * dy > 4) continue;
    const k = (128 + dy) * original.width + 128 + dx;
    cleaned.data[k] = original.data[(128 + dy) * original.width + 100 + dx];
    mask.data[k] = 65535;
  }
  const sourcePath = path.join(directory, 'source.tiff'), cleanedPath = path.join(directory, 'cleaned.tiff'), maskPath = path.join(directory, 'mask.tiff');
  for (const [filename, image] of [[sourcePath, original], [cleanedPath, cleaned], [maskPath, mask]]) await fs.writeFile(filename, encodeTiff(image));
  await client.request('app.open', { path: sourcePath });
  const snapshot = await client.getActiveDocument();
  const save = async suffix => {
    const filename = path.join(directory, suffix + '.tiff');
    await client.request('app.save', { path: filename, tiffLayers: false });
    return decodeTiff(await fs.readFile(filename));
  };
  try {
    const imported = await client.importResult({ snapshot, cleanedPath, maskPath, manualEditable: true });
    const visible = await save('imported');
    assert.deepEqual(visible.data, cleaned.data, 'editable import changed pixels outside the dust mask');
    await client.execute('channel.target.layerMask');
    await client.execute('paint.stroke', { target: 'mask', points: [[128, 128, 1]], size: 18, hardness: 1,
      opacity: 1, flow: 1, color: '#000000', seed: 7 });
    const restored = await save('restored');
    const center = 128 * original.width + 128;
    assert.equal(restored.data[center], original.data[center], 'black mask painting did not recover the original dust pixel');
    await client.execute('channel.target.composite');
    // A different unrepaired speck remains on the ordinary pixel layer. This is
    // the same command that PhotoCraft's J/Spot Healing tool dispatches.
    const x = 384, y = 268, k = y * original.width + x;
    assert.equal(restored.data[k], original.data[k]);
    await client.execute('paint.spotHealing', { layer: imported.layer, target: 'pixels', points: [[x, y, 1]],
      size: 16, hardness: 100, opacity: 100, flow: 100, type: 'proximityMatch', sampleAllLayers: false });
    const spotted = await save('spot-healed');
    assert.ok(spotted.data[k] < restored.data[k], 'Spot Healing did not repair the missed dust');
    const report = { name: 'manualEditable-white-mask-black-restore-and-spot-heal', layer: imported.layer,
      restoreBefore: visible.data[center], restoreAfter: restored.data[center], spotBefore: restored.data[k], spotAfter: spotted.data[k],
      reportPath: path.join(directory, 'report.json') };
    await fs.writeFile(report.reportPath, JSON.stringify(report, null, 2) + '\n');
    console.log(JSON.stringify(report, null, 2));
    return report;
  } finally { await client.execute('file.close', { document: snapshot.index, save: 'discard' }); }
}

if (require.main === module) {
  const args = process.argv.slice(2), get = name => args.includes(name) ? args[args.indexOf(name) + 1] : undefined;
  runHostTests({ workDir: get('--work-dir'), plugin: get('--plugin'), benchmark: !args.includes('--no-benchmark') })
    .catch(error => { console.error(error.stack || error.message); process.exitCode = 1; });
}

module.exports = { PLUGIN_ID, DEFAULT_PLUGIN, DEFAULT_PARAMS, loadModule, inspectModule, runWasm, fixture, assertLocalized, runHostTests, runManualRecoveryTest };
