#!/usr/bin/env node
'use strict';
// Original synthetic scan: no photographs or third-party artwork are used.
const fs = require('node:fs');
const path = require('node:path');
const { encodeTiff } = require('../src/tiff.cjs');
const width = 900, height = 700, data = new Uint16Array(width * height * 3);
let seed = 7;
const random = () => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed / 4294967296; };
const specks = [];
for (let y = 70; y < 650; y += 110) for (let x = 90; x < 850; x += 145) specks.push([x, y]);
for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
  const hill = y > 420 + Math.sin(x / 140) * 50;
  let v = (hill ? 0.22 : 0.48) + 0.08 * x / width + (random() - 0.5) * 0.025;
  if (specks.some(([sx, sy]) => (x - sx) ** 2 + (y - sy) ** 2 < 2.5 ** 2)) v = 0.96;
  if (x > 300 && x < 480 && Math.abs(y - 250 - (x - 300) * 0.4) < 1.4) v = 0.94;
  for (let c = 0; c < 3; c++) data[(y * width + x) * 3 + c] = Math.round(v * [0.96,1,0.91][c] * 65535);
}
const filename = path.resolve(process.argv[2] || path.join(__dirname, '../.work/synthetic-scan.tiff'));
fs.mkdirSync(path.dirname(filename), { recursive: true });
fs.writeFileSync(filename, encodeTiff({ width, height, channels: 3, colorChannels: 3, depth: 16, data, icc: null }));
console.log(filename);
