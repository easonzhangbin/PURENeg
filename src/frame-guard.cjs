'use strict';

const { gaussianBlur } = require('../vendor/film-dust/engine/filters');
const { frameEdges, beyondFrame } = require('../vendor/film-dust/engine/maps');

const NEAR_BLACK = 0.025;

// A clipped dark film rebate is different from a dark part of the picture.
// Check the outer strip before fitting a frame, then confirm clipped black
// across the band on the outside of each fitted edge.
function buildFrameProtection(data, width, height, channels) {
  const luma = (x, y) => {
    const i = (y * width + x) * channels;
    if (channels === 1) return data[i] / 65535;
    return (0.2126 * data[i] + 0.7152 * data[i + 1] + 0.0722 * data[i + 2]) / 65535;
  };
  const sides = {
    top: [width, height, (t, d) => luma(t, d)],
    bottom: [width, height, (t, d) => luma(t, height - 1 - d)],
    left: [height, width, (t, d) => luma(d, t)],
    right: [height, width, (t, d) => luma(width - 1 - d, t)],
  };
  const samples = 48;
  const reachesEdge = Object.entries(sides).filter(([, [along, depth, at]]) => {
    if (along < 128 || depth < 128) return false;
    let dark = 0;
    for (let i = 0; i < samples; i++) {
      const t = Math.floor((0.08 + 0.84 * (i + 0.5) / samples) * along);
      if (at(t, 0) < NEAR_BLACK && at(t, 4) < NEAR_BLACK) dark++;
    }
    return dark >= samples * 0.65;
  });
  if (!reachesEdge.length) return null;

  const step = Math.max(2, Math.ceil(Math.max(width, height) / 1200));
  const w = Math.floor(width / step), h = Math.floor(height / step);
  if (w < 64 || h < 64) return null;
  const sx = width / w, sy = height / h;
  const reduced = new Float32Array(w * h);
  for (let y = 0; y < h; y++) {
    const ya = Math.floor((y + 0.25) * sy), yb = Math.floor((y + 0.75) * sy);
    for (let x = 0; x < w; x++) {
      const xa = Math.floor((x + 0.25) * sx), xb = Math.floor((x + 0.75) * sx);
      reduced[y * w + x] = (luma(xa, ya) + luma(xb, ya) + luma(xa, yb) + luma(xb, yb)) / 4;
    }
  }
  const fit = frameEdges(reduced, w, h, 1, { sm: gaussianBlur(reduced, w, h, 1.5) });
  const edges = { top: null, bottom: null, left: null, right: null };
  for (const [side, [along, depth, at]] of reachesEdge) {
    if (!fit[side]) continue;
    const horizontal = side === 'top' || side === 'bottom';
    const depthScale = horizontal ? sy : sx;
    const alongScale = horizontal ? sx : sy;
    const edge = { a: fit[side].a * depthScale, b: fit[side].b * depthScale / alongScale };
    let dark = 0;
    for (let i = 0; i < samples; i++) {
      const t = Math.floor((0.08 + 0.84 * (i + 0.5) / samples) * along);
      const d = edge.a + edge.b * t;
      if (d >= 8 && d <= 0.15 * depth && at(t, Math.floor(d * 0.65)) < NEAR_BLACK &&
          at(t, Math.floor(d * 0.82)) < NEAR_BLACK) dark++;
    }
    if (dark >= samples * 0.7) edges[side] = edge;
  }
  if (!Object.values(edges).some(Boolean)) return null;
  return {
    edges,
    protects(index) {
      const y = Math.floor(index / width), x = index - y * width;
      return beyondFrame(edges, width, height, x, y, step);
    },
  };
}

module.exports = { buildFrameProtection };
