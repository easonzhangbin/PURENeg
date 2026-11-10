'use strict';

const { followsPhotoLine } = require('./scene-lines.cjs');
const { scratchPath } = require('./scratch-context.cjs');

const MAX_OFFSET = 86;
const POINTS_PER_BLOCK = 5; // scratchPath samples every four pixels.

function materialRidge(luma, width, height, line, frame, protectedLines) {
  if (line.sign <= 0) return null;
  const { vertical } = line;
  const path = scratchPath(line);
  const across = vertical ? width : height;
  const step = vertical ? 1 : width;
  const nearRebate = vertical ? frame?.edges?.left : frame?.edges?.top;
  const farRebate = vertical ? frame?.edges?.right : frame?.edges?.bottom;
  const profile = new Int32Array(2 * MAX_OFFSET + 1);
  const related = [];
  let blocks = 0, broad = 0, soft = 0;
  for (let i = 0; i + POINTS_PER_BLOCK <= path.length; i += POINTS_PER_BLOCK) {
    const middle = path[i + (POINTS_PER_BLOCK >> 1)];
    const t = vertical ? middle.y : middle.x;
    const q = vertical ? middle.x : middle.y;
    const near = nearRebate ? nearRebate.a + nearRebate.b * t : -Infinity;
    const far = farRebate ? across - 1 - farRebate.a - farRebate.b * t : Infinity;
    blocks++;
    if (q - near < 14 || far - q < 14) continue;
    let count = 0;
    profile.fill(0);
    for (let j = i; j < i + POINTS_PER_BLOCK; j++) {
      const { x, y } = path[j];
      const cross = vertical ? x : y;
      if (cross < MAX_OFFSET || cross + MAX_OFFSET >= across) continue;
      const index = y * width + x;
      for (let d = -MAX_OFFSET; d <= MAX_OFFSET; d++) profile[d + MAX_OFFSET] += luma[index + d * step];
      count++;
    }
    if (!count) continue;

    const at = d => profile[d + MAX_OFFSET];
    const band = (low, high) => {
      let sum = 0;
      for (let d = low; d <= high; d++) sum += at(d);
      return sum / (high - low + 1);
    };
    let crest = 0;
    for (let d = -2; d <= 2; d++) if (at(d) > at(crest)) crest = d;
    const prominence = (inner, outer) => at(crest) - Math.max(band(crest - outer, crest - inner), band(crest + inner, crest + outer));
    const ridge = prominence(4, 6);
    if (ridge < 84 * count) continue;
    const tight = prominence(2, 3);
    if (tight <= 0.56 * ridge && prominence(8, 12) >= 1.55 * ridge) broad++;
    if (tight <= 0.72 * ridge) soft++;

    // A more distant contour only supports a photo interpretation when it
    // is independently recognized as scene detail by the base detector.
    if (!protectedLines.length) continue;
    let strongest = 4 * Math.max(ridge, line.score * count / 4), edge = null;
    for (const side of [-1, 1]) for (let distance = 54; distance <= 82; distance++) {
      const d = side * distance;
      if (Math.abs(q + d - near) <= 6 || Math.abs(q + d - far) <= 6) continue;
      const contrast = Math.abs(band(d - 3, d - 1) - band(d + 1, d + 3));
      if (contrast <= strongest) continue;
      strongest = contrast;
      edge = vertical ? { x: q + d, y: t } : { x: t, y: q + d };
    }
    if (edge) related.push(edge);
  }

  if (blocks < 8) return null;
  if (broad >= 0.7 * blocks && soft >= 0.9 * blocks) return 'broad material ridge';
  if (soft < 0.65 * blocks || related.length < 0.8 * blocks) return null;
  const protection = followsPhotoLine(protectedLines, related, 'bright');
  return protection ? `soft ridge beside protected line ${protection.sourceId}` : null;
}

module.exports = { materialRidge };
