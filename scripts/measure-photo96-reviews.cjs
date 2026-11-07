'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const { createReadStream } = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { parseArgs } = require('node:util');
const { decodeTiff } = require('../src/tiff.cjs');

const DEFECTS = ['curvedFiber', 'horizontalLeft', 'horizontalRight', 'lowerScratch'];
const TRACE_RADIUS = 4;
const MASKED = 1, CHANGED = 2, CROSSING = 4;

// In the registered 14.18.12 screenshot, this broad scene line crosses the
// curved fibre. These anchors follow the broad green-channel ridge in the
// original TIFF, outside the intersection, and stay fixed for every review.
const FIELD = {
  x: [8765, 10389],
  centerline: [[8765, 5621], [8950, 5627], [9150, 5636], [9350, 5645],
    [9460, 5652], [9600, 5658], [9800, 5668], [10000, 5676], [10200, 5685], [10389, 5694]],
  halfWidth: 18,
  crossingRadius: 16,
  flank: [26, 34],
  sampleColumns: [8820, 8960, 9100, 9240, 9380, 9520, 9660, 9800, 9940, 10080, 10220, 10360],
};

const rounded = (number, precision = 3) => Number(number.toFixed(precision));

function measurementTraces(spec) {
  const traces = Object.fromEntries(DEFECTS.map(key => [key, spec[key].approximateTrace]));
  return { ...traces, curvedFiberHook: traces.curvedFiber.slice(0, 5), curvedFiberFaintTip: traces.curvedFiber.slice(-4),
    lowerScratchTail: traces.lowerScratch.slice(-3), horizontalRightFaintTail: traces.horizontalRight.slice(-2) };
}

function traceSamples(trace) {
  const samples = [];
  for (let i = 1; i < trace.length; i++) {
    const [x, y] = trace[i - 1], [u, v] = trace[i];
    const n = Math.round(Math.hypot(u - x, v - y));
    for (let j = 0; j < n; j++) {
      samples.push([Math.round(x + (u - x) * j / n), Math.round(y + (v - y) * j / n)]);
    }
  }
  return samples;
}

function coverage(mask, changed, points) {
  function near([x, y], pixels) {
    for (let dy = -TRACE_RADIUS; dy <= TRACE_RADIUS; dy++) for (let dx = -TRACE_RADIUS; dx <= TRACE_RADIUS; dx++) {
      if (dx * dx + dy * dy <= TRACE_RADIUS * TRACE_RADIUS && pixels[(y + dy) * mask.width + x + dx]) return true;
    }
    return false;
  }
  const hits = Uint8Array.from(points, point => (near(point, mask.data) ? MASKED : 0) | (near(point, changed) ? CHANGED : 0));
  const maskHits = hits.reduce((total, flags) => total + Boolean(flags & MASKED), 0);
  const changedHits = hits.reduce((total, flags) => total + Boolean(flags & CHANGED), 0);
  return { hits, result: { samples: points.length, maskHits, maskPercent: rounded(maskHits * 100 / points.length, 1),
    changedHits, changedPercent: rounded(changedHits * 100 / points.length, 1) } };
}

function centerY(x) {
  const end = FIELD.centerline.findIndex(([u]) => u > x);
  if (end < 0) return FIELD.centerline.at(-1)[1];
  const [u, y] = FIELD.centerline[end - 1], [v, z] = FIELD.centerline[end];
  return Math.round(y + (x - u) * (z - y) / (v - u));
}

function distanceSquaredToTrace(x, y, trace) {
  let best = Infinity;
  for (let i = 1; i < trace.length; i++) {
    const [u, v] = trace[i - 1], [u2, v2] = trace[i];
    const dx = u2 - u, dy = v2 - v;
    const t = Math.max(0, Math.min(1, ((x - u) * dx + (y - v) * dy) / (dx * dx + dy * dy)));
    best = Math.min(best, (x - u - t * dx) ** 2 + (y - v - t * dy) ** 2);
  }
  return best;
}

function fieldProtection(source, cleaned, mask, changed, fiberTrace) {
  const protectedBand = { pixels: 0, maskPixels: 0, changedPixels: 0, maxDelta16: 0, longestChangedColumnRun: 0 };
  const crossing = { pixels: 0, maskPixels: 0, changedPixels: 0, maxDelta16: 0, bounds: null };
  const core = { count: 0, originalG: 0, cleanedG: 0 };
  const flanks = { count: 0, originalG: 0, cleanedG: 0 };
  const examples = [];
  const flags = new Uint8Array((FIELD.x[1] - FIELD.x[0] + 1) * (2 * FIELD.halfWidth + 1));
  const values = new Uint16Array(flags.length * source.colorChannels);
  let flagIndex = 0;
  let columnRun = 0;
  const isCrossing = (x, y) => distanceSquaredToTrace(x, y, fiberTrace) <= FIELD.crossingRadius ** 2;
  const addGreen = (stats, pixel) => {
    stats.count++;
    stats.originalG += source.data[pixel * source.channels + 1];
    stats.cleanedG += cleaned.data[pixel * cleaned.channels + 1];
  };

  for (let x = FIELD.x[0]; x <= FIELD.x[1]; x++) {
    const cy = centerY(x);
    let changedColumn = false;
    for (let y = cy - FIELD.halfWidth; y <= cy + FIELD.halfWidth; y++) {
      const pixel = y * source.width + x;
      const insideCrossing = isCrossing(x, y);
      const stats = insideCrossing ? crossing : protectedBand;
      flags[flagIndex] = (insideCrossing ? CROSSING : 0) |
        (mask.data[pixel] ? MASKED : 0) | (changed[pixel] ? CHANGED : 0);
      for (let c = 0; c < source.colorChannels; c++) {
        values[flagIndex * source.colorChannels + c] = cleaned.data[pixel * source.channels + c];
      }
      flagIndex++;
      stats.pixels++;
      if (mask.data[pixel]) stats.maskPixels++;
      if (changed[pixel]) {
        stats.changedPixels++;
        const start = pixel * source.channels;
        for (let c = 0; c < source.colorChannels; c++) {
          stats.maxDelta16 = Math.max(stats.maxDelta16, Math.abs(source.data[start + c] - cleaned.data[start + c]));
        }
        if (!insideCrossing) changedColumn = true;
      }
      if (insideCrossing) {
        const b = crossing.bounds;
        crossing.bounds = b ? [Math.min(b[0], x), Math.min(b[1], y), Math.max(b[2], x + 1), Math.max(b[3], y + 1)] : [x, y, x + 1, y + 1];
      } else if (Math.abs(y - cy) <= 6) {
        addGreen(core, pixel);
      }
    }
    columnRun = changedColumn ? columnRun + 1 : 0;
    protectedBand.longestChangedColumnRun = Math.max(protectedBand.longestChangedColumnRun, columnRun);
    for (let offset = FIELD.flank[0]; offset <= FIELD.flank[1]; offset++) {
      for (const y of [cy - offset, cy + offset]) if (!isCrossing(x, y)) addGreen(flanks, y * source.width + x);
    }
    if (FIELD.sampleColumns.includes(x)) {
      const i = (cy * source.width + x) * source.channels;
      examples.push({ point: [x, cy], inCrossing: isCrossing(x, cy),
        sourceRgb16: Array.from(source.data.subarray(i, i + 3)), cleanedRgb16: Array.from(cleaned.data.subarray(i, i + 3)) });
    }
  }
  protectedBand.exact = protectedBand.changedPixels === 0;
  const originalContrast = core.originalG / core.count - flanks.originalG / flanks.count;
  const cleanedContrast = core.cleanedG / core.count - flanks.cleanedG / flanks.count;
  return { flags, values, result: { protectedBand, crossing, profile: {
    coreSamples: core.count, flankSamples: flanks.count, originalGreenContrast16: rounded(originalContrast),
    cleanedGreenContrast16: rounded(cleanedContrast), delta16: rounded(cleanedContrast - originalContrast),
  }, examples } };
}

function changedComponents(pixelIndices, width) {
  const remaining = new Set(pixelIndices);
  const groups = [];
  for (const start of pixelIndices) {
    if (!remaining.delete(start)) continue;
    const pending = [start];
    let x0 = width, x1 = 0, y0 = Infinity, y1 = 0;
    for (let i = 0; i < pending.length; i++) {
      const p = pending[i], x = p % width, y = Math.floor(p / width);
      x0 = Math.min(x0, x); x1 = Math.max(x1, x + 1);
      y0 = Math.min(y0, y); y1 = Math.max(y1, y + 1);
      for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
        const next = p + dy * width + dx;
        if (remaining.delete(next)) pending.push(next);
      }
    }
    groups.push({ pixels: pending.length, box: [x0, y0, x1, y1] });
  }
  groups.sort((a, b) => b.pixels - a.pixels);
  return { count: groups.length, largest: groups.slice(0, 8) };
}

function compareFieldFlags(before, after, width) {
  assert.equal(before.length, after.length);
  const counters = () => ({ newMaskPixels: 0, removedMaskPixels: 0, newChangedPixels: 0, removedChangedPixels: 0 });
  const result = { protectedBand: counters(), crossing: counters() };
  const bandRows = 2 * FIELD.halfWidth + 1;
  const newProtectedMask = [];
  for (let i = 0; i < before.length; i++) {
    const a = before[i], b = after[i];
    assert.equal(a & CROSSING, b & CROSSING, 'Field protection geometry moved between reviews');
    const crossing = Boolean(a & CROSSING);
    const stats = crossing ? result.crossing : result.protectedBand;
    if (!(a & MASKED) && (b & MASKED)) {
      stats.newMaskPixels++;
      if (!crossing) {
        const x = FIELD.x[0] + Math.floor(i / bandRows);
        const y = centerY(x) - FIELD.halfWidth + i % bandRows;
        newProtectedMask.push(y * width + x);
      }
    }
    if ((a & MASKED) && !(b & MASKED)) stats.removedMaskPixels++;
    if (!(a & CHANGED) && (b & CHANGED)) stats.newChangedPixels++;
    if ((a & CHANGED) && !(b & CHANGED)) stats.removedChangedPixels++;
  }
  result.protectedBand.newMaskComponents = changedComponents(newProtectedMask, width);
  return result;
}

function compareTraceFlags(before, after) {
  assert.equal(before.length, after.length);
  let newlyCovered = 0, noLongerCovered = 0;
  for (let i = 0; i < before.length; i++) {
    const a = Boolean(before[i] & MASKED), b = Boolean(after[i] & MASKED);
    if (!a && b) newlyCovered++;
    if (a && !b) noLongerCovered++;
  }
  return { newlyCovered, noLongerCovered };
}

function compareFieldRgb(flags, before, after) {
  assert.equal(before.length, flags.length * 3);
  assert.equal(after.length, before.length);
  const counters = () => ({ pixels: 0, differingPixels: 0, maxDelta16: 0 });
  const result = { protectedBand: counters(), crossing: counters() };
  for (let i = 0; i < flags.length; i++) {
    const stats = flags[i] & CROSSING ? result.crossing : result.protectedBand;
    let largest = 0;
    for (let c = 0; c < 3; c++) largest = Math.max(largest, Math.abs(before[i * 3 + c] - after[i * 3 + c]));
    stats.pixels++;
    if (largest) stats.differingPixels++;
    stats.maxDelta16 = Math.max(stats.maxDelta16, largest);
  }
  return result;
}

async function digest(filename) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(filename)) hash.update(chunk);
  return hash.digest('hex');
}

async function loadTiff(filename, hashSource = false) {
  const start = performance.now();
  const bytes = await fs.readFile(filename);
  const readMs = performance.now() - start;
  const decodeStart = performance.now();
  const image = decodeTiff(bytes);
  const decodeMs = performance.now() - decodeStart;
  return { image, readMs: rounded(readMs), decodeMs: rounded(decodeMs),
    sha256: hashSource ? createHash('sha256').update(bytes).digest('hex') : undefined };
}

async function loadReview(filename) {
  const raw = (await fs.readFile(filename, 'utf8')).trim();
  let event;
  try { event = JSON.parse(raw); }
  catch {
    event = raw.split('\n').reverse().map(line => {
      try { return JSON.parse(line); } catch { return null; }
    }).find(record => record?.review);
  }
  const review = event?.review || event;
  assert.ok(review?.sourcePath && review.cleanedPath && review.maskPath, 'Review event must include the source, cleaned and mask TIFF paths');
  return { review, reviewPath: event.reviewPath || filename };
}

function comparePixels(source, cleaned, mask) {
  const changed = new Uint8Array(source.width * source.height);
  let maskPixels = 0, changedPixels = 0, changedOutsideMask = 0, changedAlpha = 0;
  for (let p = 0, i = 0; p < changed.length; p++, i += source.channels) {
    const masked = Boolean(mask.data[p]);
    if (masked) maskPixels++;
    if (source.alpha && source.data[i + source.colorChannels] !== cleaned.data[i + source.colorChannels]) changedAlpha++;
    for (let c = 0; c < source.colorChannels; c++) {
      if (source.data[i + c] === cleaned.data[i + c]) continue;
      changed[p] = 1;
      changedPixels++;
      if (!masked) changedOutsideMask++;
      break;
    }
  }
  return { changed, maskPixels, changedPixels, changedOutsideMask, changedAlpha };
}

const bytes = data => Buffer.from(data.buffer, data.byteOffset, data.byteLength);

function compareReviewOutputs(before, after, pixels) {
  const { width, height, channels, colorChannels, alpha } = before.cleaned;
  const a = before.cleaned.data, b = after.cleaned.data;
  const aMask = before.mask.data, bMask = after.mask.data;
  assert.equal(a.length, b.length);
  assert.equal(aMask.length, bMask.length);
  const out = {
    comparedPixels: pixels?.size ?? width * height,
    rgbDifferentPixels: 0, rgbDifferentSamples: 0, alphaDifferentPixels: 0, maxRgbDelta16: 0,
    maskDifferentPixels: 0, addedMaskPixels: 0, removedMaskPixels: 0, rgbOutsideBothMasks: 0,
    firstRgbDifference: null, firstMaskDifference: null,
  };
  if (!pixels && bytes(a).equals(bytes(b)) && bytes(aMask).equals(bytes(bMask))) {
    return { ...out, exact: true };
  }
  const point = p => [p % width, Math.floor(p / width)];
  const visit = p => {
    const start = p * channels;
    if (aMask[p] !== bMask[p]) {
      out.maskDifferentPixels++;
      if (!aMask[p]) out.addedMaskPixels++;
      if (!bMask[p]) out.removedMaskPixels++;
      out.firstMaskDifference ??= { point: point(p), before: aMask[p], after: bMask[p] };
    }
    if (alpha && a[start + colorChannels] !== b[start + colorChannels]) out.alphaDifferentPixels++;
    let delta = 0;
    for (let c = 0; c < colorChannels; c++) {
      const difference = Math.abs(a[start + c] - b[start + c]);
      if (difference) out.rgbDifferentSamples++;
      delta = Math.max(delta, difference);
    }
    if (!delta) return;
    out.rgbDifferentPixels++;
    out.maxRgbDelta16 = Math.max(out.maxRgbDelta16, delta);
    if (!aMask[p] && !bMask[p]) out.rgbOutsideBothMasks++;
    out.firstRgbDifference ??= { point: point(p), before: Array.from(a.subarray(start, start + colorChannels)),
      after: Array.from(b.subarray(start, start + colorChannels)) };
  };
  if (pixels) for (const p of pixels) visit(p);
  else for (let p = 0; p < width * height; p++) visit(p);
  return { ...out, exact: out.rgbDifferentPixels === 0 && out.maskDifferentPixels === 0 && out.alphaDifferentPixels === 0 };
}

function tubePixels(points, width, height) {
  const pixels = new Set();
  for (const [x, y] of points) {
    for (let dy = -TRACE_RADIUS; dy <= TRACE_RADIUS; dy++) for (let dx = -TRACE_RADIUS; dx <= TRACE_RADIUS; dx++) {
      if (dx * dx + dy * dy <= TRACE_RADIUS * TRACE_RADIUS &&
        x + dx >= 0 && x + dx < width && y + dy >= 0 && y + dy < height) {
        pixels.add((y + dy) * width + x + dx);
      }
    }
  }
  return pixels;
}

async function measureReview(filename, source, sourceHash, spec, tracePoints) {
  const { review, reviewPath } = await loadReview(filename);
  assert.equal(await digest(review.sourcePath), sourceHash, 'Review is from a different input TIFF');
  const { image: cleaned, readMs: cleanedReadMs, decodeMs: cleanedDecodeMs } = await loadTiff(review.cleanedPath);
  const { image: mask, readMs: maskReadMs, decodeMs: maskDecodeMs } = await loadTiff(review.maskPath);
  for (const key of ['width', 'height', 'depth', 'channels', 'alpha']) assert.equal(cleaned[key], source[key], key);
  assert.equal(mask.width, source.width);
  assert.equal(mask.height, source.height);
  assert.equal(mask.channels, 1);
  assert.equal(mask.depth, 8);
  const { changed, ...pixels } = comparePixels(source, cleaned, mask);
  const traces = {}, traceFlags = {};
  for (const [key, points] of Object.entries(tracePoints)) {
    const { hits, result } = coverage(mask, changed, points);
    traces[key] = result;
    traceFlags[key] = hits;
  }
  const { flags: fieldFlags, values: fieldRgb, result: fieldLine } = fieldProtection(source, cleaned, mask, changed, spec.curvedFiber.approximateTrace);
  return { cleaned, mask, fieldFlags, fieldRgb, traceFlags, result: { reviewPath, stats: review.stats, iccExact: Buffer.compare(source.icc ?? Buffer.alloc(0), cleaned.icc ?? Buffer.alloc(0)) === 0,
    ...pixels, traces, fieldLine, timings: { upstreamDetectionAndRepairSeconds: review.stats?.seconds, scanInMemorySeconds: review.stats?.total_seconds,
      qaTiffReadMs: { cleaned: cleanedReadMs, mask: maskReadMs }, qaTiffDecodeMs: { cleaned: cleanedDecodeMs, mask: maskDecodeMs } } } };
}

async function main() {
  const { values } = parseArgs({ options: {
    coordinates: { type: 'string' }, baseline: { type: 'string' }, candidate: { type: 'string' }, output: { type: 'string' },
    'expect-identical': { type: 'boolean' },
  } });
  assert.ok(values.coordinates && values.baseline,
    'Use --coordinates FILE --baseline REVIEW [--candidate REVIEW] [--output FILE] [--expect-identical]');
  assert.ok(!values['expect-identical'] || values.candidate, '--expect-identical requires a candidate review');
  const started = performance.now();
  const spec = JSON.parse(await fs.readFile(values.coordinates, 'utf8'));
  const { image: source, sha256, readMs, decodeMs } = await loadTiff(spec.source, true);
  assert.deepEqual([source.width, source.height], spec.dimensions);
  assert.equal(source.colorChannels, 3);
  assert.equal(source.depth, 16);
  const traces = measurementTraces(spec);
  const tracePoints = Object.fromEntries(Object.entries(traces).map(([key, points]) => [key, traceSamples(points)]));
  const baseline = await measureReview(values.baseline, source, sha256, spec, tracePoints);
  const report = { source: spec.source, sourceSha256: sha256, dimensions: spec.dimensions, screenshotToImageOffset: spec.screenshotToImageOffset,
    traceRadiusPx: TRACE_RADIUS, traceGeometry: traces, fieldLineGeometry: FIELD, qaSourceTiffReadMs: readMs, qaSourceTiffDecodeMs: decodeMs,
    baseline: baseline.result };
  if (values.candidate) {
    const candidate = await measureReview(values.candidate, source, sha256, spec, tracePoints);
    report.candidate = candidate.result;
    const frame = compareReviewOutputs(baseline, candidate);
    report.delta = {
      frame: { ...frame, iccExact: baseline.result.iccExact && candidate.result.iccExact },
      traces: Object.fromEntries(Object.entries(tracePoints).map(([key, points]) => [key, {
        percentagePoints: rounded(report.candidate.traces[key].maskPercent - report.baseline.traces[key].maskPercent, 1),
        ...compareTraceFlags(baseline.traceFlags[key], candidate.traceFlags[key]),
        outputTube: compareReviewOutputs(baseline, candidate, tubePixels(points, source.width, source.height)),
      }])),
      fieldLine: compareFieldFlags(baseline.fieldFlags, candidate.fieldFlags, source.width),
      fieldLineRgb: compareFieldRgb(baseline.fieldFlags, baseline.fieldRgb, candidate.fieldRgb),
    };
  }
  report.qaElapsedMs = rounded(performance.now() - started);
  const output = JSON.stringify(report, null, 2) + '\n';
  if (values.output) await fs.writeFile(path.resolve(values.output), output, { flag: 'wx' });
  else process.stdout.write(output);
  if (values['expect-identical'] && (!report.delta.frame.exact || !report.delta.frame.iccExact || report.candidate.changedOutsideMask)) {
    console.error('Candidate differs from baseline. See full-frame and local output metrics.');
    process.exitCode = 1;
  }
}

if (require.main === module) main().catch(error => { console.error(error.stack); process.exitCode = 1; });

module.exports = { traceSamples, coverage, fieldProtection, compareFieldFlags, compareTraceFlags, compareFieldRgb, compareReviewOutputs };
