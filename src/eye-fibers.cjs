'use strict';

const { label, findObjects } = require('../vendor/film-dust/engine/regions');

const NORMALS = [[1, 0], [0, 1], [1, 1], [1, -1]];
const CORE_MIN = 246;
const SUPPORT_MIN = 230;
const RADIUS = 3;

function distanceToRegion(eye, region) {
  const dx = Math.max(0, region.x0 - eye.x, eye.x - region.x1);
  const dy = Math.max(0, region.y0 - eye.y, eye.y - region.y1);
  return Math.hypot(dx, dy);
}

function narrowBrightRidge(luma, x, y) {
  const center = luma(x, y);
  for (const [dx, dy] of NORMALS) {
    const left = (luma(x - 3 * dx, y - 3 * dy) + luma(x - 4 * dx, y - 4 * dy)) / 2;
    const right = (luma(x + 3 * dx, y + 3 * dy) + luma(x + 4 * dx, y + 4 * dy)) / 2;
    const rise = center - Math.max(left, right);
    if (rise < 10) continue;
    const near = Math.max(luma(x - 2 * dx, y - 2 * dy), luma(x + 2 * dx, y + 2 * dy));
    if (center - near >= 0.45 * rise) return true;
  }
  return false;
}

async function repairNearEye({ original, repaired, mask, W, H, C, probability, labels,
  rejected, threshold, eyes, photoMarks, frame, rejectBranch, patch, heal, tick }) {
  const marks = [];
  let pixels = 0;
  const validEyes = (eyes || []).filter(({ x, y, r }) => Number.isFinite(x) && Number.isFinite(y) && Number.isFinite(r) && r > 0);
  if (!validEyes.length) return { marks, pixels };
  const luma = (x, y) => {
    const i = (y * W + x) * C;
    if (C === 1) return original[i] / 257;
    return (0.2126 * original[i] + 0.7152 * original[i + 1] + 0.0722 * original[i + 2]) / 257;
  };
  for (const region of rejected) {
    const { id, x0, x1, y0, y1 } = region;
    const span = Math.max(x1 - x0, y1 - y0);
    if (!region.widthOnly || span < 70 || span > 360 || x0 < 10 || y0 < 10 || x1 >= W - 10 || y1 >= H - 10) continue;
    const distances = validEyes.map(eye => distanceToRegion(eye, region) / eye.r);
    if (distances.some(distance => distance < 1.3) || distances.every(distance => distance > 2.7)) continue;
    await tick();
    const points = [];
    let core = 0;
    for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) {
      const i = y * W + x;
      if (labels[i] !== id || probability[i] < Math.max(CORE_MIN, threshold)) continue;
      core++;
      if (narrowBrightRidge(luma, x, y)) points.push({ x, y });
    }
    if (core < 500 || core > 9000 || points.length < Math.max(140, 0.11 * core)) continue;
    const protection = rejectBranch?.(points);
    if (protection && (points.length < 0.17 * core || !photoMarks?.some(mark => mark.id === protection.sourceId &&
        mark.verdict === 'keep-photo' && mark.why === 'link texture along its length (chain/jewellery/beads)' &&
        mark.line?.per <= 0.16))) continue;
    const pad = 8, left = x0 - pad, top = y0 - pad;
    const w = x1 - left + pad + 1, h = y1 - top + pad + 1;
    const add = new Uint8Array(w * h);
    let area = 0;
    for (const { x, y } of points) {
      for (let yy = y - RADIUS; yy <= y + RADIUS; yy++) for (let xx = x - RADIUS; xx <= x + RADIUS; xx++) {
        const local = (yy - top) * w + xx - left, global = yy * W + xx;
        if (add[local] || mask[global] || labels[global] !== id || probability[global] < SUPPORT_MIN ||
            frame?.protects(global) || (xx - x) ** 2 + (yy - y) ** 2 > RADIUS ** 2) continue;
        add[local] = 1;
        area++;
      }
    }
    if (area < Math.max(200, 0.30 * core)) continue;
    // Restore small gaps at ridge intersections. Leave the skin enclosed by
    // the actual loop alone, even where the model has filled the whole loop.
    const { lab: background, n } = label(add.map(value => 1 - value), w, h, 4);
    const gaps = findObjects(background, w, h, n);
    const enclosed = gap => gap.x0 > 0 && gap.y0 > 0 && gap.x1 < w && gap.y1 < h;
    // The broad connected model may make a single bright curl look like a
    // chain with gaps. Only override that veto when the source ridges form
    // one closed loop and the upstream signal lacks repeating links.
    if (protection && gaps.filter(gap => enclosed(gap) && gap.area >= 45 && gap.area <= 350).length !== 1) continue;
    for (let i = 0; i < gaps.length; i++) {
      const gap = gaps[i];
      if (gap.area > 20 || !enclosed(gap)) continue;
      for (let y = gap.y0; y < gap.y1; y++) for (let x = gap.x0; x < gap.x1; x++) {
        const local = y * w + x, global = (top + y) * W + left + x;
        if (background[local] === i + 1 && !mask[global] && labels[global] === id &&
            probability[global] >= CORE_MIN && !frame?.protects(global)) add[local] = 1;
      }
    }
    const prior = new Uint8Array(w * h);
    for (let y = 0; y < h; y++) prior.set(mask.subarray((top + y) * W + left, (top + y) * W + left + w), y * w);
    const tile = patch(repaired, W, C, left, top, w, h);
    await heal(tile, w, h, C, add, null, null, tick, prior);
    let changed = 0;
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      const local = y * w + x, global = (top + y) * W + left + x;
      if (!add[local]) continue;
      const result = tile.subarray(local * C, (local + 1) * C);
      if (!result.some((value, channel) => value !== original[global * C + channel])) continue;
      repaired.set(result, global * C);
      mask[global] = 1;
      changed++;
    }
    if (!changed) continue;
    pixels += changed;
    marks.push({ id: -4, kind: 'hair/fibre', verdict: 'defect', origin: 'learned-near-eye',
      why: 'a high-confidence thin bright ridge outside the eye', polarity: 'bright', x0, x1, y0, y1,
      cx: Math.round((x0 + x1) / 2), cy: Math.round((y0 + y1) / 2), area: changed });
  }
  return { marks, pixels };
}

module.exports = { repairNearEye };
