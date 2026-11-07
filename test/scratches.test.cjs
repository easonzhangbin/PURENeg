'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { detectScratches, healScratches } = require('../src/scratches.cjs');

test('faint broken scratches of either polarity are detected without marking a real broad stripe', async () => {
  const W = 656, H = 440, image = new Uint16Array(W * H);
  let seed = 129763;
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    let v = 23000 + 3 * y + ((seed >>> 24) - 128);
    if (y >= 222 && y < 248) v += 4200; // the scene, not a defect
    if (x >= 56 && x < 561 && (x < 272 || x >= 308) && Math.abs(y - (71 + Math.round(x / 170))) <= 1) v += 580;
    if (y >= 117 && y < 423 && Math.abs(x - 517) <= 1) v -= 680;
    image[y * W + x] = v;
  }
  const lines = await detectScratches(image, W, H, 1, 'auto');
  assert.ok(lines.some(line => line.sign > 0 && !line.vertical && line.length >= 400));
  assert.ok(lines.some(line => line.sign < 0 && line.vertical && line.length >= 250));
  const repair = image.slice(), mask = new Uint8Array(W * H);
  const result = await healScratches(lines, repair, mask, W, H, 1, async () => {});
  assert.ok(result.marks.some(line => line.polarity === 'bright'));
  assert.ok(result.marks.some(line => line.polarity === 'dark'));
  assert.ok(repair[72 * W + 150] + 350 < image[72 * W + 150]);
  assert.ok(repair[170 * W + 517] > image[170 * W + 517] + 400);
  for (let y = 216; y <= 254; y++) for (let x = 32; x < 460; x++) {
    const p = y * W + x;
    assert.equal(mask[p], 0, 'the broad scene stripe and its edges are protected');
  }
  for (let p = 0; p < mask.length; p++) if (!mask[p]) assert.equal(repair[p], image[p]);
});

test('a faint sloped tail continues across an uneven background and stops at the end of the scratch', async () => {
  const W = 620, H = 240, image = new Uint16Array(W * H);
  const center = x => 85 + Math.round(x * 0.055);
  let seed = 2230;
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const d = y - center(x);
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    let value = 23000 + ((seed >>> 24) - 128);
    if (x >= 284 && d < -4) value += 850;
    if (x >= 284 && d > 4) value -= 300;
    if (x >= 42 && x < 518 && Math.abs(d) <= 1) value += 600;
    image[y * W + x] = value;
  }
  const lines = await detectScratches(image, W, H, 1, 'bright');
  const repair = image.slice(), mask = new Uint8Array(image.length);
  await healScratches(lines, repair, mask, W, H, 1, async () => {});
  assert.equal(mask[center(470) * W + 470], 1, 'continued to the weak side of the line');
  assert.equal(mask[center(544) * W + 544], 0, 'stopped after the thin ridge disappeared');
  assert.equal(mask[(center(470) - 5) * W + 470], 0, 'preserved the underlying brightness step');
});

test('blurred grout near a confirmed frame edge stays intact while a thin scratch is repaired', async () => {
  const W = 800, H = 460, image = new Uint16Array(W * H);
  const groutY = x => 357 + Math.round(x * 0.02);
  let seed = 18114;
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    let value = y < 424 ? 23500 + ((seed >>> 24) - 128) : 600;
    if (x >= 56 && x < 696) value += Math.round(3600 * Math.exp(-0.5 * ((y - groutY(x)) / 4.4) ** 2));
    if (x >= 80 && x < 642 && Math.abs(y - 403) <= 1) value += 520;
    image[y * W + x] = value;
  }
  const frame = { edges: { bottom: { a: 36, b: 0 } } };
  const tick = async () => {};
  const lines = await detectScratches(image, W, H, 1, 'bright', tick, frame);
  const repair = image.slice(), mask = new Uint8Array(image.length);
  await healScratches(lines, repair, mask, W, H, 1, tick);

  assert.equal(mask[403 * W + 400], 1, 'the nearby thin scratch is still selected');
  assert.ok(repair[403 * W + 400] < image[403 * W + 400] - 250);
  for (let x = 60; x < 690; x++) {
    for (let y = groutY(x) - 5; y <= groutY(x) + 5; y++) {
      assert.equal(mask[y * W + x], 0, 'the broad seam is preserved');
    }
  }
});
