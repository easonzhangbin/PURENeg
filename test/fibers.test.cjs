'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { enhanceFibers } = require('../src/fibers.cjs');

function fixture(polarity, curved = true, ridgeSigma = 2.6) {
  const W = 270, H = 245, C = 3;
  const ridgeX = y => 122 + 0.18 * (y - 107) + (curved ? 0.0022 * (y - 107) ** 2 : 0);
  const original = new Uint16Array(W * H * C);
  for (let y = 0; y < H; y++) {
    const stripe = Math.exp(-0.5 * ((y - 126) / 12) ** 2);
    const taper = Math.min(1, Math.max(0, Math.min(y - 32, 216 - y) / 15));
    for (let x = 0; x < W; x++) {
      const ridge = y >= 154 && y <= 159 ? 0 : taper * Math.exp(-0.5 * ((x - ridgeX(y)) / ridgeSigma) ** 2);
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

test('fibre sensitivity controls whether a faint fragment seeds a curved track', async () => {
  const conservative = fixture('bright');
  conservative.marks[0].z = 10;
  assert.equal((await enhanceFibers({ ...conservative, sensitivity: 0.5 })).pixels, 0);
  const sensitive = fixture('bright');
  sensitive.marks[0].z = 10;
  assert.equal((await enhanceFibers({ ...sensitive, sensitivity: 2 })).marks.length, 1);
  assert.equal(sensitive.mask[185 * sensitive.W + Math.round(sensitive.ridgeX(185))], 1);
  assert.equal(sensitive.mask[126 * sensitive.W + 36], 0, 'the broad scene stripe stays intact away from the fibre');
});

test('does not trace a broad soft ridge that the scene model left as photo detail', async () => {
  const fold = fixture('bright', true, 5.2);
  const mark = fold.marks[0];
  Object.assign(mark, { scene: -0.6, z: 32, crisp_rel: 0.68 });
  mark.line.half_w = 7.6;
  assert.deepEqual(await enhanceFibers(fold), { marks: [], pixels: 0 });
  assert.deepEqual(fold.repaired, fold.original);

  mark.scene = 2;
  assert.equal((await enhanceFibers(fold)).marks.length, 1, 'a strong scene match can still start a wide fibre');
});

test('traces a strongly supported faint fragment on smooth bright ground', async () => {
  const image = fixture('bright');
  const mark = image.marks[0];
  Object.assign(mark, { kind: 'hair/fibre', why: 'link texture along its length (chain/jewellery/beads)',
    z: 10.1, quietBrightRidge: true });
  mark.line.per = 0.41;
  assert.deepEqual(await enhanceFibers(image), { marks: [], pixels: 0 });

  mark.scene = 4.5;
  assert.equal((await enhanceFibers(image)).marks.length, 1);
  assert.equal(image.mask[185 * image.W + Math.round(image.ridgeX(185))], 1);
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

// [Claude 2026-11-08] Fibres started from the image rather than from an engine fragment.
// The width limit follows the scan's long side (6 px at 8660 px), so these fixtures use a
// full-width strip of a 50MP-class scan.
// along: the line's brightness along its length, as a multiple of amplitude.
function darkStrip({ width = 2.6, edgeAt = null, amplitude = 9000, stepAt = null, stepLevel = 0, along = () => 1 } = {}) {
  const W = 8660, H = 520, C = 3;
  const fibreY = x => 260 + 70 * Math.sin((x - 3000) / 55);
  const original = new Uint16Array(W * H * C);
  let seed = 7;
  const noise = () => ((seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0) / 2 ** 32 - 0.5) * 300;
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    let v = 5200;
    if (edgeAt !== null && y > fibreY(x) + edgeAt) v = 32000;   // a bright object beside the line
    if (stepAt !== null && y > fibreY(x) + stepAt) v = stepLevel; // another level right beside it
    if (x >= 3000 && x <= 3260) v += amplitude * along(x) * Math.exp(-0.5 * ((y - fibreY(x)) / (width / 2.355)) ** 2);
    const i = (y * W + x) * C, n = noise();
    original[i] = Math.round(v + n); original[i + 1] = Math.round(v + n); original[i + 2] = Math.round(v + n);
  }
  return { original, repaired: original.slice(), mask: new Uint8Array(W * H), W, H, C, fibreY, marks: [], polarity: 'bright' };
}

test('traces a fibre the engine left in pieces, starting from the image', async () => {
  const image = darkStrip();
  const result = await enhanceFibers(image);
  const traced = result.marks.filter(m => m.origin === 'ridge');
  assert.ok(traced.length >= 1, 'no fibre traced from an image seed');
  const { mask, W, fibreY } = image;
  let hit = 0, total = 0;
  for (let x = 3020; x <= 3240; x += 10) { total++; if (mask[Math.round(fibreY(x)) * W + x]) hit++; }
  assert.ok(hit >= 0.8 * total, `only ${hit}/${total} points of the fibre repaired`);
});

test('leaves a soft, wide line of the same shape (a paving joint, a seam)', async () => {
  const image = darkStrip({ width: 9 });
  const result = await enhanceFibers(image);
  assert.equal(result.marks.filter(m => m.origin === 'ridge').length, 0);
});

test('leaves a thin line running along an object edge (a rim highlight, a trim)', async () => {
  const image = darkStrip({ edgeAt: 16 });
  const result = await enhanceFibers(image);
  assert.equal(result.marks.filter(m => m.origin === 'ridge').length, 0);
});

test('leaves a thin line on a step between two levels (the rim of a film holder, a frame)', async () => {
  const image = darkStrip({ amplitude: 7000, stepAt: 2, stepLevel: 1500 });
  const result = await enhanceFibers(image);
  assert.equal(result.marks.filter(m => m.origin === 'ridge').length, 0);
});

test('leaves a glint that flares at one point and fades along the curve (a watch glass)', async () => {
  const image = darkStrip({ along: x => 0.25 + 3 * Math.exp(-0.5 * ((x - 3060) / 14) ** 2) });
  const result = await enhanceFibers(image);
  assert.equal(result.marks.filter(m => m.origin === 'ridge').length, 0);
});

test('still traces a fibre whose brightness varies along it', async () => {
  const image = darkStrip({ along: x => 0.4 + 1.2 * Math.exp(-0.5 * ((x - 3060) / 40) ** 2) });
  const result = await enhanceFibers(image);
  assert.ok(result.marks.some(m => m.origin === 'ridge'), 'no fibre traced');
});

// [Claude 2026-11-08] A tangle: one fibre lying across another. The first pass repairs one
// of them and breaks the other where they cross; later passes trace the pieces again.
function tangle() {
  const W = 8660, H = 520, C = 3;
  const fibreY = x => 260 + 70 * Math.sin((x - 3000) / 55);
  const fibreX = y => 3130 + 40 * Math.sin((y - 120) / 70);
  const original = new Uint16Array(W * H * C);
  let seed = 7;
  const noise = () => ((seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0) / 2 ** 32 - 0.5) * 300;
  const sigma = 2.6 / 2.355;
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const a = x >= 3000 && x <= 3260 ? Math.exp(-0.5 * ((y - fibreY(x)) / sigma) ** 2) : 0;
    const b = y >= 120 && y <= 420 ? Math.exp(-0.5 * ((x - fibreX(y)) / sigma) ** 2) : 0;
    const i = (y * W + x) * C, v = Math.round(5200 + 9000 * Math.max(a, b) + noise());
    original[i] = original[i + 1] = original[i + 2] = v;
  }
  return { original, repaired: original.slice(), mask: new Uint8Array(W * H), W, H, C, fibreY, fibreX, marks: [], polarity: 'bright' };
}

test('takes a tangle apart: both crossing fibres are repaired, over more than one pass', async () => {
  const image = tangle();
  const result = await enhanceFibers(image);
  const { mask, W, fibreY, fibreX } = image;
  let a = 0, aTotal = 0, b = 0, bTotal = 0;
  for (let x = 3020; x <= 3240; x += 10) { aTotal++; if (mask[Math.round(fibreY(x)) * W + x]) a++; }
  for (let y = 140; y <= 400; y += 10) { bTotal++; if (mask[y * W + Math.round(fibreX(y))]) b++; }
  assert.ok(a >= 0.9 * aTotal, `only ${a}/${aTotal} points of the first fibre repaired`);
  assert.ok(b >= 0.9 * bTotal, `only ${b}/${bTotal} points of the second fibre repaired`);
  assert.ok(result.marks.some(m => m.pass > 0), 'no later pass was needed');
});

// [Claude 2026-11-08] The learned dust/fibre map only adds starting points; the tracer and
// its scene tests still decide. A map covering the line, as FibreNet would give it.
function mapOver(image, halfWidth = 2) {
  const prob = new Uint8Array(image.W * image.H);
  for (let x = 3000; x <= 3260; x++) for (let d = -halfWidth; d <= halfWidth; d++) {
    prob[(Math.round(image.fibreY(x)) + d) * image.W + x] = 220;
  }
  return prob;
}

test('a faint fibre the ridge detector misses is traced from the learned map', async () => {
  const alone = await enhanceFibers(darkStrip({ amplitude: 2200 }));
  assert.equal(alone.marks.length, 0, 'the fixture should be below the ridge detector');
  const image = darkStrip({ amplitude: 2200 });
  const result = await enhanceFibers({ ...image, probability: mapOver(image) });
  assert.ok(result.marks.length >= 1, 'no fibre traced from the learned map');
});

test('the learned map does not override the scene tests (a soft, wide line stays)', async () => {
  const image = darkStrip({ width: 9 });
  const result = await enhanceFibers({ ...image, probability: mapOver(image, 5) });
  assert.equal(result.marks.length, 0);
});
