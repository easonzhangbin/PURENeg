'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { processScan, processFile, composeMasked, optionsChecked, checkImage } = require('../src/processor.cjs');
const { parseArgs } = require('../src/cli.cjs');

function fixture(width = 384, height = 320, depth = 16) {
  let seed = 19;
  const random = () => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed / 4294967296; };
  const data = new Uint16Array(width * height * 3);
  const centers = [];
  for (let y = 50; y < height - 40; y += 55) for (let x = 50; x < width - 40; x += 65) centers.push([x, y]);
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    let value = 0.32 + 0.1 * x / width + (random() - 0.5) * 0.02;
    if (centers.some(([cx, cy]) => (x - cx) ** 2 + (y - cy) ** 2 <= 2.2 ** 2)) value = 0.96;
    for (let c = 0; c < 3; c++) {
      const full = Math.round(value * [0.96, 1, 0.94][c] * 65535);
      data[(y * width + x) * 3 + c] = depth === 8 ? Math.round(full / 257) * 257 : full;
    }
  }
  return { width, height, channels: 3, colorChannels: 3, alpha: false, depth, data, icc: null };
}

test('final mask shields low-amplitude intermediate changes and preserves alpha', () => {
  const original = { channels: 4, data: new Uint16Array([10000, 10000, 10000, 65535, 20000, 20000, 20000, 65535]) };
  const repaired = new Uint16Array([9990, 9990, 9990, 15000, 16000, 17000]);
  const result = composeMasked(original, repaired, new Uint8Array([0, 1]), 3);
  assert.deepEqual([...result.data], [10000,10000,10000,65535,15000,16000,17000,65535]);
  assert.equal(result.changedPixels, 1);
  assert.equal(original.data[4], 20000);
});

test('rejects unsupported modes, transparency and invalid options before processing', () => {
  assert.throws(() => optionsChecked({ sensitivity: NaN }), /灵敏度/);
  assert.throws(() => optionsChecked({ polarity: 'negative' }), /灰尘类型/);
  for (const detect of ['', [], 'dust,unknown', 'dust,dust']) {
    assert.throws(() => optionsChecked({ detect }), /识别类型/);
  }
  assert.throws(() => checkImage({ width: 1, height: 1, depth: 32, channels: 3, data: new Uint16Array(3) }), /8\/16/);
  assert.throws(() => checkImage({ width: 1, height: 1, depth: 16, channels: 4, colorChannels: 3, alpha: true, data: new Uint16Array([1,2,3,30000]) }), /不透明/);
  assert.throws(() => parseArgs(['process', '--unexpected', '1']), /未知参数/);
  assert.throws(() => parseArgs(['process', '--input']), /缺少值/);
  assert.throws(() => parseArgs(['process', '--input', 'a', '--input', 'b']), /重复参数/);
});

test('scratch and dust selection changes the real mask independently', async () => {
  const image = fixture(656, 440);
  const at = (x, y) => y * image.width + x;
  for (let y = 26; y <= 28; y++) for (let x = 72; x < 580; x++) for (let c = 0; c < 3; c++) {
    image.data[at(x, y) * 3 + c] += 1000;
  }
  const scratches = await processScan(image, { polarity: 'bright', detect: 'scratches' });
  assert.deepEqual(scratches.stats.detection_types, ['scratches']);
  assert.ok(scratches.mask.data[at(310, 27)], 'the thin line belongs in the scratch mask');
  assert.equal(scratches.mask.data[at(50, 50)], 0, 'the isolated dust spot was not selected');
  assert.equal(scratches.cleaned.data[at(50, 50) * 3], image.data[at(50, 50) * 3]);
  const dust = await processScan(image, { polarity: 'bright', detect: 'dust' });
  assert.deepEqual(dust.stats.detection_types, ['dust']);
  assert.ok(dust.mask.data[at(50, 50)], 'the isolated spot belongs in the dust mask');
  assert.equal(dust.mask.data[at(310, 27)], 0, 'the scratch was not selected');
});

test('aborted jobs never enter the engine', async () => {
  const controller = new AbortController(); controller.abort();
  await assert.rejects(processScan(fixture(64, 64), { signal: controller.signal }), { name: 'AbortError' });
});

test('real complete engine repairs a synthetic 16-bit scan without changing unmasked samples', { timeout: 120000 }, async () => {
  const image = fixture();
  const before = Uint16Array.from(image.data);
  const progress = [];
  const result = await processScan(image, { polarity: 'bright', onProgress: (p) => progress.push(p.fraction) });
  assert.deepEqual(image.data, before, 'input array must remain immutable');
  assert.ok(result.stats.healed > 0, 'known high-contrast synthetic specks should be detected');
  assert.ok(result.changed);
  assert.equal(result.cleaned.depth, 16);
  assert.equal(result.mask.depth, 8);
  for (let i = 0; i < result.mask.data.length; i++) if (!result.mask.data[i]) {
    for (let c = 0; c < 3; c++) assert.equal(result.cleaned.data[i * 3 + c], before[i * 3 + c]);
  }
  assert.ok(progress.every((fraction, i) => fraction >= 0 && fraction <= 1 && (i === 0 || fraction >= progress[i - 1])));
});

test('TIFF file workflow preserves source and creates independent result/mask/report', { timeout: 120000 }, async () => {
  const { encodeTiff, decodeTiff } = require('../src/tiff.cjs');
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'pureneg-file-test-'));
  try {
    const input = path.join(dir, '扫描件.tiff');
    const inputBytes = encodeTiff(fixture(192, 160, 8));
    await fs.writeFile(input, inputBytes);
    const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
    const result = await processFile(input, path.join(dir, 'output'), { polarity: 'bright' });
    assert.equal(digest(await fs.readFile(input)), digest(inputBytes));
    const cleaned = decodeTiff(await fs.readFile(result.paths.cleaned));
    const mask = decodeTiff(await fs.readFile(result.paths.mask));
    assert.equal(cleaned.depth, 8);
    assert.equal(mask.channels, 1);
    assert.equal(mask.width, cleaned.width);
    const report = JSON.parse(await fs.readFile(result.paths.report, 'utf8'));
    assert.equal(report.upstream.revision, 'fcf68d6c6a77e4373db28f878c7f80f7b8934f3f');
    assert.notEqual(result.paths.cleaned, input);
  } finally { await fs.rm(dir, { recursive: true, force: true }); }
});

module.exports = { fixture };
