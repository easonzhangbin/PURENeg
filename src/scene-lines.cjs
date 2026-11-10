'use strict';

const measurements = require('../vendor/film-dust/engine/marks');
const { PointGrid, skeletonize } = require('../vendor/film-dust/engine/regions');

const samplePath = Symbol('photo line samples');
const linkTexture = 'link texture along its length (chain/jewellery/beads)';
const detailedTexture = 'in detailed photo texture (hair/fabric/foliage): left for safety';
const softTexture = 'not crisp enough for debris on the film (photo detail)';

function longCoherentLine(line) {
  return line.length >= 150 && line.straight <= 0.06 && line.path >= 0.75 * line.length;
}

function capturePhotoLinePaths() {
  const lineFeatures = measurements.lineFeatures;
  measurements.lineFeatures = function (luma, region, width, height, bright) {
    const line = lineFeatures(luma, region, width, height, bright);
    if (!line || line.length < 60 || (line.gaps < 0.18 && line.per < 0.36 && !longCoherentLine(line))) return line;
    const points = skeletonize(region, width, height);
    const xs = [], ys = [];
    for (let index = 0; index < points.length; index++) {
      if (!points[index]) continue;
      xs.push(index % width);
      ys.push(Math.floor(index / width));
    }
    Object.defineProperty(line, samplePath, { value: { xs, ys } });
    return line;
  };
}

function photoLineProtections(marks, factor = 1) {
  const result = [];
  for (const mark of marks) {
    const sample = mark.line?.[samplePath];
    if (!sample || mark.verdict !== 'keep-photo' || mark.quietBrightRidge || mark.polarity !== 'bright') continue;
    const linked = mark.why === linkTexture;
    const textured = mark.why === detailedTexture && mark.net <= -1.6 && mark.line.gaps >= 0.18;
    const soft = mark.why === softTexture && longCoherentLine(mark.line);
    if (!linked && !textured && !soft) continue;
    const x0 = Math.max(0, mark.x0 - 20 * factor), y0 = Math.max(0, mark.y0 - 20 * factor);
    const center = (factor - 1) / 2;
    const xs = sample.xs.map(x => x0 + factor * x + center);
    const ys = sample.ys.map(y => y0 + factor * y + center);
    const radius = Math.max(6, Math.min(12, (soft ? 2 : 1.5) * mark.line.half_w)) * factor;
    const directTexture = linked && (mark.line.per >= 0.35 || (mark.detail >= 1 && mark.net <= -1.2));
    const directSoftLength = soft && mark.detail >= 1 && mark.net < 0 ? mark.line.length * factor : 0;
    result.push({ directTexture, directSoftLength, x0: mark.x0 - radius, x1: mark.x1 + radius, y0: mark.y0 - radius, y1: mark.y1 + radius,
      xs, ys, radius, grid: new PointGrid(ys, xs, Math.ceil(radius * 2)), sourceId: mark.id, soft, softWithTexture: soft && mark.line.gaps >= 0.18 && (mark.net <= -1.2 || mark.detail >= 1) });
  }
  return result;
}

function followsPhotoLine(protections, points, polarity, includeSoft = false) {
  if (polarity !== 'bright' || points.length < 3) return null;
  const required = Math.ceil(points.length * 0.6);
  for (const item of protections) {
    if (item.soft && !includeSoft) continue;
    const { x0, x1, y0, y1, xs, ys, radius, grid } = item;
    const nearby = points.filter(({ x, y }) => x >= x0 && x <= x1 && y >= y0 && y <= y1);
    if (nearby.length < required) continue;
    let matched = 0;
    for (const { x, y } of nearby) {
      if (grid.queryBox(y, x, radius).some(index => (x - xs[index]) ** 2 + (y - ys[index]) ** 2 <= radius ** 2)) matched++;
      if (matched >= required) return item;
    }
  }
  return null;
}

module.exports = { capturePhotoLinePaths, photoLineProtections, followsPhotoLine };
