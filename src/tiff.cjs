'use strict';

// A deliberately narrow, lossless TIFF boundary for film scans. Pixel samples are
// always returned as full-range Uint16 (8-bit samples are multiplied by 257).
// No colour transform, tone mapping, or implicit HDR conversion happens here.
const zlib = require('node:zlib');
const { promisify } = require('node:util');
const inflate = promisify(zlib.inflate), inflateRaw = promisify(zlib.inflateRaw);

const LIMITS = Object.freeze({ maxPixels: 300_000_000, maxSamples: 500_000_000, maxMetadataBytes: 16 * 1024 * 1024 });
const TYPE_SIZE = { 1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4 };
const LITTLE_HOST = new Uint8Array(new Uint16Array([0x0102]).buffer)[0] === 2;

function fail(message) { throw new Error(`TIFF: ${message}`); }
function positive(value, name, max = 0xffffffff) {
  if (!Number.isSafeInteger(value) || value < 1 || value > max) fail(`invalid ${name}`);
  return value;
}
function checkedSize(width, height, channels, limits) {
  positive(width, 'width'); positive(height, 'height'); positive(channels, 'channels', 4);
  const pixels = width * height, samples = pixels * channels;
  if (!Number.isSafeInteger(pixels) || pixels > limits.maxPixels || !Number.isSafeInteger(samples) || samples > limits.maxSamples) {
    fail('image exceeds the configured pixel/sample limit');
  }
  return samples;
}
function bytes(value) {
  if (!Buffer.isBuffer(value) && !(value instanceof Uint8Array)) fail('input must be a Buffer or Uint8Array');
  return Buffer.from(value.buffer, value.byteOffset, value.byteLength);
}

function unpackBits(input, expected) {
  const out = Buffer.allocUnsafe(expected);
  let src = 0, dst = 0;
  while (src < input.length) {
    const n = input.readInt8(src++);
    if (n === -128) continue;
    if (n >= 0) {
      const count = n + 1;
      if (src + count > input.length || dst + count > expected) fail('invalid PackBits strip');
      input.copy(out, dst, src, src + count); src += count; dst += count;
    } else {
      const count = 1 - n;
      if (src >= input.length || dst + count > expected) fail('invalid PackBits strip');
      out.fill(input[src++], dst, dst + count); dst += count;
    }
  }
  if (dst !== expected) fail('truncated PackBits strip');
  return out;
}

function unpackLzw(input, expected) {
  // TIFF 6 LZW: MSB-first codes, clear=256, EOI=257, early code-width change.
  // Prefix/suffix tables keep the decompressor bounded to the expected strip size.
  const out = Buffer.allocUnsafe(expected), prefix = new Int16Array(4096), suffix = new Uint8Array(4096), stack = new Uint8Array(4096);
  let byte = 0, pending = 0, bits = 0, width = 9, next = 258, prev = -1, dst = 0, ended = false;
  while (bits + (input.length - byte) * 8 >= width) {
    while (bits < width) {
      pending = (pending << 8) | input[byte++];
      bits += 8;
    }
    bits -= width;
    const current = (pending >>> bits) & ((1 << width) - 1);
    if (current === 256) { width = 9; next = 258; prev = -1; continue; }
    if (current === 257) { ended = true; break; }
    if (current > next || current >= 4096 || (prev < 0 && current >= 256)) fail('invalid LZW code');
    let c = current, top = 0;
    const special = c === next;
    if (special) c = prev;
    while (c >= 256) {
      if (c >= next || top >= stack.length - 1) fail('invalid LZW dictionary');
      stack[top++] = suffix[c]; c = prefix[c];
    }
    const first = c;
    stack[top++] = first;
    if (dst + top + (special ? 1 : 0) > expected) fail('LZW strip expands beyond its declared dimensions');
    while (top) out[dst++] = stack[--top];
    if (special) out[dst++] = first;
    if (prev >= 0 && next < 4096) {
      prefix[next] = prev; suffix[next] = first; next++;
      if (width < 12 && next === (1 << width) - 1) width++;
    }
    prev = current;
  }
  if (!ended || dst !== expected) fail('truncated or wrong-sized LZW strip');
  return out;
}

function decompress(input, compression, expected) {
  if (compression === 1) {
    if (input.length !== expected) fail('uncompressed strip length does not match its dimensions');
    return input;
  }
  if (compression === 32773) return unpackBits(input, expected);
  if (compression === 5) return unpackLzw(input, expected);
  if (compression === 8 || compression === 32946) {
    let out;
    try { out = zlib.inflateSync(input, { maxOutputLength: expected }); }
    catch (e) {
      if (compression !== 32946) fail(`invalid Deflate strip (${e.code || 'decompression failed'})`);
      try { out = zlib.inflateRawSync(input, { maxOutputLength: expected }); }
      catch { fail('invalid legacy Deflate strip'); }
    }
    if (out.length !== expected) fail('Deflate strip length does not match its dimensions');
    return out;
  }
  fail(`unsupported compression ${compression}; export an uncompressed or Deflate TIFF`);
}

function readTiff(input, options = {}) {
  const buf = bytes(input), limits = { ...LIMITS, ...options };
  if (buf.length < 8) fail('header is truncated');
  const sig = buf.toString('ascii', 0, 2), le = sig === 'II';
  if (!le && sig !== 'MM') fail('invalid byte-order marker');
  const range = (at, len) => {
    if (!Number.isSafeInteger(at) || !Number.isSafeInteger(len) || at < 0 || len < 0 || at + len > buf.length) fail('offset or byte count is outside the file');
  };
  const u16 = at => { range(at, 2); return le ? buf.readUInt16LE(at) : buf.readUInt16BE(at); };
  const u32 = at => { range(at, 4); return le ? buf.readUInt32LE(at) : buf.readUInt32BE(at); };
  const magic = u16(2);
  if (magic === 43) fail('BigTIFF is not supported; export a classic TIFF smaller than 4 GiB');
  if (magic !== 42) fail('invalid TIFF signature');
  const readDirectory = ifd => {
    if (ifd < 8) fail('missing image directory');
    const count = u16(ifd);
    if (count > 4096) fail('too many directory entries');
    range(ifd + 2, count * 12 + 4);
    const entries = new Map();
    for (let i = 0; i < count; i++) {
      const at = ifd + 2 + i * 12, tag = u16(at), type = u16(at + 2), n = u32(at + 4), size = TYPE_SIZE[type];
      if (entries.has(tag)) fail(`duplicate TIFF tag ${tag}`);
      if (!size) continue; // Unknown private tags do not affect the pixel boundary.
      const len = n * size;
      if (!Number.isSafeInteger(len)) fail('tag size overflows');
      const offset = len <= 4 ? at + 8 : u32(at + 8);
      range(offset, len);
      entries.set(tag, { type, n, offset, len });
    }
    return { entries, next: u32(ifd + 2 + count * 12) };
  };
  const ifd = u32(4), { entries: tags, next } = readDirectory(ifd);
  const ints = (tag, fallback, entries = tags) => {
    const t = entries.get(tag);
    if (!t) return fallback;
    if (![1, 3, 4, 13].includes(t.type) || t.n > 1_000_000) fail(`invalid integer tag ${tag}`);
    const out = [];
    for (let k = 0; k < t.n; k++) out.push(t.type === 1 ? buf[t.offset + k] : t.type === 3 ? u16(t.offset + 2 * k) : u32(t.offset + 4 * k));
    return out;
  };
  const one = (tag, fallback, entries = tags) => {
    if ((entries.get(tag)?.n ?? 1) !== 1) fail(`missing or invalid tag ${tag}`);
    const v = ints(tag, fallback === undefined ? undefined : [fallback], entries);
    if (!v || v.length !== 1) fail(`missing or invalid tag ${tag}`);
    return v[0];
  };
  if (one(274, 1) !== 1) fail('TIFF orientation must be top-left (1); normalize orientation before processing');
  if (one(284, 1) !== 1) fail('planar TIFF is not supported; export interleaved pixels');
  if (tags.has(322) || tags.has(323) || tags.has(324) || tags.has(325)) fail('tiled TIFF is not supported; export strip-based TIFF');
  if (tags.has(330) || tags.has(50706)) fail('TIFF with sub-images or RAW/DNG metadata is not supported');
  if (one(254, 0) !== 0) fail('reduced-resolution or mask TIFF directory is not supported');
  const width = one(256), height = one(257), channels = one(277, 1), samples = checkedSize(width, height, channels, limits);
  if (next) {
    const seen = new Set([ifd]);
    for (let offset = next; offset;) {
      const multiPage = 'multi-page TIFF is not supported; export one flattened frame';
      if (seen.has(offset) || seen.size >= 64) fail(multiPage);
      seen.add(offset);
      const preview = readDirectory(offset), entries = preview.entries;
      // Some editors link a thumbnail after the full-size scan. Only skip a
      // directory explicitly marked as a reduced-resolution image.
      if (entries.get(254)?.type !== 4 || one(254, 0, entries) !== 1 || entries.has(330) || entries.has(50706)) fail(multiPage);
      const w = one(256, 0, entries), h = one(257, 0, entries);
      if (!w || !h || w > width || h > height || (w === width && h === height)) fail(multiPage);
      offset = preview.next;
    }
  }
  const photo = one(262), colorChannels = photo === 2 ? 3 : (photo === 0 || photo === 1) ? 1 : 0;
  if (!colorChannels) fail(`unsupported photometric mode ${photo}; use RGB or grayscale`);
  const alpha = channels === colorChannels + 1;
  if (channels !== colorChannels && !alpha) fail('only RGB/grayscale with optional one alpha channel is supported');
  const extras = ints(338, []);
  if (alpha && (extras.length !== 1 || extras[0] !== 2)) fail('only explicitly unassociated (straight) alpha is supported');
  if (!alpha && extras.length) fail('unexpected extra sample channels');
  const bits = ints(258, [1]), depth = bits[0];
  if (![8, 16].includes(depth) || ![1, channels].includes(bits.length) || bits.some(v => v !== depth)) fail('only uniform unsigned 8-bit or 16-bit samples are supported');
  const formats = ints(339, [1]);
  if (![1, channels].includes(formats.length) || formats.some(v => v !== 1)) fail('floating-point or signed TIFF samples are not supported');
  const compression = one(259, 1), predictor = one(317, 1);
  if (![1, 5, 8, 32946, 32773].includes(compression)) fail(`unsupported compression ${compression}; export an uncompressed or Deflate TIFF`);
  if (![1, 2].includes(predictor)) fail('unsupported predictor; only horizontal integer prediction is supported');
  const rowsPerStrip = Math.min(height, positive(one(278, 0xffffffff), 'rows per strip'));
  const nstrips = Math.ceil(height / rowsPerStrip), offsets = ints(273), counts = ints(279);
  if (!offsets || !counts || offsets.length !== nstrips || counts.length !== nstrips) fail('strip table does not match image dimensions');
  // Check ranges and cheap length constraints before reserving the full output.
  // A tiny malformed file must not force a large allocation just to report EOF.
  for (let s = 0; s < nstrips; s++) {
    if (!counts[s]) fail('empty strip');
    range(offsets[s], counts[s]);
    const rows = Math.min(rowsPerStrip, height - s * rowsPerStrip);
    if (compression === 1 && counts[s] !== rows * width * channels * (depth / 8)) fail('uncompressed strip length does not match its dimensions');
  }
  const iccTag = tags.get(34675);
  let icc = null;
  if (iccTag) {
    if (![1, 7].includes(iccTag.type) || iccTag.len > limits.maxMetadataBytes) fail('invalid or oversized ICC profile');
    icc = Buffer.from(buf.subarray(iccTag.offset, iccTag.offset + iccTag.len));
  }
  const rational = tag => {
    const t = tags.get(tag);
    if (!t || t.type !== 5 || t.n !== 1) return null;
    const d = u32(t.offset + 4);
    return d ? u32(t.offset) / d : null;
  };
  const x = rational(282), y = rational(283), unit = one(296, 2);
  const resolution = x > 0 && y > 0 && [1, 2, 3].includes(unit) ? { x, y, unit } : null;
  const image = { width, height, channels, colorChannels, alpha, depth, icc, resolution, orientation: 1, compression };
  return { image, buf, le, photo, predictor, samples, rowsPerStrip, offsets, counts };
}

function copyStrip(layout, data, firstSample, raw) {
  const { image: { width, channels, depth }, le, predictor } = layout;
  const rowSamples = width * channels, ns = raw.length / (depth / 8);
  const target = data.subarray(firstSample, firstSample + ns);
  if (depth === 16 && le === LITTLE_HOST && raw.byteOffset % 2 === 0) {
    target.set(new Uint16Array(raw.buffer, raw.byteOffset, ns));
    if (predictor === 2) {
      // Each row restarts the horizontal predictor. Uint16 assignment
      // performs the TIFF-specified modulo 65536 addition.
      for (let row = 0; row < ns; row += rowSamples) {
        for (let k = row + channels; k < row + rowSamples; k++) target[k] += target[k - channels];
      }
    }
  } else if (depth === 8 && predictor === 1) {
    for (let k = 0; k < ns; k++) target[k] = raw[k] * 257;
  } else {
    for (let k = 0; k < ns; k++) {
      let v = depth === 8 ? raw[k] : le ? raw.readUInt16LE(2 * k) : raw.readUInt16BE(2 * k);
      if (predictor === 2 && k % rowSamples >= channels) {
        const previous = target[k - channels];
        v = (v + (depth === 8 ? previous / 257 : previous)) & (depth === 8 ? 255 : 65535);
      }
      target[k] = depth === 8 ? v * 257 : v;
    }
  }
}

function decodedTiff({ image, photo }, data) {
  // Convert WhiteIsZero to the same black=0 convention used by the engine. Alpha
  // is independent and must never be inverted with the gray channel.
  if (photo === 0) for (let i = 0; i < data.length; i += image.channels) data[i] = 65535 - data[i];
  return { ...image, data };
}

function decodeStrips(layout) {
  const { buf, offsets, counts, rowsPerStrip, samples, image: { width, height, channels, depth, compression } } = layout;
  const data = new Uint16Array(samples), stripSamples = rowsPerStrip * width * channels;
  for (let s = 0; s < offsets.length; s++) {
    const expected = Math.min(rowsPerStrip, height - s * rowsPerStrip) * width * channels * (depth / 8);
    const raw = decompress(buf.subarray(offsets[s], offsets[s] + counts[s]), compression, expected);
    copyStrip(layout, data, s * stripSamples, raw);
  }
  return decodedTiff(layout, data);
}

function decodeTiff(input, options) {
  return decodeStrips(readTiff(input, options));
}

async function inflateStrip(input, expected, compression) {
  const settings = { maxOutputLength: expected, chunkSize: Math.max(16_384, Math.min(expected, 1_048_576)) };
  let raw;
  try { raw = await inflate(input, settings); }
  catch (error) {
    if (compression !== 32946) fail(`invalid Deflate strip (${error.code || 'decompression failed'})`);
    try { raw = await inflateRaw(input, settings); }
    catch { fail('invalid legacy Deflate strip'); }
  }
  if (raw.length !== expected) fail('Deflate strip length does not match its dimensions');
  return raw;
}

async function decodeTiffForWork(input, { tiffWorkers = 1, signal } = {}) {
  signal?.throwIfAborted();
  const layout = readTiff(input);
  const { image: { width, height, channels, depth, compression }, buf, offsets, counts, rowsPerStrip, samples } = layout;
  const stripSamples = rowsPerStrip * width * channels;
  const workers = Math.min(Math.floor(tiffWorkers), 8, offsets.length, Math.floor(32 * 1024 * 1024 / (stripSamples * (depth / 8))));
  if (!(workers >= 2) || (compression !== 8 && compression !== 32946)) return decodeStrips(layout);
  // Only one small batch of independent strips is inflated at a time. Writes
  // stay in file order and use the same sample and predictor path as sync.
  const data = new Uint16Array(samples);
  for (let from = 0; from < offsets.length; from += workers) {
    signal?.throwIfAborted();
    const tasks = offsets.slice(from, from + workers).map((offset, index) => {
      const s = from + index;
      const expected = Math.min(rowsPerStrip, height - s * rowsPerStrip) * width * channels * (depth / 8);
      return inflateStrip(buf.subarray(offset, offset + counts[s]), expected, compression);
    });
    const results = await Promise.allSettled(tasks);
    signal?.throwIfAborted();
    for (const [i, result] of results.entries()) {
      if (result.status === 'rejected') throw result.reason;
      copyStrip(layout, data, (from + i) * stripSamples, result.value);
    }
  }
  return decodedTiff(layout, data);
}

function encodeTiff(image, options = {}) {
  if (!image || typeof image !== 'object') fail('image is required');
  const { width, height, channels, depth, data } = image, limits = { ...LIMITS, ...options };
  const samples = checkedSize(width, height, channels, limits);
  if (![8, 16].includes(depth)) fail('only 8-bit or 16-bit output is supported');
  if (!(data instanceof Uint16Array) || data.length !== samples) fail('pixel data must be an exactly sized Uint16Array');
  const colorChannels = channels <= 2 ? 1 : 3, alpha = channels === 2 || channels === 4;
  if (image.alpha !== undefined && image.alpha !== alpha) fail('alpha flag does not match the channel count');
  if (image.colorChannels !== undefined && image.colorChannels !== colorChannels) fail('colour channel count is inconsistent');
  const icc = image.icc == null ? null : bytes(image.icc);
  if (icc && icc.length > limits.maxMetadataBytes) fail('ICC profile is too large');
  const compression = options.compression ?? 'none';
  if (!['none', 'deflate', 1, 8].includes(compression)) fail('writer compression must be none or deflate');
  const compress = compression === 'deflate' || compression === 8;
  const predictor = options.predictor ?? (compress ? 2 : 1);
  if (![1, 2].includes(predictor)) fail('unsupported output predictor');
  const rowSamples = width * channels, rowBytes = rowSamples * (depth / 8);
  const rowsPerStrip = Math.min(height, positive(options.rowsPerStrip ?? Math.max(1, Math.floor(1024 * 1024 / rowBytes)), 'rows per strip'));
  const nstrips = Math.ceil(height / rowsPerStrip), strips = [];
  for (let s = 0; s < nstrips; s++) {
    const from = s * rowsPerStrip * rowSamples, ns = Math.min(rowsPerStrip, height - s * rowsPerStrip) * rowSamples;
    let raw;
    if (depth === 16 && LITTLE_HOST) raw = Buffer.from(data.buffer, data.byteOffset + from * 2, ns * 2);
    else {
      raw = Buffer.allocUnsafe(ns * (depth / 8));
      for (let k = 0; k < ns; k++) {
        if (depth === 8) raw[k] = Math.round(data[from + k] / 257);
        else raw.writeUInt16LE(data[from + k], 2 * k);
      }
    }
    if (predictor === 2) {
      raw = Buffer.from(raw);
      for (let r = 0; r < ns; r += rowSamples) for (let k = rowSamples - 1; k >= channels; k--) {
        if (depth === 8) raw[r + k] = (raw[r + k] - raw[r + k - channels]) & 255;
        else raw.writeUInt16LE((raw.readUInt16LE(2 * (r + k)) - raw.readUInt16LE(2 * (r + k - channels))) & 65535, 2 * (r + k));
      }
    }
    strips.push(compress ? zlib.deflateSync(raw) : raw);
  }
  const entries = [];
  const field = (tag, type, values) => {
    let payload;
    if (type === 7 || type === 1 || type === 2) payload = bytes(values);
    else {
      payload = Buffer.alloc(values.length * (type === 5 ? 4 : TYPE_SIZE[type]));
      values.forEach((v, k) => type === 3 ? payload.writeUInt16LE(v, 2 * k) : payload.writeUInt32LE(v, 4 * k));
    }
    entries.push({ tag, type, count: type === 5 ? values.length / 2 : payload.length / TYPE_SIZE[type], payload, offset: 0 });
  };
  field(256, 4, [width]); field(257, 4, [height]); field(258, 3, Array(channels).fill(depth));
  field(259, 3, [compress ? 8 : 1]); field(262, 3, [colorChannels === 3 ? 2 : 1]);
  field(273, 4, Array(nstrips).fill(0)); field(274, 3, [1]); field(277, 3, [channels]); field(278, 4, [rowsPerStrip]);
  field(279, 4, strips.map(s => s.length)); field(284, 3, [1]); field(317, 3, [predictor]);
  field(339, 3, Array(channels).fill(1));
  if (alpha) field(338, 3, [2]);
  if (icc && icc.length) field(34675, 7, icc);
  if (image.resolution) {
    const { x, y, unit = 2 } = image.resolution;
    if (![x, y].every(v => Number.isFinite(v) && v > 0 && v <= 429496) || ![1, 2, 3].includes(unit)) fail('invalid image resolution');
    field(282, 5, [Math.round(x * 10000), 10000]); field(283, 5, [Math.round(y * 10000), 10000]); field(296, 3, [unit]);
  }
  entries.sort((a, b) => a.tag - b.tag);
  let size = 8 + 2 + 12 * entries.length + 4;
  for (const e of entries) if (e.payload.length > 4) { e.offset = size; size += e.payload.length + (e.payload.length & 1); }
  const stripOffsets = entries.find(e => e.tag === 273);
  for (let s = 0; s < strips.length; s++) { stripOffsets.payload.writeUInt32LE(size, s * 4); size += strips[s].length + (strips[s].length & 1); }
  if (!Number.isSafeInteger(size) || size > 0xffffffff) fail('output exceeds classic TIFF size');
  const result = Buffer.allocUnsafe(size);
  result.write('II', 0, 2, 'ascii'); result.writeUInt16LE(42, 2); result.writeUInt32LE(8, 4); result.writeUInt16LE(entries.length, 8);
  let cursor = 10;
  for (const e of entries) {
    result.writeUInt16LE(e.tag, cursor); result.writeUInt16LE(e.type, cursor + 2); result.writeUInt32LE(e.count, cursor + 4);
    result.fill(0, cursor + 8, cursor + 12);
    if (e.payload.length <= 4) e.payload.copy(result, cursor + 8);
    else {
      result.writeUInt32LE(e.offset, cursor + 8); e.payload.copy(result, e.offset);
      if (e.payload.length & 1) result[e.offset + e.payload.length] = 0;
    }
    cursor += 12;
  }
  result.writeUInt32LE(0, cursor);
  for (let s = 0; s < strips.length; s++) {
    const at = stripOffsets.payload.readUInt32LE(s * 4);
    strips[s].copy(result, at);
    if (strips[s].length & 1) result[at + strips[s].length] = 0;
  }
  return result;
}

module.exports = { decodeTiff, decodeTiffForWork, encodeTiff, LIMITS };
