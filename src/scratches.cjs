'use strict';

const { heal } = require('../vendor/film-dust/engine/heal');

const BLOCK = 40, BORDER = 16, CONTEXT = 112;

function luma16(data, W, H, C) {
  if (C === 1) return data;
  const luma = new Uint16Array(W * H);
  for (let p = 0, i = 0; p < luma.length; p++, i += C) {
    luma[p] = (54 * data[i] + 183 * data[i + 1] + 19 * data[i + 2]) >>> 8;
  }
  return luma;
}

// A thin scratch yields a ridge against both flanks, in the same direction
// for many successive blocks. A step edge, a wide painted stripe or a
// highlight confined to a small object fails the profile or length tests.
function ridge(profile, q, d, far) {
  const center = profile[q];
  const a = center - (profile[q - d] + profile[q - d - 1]) / 2;
  const b = center - (profile[q + d] + profile[q + d + 1]) / 2;
  if (a * b <= 0) return 0;
  const peak = Math.min(Math.abs(a), Math.abs(b));
  if (peak < 84 || peak < 0.32 * Math.max(Math.abs(a), Math.abs(b))) return 0;
  const sign = Math.sign(a);
  const a2 = sign * (center - (profile[q - far] + profile[q - far - 2]) / 2);
  const b2 = sign * (center - (profile[q + far] + profile[q + far + 2]) / 2);
  if (Math.min(a2, b2) < 0.56 * peak || peak < 0.44 * Math.max(a2, b2)) return 0;
  return sign * Math.round(peak);
}

// A fixed scan row can lose a faint scratch when its centre drifts across
// pixels or the background brightens on one side. Follow a confirmed end
// along its measured slope, checking the narrow cross section at each sample.
function continuationScore(luma, W, vertical, t, q, slope, sign) {
  const step = vertical ? 1 : W;
  let left = 0, right = 0, wide = 0, support = 0;
  for (let d = -BLOCK / 2; d < BLOCK / 2; d += 2) {
    const u = t + d, v = q + Math.round(d * slope);
    const p = vertical ? u * W + v : v * W + u;
    const center = luma[p];
    const a = sign * (center - (luma[p - 3 * step] + luma[p - 4 * step]) / 2);
    const b = sign * (center - (luma[p + 3 * step] + luma[p + 4 * step]) / 2);
    left += a; right += b;
    wide += sign * (center - (luma[p - 7 * step] + luma[p - 9 * step] + luma[p + 7 * step] + luma[p + 9 * step]) / 4);
    if (Math.min(a, b) >= 40) support++;
  }
  const narrow = (left + right) / 2;
  if (support < BLOCK * 0.275 || Math.min(left, right) < Math.max(left, right) * 0.28 ||
      narrow < 0.55 * wide || wide < 0.52 * narrow) return 0;
  return Math.min(left, right) / (BLOCK / 2);
}

function extendTrack(luma, W, H, vertical, track, mean) {
  const along = vertical ? H : W, across = vertical ? W : H;
  const samples = track.samples;
  if (samples.length > 18) return samples;
  const ends = [];
  for (const direction of [-1, 1]) {
    const first = direction < 0 ? samples[0] : samples.at(-1);
    const inner = direction < 0 ? samples[4] : samples.at(-5);
    const slope = (first.q - inner.q) / (first.t - inner.t);
    const added = [];
    if (Math.abs(slope) <= 0.08) for (let i = 1; i <= 6; i++) {
      const t = first.t + i * BLOCK * direction;
      const expected = Math.round(first.q + (t - first.t) * slope);
      if (t < BORDER + BLOCK / 2 || t + BLOCK / 2 > along - BORDER) break;
      let best = null, bestRank = 0;
      for (let q = expected - 3; q <= expected + 3; q++) {
        if (q < BORDER || q >= across - BORDER || Math.abs(q - (added.at(-1) ?? first).q) > 4) continue;
        const score = continuationScore(luma, W, vertical, t, q, slope, track.sign);
        const rank = score - 18 * Math.abs(q - expected);
        if (score >= Math.max(150, mean * 0.32) && rank > bestRank) {
          best = { t, q, score, radius: first.radius };
          bestRank = rank;
        }
      }
      if (!best) break;
      added.push(best);
    }
    ends.push(added);
  }
  return [...ends[0].reverse(), ...samples, ...ends[1]];
}

async function alongAxis(luma, W, H, vertical, polarity, tick) {
  const along = vertical ? H : W, across = vertical ? W : H;
  if (along < 6 * BLOCK + 2 * BORDER || across <= 2 * BORDER) return [];
  const profile = new Int32Array(across), scores = new Int32Array(across);
  const radii = new Uint8Array(across), tracks = [];
  const layers = [null, null];
  for (let start = BORDER, block = 0; start + BLOCK <= along - BORDER; start += BLOCK, block++) {
    profile.fill(0);
    const end = start + BLOCK;
    if (vertical) {
      for (let y = start; y < end; y += 3) {
        const row = y * W;
        for (let x = 0; x < W; x++) profile[x] += luma[row + x];
      }
    } else {
      for (let y = 0; y < H; y++) {
        const row = y * W;
        let sum = 0;
        for (let x = start; x < end; x += 3) sum += luma[row + x];
        profile[y] = sum;
      }
    }
    const n = Math.ceil(BLOCK / 3);
    for (let q = 0; q < across; q++) profile[q] = Math.round(profile[q] / n);
    for (let q = BORDER; q < across - BORDER; q++) {
      const narrow = ridge(profile, q, 3, 7), wide = ridge(profile, q, 5, 11);
      const preferNarrow = Math.abs(narrow) >= Math.abs(wide) * 0.82;
      let score = preferNarrow ? narrow : wide;
      if ((polarity === 'bright' && score < 0) || (polarity === 'dark' && score > 0)) score = 0;
      scores[q] = score;
      radii[q] = preferNarrow ? 2 : 4;
    }
    const current = new Map();
    for (let q = BORDER; q < across - BORDER; q++) {
      const score = scores[q], magnitude = Math.abs(score);
      if (!score) continue;
      let peak = true;
      for (let d = -3; d <= 3 && peak; d++) {
        const other = scores[q + d];
        if (score * other > 0 && (Math.abs(other) > magnitude || (d < 0 && Math.abs(other) === magnitude))) peak = false;
      }
      if (!peak) continue;
      // An isolated dust speck can dominate the mean of a whole block.
      // Require the ridge to appear in several separated raw samples as well.
      const sign = Math.sign(score), d = radii[q] === 2 ? 4 : 7;
      const step = vertical ? 1 : W, threshold = Math.max(38, 0.26 * magnitude);
      let support = 0;
      for (let t = start; t < end; t += 3) {
        const p = vertical ? t * W + q : q * W + t;
        const v = luma[p];
        if (sign * (v - (luma[p - d * step] + luma[p - (d + 2) * step]) / 2) >= threshold &&
            sign * (v - (luma[p + d * step] + luma[p + (d + 2) * step]) / 2) >= threshold) support++;
      }
      if (support < 7) continue;
      let best, cost = Infinity;
      for (let age = 1; age <= 2; age++) {
        const recent = layers[age - 1];
        if (!recent) continue;
        const reach = age === 1 ? 3 : 4;
        for (let d = -reach; d <= reach; d++) {
          const t = recent.get(q + d);
          if (!t || t.block !== block - age || t.sign !== sign) continue;
          const v = Math.abs(d) + (age - 1) * 2;
          if (v < cost) { best = t; cost = v; }
        }
      }
      const item = { t: start + (BLOCK >> 1), q, score: magnitude, radius: radii[q] };
      if (!best) best = { sign, samples: [], sum: 0, block };
      best.samples.push(item); best.block = block; best.sum += magnitude;
      if (best.samples.length === 6) tracks.push(best);
      current.set(q, best);
    }
    layers[1] = layers[0]; layers[0] = current;
    if (block % 8 === 0) await tick();
  }
  const lines = [];
  for (const track of tracks) {
    const samples = track.samples, first = samples[0], last = samples.at(-1);
    const length = last.t - first.t + BLOCK;
    const mean = track.sum / samples.length;
    if (samples.length * BLOCK < 0.8 * length || mean < (length < 320 ? 350 : 190)) continue;
    const slope = (last.q - first.q) / (last.t - first.t);
    if (Math.abs(slope) > 0.08 ||
        samples.filter(({ t, q }) => Math.abs(q - (first.q + (t - first.t) * slope)) <= 5).length < samples.length * 0.8) continue;
    const extended = extendTrack(luma, W, H, vertical, track, mean);
    lines.push({ vertical, sign: track.sign, samples: extended, score: mean, length: extended.at(-1).t - extended[0].t + BLOCK });
  }
  return lines;
}

function isBroadRidgeNearFrame(luma, W, H, line, edges) {
  const { vertical, samples, sign } = line;
  const first = samples[0], last = samples.at(-1);
  const across = vertical ? W : H;
  const slope = (last.q - first.q) / (last.t - first.t);
  const nearEdge = (edge, reverse) => edge && Math.abs(slope - (reverse ? -edge.b : edge.b)) <= 0.03 &&
    samples.every(({ t, q }) => {
      const distance = (reverse ? across - 1 - q : q) - (edge.a + edge.b * t);
      return distance >= 0 && distance < 0.2 * across;
    });
  if (!nearEdge(vertical ? edges.left : edges.top, false) &&
      !nearEdge(vertical ? edges.right : edges.bottom, true)) return false;

  // The preliminary scan finds blurred grout and similar straight detail
  // at a wide scale. An actual thin ridge retains its contrast when the
  // shoulders move in close. Compare both sides over the full track.
  const step = vertical ? 1 : W;
  let broad = 0;
  for (const { t, q } of samples) {
    let nearLeft = 0, nearRight = 0, farLeft = 0, farRight = 0;
    for (let d = -12; d <= 12; d += 2) {
      const u = t + d, v = q + Math.round(d * slope);
      const p = vertical ? u * W + v : v * W + u;
      const center = 2 * luma[p];
      nearLeft += sign * (center - luma[p - 3 * step] - luma[p - 4 * step]);
      nearRight += sign * (center - luma[p + 3 * step] - luma[p + 4 * step]);
      farLeft += sign * (center - luma[p - 8 * step] - luma[p - 9 * step]);
      farRight += sign * (center - luma[p + 8 * step] - luma[p + 9 * step]);
    }
    const far = Math.min(farLeft, farRight);
    if (far > 0 && Math.min(nearLeft, nearRight) < 0.65 * far) broad++;
  }
  return broad * 3 >= samples.length * 2;
}

async function detectScratches(data, W, H, C, polarity = 'auto', tick = async () => {}, frame = null) {
  const luma = luma16(data, W, H, C);
  const horizontal = await alongAxis(luma, W, H, false, polarity, tick);
  const vertical = await alongAxis(luma, W, H, true, polarity, tick);
  const lines = [...horizontal, ...vertical];
  const accepted = frame ? lines.filter(line => !isBroadRidgeNearFrame(luma, W, H, line, frame.edges)) : lines;
  return accepted.sort((a, b) => (b.score * Math.sqrt(b.length)) - (a.score * Math.sqrt(a.length)));
}

async function healScratches(lines, pixels, mask, W, H, C, tick) {
  const marks = [];
  let fresh = 0;
  const cap = Math.min(150_000, Math.max(12_000, Math.floor(W * H * 0.0015)));
  for (const { vertical, samples, sign, length, score } of lines) {
    const first = samples[0], last = samples.at(-1);
    const T = vertical ? H : W, Q = vertical ? W : H;
    const t0 = first.t - (BLOCK >> 1), t1 = Math.min(T, last.t + (BLOCK >> 1));
    let lo = Q, hi = 0;
    for (const s of samples) { lo = Math.min(lo, s.q - s.radius - 1); hi = Math.max(hi, s.q + s.radius + 2); }
    const [x0, y0, x1, y1] = vertical ?
      [Math.max(0, lo - CONTEXT), Math.max(0, t0 - CONTEXT), Math.min(W, hi + CONTEXT), Math.min(H, t1 + CONTEXT)] :
      [Math.max(0, t0 - CONTEXT), Math.max(0, lo - CONTEXT), Math.min(W, t1 + CONTEXT), Math.min(H, hi + CONTEXT)];
    const w = x1 - x0, h = y1 - y0;
    const targets = [], originalIndices = [];
    let covered = 0, s = 0;
    for (let t = t0; t < t1; t++) {
      while (s + 1 < samples.length && t > samples[s + 1].t) s++;
      const a = samples[s], b = samples[Math.min(s + 1, samples.length - 1)];
      const mix = a === b ? 0 : Math.max(0, (t - a.t) / (b.t - a.t));
      const center = Math.round(a.q + mix * (b.q - a.q)), radius = Math.round(a.radius + mix * (b.radius - a.radius));
      for (let q = Math.max(0, center - radius); q <= Math.min(Q - 1, center + radius); q++) {
        const [x, y] = vertical ? [q, t] : [t, q];
        const p = y * W + x;
        if (mask[p]) { covered++; continue; }
        targets.push((y - y0) * w + x - x0); originalIndices.push(p);
      }
    }
    // Two neighbouring ridge tracks can describe the same scratch. Retain
    // only lines with meaningful new coverage, within an image-wide budget.
    if (targets.length < 0.45 * (targets.length + covered) || fresh + targets.length > cap || !targets.length) continue;
    const crop = new Uint16Array(w * h * C), selected = new Uint8Array(w * h), avoid = new Uint8Array(w * h);
    for (let y = y0; y < y1; y++) {
      crop.set(pixels.subarray((y * W + x0) * C, (y * W + x1) * C), (y - y0) * w * C);
      avoid.set(mask.subarray(y * W + x0, y * W + x1), (y - y0) * w);
    }
    for (const p of targets) selected[p] = 1;
    await heal(crop, w, h, C, selected, null, null, tick, avoid);
    for (let i = 0; i < targets.length; i++) {
      const p = originalIndices[i], q = targets[i];
      for (let c = 0; c < C; c++) pixels[p * C + c] = crop[q * C + c];
      mask[p] = 1;
    }
    fresh += targets.length;
    marks.push({ kind: 'scratch', verdict: 'defect', why: 'a narrow, two-sided ridge continuing over multiple blocks',
      polarity: sign > 0 ? 'bright' : 'dark', length, contrast: Math.round(score), area: targets.length,
      x0: vertical ? lo : t0, y0: vertical ? t0 : lo, x1: vertical ? hi : t1, y1: vertical ? t1 : hi });
    await tick();
  }
  return { marks, pixels: fresh };
}

module.exports = { detectScratches, healScratches };
