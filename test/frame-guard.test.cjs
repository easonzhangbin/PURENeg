'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { buildFrameProtection } = require('../src/frame-guard.cjs');

test('protects bright print in a dark film rebate and leaves the picture available for repair', () => {
  const width = 640, height = 400, depth = 27;
  const scan = new Uint16Array(width * height);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      if (y >= depth && y < height - depth) {
        scan[y * width + x] = 21000 + x * 7 + y * 9;
      } else if (y >= 3 && y < 15 && x % 130 < 25) {
        scan[y * width + x] = 46000;
      }
    }
  }
  const frame = buildFrameProtection(scan, width, height, 1);
  assert.ok(frame?.protects(6 * width + 5), 'printed character');
  assert.ok(frame.protects((height - 5) * width + 320), 'bottom film rebate');
  assert.ok(!frame.protects((depth + 3) * width + 5), 'picture by the rebate');

  // The same geometry above the clipped black level is a dark scene band,
  // with no evidence that pixels outside the subject are scanner margins.
  for (let i = 0; i < scan.length; i++) if (!scan[i]) scan[i] = 3600;
  assert.equal(buildFrameProtection(scan, width, height, 1), null);
});
