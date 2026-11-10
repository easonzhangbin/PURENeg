'use strict';

const { heal } = require('../vendor/film-dust/engine/heal');
const { lumaFromU16 } = require('../vendor/film-dust/engine/maps');
const { label } = require('../vendor/film-dust/engine/regions');

const MAX_TILE_PIXELS = 160_000;
const MAX_CANDIDATES = 256;

function median(values) {
  return values.sort((a, b) => a - b)[values.length >> 1];
}

// Bright debris can be too wide for fibre tracing and too large for the dust
// classifier. Limit the second opinion to existing, bounded candidates and
// require a bright neutral core with agreement from the learned map.
async function repairPatches({ original, repaired, mask, W, H, C, candidates, probability, eyes = [], frame, sensitivity, tick }) {
  const scale = Math.max(0.3, Math.max(W, H) / 8660);
  const minArea = Math.max(24, Math.round(140 * scale * scale));
  const maxArea = Math.min(20_000, Math.round(12_000 * scale * scale));
  const margin = Math.max(10, Math.round(25 * scale));
  const coreThreshold = Math.round(214 - 18 * (sensitivity - 1));
  const outlineThreshold = coreThreshold - 74;
  const minimumLift = 0.14 - 0.035 * (sensitivity - 1);
  const candidatesToCheck = candidates.filter(mark => mark.verdict === 'keep-photo' && mark.kind === 'dust' &&
    mark.polarity === 'bright' && !mark.zone && !mark.print && !mark.frame && mark.area >= minArea && mark.area <= maxArea &&
    !/catchlight|rides along an edge|chain\/jewellery|on skin/i.test(mark.why ?? ''))
    .sort((a, b) => b.z - a.z).slice(0, MAX_CANDIDATES);
  const marks = [];
  let pixels = 0;
  for (const mark of candidatesToCheck) {
    const bw = mark.x1 - mark.x0 + 1, bh = mark.y1 - mark.y0 + 1;
    if (!(Math.min(bw, bh) >= 10 * scale && Math.max(bw, bh) <= 5 * Math.min(bw, bh))) continue;
    if (eyes.some(({ x, y, r }) => Math.hypot(x - Math.max(mark.x0, Math.min(mark.x1, x)),
      y - Math.max(mark.y0, Math.min(mark.y1, y))) < 1.5 * r)) continue;
    const x0 = Math.max(0, mark.x0 - margin), y0 = Math.max(0, mark.y0 - margin);
    const w = Math.min(W, mark.x1 + margin + 1) - x0, h = Math.min(H, mark.y1 + margin + 1) - y0;
    if (w * h > MAX_TILE_PIXELS) continue;
    const originalTile = new Uint16Array(w * h * C);
    for (let y = 0; y < h; y++) {
      const start = ((y0 + y) * W + x0) * C;
      originalTile.set(original.subarray(start, start + w * C), y * w * C);
    }
    const luma = lumaFromU16(originalTile, w, h, C);
    const core = [], surround = [];
    let neutralCore = 0;
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      const local = y * w + x, i = (y0 + y) * W + x0 + x;
      const inBox = x0 + x >= mark.x0 && x0 + x <= mark.x1 && y0 + y >= mark.y0 && y0 + y <= mark.y1;
      if (inBox && probability[i] >= coreThreshold) {
        core.push(luma[local]);
        const j = local * C;
        if (C === 1 || Math.max(originalTile[j], originalTile[j + 1], originalTile[j + 2]) -
          Math.min(originalTile[j], originalTile[j + 1], originalTile[j + 2]) <= 0.075 * 65535) neutralCore++;
      } else if (!inBox && probability[i] < outlineThreshold && !mask[i]) {
        surround.push(luma[local]);
      }
    }
    if (core.length < minArea || surround.length < minArea || neutralCore < 0.85 * core.length) continue;
    const background = median(surround), peak = median(core);
    if (peak < 0.78 || peak - background < minimumLift) continue;

    const outline = new Uint8Array(w * h), avoid = new Uint8Array(w * h);
    const lip = Math.min(4, Math.floor(margin / 2));
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      const local = y * w + x, px = x0 + x, py = y0 + y, i = py * W + px;
      avoid[local] = mask[i];
      if (px < mark.x0 - lip || px > mark.x1 + lip || py < mark.y0 - lip || py > mark.y1 + lip || frame?.protects(i)) continue;
      if (probability[i] >= outlineThreshold && luma[local] >= background + 0.05) outline[local] = 1;
    }
    const { lab, n } = label(outline, w, h, 8);
    const support = new Uint32Array(n + 1), sizes = new Uint32Array(n + 1);
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      const id = lab[y * w + x];
      if (!id) continue;
      sizes[id]++;
      if (probability[(y0 + y) * W + x0 + x] >= coreThreshold) support[id]++;
    }
    let strongest = 0;
    for (let id = 1; id <= n; id++) if (support[id] > support[strongest]) strongest = id;
    if (support[strongest] < minArea || sizes[strongest] > Math.min(maxArea, 2.5 * mark.area)) continue;
    let added = 0;
    for (let i = 0; i < outline.length; i++) {
      outline[i] = lab[i] === strongest && !avoid[i] ? 1 : 0;
      added += outline[i];
    }
    if (added < minArea) continue;
    await tick();
    await heal(originalTile, w, h, C, outline, null, null, tick, avoid);
    await tick();
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      const local = y * w + x;
      if (!outline[local]) continue;
      const i = (y0 + y) * W + x0 + x;
      repaired.set(originalTile.subarray(local * C, (local + 1) * C), i * C);
      mask[i] = 1;
    }
    pixels += added;
    marks.push({ id: -5, kind: 'patch', verdict: 'defect', polarity: 'bright', origin: 'learned',
      why: 'a bright blotch supported by the learned dust map', area: added,
      x0: Math.max(0, mark.x0 - lip), y0: Math.max(0, mark.y0 - lip),
      x1: Math.min(W - 1, mark.x1 + lip), y1: Math.min(H - 1, mark.y1 + lip), cx: mark.cx, cy: mark.cy });
  }
  return { marks, pixels };
}

module.exports = { repairPatches };
