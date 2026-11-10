'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const { decodeTiff, decodeTiffForWork, encodeTiff } = require('../src/tiff.cjs');

function samples(n, depth) {
  let seed = 77;
  return Uint16Array.from({ length: n }, () => {
    seed = (Math.imul(1664525, seed) + 1013904223) >>> 0;
    return depth === 8 ? (seed >>> 24) * 257 : seed >>> 16;
  });
}
function image(channels = 3, depth = 16, width = 17, height = 11) {
  return { width, height, channels, depth, data: samples(width * height * channels, depth) };
}
function entry(buf, tag) {
  const ifd = buf.readUInt32LE(4), count = buf.readUInt16LE(ifd);
  for (let i = 0; i < count; i++) {
    const at = ifd + 2 + 12 * i;
    if (buf.readUInt16LE(at) === tag) return at;
  }
  throw new Error(`test fixture lacks tag ${tag}`);
}
function setScalar(buf, tag, value) {
  const at = entry(buf, tag), type = buf.readUInt16LE(at + 2);
  assert.equal(buf.readUInt32LE(at + 4), 1);
  if (type === 3) buf.writeUInt16LE(value, at + 8); else buf.writeUInt32LE(value, at + 8);
  return buf;
}
function replaceStrip(buf, compression, strip) {
  const offset = buf.readUInt32LE(entry(buf, 273) + 8);
  const out = Buffer.concat([buf.subarray(0, offset), strip]);
  setScalar(out, 259, compression); setScalar(out, 279, strip.length);
  return out;
}

function appendDirectory(buf, width, height, subfileType) {
  let ifd = buf.readUInt32LE(4), nextAt;
  do {
    nextAt = ifd + 2 + 12 * buf.readUInt16LE(ifd);
    ifd = buf.readUInt32LE(nextAt);
  } while (ifd);
  const directory = buf.length + (buf.length % 2);
  const pixels = width * height;
  const fields = [[256, 3, width], [257, 3, height], [258, 3, 8], [262, 3, 1],
    [273, 4, 0], [277, 3, 1], [278, 4, height], [279, 4, pixels]];
  if (subfileType !== undefined) fields.unshift([254, 4, subfileType]);
  const strip = directory + 2 + fields.length * 12 + 4;
  const out = Buffer.alloc(strip + pixels);
  buf.copy(out);
  out.writeUInt32LE(directory, nextAt);
  out.writeUInt16LE(fields.length, directory);
  fields.forEach(([tag, type, value], i) => {
    const at = directory + 2 + 12 * i;
    out.writeUInt16LE(tag, at); out.writeUInt16LE(type, at + 2); out.writeUInt32LE(1, at + 4);
    if (type === 3) out.writeUInt16LE(value, at + 8);
    else out.writeUInt32LE(tag === 273 ? strip : value, at + 8);
  });
  out.fill(175, strip);
  return out;
}

for (const depth of [8, 16]) for (const channels of [1, 2, 3, 4]) for (const compression of ['none', 'deflate']) {
  test(`${depth}-bit ${channels}-channel ${compression} round trip keeps samples and ICC`, () => {
    const source = image(channels, depth), before = source.data.slice();
    source.icc = Buffer.from([0, 0, 0, 12, 0xff, 2, 7, 0, 0x80, 5, 9, 0]);
    source.resolution = { x: 2400, y: 2399.5, unit: 2 };
    const decoded = decodeTiff(encodeTiff(source, { compression, rowsPerStrip: 3 }));
    assert.equal(decoded.width, source.width); assert.equal(decoded.height, source.height);
    assert.equal(decoded.depth, depth); assert.equal(decoded.channels, channels);
    assert.equal(decoded.alpha, channels === 2 || channels === 4);
    assert.deepEqual(decoded.data, source.data); assert.deepEqual(source.data, before);
    assert.deepEqual(decoded.icc, source.icc); assert.deepEqual(decoded.resolution, source.resolution);
  });
}

test('parallel Deflate preserves strip order, predictors, pixels and metadata', async () => {
  for (const depth of [8, 16]) {
    const source = image(4, depth, 47, 31);
    source.icc = Buffer.from([0, 0, 0, 7, 255, 88, 0]);
    source.resolution = { x: 2400, y: 2399.5, unit: 2 };
    const bytes = encodeTiff(source, { compression: 'deflate', rowsPerStrip: 3 });
    assert.deepEqual(await decodeTiffForWork(bytes, { tiffWorkers: 4 }), decodeTiff(bytes));
  }
});

test('parallel Deflate rejects a corrupt strip and honors cancellation', async () => {
  const bytes = encodeTiff(image(3, 16, 113, 81), { compression: 'deflate', rowsPerStrip: 5 });
  const controller = new AbortController();
  const decoding = decodeTiffForWork(bytes, { tiffWorkers: 4, signal: controller.signal });
  controller.abort();
  await assert.rejects(decoding, { name: 'AbortError' });

  const corrupt = Buffer.from(bytes);
  const offsets = corrupt.readUInt32LE(entry(corrupt, 273) + 8);
  corrupt.writeUInt16LE(0, corrupt.readUInt32LE(offsets + 4));
  await assert.rejects(decodeTiffForWork(corrupt, { tiffWorkers: 4 }), /invalid Deflate strip/);
});

for (const depth of [8, 16]) for (const codec of ['lzw', 'packbits', 'deflate']) {
  test(`independent Pillow fixture: ${depth}-bit ${codec}`, () => {
    const fixture = fs.readFileSync(path.join(__dirname, 'fixtures', 'tiff', `pillow-${depth}-${codec}.tiff`));
    const got = decodeTiff(fixture), width = depth === 8 ? 97 : 37, height = depth === 8 ? 83 : 31, channels = depth === 8 ? 3 : 1;
    assert.equal(got.width, width); assert.equal(got.height, height); assert.equal(got.channels, channels);
    assert.equal(got.depth, depth); assert.deepEqual(got.data, samples(width * height * channels, depth));
  });
}

test('independent big-endian 16-bit uncompressed fixture', () => {
  const fixture = fs.readFileSync(path.join(__dirname, 'fixtures', 'tiff', 'pillow-16-be-raw.tiff'));
  assert.equal(fixture.toString('ascii', 0, 2), 'MM');
  assert.deepEqual(decodeTiff(fixture).data, samples(37 * 31, 16));
});

test('WhiteIsZero is normalized, without inverting straight alpha', () => {
  const src = image(2, 16, 2, 1), encoded = setScalar(encodeTiff(src), 262, 0), got = decodeTiff(encoded);
  assert.deepEqual(got.data, Uint16Array.from([65535 - src.data[0], src.data[1], 65535 - src.data[2], src.data[3]]));
});

test('8-bit writer rounds full-range samples without changing its source', () => {
  const src = { width: 3, height: 1, channels: 1, depth: 8, data: new Uint16Array([0, 32768, 65535]) };
  assert.deepEqual(decodeTiff(encodeTiff(src)).data, new Uint16Array([0, 32896, 65535]));
  assert.deepEqual(src.data, new Uint16Array([0, 32768, 65535]));
});

test('LZW handles the code == next dictionary case', () => {
  const codes = [256, 65, 258, 257], encoded = Buffer.alloc(Math.ceil(codes.length * 9 / 8));
  let bit = 0;
  for (const code of codes) for (let k = 8; k >= 0; k--, bit++) encoded[bit >> 3] |= ((code >> k) & 1) << (7 - (bit & 7));
  const base = encodeTiff(image(1, 8, 3, 1));
  assert.deepEqual(decodeTiff(replaceStrip(base, 5, encoded)).data, new Uint16Array([65 * 257, 65 * 257, 65 * 257]));
});

test('PackBits accepts a no-op and a repeated-byte run', () => {
  const base = encodeTiff(image(1, 8, 4, 1));
  assert.deepEqual(decodeTiff(replaceStrip(base, 32773, Buffer.from([128, 253, 17]))).data, new Uint16Array(4).fill(17 * 257));
});

test('legacy raw Deflate strips are bounded and supported', () => {
  const src = image(1, 8, 7, 1), base = encodeTiff(src), raw = Buffer.from(Uint8Array.from(src.data, v => v / 257));
  const packed = zlib.deflateRawSync(raw);
  assert.deepEqual(decodeTiff(replaceStrip(base, 32946, packed)).data, src.data);
});

test('rejects a decompression bomb before allocating oversized output', () => {
  const base = encodeTiff(image(1, 8, 1, 1)), packed = zlib.deflateSync(Buffer.alloc(1024 * 1024));
  assert.throws(() => decodeTiff(replaceStrip(base, 8, packed)), /Deflate strip/);
});

test('rejects truncation, invalid offsets and a wrong uncompressed strip length', () => {
  const good = encodeTiff(image());
  assert.throws(() => decodeTiff(good.subarray(0, 7)), /truncated/);
  assert.throws(() => decodeTiff(good.subarray(0, good.length - 1)), /outside the file/);
  const offset = Buffer.from(good); setScalar(offset, 273, 0xffffffff);
  assert.throws(() => decodeTiff(offset), /outside the file/);
  const count = Buffer.from(good); setScalar(count, 279, 2);
  assert.throws(() => decodeTiff(count), /strip length/);
});

test('rejects unsupported TIFF interpretations before processing pixels', () => {
  for (const [tag, value, error] of [[274, 6, /orientation/], [284, 2, /planar/], [262, 5, /photometric/], [259, 7, /compression/], [278, 0, /rows per strip/]]) {
    const buf = setScalar(encodeTiff(image()), tag, value);
    assert.throws(() => decodeTiff(buf), error);
  }
  const gray = encodeTiff(image(1)); setScalar(gray, 258, 32);
  assert.throws(() => decodeTiff(gray), /8-bit or 16-bit/);
  const signed = encodeTiff(image(1)); setScalar(signed, 339, 2);
  assert.throws(() => decodeTiff(signed), /signed/);
  const associated = encodeTiff(image(4)); setScalar(associated, 338, 1);
  assert.throws(() => decodeTiff(associated), /straight.*alpha/);
});

test('skips explicitly tagged reduced previews and keeps the primary pixels and ICC', () => {
  const original = image(3, 16);
  original.icc = Buffer.from([0, 0, 0, 12, 0xff, 2, 7, 0, 0x80, 5, 9, 0]);
  const primary = encodeTiff(original, { compression: 'deflate' });
  const preview = appendDirectory(primary, 6, 4, 1);
  const pyramid = appendDirectory(preview, 3, 2, 1);
  assert.deepEqual(decodeTiff(pyramid), decodeTiff(primary));
  assert.throws(() => decodeTiff(appendDirectory(preview, 6, 4)), /multi-page/, 'an unmarked second photo may also be small');
  assert.throws(() => decodeTiff(appendDirectory(primary, original.width, original.height, 1)), /multi-page/);
  assert.throws(() => decodeTiff(appendDirectory(primary, 6, 4, 3)), /multi-page/, 'page bit is still unsupported');
  assert.throws(() => decodeTiff(appendDirectory(primary, 6, 4, 4)), /multi-page/, 'a transparency mask can affect compositing');
});

test('rejects multi-page, duplicate-tag and oversized images', () => {
  const good = encodeTiff(image(1));
  const multi = Buffer.from(good), ifd = multi.readUInt32LE(4), count = multi.readUInt16LE(ifd);
  multi.writeUInt32LE(ifd, ifd + 2 + count * 12);
  assert.throws(() => decodeTiff(multi), /multi-page/);
  const duplicate = Buffer.from(good); duplicate.writeUInt16LE(256, entry(duplicate, 257));
  assert.throws(() => decodeTiff(duplicate), /duplicate/);
  const huge = Buffer.from(good); setScalar(huge, 256, 0xffffffff);
  assert.throws(() => decodeTiff(huge), /pixel\/sample limit/);
  assert.throws(() => decodeTiff(good, { maxPixels: 1 }), /pixel\/sample limit/);
});

test('writer rejects missing samples, unsupported depth and inconsistent channels', () => {
  assert.throws(() => encodeTiff({ ...image(), data: new Uint16Array(1) }), /exactly sized/);
  assert.throws(() => encodeTiff({ ...image(), depth: 32 }), /8-bit or 16-bit/);
  assert.throws(() => encodeTiff({ ...image(4), alpha: false }), /alpha flag/);
  assert.throws(() => encodeTiff({ ...image(1), colorChannels: 3 }), /channel count/);
  assert.throws(() => encodeTiff(image(), { compression: 'jpeg' }), /compression/);
  assert.throws(() => encodeTiff({ ...image(), resolution: { x: Infinity, y: 72 } }), /resolution/);
});
