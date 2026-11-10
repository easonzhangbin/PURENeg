'use strict';

const BRANCH_FLOOR = 144;
const THICK_CORE_MARGIN = 6;
const MIN_RIDGE_SUPPORT = 0.90;
const MIN_NARROW_SUPPORT = 0.55;
const NORMALS = [[0, 6], [6, 0], [4, 4], [4, -4]];

// Cross-shaped erosion depth, as used by the direct repair width check.
function coreDepth(core, width, height) {
  const depth = new Uint8Array(core.length);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const i = y * width + x;
      if (!core[i]) continue;
      depth[i] = 1 + Math.min(254, x ? depth[i - 1] : 0, y ? depth[i - width] : 0);
    }
  }
  for (let y = height - 1; y >= 0; y--) {
    for (let x = width - 1; x >= 0; x--) {
      const i = y * width + x;
      if (!depth[i]) continue;
      depth[i] = Math.min(depth[i], 1 + (x + 1 < width ? depth[i + 1] : 0),
        1 + (y + 1 < height ? depth[i + width] : 0));
    }
  }
  return depth;
}

function wideCoreMargin(depth, width, height, maxWidth) {
  const excluded = new Uint8Array(depth.length);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      if (2 * depth[y * width + x] - 1 <= maxWidth) continue;
      const left = Math.max(0, x - THICK_CORE_MARGIN);
      const right = Math.min(width, x + THICK_CORE_MARGIN + 1);
      for (let row = Math.max(0, y - THICK_CORE_MARGIN); row < Math.min(height, y + THICK_CORE_MARGIN + 1); row++) {
        excluded.fill(1, row * width + left, row * width + right);
      }
    }
  }
  return excluded;
}

function isMedial(depth, width, height, x, y) {
  const value = depth[y * width + x];
  for (let row = Math.max(0, y - 1); row <= Math.min(height - 1, y + 1); row++) {
    for (let col = Math.max(0, x - 1); col <= Math.min(width - 1, x + 1); col++) {
      if (depth[row * width + col] > value) return false;
    }
  }
  return true;
}

function ridgeSupport(luma, x, y) {
  const center = luma(x, y);
  let support = 0;
  for (const [dx, dy] of NORMALS) {
    const a = luma(x - dx, y - dy), b = luma(x + dx, y + dy);
    const contrast = center - Math.max(a, b);
    if (contrast < 2.5 || Math.abs(a - b) >= Math.max(8, 1.5 * contrast)) continue;
    // A broad glow can have a thin model score band. The original ridge
    // should already carry half its contrast at the nearer shoulders.
    const nearA = luma(x - dx / 2, y - dy / 2), nearB = luma(x + dx / 2, y + dy / 2);
    if (center - nearA >= 0.5 * (center - a) && center - nearB >= 0.5 * (center - b)) return 2;
    support = 1;
  }
  return support;
}

async function proposeTangleScores({ original, mask, W, H, C, probability, labels, rejected,
  threshold, maxWidth, minCore, minArea, maxArea, maxPatchPixels, labelRegions, findObjects, rejectBranch, tick }) {
  let scores = null;
  const luma = (x, y) => {
    const i = (Math.min(H - 1, Math.max(0, y)) * W + Math.min(W - 1, Math.max(0, x))) * C;
    if (C === 1) return original[i] / 257;
    return (0.2126 * original[i] + 0.7152 * original[i + 1] + 0.0722 * original[i + 2]) / 257;
  };
  for (const { id, widthOnly, x0, y0, x1, y1 } of rejected) {
    const width = x1 - x0 + 1, height = y1 - y0 + 1;
    if (width * height > maxPatchPixels) continue;
    await tick();
    const core = new Uint8Array(width * height);
    const candidate = new Uint8Array(core.length);
    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        const i = y * width + x, g = (y0 + y) * W + x0 + x;
        if (labels[g] !== id || probability[g] < BRANCH_FLOOR) continue;
        candidate[i] = 1;
        if (probability[g] >= threshold) core[i] = 1;
      }
    }
    // A thick knot cannot make the whole parent eligible. Cut it out with a
    // margin and judge the remaining high-confidence branches separately.
    const excluded = wideCoreMargin(coreDepth(core, width, height), width, height, maxWidth);
    for (let i = 0; i < excluded.length; i++) {
      if (excluded[i]) { candidate[i] = 0; core[i] = 0; }
    }
    const { lab, n } = labelRegions(candidate, width, height, 8);
    if (!n) continue;
    const depth = coreDepth(core, width, height);
    const boxes = findObjects(lab, width, height, n);
    for (let branch = 1; branch <= n; branch++) {
      const box = boxes[branch - 1];
      const span = Math.hypot(box.x1 - box.x0, box.y1 - box.y0);
      if (box.area < minArea || box.area > maxArea || span < 44 || box.area > span * 40) continue;
      let high = 0, alreadyRepaired = 0, medial = 0, ridge = 0, narrow = 0;
      const points = rejectBranch ? [] : null;
      for (let y = box.y0; y < box.y1; y++) {
        for (let x = box.x0; x < box.x1; x++) {
          const i = y * width + x;
          if (lab[i] !== branch) continue;
          const gx = x0 + x, gy = y0 + y;
          if (mask[gy * W + gx]) alreadyRepaired++;
          if (!core[i]) continue;
          high++;
          if (isMedial(depth, width, height, x, y)) {
            medial++;
            points?.push({ x: gx, y: gy });
            const support = ridgeSupport(luma, gx, gy);
            if (support) ridge++;
            if (support === 2) narrow++;
          }
        }
      }
      if (high < minCore || alreadyRepaired * 2 >= box.area || !medial ||
          ridge / medial < MIN_RIDGE_SUPPORT || (widthOnly && narrow / medial < MIN_NARROW_SUPPORT)) continue;
      if (rejectBranch?.(points)) continue;
      scores ??= new Uint8Array(W * H);
      for (let y = box.y0; y < box.y1; y++) {
        for (let x = box.x0; x < box.x1; x++) {
          if (lab[y * width + x] !== branch) continue;
          const i = (y0 + y) * W + x0 + x;
          scores[i] = probability[i];
        }
      }
    }
  }
  return scores;
}

module.exports = { proposeTangleScores };
