'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { execFile } = require('node:child_process');
const { promisify, parseArgs } = require('node:util');
const { setTimeout: delay } = require('node:timers/promises');
const { PhotoCraftClient, confinedPath } = require('../src/photocraft.cjs');
const { decodeTiff } = require('../src/tiff.cjs');
const { PLUGIN_ID, DEFAULT_PLUGIN, DEFAULT_PARAMS, loadModule, inspectModule, runWasm } = require('./test-plugin-host.cjs');

const exec = promisify(execFile);
const SAVE = { wait: false, tiffLayers: false, tiffCompression: 'none', tiffTransparency: true };
const FORMAT = ['width', 'height', 'channels', 'depth', 'alpha'];

function signature(document) {
  assert.ok(document, 'PhotoCraft did not report a document');
  const { path, revision, history, activeLayer, layers, selectionBounds, quickMask } = document;
  return { path, revision, history, activeLayer, layers: layers.map(layer => layer.id), selectionBounds, quickMask };
}

function samples(image, [x, y]) {
  const offset = (y * image.width + x) * image.channels;
  return Array.from(image.data.subarray(offset, offset + image.channels));
}

function assertFormat(source, output) {
  for (const field of FORMAT) assert.equal(output[field], source[field], field);
  assert.deepEqual(output.icc, source.icc, 'ICC profile changed');
  if (source.alpha) for (let k = source.colorChannels; k < source.data.length; k += source.channels) {
    if (output.data[k] !== source.data[k]) assert.fail(`alpha changed at sample ${k}`);
  }
}

function crop(image, x, y, width, height) {
  const data = new Uint16Array(width * height * image.channels);
  const stride = width * image.channels;
  for (let j = 0; j < height; j++) {
    const start = ((y + j) * image.width + x) * image.channels;
    data.set(image.data.subarray(start, start + stride), j * stride);
  }
  return { ...image, width, height, data };
}

async function findPreviewPoint(image, module) {
  const side = 192;
  for (const fy of [.25, .4, .55, .7, .15, .85]) {
    for (const fx of [.3, .45, .6, .75, .15, .85]) {
      const x = Math.round(image.width * fx) - side / 2;
      const y = Math.round(image.height * fy) - side / 2;
      const patch = crop(image, x, y, side, side);
      const repair = await runWasm(module, patch, DEFAULT_PARAMS);
      assert.equal(repair.rc, 0);
      let best = null;
      for (let j = 52; j < side - 52; j++) for (let i = 52; i < side - 52; i++) {
        const k = (j * side + i) * image.channels;
        const delta = Math.abs(Math.round(repair.data[k] * 65535) - patch.data[k]);
        if (delta >= 2500 && (!best || delta > best.delta)) best = { point: [x + i, y + j], delta };
      }
      if (best) return best;
    }
  }
  assert.fail('No sufficiently strong known repair in source crops. Supply a verified --point x,y.');
}

function autoChanges(original, repaired, preferred) {
  assertFormat(original, repaired);
  let changed = 0, largest = 0, recovery = null, other = null;
  const preferredOutput = preferred && samples(repaired, preferred);
  const usePreferred = preferred && samples(original, preferred).some((value, c) => value !== preferredOutput[c]);
  for (let y = 0; y < original.height; y++) for (let x = 0; x < original.width; x++) {
    const k = (y * original.width + x) * original.channels;
    let delta = 0;
    for (let c = 0; c < original.colorChannels; c++) delta = Math.max(delta, Math.abs(original.data[k + c] - repaired.data[k + c]));
    if (delta === 0) continue;
    changed++;
    if (!usePreferred && delta > largest && x > 30 && y > 30 && x < original.width - 30 && y < original.height - 30) {
      largest = delta;
      recovery = [x, y];
    }
  }
  if (usePreferred) recovery = preferred;
  assert.ok(recovery, 'No repair candidate was found in the full-resolution export');
  // A distant edit is a positive control that the mask only restores locally.
  for (let y = 30; !other && y < original.height - 30; y++) for (let x = 30; x < original.width - 30; x++) {
    if (Math.max(Math.abs(x - recovery[0]), Math.abs(y - recovery[1])) < 100) continue;
    const k = (y * original.width + x) * original.channels;
    if (Math.abs(original.data[k] - repaired.data[k]) > 200) { other = [x, y]; break; }
  }
  assert.ok(other, 'No distant repaired point for the recovery control');
  return { changed, recovery, other };
}

function canvasDelta(before, after, { region, selection = false } = {}) {
  assert.equal(before.width, after.width);
  assert.equal(before.height, after.height);
  // Keep to the canvas left of the centered command dialog, outside its controls.
  const box = region || [
    .07 * before.width, .36 * before.height, .27 * before.width, .64 * before.height,
  ].map(Math.round);
  const [x0, y0, x1, y1] = box;
  assert.ok(x0 >= 0 && y0 >= 0 && x0 < x1 && y0 < y1 && x1 <= before.width && y1 <= before.height,
    'Screen comparison bounds must fit the screenshot');
  let changed = 0, marked = 0, strongest = null, maxDelta = 0;
  for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
    const a = samples(before, [x, y]), b = samples(after, [x, y]);
    const delta = Math.max(...b.slice(0, 3).map((v, c) => Math.abs(v - a[c]))) / 257;
    if (delta === 0) continue;
    // With no exact interior box, ignore black-to-white marching ants animation.
    if (selection && !region && isSelectionEdge(a) && isSelectionEdge(b)) continue;
    changed++;
    const redGain = ((b[0] - Math.max(b[1], b[2])) - (a[0] - Math.max(a[1], a[2]))) / 257;
    if (redGain >= 28 && b[0] - b[1] >= 20 * 257 && b[1] - b[2] >= 5 * 257) marked++;
    if (delta > maxDelta) { maxDelta = delta; strongest = { x, y, before: a, after: b }; }
  }
  return { changed, marked, maxDelta, strongest, box, compared: (x1 - x0) * (y1 - y0) };
}

function isSelectionEdge([r, g, b]) {
  return r === g && g === b && (r === 0 || r === 65535);
}

async function run(options) {
  const source = await fs.realpath(options.source);
  const plugin = await fs.realpath(options.plugin || DEFAULT_PLUGIN);
  const { bytes, module } = await loadModule(plugin);
  const manifest = await inspectModule(module);
  if (options['find-point']) {
    const image = await readImage(source);
    return findPreviewPoint(image, module);
  }

  // Require both the directory and the exact PID given by a dedicated launch.
  // An existing or nonempty editing session is never a test target.
  const workDir = await fs.realpath(options['work-dir']);
  const session = JSON.parse(await fs.readFile(path.join(workDir, 'session.json'), 'utf8'));
  assert.equal(session.workDir, workDir, 'session work directory differs');
  assert.equal(session.pid, Number(options.pid), 'session PID differs');
  const tokenFile = await confinedPath(workDir, session.tokenFile);
  const client = new PhotoCraftClient({ port: session.port, tokenFile, workDir, timeoutMs: 65000 });
  const probe = new PhotoCraftClient({ port: session.port, tokenFile, workDir, timeoutMs: 3500 });
  const initial = await probe.request('ui.inspect');
  assert.equal(initial.session.documents.length, 0, 'Use a fresh, empty, dedicated PhotoCraft session');
  assert.equal(initial.dialogs.length, 0, 'Dismiss isolated session dialogs before testing');

  const directory = await fs.mkdtemp(path.join(workDir, 'photo96-workflow-'));
  const input = path.join(directory, 'AUTOMATION-TEST-96MP.tiff');
  const reportPath = path.join(directory, 'report.json');
  const originalStat = await fs.stat(source);
  const report = {
    source, input, reportPath, sessionPid: session.pid, manifest, plugin,
    pluginSha256: createHash('sha256').update(bytes).digest('hex'), startedAt: new Date().toISOString(), phases: [],
  };
  const write = () => fs.writeFile(reportPath, JSON.stringify(report, null, 2) + '\n');

  async function phase(name, work) {
    const entry = { name, startedAt: new Date().toISOString() };
    report.phases.push(entry);
    await write();
    console.error(`[${entry.startedAt}] ${name}`);
    const started = performance.now();
    const tick = setInterval(() => console.error(`  ${name} ${Math.round((performance.now() - started) / 1000)}s`), 12000);
    try {
      const result = await work(entry);
      entry.elapsedMs = Math.round(performance.now() - started);
      entry.passed = true;
      console.error(`  completed in ${(entry.elapsedMs / 1000).toFixed(2)}s`);
      return result;
    } catch (error) {
      entry.elapsedMs = Math.round(performance.now() - started);
      entry.error = error.message;
      entry.passed = false;
      throw error;
    } finally { clearInterval(tick); await write(); }
  }

  const inspect = () => probe.request('ui.inspect');
  async function poll(check, maxMs = 180000) {
    const deadline = Date.now() + maxMs;
    let last;
    while (Date.now() < deadline) {
      try {
        const result = await check();
        if (result) return result;
      } catch (error) {
        if (!['TIMEOUT', 'CONNECTION_CLOSED', 'CONNECTION_FAILED'].includes(error.code)) throw error;
        last = error.message;
      }
      await delay(1200);
    }
    assert.fail(`Expected PhotoCraft state was not observed in ${maxMs / 1000}s${last ? `: ${last}` : ''}`);
  }

  // A timeout never triggers a second edit. Reconcile only against a read-only
  // observation of this exact operation's result.
  async function once(method, params, entry, observed) {
    try { return await client.request(method, params); }
    catch (error) {
      if (!error.mayHaveApplied || !observed) throw error;
      entry.uncertainReply = error.message;
      console.error('  reply was uncertain; checking document/job state without repeating the operation');
      const confirmed = await poll(observed);
      entry.reconciled = true;
      return confirmed;
    }
  }

  async function waitJob(result, entry) {
    if (!result?.pending) return;
    entry.job = result.job;
    await poll(async () => {
      const status = await probe.request('jobs.list');
      const job = (Array.isArray(status) ? status : status.jobs).find(job => job.id === result.job);
      if (!job) return;
      if (['failed', 'cancelled'].includes(job.state)) assert.fail(job.error || `PhotoCraft job ${job.state}`);
      if (job.state === 'done') { entry.jobElapsedMs = job.elapsedMs; return true; }
    });
  }

  async function save(name) {
    return phase(`export ${name}`, async entry => {
      const filename = path.join(directory, `${name}.tiff`);
      let previousSize = 0;
      const saved = async () => {
        const state = await inspect();
        if (state.jobs?.saving?.some(job => job.path === filename)) return false;
        const stat = await fs.stat(filename).catch(error => error.code === 'ENOENT' ? null : Promise.reject(error));
        if (!stat?.size) return false;
        const stable = previousSize === stat.size;
        previousSize = stat.size;
        return stable;
      };
      await waitJob(await once('app.save', { ...SAVE, path: filename }, entry, saved), entry);
      await poll(saved);
      entry.file = filename;
      return filename;
    });
  }

  async function screenshot(name) {
    const png = path.join(directory, `${name}.png`);
    await client.request('ui.screenshot', { path: path.relative(workDir, png), focus: Boolean(options['raise-window']) });
    const tiff = path.join(directory, `${name}.tiff`);
    await exec('/usr/bin/sips', ['-s', 'format', 'tiff', png, '--out', tiff]);
    const image = await readImage(tiff);
    await fs.unlink(tiff);
    return { png, image };
  }

  const openDialog = async () => {
    const opened = await client.request('ui.menu.invoke', { id: `plugin.filter.${PLUGIN_ID}` });
    assert.ok(Number.isInteger(opened.dialog), 'Film Dust menu did not open a parameter dialog');
    return opened.dialog;
  };
  const field = (dialog, field, value) => client.request('ui.dialog.set', { dialog, field, value });

  try {
    await phase('copy and open real 96MP TIFF', async entry => {
      await fs.copyFile(source, input);
      const opened = async () => {
        const state = await inspect();
        return state.document?.path === input && state;
      };
      await once('app.open', { path: input }, entry, opened);
      const state = await poll(opened);
      const { width, height, depth, mode } = state.document;
      assert.ok(width * height >= 90_000_000, 'Expected the real ~96MP input');
      assert.equal(depth, 16);
      assert.equal(mode, 'Rgb');
      assert.equal(state.session.documents.length, 1);
      Object.assign(report, { width, height, depth, mode });
    });
    await phase('install and duplicate original layer', async entry => {
      await client.execute('plugin.install', { data: bytes.toString('base64') });
      const menus = await client.request('ui.menu.list');
      assert.ok(menus.some(item => item.id === `plugin.filter.${PLUGIN_ID}` && item.enabled));
      const original = (await inspect()).document.activeLayer;
      await once('engine.execute', { command: 'layer.duplicate', params: { layer: original, inPlace: true, name: 'Film Dust 修复' } },
        entry, async () => (await inspect()).document.layers.length === 2);
      const doc = (await inspect()).document;
      assert.equal(doc.layers.length, 2);
      assert.equal(doc.layers[1].id, original);
      assert.equal(doc.layers[0].id, doc.activeLayer);
      report.layers = { original, repaired: doc.activeLayer };
    });

    let point = parsePoint(options.point);
    if (!options['skip-preview']) {
      await phase('locate a known small speck and zoom the PhotoCraft canvas', async entry => {
        if (!point) {
          const candidate = await findPreviewPoint(await readImage(input), module);
          point = candidate.point;
          entry.cropWasmDelta = candidate.delta;
        }
        checkPoint(point, report, 100);
        const state = await inspect();
        const physicalWidth = state.window.width * state.window.pixelsPerPoint;
        await client.request('ui.set', { zoom: 2, center: [point[0] + Math.round(physicalWidth * .29 / 2), point[1]], rotation: 0 });
        entry.point = point;
        if (options['preview-selection']) {
          await client.execute('select.rect', { x: point[0] - 96, y: point[1] - 96, width: 192, height: 192, antiAlias: false });
        }
        entry.selection = Boolean(options['preview-selection']);
      });
      await phase('visible preview on the canvas and Cancel', async entry => {
        const initialView = await inspect();
        const before = signature(initialView.document);
        const region = options['screen-region']?.split(',').map(Number);
        if (region) assert.ok(region.length === 4 && region.every(Number.isInteger), 'Screen region must be x0,y0,x1,y1');
        const comparison = { region, selection: Boolean(options['preview-selection']) };
        const camera = state => ({
          view: state.views[state.session.active], window: state.window,
        });
        entry.camera = camera(initialView);
        entry.selectionBounds = before.selectionBounds;
        entry.lowResolutionPreviews = await client.execute('prefs.get', { path: 'performance.lowResolutionPreviews' });
        const dialog = await openDialog();
        const unchanged = async () => {
          const state = await inspect();
          assert.deepEqual(signature(state.document), before, 'Dialog preview or Cancel changed committed document history/pixels');
          assert.deepEqual(camera(state), camera(initialView), 'Canvas camera changed during the test');
          return state;
        };
        await field(dialog, '__preview', false);
        await field(dialog, 'preview', 'mark');
        await unchanged();
        await delay(300);
        const off = await screenshot('preview-off');
        await field(dialog, '__preview', true);
        let delta, on, previewError;
        try {
          await poll(async () => {
            const state = await unchanged();
            assert.equal(state.dialogs.find(item => item.id === dialog)?.fields?.__preview, true, 'Preview dialog changed externally');
            on = await screenshot('preview-mark');
            await unchanged();
            delta = canvasDelta(off.image, on.image, comparison);
            // A few high-chroma orange pixels are a mark. Whole-band differences
            // are an invalid comparison even if they meet a color threshold.
            return delta.marked >= 4 && delta.changed < delta.compared * .05;
          }, options['preview-timeout'] * 1000);
        } catch (error) { previewError = error; }
        entry.preview = { delta, off: off.png, mark: on?.png, error: previewError?.message };
        await unchanged();
        await client.request('ui.dialog.cancel', { dialog });
        await unchanged();
        assert.ok(!(await inspect()).dialogs.some(item => item.id === dialog), 'Cancel left the filter dialog open');
        const cancelled = await screenshot('preview-cancelled');
        await unchanged();
        const cancelDelta = canvasDelta(off.image, cancelled.image, comparison);
        entry.cancel = { delta: cancelDelta, screenshot: cancelled.png, history: before.history, revision: before.revision };
        assert.equal(cancelDelta.changed, 0, 'Cancel did not restore the original canvas');
        if (previewError) throw previewError;
      });
      if (options['preview-selection']) await client.execute('select.deselect');
    }
    if (options['preview-only']) {
      report.passed = true;
      return report;
    }

    await client.request('ui.set', { fit: true });
    const baselinePath = await save('baseline');
    await phase('confirm full-resolution repair once', async entry => {
      const before = signature((await inspect()).document);
      const dialog = await openDialog();
      // Disable live preview for this second dialog so the actual timing isolates OK.
      await field(dialog, '__preview', false);
      for (const [key, value] of Object.entries(DEFAULT_PARAMS)) await field(dialog, key, value);
      const committed = async () => {
        const state = await inspect();
        return state.document?.path === input && state.document.revision > before.revision &&
          JSON.stringify(state.document.history).includes(manifest.name) && state.document;
      };
      await waitJob(await once('ui.dialog.confirm', { dialog, wait: false }, entry, committed), entry);
      const after = signature(await poll(committed));
      assert.equal(after.history.length, before.history.length + 1, 'Confirm did not produce exactly one undo step');
      assert.equal(after.activeLayer, report.layers.repaired);
      entry.revision = after.revision;
      entry.history = after.history;
    });
    const repairPath = await save('repaired');
    const { recovery, other, originalWindow, repairedWindow, knownMissed, spot } = await phase('compare automatic pixels, alpha, and ICC', async entry => {
      const original = await readImage(baselinePath);
      const repaired = await readImage(repairPath);
      const preferred = parsePoint(options.recover) || point;
      if (preferred) checkPoint(preferred, original, 30);
      const changes = autoChanges(original, repaired, preferred);
      Object.assign(entry, changes, {
        iccBytes: original.icc?.length || 0, alphaSamplesChecked: original.alpha ? original.width * original.height : 0,
        original: samples(original, changes.recovery), repaired: samples(repaired, changes.recovery),
      });
      const knownMissed = parsePoint(options.missed);
      const spot = knownMissed || [Math.round(original.width * .1), Math.round(original.height * .15)];
      checkPoint(spot, original, 30);
      assert.ok(Math.max(Math.abs(spot[0] - changes.recovery[0]), Math.abs(spot[1] - changes.recovery[1])) > 50,
        'The missed point must be separate from the restored region');
      if (knownMissed) assert.deepEqual(samples(original, spot), samples(repaired, spot), 'Known missed point was already auto-repaired');
      return { ...changes, originalWindow: neighborhood(original, changes.recovery),
        repairedWindow: neighborhood(repaired, changes.recovery), knownMissed, spot };
    });

    const layer = report.layers.repaired;
    await phase('restore a real auto-edited point with the black layer mask', async () => {
      await client.execute('layer.layerMask.revealAll', { layer });
      assert.ok((await inspect()).document.layers.find(item => item.id === layer)?.hasMask);
      await client.execute('channel.target.layerMask');
      await client.execute('paint.stroke', { layer, target: 'mask', points: [[...recovery, 1]], size: 28,
        hardness: 1, opacity: 1, flow: 1, color: '#000000', seed: 7 });
      await client.execute('channel.target.composite');
    });
    const restoredPath = await save('restored');
    const restoredPoint = await phase('verify restored pixels and a distant retained edit', async entry => {
      const [restored, repaired] = await Promise.all([readImage(restoredPath), readImage(repairPath)]);
      assertFormat(repaired, restored);
      assert.notDeepEqual(originalWindow, repairedWindow);
      assert.deepEqual(neighborhood(restored, recovery), originalWindow, 'Black mask did not exactly restore original 3×3 samples');
      assert.deepEqual(samples(restored, other), samples(repaired, other), 'Black mask changed the distant control');
      entry.original = originalWindow[4];
      entry.autoRepaired = repairedWindow[4];
      entry.restored = samples(restored, recovery);
      return samples(restored, spot);
    });

    let beforeHealing = restoredPath;
    if (!knownMissed) {
      await phase('add a controlled missed speck on the test copy', async () => {
        await client.execute('paint.stroke', { layer, target: 'pixels', points: [[...spot, 1]], size: 5,
          hardness: 1, opacity: 1, flow: 1, color: '#ffffff', seed: 7 });
      });
      beforeHealing = await save('missed-speck');
    }
    await phase('run the J Spot Healing Brush path', async () => {
      await client.execute('paint.spotHealing', { layer, target: 'pixels', points: [[...spot, 1]],
        size: 18, hardness: 100, opacity: 100, flow: 100, type: 'proximityMatch', sampleAllLayers: false });
    });
    const healedPath = await save('healed');
    await phase('verify J pixels, retained recovery, alpha, and ICC', async entry => {
      const [missed, healed] = await Promise.all([readImage(beforeHealing), readImage(healedPath)]);
      assertFormat(missed, healed);
      assert.deepEqual(samples(healed, recovery), originalWindow[4], 'J invalidated the previous mask recovery');
      const before = samples(missed, spot), after = samples(healed, spot);
      assert.notDeepEqual(after, before, 'J did not change the missed point');
      if (!knownMissed) {
        const distance = a => a.reduce((total, value, i) => total + Math.abs(value - restoredPoint[i]), 0);
        assert.ok(distance(before) > 1000 && distance(after) < distance(before) * .4,
          'J did not remove the controlled speck');
      }
      Object.assign(entry, { spot, controlled: !knownMissed, before, after, cleanReference: knownMissed ? undefined : restoredPoint });
    });
    report.passed = true;
    return report;
  } catch (error) {
    report.passed = false;
    report.error = error.message;
    throw error;
  } finally {
    const stat = await fs.stat(source);
    report.originalSourceUnchanged = stat.size === originalStat.size && stat.mtimeMs === originalStat.mtimeMs;
    report.finishedAt = new Date().toISOString();
    await write();
    console.error(`Report ${reportPath}`);
  }
}

const readImage = async filename => decodeTiff(await fs.readFile(filename));

function neighborhood(image, [x, y]) {
  const pixels = [];
  for (let j = y - 1; j <= y + 1; j++) for (let i = x - 1; i <= x + 1; i++) pixels.push(samples(image, [i, j]));
  return pixels;
}

function parsePoint(value) {
  if (value === undefined) return null;
  assert.match(value, /^\d+,\d+$/, 'Point must be x,y in document pixels');
  return value.split(',').map(Number);
}

function checkPoint([x, y], { width, height }, margin) {
  assert.ok(x >= margin && y >= margin && x < width - margin && y < height - margin,
    `Point must be at least ${margin} pixels from image edges`);
}

if (require.main === module) {
  const options = parseArgs({ options: {
    help: { type: 'boolean' }, source: { type: 'string' }, plugin: { type: 'string' },
    'work-dir': { type: 'string' }, pid: { type: 'string' }, point: { type: 'string' },
    missed: { type: 'string' }, recover: { type: 'string' }, 'find-point': { type: 'boolean' },
    'preview-selection': { type: 'boolean' }, 'preview-only': { type: 'boolean' },
    'skip-preview': { type: 'boolean' }, 'raise-window': { type: 'boolean' },
    'screen-region': { type: 'string' },
    'preview-timeout': { type: 'string', default: '105' },
  } }).values;
  if (options.help) {
    console.log(`node scripts/test-photo96-workflow.cjs --source /path/to/96MP.tiff --work-dir /path/to/isolated-session --pid PID
  --plugin FILE          Plug-in WASM, defaults to the project build
  --point x,y            Known visible repair for preview. Otherwise search source crops
  --recover x,y          Verified automatic edit to restore, if changed by the full repair
  --missed x,y           Verified real missed spot. Otherwise add a controlled speck to the test copy
  --preview-selection    Limit the preview filter to a 192×192 selected region, then deselect
  --preview-only         Stop after preview and cancel
  --skip-preview         Run full repair and manual recovery only
  --raise-window         Bring the isolated test window forward for screenshots
  --screen-region BOX    Compare exact screenshot pixels inside x0,y0,x1,y1
  --find-point           Search source crops offline; no session required
  --preview-timeout SEC  Maximum preview observation time (default 105)`);
  } else {
    assert.ok(options.source, '--source is required');
    assert.ok(options['find-point'] || options['work-dir'] && /^\d+$/.test(options.pid || ''), '--work-dir and --pid are required');
    assert.ok(!(options['preview-only'] && options['skip-preview']), 'Incompatible preview options');
    assert.ok(Number(options['preview-timeout']) >= 1, 'Positive --preview-timeout required');
    run(options).then(report => console.log(JSON.stringify(report, null, 2))).catch(error => {
      console.error(error.stack);
      process.exitCode = 1;
    });
  }
}

module.exports = { findPreviewPoint, autoChanges, canvasDelta };
