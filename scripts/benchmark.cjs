#!/usr/bin/env node
'use strict';
// Deterministic synthetic 24MP scan. This measures runtime, not photographic
// accuracy: it is not a substitute for testing the user's own film scans.
const { processScan } = require('../src/processor.cjs');
const width = 6000, height = 4000, data = new Uint16Array(width * height * 3);
let seed = 7;
for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
  seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
  const value = 18000 + Math.round(x * 8000 / width) + Math.round((seed / 4294967296 - 0.5) * 1300);
  const i = (y * width + x) * 3;
  data[i] = value; data[i + 1] = value + 1000; data[i + 2] = value - 500;
}
for (let y = 120; y < height - 100; y += 270) for (let x = 140; x < width - 100; x += 350) {
  for (let dy = -3; dy <= 3; dy++) for (let dx = -3; dx <= 3; dx++) {
    if (dx * dx + dy * dy > 8) continue;
    const i = ((y + dy) * width + x + dx) * 3;
    data[i] = 62000; data[i + 1] = 63000; data[i + 2] = 61000;
  }
}
const started = performance.now();
let last = 0;
processScan({ width, height, depth: 16, channels: 3, colorChannels: 3, data }, {
  polarity: 'bright',
  onProgress: (p) => { if (performance.now() - last > 10000) { console.log(JSON.stringify({ type: 'progress', ...p })); last = performance.now(); } },
}).then(result => {
  console.log(JSON.stringify({ type: 'benchmark', width, height, seconds: (performance.now() - started) / 1000,
    maxRssMiB: process.resourceUsage().maxRSS / 1024, stats: result.stats }));
}).catch(error => { console.error(error.message); process.exitCode = 1; });
