'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { DEFAULT_PLUGIN, loadModule, inspectModule, runWasm, fixture } = require('../scripts/test-plugin-host.cjs');

const built = fs.existsSync(DEFAULT_PLUGIN);
let loaded;
const plugin = () => loaded ||= loadModule();
const options = { skip: built ? false : 'run plugin/build.sh to build the PhotoCraft Wasm plugin first' };

test('PhotoCraft module is self-contained ABI v1 with a valid filter manifest', options, async () => {
  const { module } = await plugin();
  const m = await inspectModule(module);
  assert.equal(m.kind, 'filter');
  assert.ok(m.overlap > 0 && m.overlap <= 256);
  assert.equal(m.params.preview.type, 'choice');
});

for (const channels of [1, 2, 3, 4]) test(`Wasm repairs dust and preserves every unrelated 16-bit/${channels}-channel sample`, options, async () => {
  const { module } = await plugin();
  const image = fixture(320, 320, channels);
  const before = Float32Array.from(image.data, v => v / 65535);
  const result = await runWasm(module, image);
  assert.equal(result.rc, 0);
  assert.ok(result.data[(128 * 320 + 128) * channels] < before[(128 * 320 + 128) * channels]);
  const colors = channels <= 2 ? 1 : 3;
  for (let y = 0; y < image.height; y++) for (let x = 0; x < image.width; x++) {
    const near = image.points.some(([cx, cy]) => Math.abs(x - cx) <= 12 && Math.abs(y - cy) <= 12);
    for (let c = 0; c < channels; c++) if (!near || c >= colors) {
      const k = (y * image.width + x) * channels + c;
      assert.equal(result.data[k], before[k], `changed ${x},${y},${c}`);
    }
  }
});

test('Wasm supports dark dust and strength zero leaves the image exact', options, async () => {
  const { module } = await plugin();
  const image = fixture(320, 320, 3, 16, 'dark');
  const repaired = await runWasm(module, image, { polarity: 'dark' });
  assert.equal(repaired.rc, 0);
  assert.ok(repaired.data[(128 * 320 + 128) * 3] > 2000 / 65535);
  const identity = await runWasm(module, image, { strength: 0 });
  assert.equal(identity.rc, 0);
  assert.deepEqual(identity.data, Float32Array.from(image.data, v => v / 65535));
});

test('Wasm repairs RGB8 dust and conservatively leaves semi-transparent pixels alone', options, async () => {
  const { module } = await plugin();
  const image = fixture(320, 320, 3, 8);
  const repaired = await runWasm(module, image);
  assert.equal(repaired.rc, 0);
  assert.ok(repaired.data[(128 * 320 + 128) * 3] < image.data[(128 * 320 + 128) * 3] / 65535);
  const transparent = fixture(320, 320, 4);
  for (let i = 3; i < transparent.data.length; i += 4) transparent.data[i] = 32768;
  const protectedResult = await runWasm(module, transparent);
  assert.equal(protectedResult.rc, 0);
  assert.deepEqual(protectedResult.data, Float32Array.from(transparent.data, v => v / 65535));
});

test('Wasm rejects unsupported HDR and CMYK before changing input samples', options, async () => {
  const { module } = await plugin();
  const image = fixture(32, 32, 4);
  for (const format of [32 | (1 << 8) | (3 << 16), 16 | (4 << 16)]) {
    const result = await runWasm(module, image, {}, format);
    assert.notEqual(result.rc, 0);
    assert.deepEqual(result.data, Float32Array.from(image.data, v => v / 65535));
  }
});

test('Wasm band interiors agree exactly with a whole-image pass at host 256px boundaries', options, async () => {
  const { module } = await plugin(), manifest = await inspectModule(module);
  const image = fixture(1152, 512, 1);
  const source = Float32Array.from(image.data, v => v / 65535);
  const whole = await runWasm(module, image, { maxSize: 16 });
  assert.equal(whole.rc, 0);
  const halo = manifest.overlap, result = new Float32Array(source.length);
  for (let by = 0; by < image.height; by += 256) for (let bx = 0; bx < image.width; bx += 1024) {
    const bw = Math.min(1024, image.width - bx), bh = Math.min(256, image.height - by);
    const width = bw + halo * 2, height = bh + halo * 2, data = new Float32Array(width * height);
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
      const sx = Math.max(0, Math.min(image.width - 1, bx + x - halo));
      const sy = Math.max(0, Math.min(image.height - 1, by + y - halo));
      data[y * width + x] = source[sy * image.width + sx];
    }
    const band = await runWasm(module, { width, height, channels: 1, depth: 16, data }, {
      maxSize: 16,
      _image: { x: bx - halo, y: by - halo, canvasWidth: image.width, canvasHeight: image.height, overlap: halo },
    });
    assert.equal(band.rc, 0);
    for (let y = 0; y < bh; y++) result.set(band.data.subarray((y + halo) * width + halo, (y + halo) * width + halo + bw), (by + y) * image.width + bx);
  }
  assert.deepEqual(result, whole.data);
});
