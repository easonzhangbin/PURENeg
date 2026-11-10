'use strict';

const BLOCK = 20, MIN_OFFSET = 12, MAX_OFFSET = 34;

function centerAt(samples, index, t) {
  const a = samples[index], b = samples[index + 1] ?? a;
  return a === b ? a.q : Math.round(a.q + (b.q - a.q) * (t - a.t) / (b.t - a.t));
}

function scratchPath(line) {
  const { samples, vertical } = line;
  const points = [];
  for (let t = samples[0].t, index = 0; t <= samples.at(-1).t; t += 4) {
    while (index + 1 < samples.length && t > samples[index + 1].t) index++;
    const q = centerAt(samples, index, t);
    points.push(vertical ? { x: q, y: t } : { x: t, y: q });
  }
  return points;
}

function followsParallelEdge(luma, width, height, line, frame) {
  const { samples, vertical, sign, score } = line;
  const across = vertical ? width : height;
  const step = vertical ? 1 : width;
  const nearRebate = vertical ? frame?.edges?.left : frame?.edges?.top;
  const farRebate = vertical ? frame?.edges?.right : frame?.edges?.bottom;
  const profile = new Int32Array(2 * MAX_OFFSET + 7);
  const center = MAX_OFFSET + 3;
  const rising = new Uint32Array(2 * MAX_OFFSET + 1), falling = new Uint32Array(rising.length);
  let blocks = 0;
  for (let start = samples[0].t, index = 0; start + BLOCK <= samples.at(-1).t; start += BLOCK) {
    profile.fill(0);
    let count = 0, sumQ = 0;
    blocks++;
    for (let t = start; t < start + BLOCK; t += 2) {
      while (index + 1 < samples.length && t > samples[index + 1].t) index++;
      const q = centerAt(samples, index, t);
      if (q < center || q + center >= across) continue;
      const p = vertical ? t * width + q : q * width + t;
      for (let i = 0; i < profile.length; i++) profile[i] += luma[p + (i - center) * step];
      count++;
      sumQ += q;
    }
    if (!count) continue;
    const band = q => (profile[q - 1] + profile[q] + profile[q + 1]) / 3;
    const crest = sign * Math.max(sign * profile[center - 1], sign * profile[center], sign * profile[center + 1]);
    const ridge = Math.max(84 * count, score * count / 4,
      Math.min(sign * (crest - band(center - 5)), sign * (crest - band(center + 5))));
    let strongest = 4 * ridge, edge = null;
    const midpoint = start + BLOCK / 2;
    const nearEdge = nearRebate ? nearRebate.a + nearRebate.b * midpoint : -Infinity;
    const farEdge = farRebate ? across - 1 - farRebate.a - farRebate.b * midpoint : Infinity;
    for (const side of [-1, 1]) for (let distance = MIN_OFFSET; distance <= MAX_OFFSET; distance++) {
      const offset = side * distance, q = center + offset;
      const position = sumQ / count + offset;
      if (Math.abs(position - nearEdge) <= 6 || Math.abs(position - farEdge) <= 6) continue;
      const gradient = band(q - 2) - band(q + 2);
      if (Math.abs(gradient) <= strongest) continue;
      strongest = Math.abs(gradient);
      edge = { offset, direction: Math.sign(gradient) };
    }
    if (edge) (edge.direction > 0 ? rising : falling)[edge.offset + MAX_OFFSET]++;
  }
  // A short crossing can have a stronger edge in a few samples. Require
  // the same nearby contour and contrast direction along most of the track.
  for (const counts of [rising, falling]) for (let i = 0; i < counts.length; i++) {
    if (!counts[i]) continue;
    let agreeing = 0;
    for (let j = Math.max(0, i - 6); j <= Math.min(counts.length - 1, i + 6); j++) agreeing += counts[j];
    if (agreeing >= 0.8 * blocks) return true;
  }
  return false;
}

module.exports = { followsParallelEdge, scratchPath };
