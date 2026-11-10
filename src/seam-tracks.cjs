'use strict';

const { followsPhotoLine } = require('./scene-lines.cjs');

const SAMPLE_REACH = 48;
const POINTS_PER_BLOCK = 5;
const MIN_BLOCKS = 6;
const MIN_RAIL_OFFSET = 14;
const MAX_RAIL_OFFSET = 42;

function sampleLuma(source, width, channels, x, y) {
  const ix = Math.floor(x), iy = Math.floor(y);
  const dx = x - ix, dy = y - iy;
  const value = (column, row) => {
    const i = (row * width + column) * channels;
    if (channels === 1) return source[i];
    return (54 * source[i] + 183 * source[i + 1] + 19 * source[i + 2]) / 256;
  };
  return (1 - dy) * ((1 - dx) * value(ix, iy) + dx * value(ix + 1, iy)) +
    dy * ((1 - dx) * value(ix, iy + 1) + dx * value(ix + 1, iy + 1));
}

function modelNear(probability, width, height, x, y, threshold) {
  const cx = Math.round(x), cy = Math.round(y);
  for (let row = Math.max(0, cy - 2); row <= Math.min(height - 1, cy + 2); row++) {
    for (let col = Math.max(0, cx - 2); col <= Math.min(width - 1, cx + 2); col++) {
      if (probability[row * width + col] >= threshold) return true;
    }
  }
  return false;
}

function hasTwinRail(source, width, height, channels, points, probability) {
  if (points.length < MIN_BLOCKS * POINTS_PER_BLOCK) return null;
  const profile = new Float64Array(2 * SAMPLE_REACH + 1);
  const at = d => profile[d + SAMPLE_REACH];
  const band = (lo, hi) => {
    let total = 0;
    for (let d = lo; d <= hi; d++) total += at(d);
    return total / (hi - lo + 1);
  };
  const offsets = [];
  let blocks = 0, modelBlocks = 0;
  for (let start = 0; start + POINTS_PER_BLOCK <= points.length; start += POINTS_PER_BLOCK) {
    blocks++;
    let count = 0, high = 0;
    profile.fill(0);
    for (let j = start; j < start + POINTS_PER_BLOCK; j++) {
      const a = points[Math.max(0, j - 2)], b = points[Math.min(points.length - 1, j + 2)];
      const { x, y } = points[j];
      if (x <= SAMPLE_REACH || y <= SAMPLE_REACH || x >= width - SAMPLE_REACH - 1 || y >= height - SAMPLE_REACH - 1) continue;
      const length = Math.hypot(b.x - a.x, b.y - a.y);
      if (!length) continue;
      const nx = (a.y - b.y) / length, ny = (b.x - a.x) / length;
      for (let d = -SAMPLE_REACH; d <= SAMPLE_REACH; d++) {
        profile[d + SAMPLE_REACH] += sampleLuma(source, width, channels, x + nx * d, y + ny * d);
      }
      if (probability && modelNear(probability, width, height, x, y, 220)) high++;
      count++;
    }
    if (count < 3) continue;
    if (high * 2 >= count) modelBlocks++;
    let crest = 0;
    for (let d = -2; d <= 2; d++) if (at(d) > at(crest)) crest = d;
    const riseAt = d => at(d) - Math.max(band(d - 6, d - 4), band(d + 4, d + 6));
    const rise = riseAt(crest);
    if (rise < 250 * count) continue;
    let strongest = 0.20 * rise, offset = null;
    for (let d = -MAX_RAIL_OFFSET; d <= MAX_RAIL_OFFSET; d++) {
      if (Math.abs(d - crest) < MIN_RAIL_OFFSET) continue;
      const score = riseAt(d);
      if (score > strongest) { strongest = score; offset = d - crest; }
    }
    if (offset !== null) offsets.push({ offset, strength: strongest / rise, block: blocks });
  }
  // A fibre may cross either seam. Require a second ridge on the same side,
  // at nearly the same offset, along most of this track rather than at one crossing.
  if (modelBlocks * 2 > blocks) return null;
  let strongOffset = null, strongestCluster = 0;
  for (let offset = -MAX_RAIL_OFFSET; offset <= MAX_RAIL_OFFSET; offset++) {
    if (Math.abs(offset) < MIN_RAIL_OFFSET) continue;
    const votes = offsets.filter(sample => sample.strength >= 0.60 && Math.abs(sample.offset - offset) <= 7).length;
    if (votes >= 0.72 * blocks && votes > strongestCluster) { strongOffset = offset; strongestCluster = votes; }
  }
  if (strongOffset !== null) return { strongOffset };
  for (const { offset } of offsets) {
    const matching = offsets.filter(sample => Math.abs(sample.offset - offset) <= 7);
    if (blocks < 15 || modelBlocks * 4 > blocks || matching.length < 0.52 * blocks) continue;
    let previous = -1, contiguous = 0;
    for (const { block } of matching) {
      contiguous = previous + 1 === block ? contiguous + 1 : 1;
      if (contiguous >= 6) return {};
      previous = block;
    }
  }
  return null;
}

function tracesPhotoMaterial({ source, width, height, channels, points, probability, protectedLines, polarity }) {
  if (polarity !== 'bright' || points.length < MIN_BLOCKS * POINTS_PER_BLOCK) return null;
  const textureLines = protectedLines.filter(line => line.softWithTexture);
  if (probability && textureLines.length && followsPhotoLine(textureLines, points, polarity, true)) {
    const supported = points.filter(({ x, y }) => modelNear(probability, width, height, x, y, 144)).length;
    if (supported < 0.25 * points.length) return {};
  }
  return hasTwinRail(source, width, height, channels, points, probability);
}

function recordMaterialPath(excluded, width, height, points) {
  for (const { x, y, radius } of points) {
    const padding = Math.max(7, Math.min(14, radius + 4));
    for (let row = Math.max(0, Math.ceil(y - padding)); row <= Math.min(height - 1, Math.floor(y + padding)); row++) {
      for (let col = Math.max(0, Math.ceil(x - padding)); col <= Math.min(width - 1, Math.floor(x + padding)); col++) {
        if ((row - y) ** 2 + (col - x) ** 2 <= padding ** 2) excluded.add(row * width + col);
      }
    }
  }
}

const MAX_RAIL_PIXELS = 20_000;

function nearestMasked(mask, width, height, x, y) {
  let nearest = -1, distance = 37;
  for (let row = Math.max(0, y - 6); row <= Math.min(height - 1, y + 6); row++) {
    for (let col = Math.max(0, x - 6); col <= Math.min(width - 1, x + 6); col++) {
      const index = row * width + col;
      const square = (row - y) ** 2 + (col - x) ** 2;
      if (mask[index] && square < distance) { nearest = index; distance = square; }
    }
  }
  return nearest;
}

function maskedRail(mask, width, height, seed, probability, cache) {
  if (cache.has(seed)) return cache.get(seed);
  const pixels = [seed];
  const item = { pixels, aligned: [0, 0] };
  cache.set(seed, item);
  let x0 = width, x1 = 0, y0 = height, y1 = 0, modelSupport = 0, modelCore = false;
  for (let i = 0; i < pixels.length && pixels.length <= MAX_RAIL_PIXELS; i++) {
    const index = pixels[i], x = index % width, y = Math.floor(index / width);
    x0 = Math.min(x0, x); x1 = Math.max(x1, x); y0 = Math.min(y0, y); y1 = Math.max(y1, y);
    if (probability[index] >= 144) modelSupport++;
    if (probability[index] >= 192) modelCore = true;
    for (let row = Math.max(0, y - 1); row <= Math.min(height - 1, y + 1); row++) {
      for (let col = Math.max(0, x - 1); col <= Math.min(width - 1, x + 1); col++) {
        const next = row * width + col;
        if (!mask[next] || cache.has(next)) continue;
        cache.set(next, item);
        pixels.push(next);
      }
    }
  }
  const xSpan = x1 - x0 + 1, ySpan = y1 - y0 + 1;
  const long = Math.max(xSpan, ySpan), short = Math.min(xSpan, ySpan);
  item.eligible = pixels.length <= MAX_RAIL_PIXELS && long >= 160 && long >= 5 * short &&
    modelSupport <= 0.01 * pixels.length && !modelCore;
  return item;
}

function restoreMaskedTwinRails({ original, repaired, mask, width, height, channels, points, probability, offset }) {
  // Both rails must be independently masked, elongated and model-negative.
  // A true fibre that crosses or joins either component keeps it intact.
  if (!probability || !Number.isFinite(offset) || points.length < 75) return 0;
  const cache = new Map(), candidates = new Set();
  for (let i = 0; i < points.length; i++) {
    const a = points[Math.max(0, i - 2)], b = points[Math.min(points.length - 1, i + 2)];
    const length = Math.hypot(b.x - a.x, b.y - a.y);
    if (!length) continue;
    const { x, y } = points[i];
    const ox = offset * (a.y - b.y) / length, oy = offset * (b.x - a.x) / length;
    for (const [rail, px, py] of [[0, x, y], [1, x + ox, y + oy]]) {
      const seed = nearestMasked(mask, width, height, Math.round(px), Math.round(py));
      if (seed < 0) continue;
      const item = maskedRail(mask, width, height, seed, probability, cache);
      if (!item.eligible) continue;
      candidates.add(item);
      item.aligned[rail]++;
    }
  }
  const minimum = 0.2 * points.length;
  const main = [...candidates].sort((a, b) => b.aligned[0] - a.aligned[0]).find(item => item.aligned[0] >= minimum);
  if (!main) return 0;
  const second = [...candidates].sort((a, b) => b.aligned[1] - a.aligned[1]).find(item => item !== main && item.aligned[1] >= minimum);
  if (!second) return 0;
  for (const item of [main, second]) for (const index of item.pixels) {
    mask[index] = 0;
    const at = index * channels;
    repaired.set(original.subarray(at, at + channels), at);
  }
  return main.pixels.length + second.pixels.length;
}

module.exports = { tracesPhotoMaterial, recordMaterialPath, restoreMaskedTwinRails };
