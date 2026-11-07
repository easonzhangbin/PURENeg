'use strict';

// A narrow highlight with uneven flanks can belong to a fold or an edge.
// Require agreement between that geometry and the two classifiers before
// overriding a previously accepted repair.
function isSceneEdge(mark) {
  const line = mark.line;
  return line && mark.kind !== 'speck' && mark.area >= 250 && mark.length >= 36 &&
    mark.length >= 2.8 * mark.width && mark.scene <= 0 && mark.learned <= 0.65 &&
    line.one_med >= 0.28 && line.per >= 0.24;
}

function isSmallCoreInDetail(mark) {
  return !mark.line && mark.kind === 'dust' && mark.area <= 160 && mark.detail >= 8 && mark.tex >= 1;
}

function nearestMaskPixel(mask, width, height, mark) {
  const x = Math.round(mark.cx), y = Math.round(mark.cy);
  if (!Number.isInteger(x) || !Number.isInteger(y) || x < 0 || y < 0 || x >= width || y >= height) return -1;
  const radius = Math.min(24, Math.max(6, Math.ceil(mark.width * 2)));
  let best = -1, distance = radius * radius + 1;
  for (let qy = Math.max(0, y - radius); qy <= Math.min(height - 1, y + radius); qy++) {
    for (let qx = Math.max(0, x - radius); qx <= Math.min(width - 1, x + radius); qx++) {
      const index = qy * width + qx;
      const squared = (qx - x) ** 2 + (qy - y) ** 2;
      if (mask[index] && squared < distance) {
        best = index;
        distance = squared;
      }
    }
  }
  return best;
}

function connectedRepair(mask, width, height, seed, limit) {
  const seen = new Set([seed]), pixels = [seed];
  for (let cursor = 0; cursor < pixels.length; cursor++) {
    const index = pixels[cursor], x = index % width, y = Math.floor(index / width);
    for (let qy = Math.max(0, y - 1); qy <= Math.min(height - 1, y + 1); qy++) {
      for (let qx = Math.max(0, x - 1); qx <= Math.min(width - 1, x + 1); qx++) {
        const next = qy * width + qx;
        if (!mask[next] || seen.has(next)) continue;
        seen.add(next);
        pixels.push(next);
        if (pixels.length > limit) return null;
      }
    }
  }
  return seen;
}

function protectSceneStructures(mask, width, height, marks) {
  const accepted = marks.filter(mark => mark.verdict === 'defect');
  const strong = accepted.filter(mark => mark.scene >= 1 && mark.learned >= 0.85 && Number.isFinite(mark.cx) && Number.isFinite(mark.cy));
  let protectedPixels = 0;
  for (const mark of accepted) {
    const edge = isSceneEdge(mark);
    if (!edge && !isSmallCoreInDetail(mark)) continue;
    const seed = nearestMaskPixel(mask, width, height, mark);
    if (seed < 0) continue;
    // Work on the connected repair, not a rectangle around it. A small
    // bright core cannot justify growing into a much larger textured shape.
    const pixels = connectedRepair(mask, width, height, seed, Math.min(20_000, Math.max(3_000, 8 * mark.area)));
    if (!pixels || (!edge && pixels.size < Math.max(300, 8 * mark.area))) continue;
    if (strong.some(other => other !== mark && pixels.has(Math.round(other.cy) * width + Math.round(other.cx)))) continue;
    for (const index of pixels) mask[index] = 0;
    protectedPixels += pixels.size;
    mark.verdict = 'keep-photo';
    mark.why = edge ? 'a bright ridge that follows an edge in the photo' : 'a small core growing into a larger area of photo detail';
    for (const other of accepted) {
      if (other.id !== -3 || other.cx !== mark.cx || other.cy !== mark.cy) continue;
      other.verdict = 'keep-photo';
      other.why = mark.why;
    }
  }
  return protectedPixels;
}

module.exports = { protectSceneStructures };
