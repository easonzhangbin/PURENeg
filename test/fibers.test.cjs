'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { enhanceFibers } = require('../src/fibers.cjs');

function fixture(polarity, curved = true) {
  const W = 270, H = 245, C = 3;
  const ridgeX = y => 122 + 0.18 * (y - 107) + (curved ? 0.0022 * (y - 107) ** 2 : 0);
  const original = new Uint16Array(W * H * C);
  for (let y = 0; y < H; y++) {
    const stripe = Math.exp(-0.5 * ((y - 126) / 12) ** 2);
    const taper = Math.min(1, Math.max(0, Math.min(y - 32, 216 - y) / 15));
    for (let x = 0; x < W; x++) {
      const ridge = y >= 154 && y <= 159 ? 0 : taper * Math.exp(-0.5 * ((x - ridgeX(y)) / 2.6) ** 2);
      const lift = (polarity === 'bright' ? 4300 : -4300) * ridge;
      const i = (y * W + x) * C;
      original[i] = Math.round(16000 + 7400 * stripe + lift);
      original[i + 1] = Math.round(26000 + 6100 * stripe + lift);
      original[i + 2] = Math.round(18000 + 550 * stripe + lift);
    }
  }
  const mark = { x0: 109, x1: 134, y0: 86, y1: 123, cx: 122, cy: 107,
    length: 37, width: 8, z: 20, white: 0.9, polarity, kind: 'dust', scene: 2,
    verdict: 'keep-photo', why: 'not crisp enough for debris on the film (photo detail)',
    line: { one_med: 0.1, one_frac: 0, hf: 0.1, per: 0.12 } };
  return { original, repaired: original.slice(), mask: new Uint8Array(W * H), W, H, C, ridgeX, marks: [mark], polarity };
}

for (const polarity of ['bright', 'dark']) test(`traces a ${polarity} curved fibre across a real stripe`, async () => {
  const image = fixture(polarity);
  const { original, repaired, mask, W, C, ridgeX } = image;
  const existing = 94 * W + Math.round(ridgeX(94));
  mask[existing] = 255;
  repaired[existing * C] = 12345;
  const result = await enhanceFibers(image);
  assert.equal(result.marks.length, 1);
  assert.ok(result.marks[0].length > 115);
  assert.ok(result.pixels > 500 && result.pixels < 2800);
  assert.equal(mask[existing], 255);
  assert.equal(repaired[existing * C], 12345);
  const at = (x, y, c = 0) => (y * W + x) * C + c;
  const sign = polarity === 'bright' ? 1 : -1;
  for (const y of [63, 126, 185]) {
    const center = at(Math.round(ridgeX(y)), y);
    assert.ok(sign * (original[center] - repaired[center]) > 2000, `fibre still visible at ${y}`);
  }
  const crossing = Math.round(ridgeX(126));
  assert.ok(repaired[at(crossing, 126)] - repaired[at(Math.round(ridgeX(100)), 100)] > 4000,
    'the broad stripe should still cross the repaired spot');
  for (let y = 110; y <= 142; y++) for (let x = 0; x < W; x++) {
    if (Math.abs(x - ridgeX(y)) < 12) continue;
    assert.equal(mask[y * W + x], 0);
    for (let c = 0; c < C; c++) assert.equal(repaired[at(x, y, c)], original[at(x, y, c)]);
  }
  assert.equal(mask.filter(Boolean).length, result.pixels + 1);
});

test('keeps a straight edge or a protected fragment out of curved-fibre repair', async () => {
  const straight = fixture('bright', false);
  assert.deepEqual(await enhanceFibers(straight), { marks: [], pixels: 0 });
  assert.deepEqual(straight.repaired, straight.original);
  const protectedMark = fixture('bright');
  protectedMark.marks[0].print = true;
  assert.deepEqual(await enhanceFibers(protectedMark), { marks: [], pixels: 0 });
  assert.deepEqual(protectedMark.repaired, protectedMark.original);
});

test('can use a dust fragment as a seed when only fibres are selected', async () => {
  const image = fixture('bright');
  image.marks[0].verdict = 'not-selected';
  const result = await enhanceFibers(image);
  assert.deepEqual(result.marks.map(mark => mark.kind), ['hair/fibre']);
  assert.ok(result.pixels > 500);
});

test('reconnects a faint tail after a sharp bend without rerendering the stripe crossing', async () => {
  const W = 295, H = 245, C = 3;
  const body = [[202, 36], [178, 76], [164, 112], [155, 143], [150, 176]];
  const tail = [[138, 188], [124, 180], [111, 178], [92, 179], [72, 185]];
  const mark = { ...fixture('bright').marks[0], x0: 155, x1: 187, y0: 85, y1: 135, cx: 164, cy: 112, length: 50 };

  async function run(paths) {
    const original = new Uint16Array(W * H * C);
    for (let y = 0; y < H; y++) {
      const stripe = Math.exp(-0.5 * ((y - 124) / 12) ** 2);
      for (let x = 0; x < W; x++) {
        const amplitude = 4500 - 2700 * Math.min(1, Math.max(0, (148 - x) / 55));
        let lift = 0;
        for (const points of paths) for (let j = 1; j < points.length; j++) {
          const [ax, ay] = points[j - 1], [bx, by] = points[j];
          const dx = bx - ax, dy = by - ay;
          const t = Math.max(0, Math.min(1, ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy)));
          const d2 = (x - ax - t * dx) ** 2 + (y - ay - t * dy) ** 2;
          lift = Math.max(lift, amplitude * Math.exp(-d2 / 22));
        }
        const i = (y * W + x) * C;
        original[i] = Math.round(16000 + 7400 * stripe + lift);
        original[i + 1] = Math.round(26000 + 6100 * stripe + lift);
        original[i + 2] = Math.round(18000 + 550 * stripe + lift);
      }
    }
    const repaired = original.slice(), mask = new Uint8Array(W * H);
    const result = await enhanceFibers({ original, repaired, mask, W, H, C, marks: [mark] });
    assert.equal(result.marks.length, 1);
    return { original, repaired, mask };
  }

  const base = await run([body]);
  const extended = await run([body, tail]);
  for (const [x, y] of tail) {
    const i = y * W + x;
    assert.equal(base.mask[i], 0);
    assert.equal(extended.mask[i], 1);
    assert.ok(extended.original[i * C] - extended.repaired[i * C] > 1200);
  }
  const crossingStart = 105 * W, crossingEnd = 146 * W;
  assert.deepEqual(extended.mask.subarray(crossingStart, crossingEnd), base.mask.subarray(crossingStart, crossingEnd));
  assert.deepEqual(extended.repaired.subarray(crossingStart * C, crossingEnd * C),
    base.repaired.subarray(crossingStart * C, crossingEnd * C));
});
