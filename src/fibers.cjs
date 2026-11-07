'use strict';

const { gaussianBlur } = require('../vendor/film-dust/engine/filters');
const { heal } = require('../vendor/film-dust/engine/heal');
const { lumaFromU16 } = require('../vendor/film-dust/engine/maps');

const PAD = 160;
const STEP = 4;
const TURN = Math.PI / 15;
const MAX_SEEDS = 128;

function usefulSeed(mark) {
  const line = mark.line;
  const scene = mark.scene ?? -Infinity;
  // A very strong, symmetric profile can seed a track on a cropped scan,
  // where the scene model sees less context and can be uncertain.
  const supported = scene >= 0.7 || (scene >= -1 && mark.z >= 24 && line?.one_med <= 0.15);
  return line && !mark.frame && !mark.print && !mark.zone && mark.pass !== 2
    && (mark.verdict === 'defect' || mark.verdict === 'not-selected' || (mark.verdict === 'keep-photo'
      && (mark.kind === 'hair/fibre' || mark.why?.startsWith('not crisp')) && supported))
    && mark.length >= 25 && mark.length <= 180 && mark.width <= 25 && mark.length >= 2.5 * mark.width
    && mark.z >= 12 && mark.white >= 0.55 && line.one_med <= 0.38 && line.one_frac <= 0.35
    && (line.per ?? 0) <= 0.38 && (line.hf ?? 0) <= 0.4;
}

function patch(src, W, C, x0, y0, w, h) {
  const data = new Uint16Array(w * h * C);
  for (let y = 0; y < h; y++) {
    const start = ((y0 + y) * W + x0) * C;
    data.set(src.subarray(start, start + w * C), y * w * C);
  }
  return data;
}

function sample(luma, w, x, y) {
  const ix = Math.floor(x), iy = Math.floor(y), fx = x - ix, fy = y - iy;
  const i = iy * w + ix;
  return (1 - fy) * (luma[i] * (1 - fx) + luma[i + 1] * fx)
    + fy * (luma[i + w] * (1 - fx) + luma[i + w + 1] * fx);
}

function ridge(luma, w, h, x, y, angle, sign) {
  if (x < 15 || y < 15 || x >= w - 15 || y >= h - 15) return null;
  const nx = -Math.sin(angle), ny = Math.cos(angle);
  const across = d => sample(luma, w, x + nx * d, y + ny * d);
  const core = across(0);
  const a = sign * (core - (across(-10) + across(-13)) * 0.5);
  const b = sign * (core - (across(10) + across(13)) * 0.5);
  const rise = (a + b) * 0.5;
  if (rise < 0.012 || Math.min(a, b) < 0.38 * Math.max(a, b)) return null;

  // A narrow ridge falls back to the ground on both sides. A broad painted
  // stripe or a single edge gives no such pair of shoulders near its core.
  for (const d of [3, 5, 7, 9]) {
    if (sign * (core - across(-d)) >= a * 0.76 && sign * (core - across(d)) >= b * 0.76) {
      return { x, y, angle, radius: d, score: Math.min(a, b) };
    }
  }
  return null;
}

function trace(luma, w, h, start, angle, sign, limit = PAD - 18) {
  const points = [];
  let { x, y } = start;
  let misses = 0;
  for (let travel = 0; travel < limit; travel += STEP) {
    let best = null, bestScore = 0;
    for (const turn of [-1, 0, 1]) {
      const heading = angle + turn * TURN;
      const vx = Math.cos(heading), vy = Math.sin(heading);
      for (const shift of [-2, -1, 0, 1, 2]) {
        const q = ridge(luma, w, h, x + vx * STEP - vy * shift, y + vy * STEP + vx * shift, heading, sign);
        if (!q) continue;
        const score = q.score - 0.001 * (Math.abs(shift) + Math.abs(turn));
        if (score > bestScore) { best = q; bestScore = score; }
      }
    }
    if (!best) {
      if (++misses === 3) break;
      x += Math.cos(angle) * STEP;
      y += Math.sin(angle) * STEP;
      continue;
    }
    // A short weak gap can reconnect a track, while only the supported
    // points contribute their own footprints to the repair mask.
    angle += 0.65 * (best.angle - angle);
    x = best.x; y = best.y;
    points.push(best);
    misses = 0;
  }
  return points;
}

function turnAtTip(luma, w, h, track, sign) {
  if (track.length < 5) return [];
  const tip = track.at(-1), prior = track.at(-4);
  const heading = Math.atan2(tip.y - prior.y, tip.x - prior.x);
  const tx = Math.cos(heading), ty = Math.sin(heading);
  // Normal tracking can lose both shoulders right at a tight turn. Look
  // for a nearby ridge heading away from the tip and require three checks
  // on that ridge before attempting to follow it.
  const proposals = [];
  for (let along = 4; along <= 20; along += 4) for (let across = -12; across <= 12; across += 3) {
    const gap = Math.hypot(along, across);
    if (gap > 22) continue;
    const dx = tx * along - ty * across, dy = ty * along + tx * across;
    for (let j = -7; j <= 7; j++) {
      if (Math.abs(j) < 2) continue;
      const angle = heading + j * Math.PI / 12;
      const vx = Math.cos(angle), vy = Math.sin(angle);
      if (vx * dx + vy * dy < 0.35 * gap) continue;
      const q = ridge(luma, w, h, tip.x + dx, tip.y + dy, angle, sign);
      if (!q) continue;
      const a = ridge(luma, w, h, q.x + 4 * vx, q.y + 4 * vy, angle, sign);
      const b = ridge(luma, w, h, q.x + 8 * vx, q.y + 8 * vy, angle, sign);
      if (a && b) proposals.push({ q, gap, strength: Math.min(q.score, a.score, b.score) });
    }
  }
  proposals.sort((a, b) => b.strength - a.strength);
  let best = [], bestScore = 0;
  for (const { q, gap } of proposals.slice(0, 10)) {
    const tail = [q, ...trace(luma, w, h, q, q.angle, sign, 92)];
    if (tail.length < 6 || gap > tip.radius + q.radius + 5) continue;
    const end = tail.at(-1);
    if (Math.hypot(end.x - tip.x, end.y - tip.y) < 26) continue;
    if (tail.some(p => track.some(s => Math.hypot(p.x - s.x, p.y - s.y) < 4))) continue;
    const strength = tail.reduce((sum, p) => sum + Math.min(p.score, 0.04), 0);
    const score = strength - 0.012 * gap;
    if (score > bestScore) { best = tail; bestScore = score; }
  }
  return best;
}

function startRidge(luma, w, h, x, y, sign) {
  let best = null, score = 0;
  for (let dy = -6; dy <= 6; dy += 3) for (let dx = -6; dx <= 6; dx += 3) {
    const cx = x + dx, cy = y + dy;
    for (let i = 0; i < 12; i++) {
      const angle = i * Math.PI / 12;
      const q = ridge(luma, w, h, cx, cy, angle, sign);
      if (!q) continue;
      const vx = Math.cos(angle) * 6, vy = Math.sin(angle) * 6;
      const a = ridge(luma, w, h, cx - vx, cy - vy, angle, sign);
      const b = ridge(luma, w, h, cx + vx, cy + vy, angle, sign);
      if (!a || !b) continue;
      const s = Math.min(a.score, q.score, b.score) - 0.00025 * (Math.abs(dx) + Math.abs(dy));
      if (s > score) { best = q; score = s; }
    }
  }
  return best;
}

function footprint(points, w, h, x0, y0, W, mask) {
  const add = new Uint8Array(w * h);
  let left = w, right = 0, top = h, bottom = 0, area = 0;
  for (const { x, y, radius } of points) {
    for (let iy = Math.ceil(y - radius); iy <= Math.floor(y + radius); iy++) {
      for (let ix = Math.ceil(x - radius); ix <= Math.floor(x + radius); ix++) {
        const i = iy * w + ix, global = (y0 + iy) * W + x0 + ix;
        if (add[i] || mask[global] || (ix - x) ** 2 + (iy - y) ** 2 > radius ** 2) continue;
        add[i] = 1;
        area++;
        left = Math.min(left, ix); right = Math.max(right, ix);
        top = Math.min(top, iy); bottom = Math.max(bottom, iy);
      }
    }
  }
  return { add, left, right, top, bottom, area };
}

async function enhanceFibers({ original, repaired, mask, W, H, C, marks, polarity = 'auto', tick = async () => {} }) {
  const seeds = marks.filter(mark => usefulSeed(mark) && (polarity === 'auto' || mark.polarity === polarity))
    .sort((a, b) => b.z - a.z).slice(0, MAX_SEEDS);
  const found = [];
  let pixels = 0;
  for (const seed of seeds) {
    await tick();
    if (found.some(mark => seed.cx >= mark.x0 && seed.cx <= mark.x1 && seed.cy >= mark.y0 && seed.cy <= mark.y1)) continue;
    const x0 = Math.max(0, Math.floor(seed.cx) - PAD), y0 = Math.max(0, Math.floor(seed.cy) - PAD);
    const w = Math.min(W, Math.ceil(seed.cx) + PAD + 1) - x0;
    const h = Math.min(H, Math.ceil(seed.cy) + PAD + 1) - y0;
    const data = patch(original, W, C, x0, y0, w, h);
    const luma = gaussianBlur(lumaFromU16(data, w, h, C), w, h, 1.35);
    const sign = seed.polarity === 'dark' ? -1 : 1;
    const start = startRidge(luma, w, h, seed.cx - x0, seed.cy - y0, sign);
    if (!start) continue;
    const backward = trace(luma, w, h, start, start.angle + Math.PI, sign);
    const forward = trace(luma, w, h, start, start.angle, sign);
    const points = [...backward.slice().reverse(), start, ...forward];
    const first = points[0], last = points[points.length - 1];
    const dx = last.x - first.x, dy = last.y - first.y, length = Math.hypot(dx, dy);
    if (points.length < 14 || length < 44 || points.length * STEP > 1.65 * length) continue;
    const bend = Math.max(...points.map(q => Math.abs(dy * (q.x - first.x) - dx * (q.y - first.y)))) / (length * length);
    if (bend < 0.03 || !points.some(q => q.x + x0 < seed.x0 - 5 || q.x + x0 > seed.x1 + 5
      || q.y + y0 < seed.y0 - 5 || q.y + y0 > seed.y1 + 5)) continue;

    const tail = [...turnAtTip(luma, w, h, backward, sign), ...turnAtTip(luma, w, h, forward, sign)];
    let changed = 0, trackLength = length;
    let minX = w, minY = h, maxX = 0, maxY = 0;
    // Repair a recovered tip separately so its donors and mask cannot
    // change the already healed body, including where it crosses an edge.
    for (const part of [points, tail]) {
      if (!part.length) continue;
      const { add, left, right, top, bottom, area } = footprint(part, w, h, x0, y0, W, mask);
      if (area < 35) continue;
      const previous = new Uint8Array(w * h);
      for (let y = 0; y < h; y++) previous.set(mask.subarray((y0 + y) * W + x0, (y0 + y) * W + x0 + w), y * w);
      const healed = patch(repaired, W, C, x0, y0, w, h);
      await heal(healed, w, h, C, add, null, null, tick, previous);
      const before = changed;
      for (let y = top; y <= bottom; y++) for (let x = left; x <= right; x++) {
        const local = y * w + x, global = (y0 + y) * W + x0 + x;
        if (!add[local]) continue;
        let differs = false;
        for (let c = 0; c < C; c++) differs ||= healed[local * C + c] !== original[global * C + c];
        if (!differs) continue;
        repaired.set(healed.subarray(local * C, (local + 1) * C), global * C);
        mask[global] = 1;
        changed++;
      }
      if (changed === before) continue;
      minX = Math.min(minX, left); minY = Math.min(minY, top);
      maxX = Math.max(maxX, right); maxY = Math.max(maxY, bottom);
      if (part === tail) trackLength += tail.length * STEP;
    }
    if (changed) {
      pixels += changed;
      found.push({ id: -3, kind: 'hair/fibre', verdict: 'defect', why: 'a narrow curved fibre traced from a detected fragment',
        polarity: seed.polarity, x0: x0 + minX, x1: x0 + maxX, y0: y0 + minY, y1: y0 + maxY,
        cx: Math.round(seed.cx), cy: Math.round(seed.cy), area: changed, width: 2 * start.radius, length: Math.round(trackLength) });
    }
  }
  return { marks: found, pixels };
}

module.exports = { enhanceFibers };
