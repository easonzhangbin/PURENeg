'use strict';

const { PointGrid, skeletonize } = require('../vendor/film-dust/engine/regions');
const { mainPath } = require('../vendor/film-dust/engine/marks');

function median(values) {
  values.sort((a, b) => a - b);
  return values[values.length >> 1];
}

function corePath({ labels, probability, W, threshold, id, x0, x1, y0, y1 }) {
  const w = x1 - x0 + 3, h = y1 - y0 + 3;
  if (Math.max(w, h) < 70 || Math.max(w, h) > 450) return null;
  const core = new Uint8Array(w * h);
  let pixels = 0;
  for (let y = 1; y < h - 1; y++) for (let x = 1; x < w - 1; x++) {
    const index = (y + y0 - 1) * W + x + x0 - 1;
    if (labels[index] === id && probability[index] >= threshold) {
      core[y * w + x] = 1;
      pixels++;
    }
  }
  if (pixels < 500 || pixels > 10_000) return null;
  const thin = skeletonize(core, w, h);
  const xs = [], ys = [];
  for (let i = 0; i < thin.length; i++) if (thin[i]) {
    xs.push(i % w + x0 - 1);
    ys.push(Math.floor(i / w) + y0 - 1);
  }
  if (xs.length < 100 || xs.length > 550) return null;
  const path = mainPath(ys, xs, new PointGrid(ys, xs, 16));
  if (path.length < 100 || path.length < 0.85 * xs.length || pixels > 23 * path.length) return null;
  return path.map(index => ({ x: xs[index], y: ys[index] }));
}

function imageProfiles({ original, W, H, C, probability, path }) {
  const lum = (x, y) => {
    const i = (y * W + x) * C;
    if (C === 1) return original[i] / 257;
    return (0.2126 * original[i] + 0.7152 * original[i + 1] + 0.0722 * original[i + 2]) / 257;
  };
  const sample = (x, y) => {
    const ix = Math.floor(x), iy = Math.floor(y), fx = x - ix, fy = y - iy;
    return (lum(ix, iy) * (1 - fx) + lum(ix + 1, iy) * fx) * (1 - fy) +
      (lum(ix, iy + 1) * (1 - fx) + lum(ix + 1, iy + 1) * fx) * fy;
  };
  const profiles = [];
  const line = new Float32Array(23);
  for (let i = 0; i < path.length; i++) {
    const a = path[Math.max(0, i - 5)], b = path[Math.min(path.length - 1, i + 5)];
    const { x, y } = path[i];
    const dx = b.x - a.x, dy = b.y - a.y, span = Math.hypot(dx, dy);
    if (!span || x < 12 || y < 12 || x > W - 14 || y > H - 14) return null;
    const nx = -dy / span, ny = dx / span;
    for (let j = 0; j < line.length; j++) line[j] = sample(x + nx * (j - 11), y + ny * (j - 11));
    let best = -Infinity, offset = 11, rise = -Infinity;
    for (let j = 7; j <= 15; j++) {
      const cx = Math.round(x + nx * (j - 11)), cy = Math.round(y + ny * (j - 11));
      if (probability[cy * W + cx] < 144) continue;
      const local = line[j] - Math.max(line[j - 4], line[j - 3], line[j + 3], line[j + 4]);
      const score = local - 0.18 * Math.abs(j - 11);
      if (score > best) { best = score; offset = j; rise = local; }
    }
    const left = line[offset - 7], right = line[offset + 7];
    const background = (left + right) / 2;
    const balanced = Math.abs(left - right) <= Math.max(10, rise);
    profiles.push({ x: x + nx * (offset - 11), y: y + ny * (offset - 11),
      background, rise, balanced, radius: rise > 35 ? 5 : 4 });
  }
  return profiles;
}

function isCrossing(profiles) {
  const end = Math.floor(profiles.length * 0.18);
  const first = profiles.slice(0, end), last = profiles.slice(-end);
  const interior = profiles.slice(end, -end);
  const startLight = median(first.map(point => point.background));
  const endLight = median(last.map(point => point.background));
  const bright = Math.min(startLight, endLight);
  if (bright < 145 || Math.abs(startLight - endLight) > 40) return false;
  const dark = interior.filter(point => point.background <= bright - 65);
  if (dark.length < Math.max(20, 0.22 * profiles.length)) return false;
  // Both ends and the dark interior need their own two-sided ridge evidence.
  // A narrow probability band following a shadow edge has only one flank.
  const support = (points, ratio) => points.filter(point => point.rise >= 5).length >= ratio * points.length;
  if (![first, last, dark].every(points => support(points, 0.85) &&
      points.filter(point => point.balanced && point.rise >= 5).length >= 0.45 * points.length)) return false;
  let gap = 0;
  for (const { rise } of profiles) {
    gap = rise >= 5 ? 0 : gap + 1;
    if (gap > 8) return false;
  }
  return support(profiles, 0.90);
}

async function repairCrossings({ original, repaired, mask, W, H, C, probability,
  labels, rejected, threshold, frame, rejectBranch, patch, heal, tick }) {
  const marks = [];
  let pixels = 0;
  for (const region of rejected) {
    if (!region.widthOnly || region.x0 < 20 || region.y0 < 20 || region.x1 > W - 21 || region.y1 > H - 21) continue;
    await tick();
    const path = corePath({ labels, probability, W, threshold, ...region });
    if (!path || rejectBranch?.(path)) continue;
    const profiles = imageProfiles({ original, W, H, C, probability, path });
    if (!profiles || !isCrossing(profiles)) continue;
    const x0 = region.x0 - 12, y0 = region.y0 - 12;
    const w = region.x1 - x0 + 13, h = region.y1 - y0 + 13;
    const add = new Uint8Array(w * h);
    let area = 0;
    for (const { x, y, radius } of profiles) {
      for (let yy = Math.ceil(y - radius); yy <= Math.floor(y + radius); yy++) {
        for (let xx = Math.ceil(x - radius); xx <= Math.floor(x + radius); xx++) {
          const local = (yy - y0) * w + xx - x0, global = yy * W + xx;
          if (add[local] || mask[global] || frame?.protects(global) || (xx - x) ** 2 + (yy - y) ** 2 > radius ** 2) continue;
          add[local] = 1;
          area++;
        }
      }
    }
    if (area < Math.max(60, 2 * path.length)) continue;
    const prior = new Uint8Array(w * h);
    for (let y = 0; y < h; y++) prior.set(mask.subarray((y0 + y) * W + x0, (y0 + y) * W + x0 + w), y * w);
    const tile = patch(repaired, W, C, x0, y0, w, h);
    await heal(tile, w, h, C, add, null, null, tick, prior);
    let changed = 0;
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      const local = y * w + x, global = (y0 + y) * W + x0 + x;
      if (!add[local]) continue;
      const output = tile.subarray(local * C, (local + 1) * C);
      if (!output.some((value, channel) => value !== original[global * C + channel])) continue;
      repaired.set(output, global * C);
      mask[global] = 1;
      changed++;
    }
    if (!changed) continue;
    const center = profiles[profiles.length >> 1];
    pixels += changed;
    marks.push({ id: -4, kind: 'hair/fibre', verdict: 'defect', origin: 'learned-crossing',
      why: 'a narrow bright fibre crossing contrasting parts of the photo', polarity: 'bright',
      x0: region.x0, x1: region.x1, y0: region.y0, y1: region.y1, cx: Math.round(center.x), cy: Math.round(center.y),
      length: profiles.length, area: changed });
  }
  return { marks, pixels };
}

module.exports = { repairCrossings };
