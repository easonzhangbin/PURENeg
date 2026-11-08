'use strict';

const { setImmediate: yieldNow } = require('node:timers/promises');
const { heal } = require('../vendor/film-dust/engine/heal');
const { cancelled } = require('./processor.cjs');

const TILE = 256;
const HALO = 224;
const ADD = 1, ERASE = 2;
const MAX_STROKES = 1024, MAX_POINTS = 200_000;

function checkedStrokes(strokes, { width, height }) {
  // [Claude 2026-11-08] 128 strokes / 16 000 points ran out on one dusty frame. A 6 px
  // stroke is about 13 rows per point, so 200 000 points stays far inside the span limit.
  if (!Array.isArray(strokes) || strokes.length > MAX_STROKES) throw new Error(`笔画列表无效或超过 ${MAX_STROKES} 笔。`);
  let points = 0;
  for (const stroke of strokes) {
    if (!stroke || typeof stroke !== 'object' || Array.isArray(stroke) ||
        Object.keys(stroke).some(key => !['kind', 'radius', 'points'].includes(key)) ||
        !['add', 'erase'].includes(stroke.kind) || !Number.isInteger(stroke.radius) ||
        stroke.radius < 1 || stroke.radius > 96 || !Array.isArray(stroke.points) ||
        stroke.points.length < 1 || stroke.points.length > 2048) throw new Error('笔画类型、半径或点数无效。');
    points += stroke.points.length;
    if (points > MAX_POINTS) throw new Error('笔画采样点过多。');
    for (const point of stroke.points) {
      if (!Array.isArray(point) || point.length !== 2 || !point.every(Number.isInteger) ||
          point[0] < 0 || point[0] >= width || point[1] < 0 || point[1] >= height) throw new Error('笔画坐标超出原图。');
    }
  }
  return strokes;
}

// Store only tiles touched by the brush. Later stamps replace earlier edits,
// so an erased automatic/manual repair returns to the original scan.
async function rasterize(strokes, W, H, signal) {
  const across = Math.ceil(W / TILE), tiles = new Map();
  let spanCount = 0;
  for (const { kind, radius, points } of strokes) {
    const action = kind === 'add' ? ADD : ERASE;
    const spans = Array.from({ length: 2 * radius + 1 }, (_, row) => Math.floor(Math.sqrt(radius ** 2 - (row - radius) ** 2)));
    const stamp = (x, y) => {
      const y0 = Math.max(0, y - radius), y1 = Math.min(H - 1, y + radius);
      spanCount += y1 - y0 + 1;
      if (spanCount > 40_000_000) throw new Error('笔画覆盖范围过大，请缩小画笔或分次处理。');
      for (let v = y0; v <= y1; v++) {
        const dx = spans[v - y + radius], end = Math.min(W, x + dx + 1);
        const ty = Math.floor(v / TILE), base = (v % TILE) * TILE;
        for (let u = Math.max(0, x - dx); u < end;) {
          const tx = Math.floor(u / TILE), key = ty * across + tx;
          let tile = tiles.get(key);
          if (!tile) {
            // Many small strokes spread over the frame touch many tiles; every tile of a
            // 50MP scan (about 800, 64 KB each) fits.
            if (tiles.size >= 2048) throw new Error('笔画覆盖范围过大，请缩小画笔或分次处理。');
            tile = { x: tx * TILE, y: ty * TILE, actions: new Uint8Array(TILE * TILE), hasAdd: false };
            tiles.set(key, tile);
          }
          const next = Math.min(end, (tx + 1) * TILE);
          tile.actions.fill(action, base + u - tile.x, base + next - tile.x);
          if (action === ADD) tile.hasAdd = true;
          u = next;
        }
      }
    };
    stamp(...points[0]);
    const spacing = Math.max(1, radius / 3);
    for (let i = 1; i < points.length; i++) {
      const [x, y] = points[i - 1], [x1, y1] = points[i];
      const dx = x1 - x, dy = y1 - y, steps = Math.ceil(Math.hypot(dx, dy) / spacing);
      for (let s = 1; s <= steps; s++) stamp(Math.round(x + dx * s / steps), Math.round(y + dy * s / steps));
      if (i % 32 === 0) { await yieldNow(); cancelled(signal); }
    }
    cancelled(signal);
  }
  return { across, tiles };
}

const differs = (a, b, from, count) => {
  for (let c = 0; c < count; c++) if (a[from + c] !== b[from + c]) return true;
  return false;
};

async function applyStrokes(source, data, mask, strokes, signal) {
  const { width: W, height: H, channels: stride, colorChannels: C } = source;
  const { across, tiles } = await rasterize(strokes, W, H, signal);
  let changedDelta = 0, addedPixels = 0, restoredPixels = 0;
  const tick = async () => { await yieldNow(); cancelled(signal); };
  for (const { x, y, actions } of tiles.values()) {
    for (let dy = 0; dy < TILE && y + dy < H; dy++) {
      for (let dx = 0; dx < TILE && x + dx < W; dx++) {
        if (actions[dy * TILE + dx] !== ERASE) continue;
        const p = (y + dy) * W + x + dx;
        if (!mask[p]) continue;
        mask[p] = 0; restoredPixels++;
        const from = p * stride;
        if (differs(data, source.data, from, stride)) changedDelta--;
        for (let c = 0; c < stride; c++) data[from + c] = source.data[from + c];
      }
    }
    await tick();
  }
  for (const { x, y, actions, hasAdd } of tiles.values()) {
    if (!hasAdd || !actions.includes(ADD)) continue;
    const w = Math.min(TILE, W - x), h = Math.min(TILE, H - y);
    let left = w, top = h, right = 0, bottom = 0;
    for (let dy = 0; dy < h; dy++) for (let dx = 0; dx < w; dx++) if (actions[dy * TILE + dx] === ADD) {
      left = Math.min(left, dx); right = Math.max(right, dx + 1);
      top = Math.min(top, dy); bottom = Math.max(bottom, dy + 1);
    }
    const x0 = Math.max(0, x + left - HALO), y0 = Math.max(0, y + top - HALO);
    const ww = Math.min(W, x + right + HALO) - x0, hh = Math.min(H, y + bottom + HALO) - y0;
    const colors = new Uint16Array(ww * hh * C), marks = new Uint8Array(ww * hh), avoid = new Uint8Array(ww * hh);
    for (let v = y0; v < y0 + hh; v++) {
      const ty = Math.floor(v / TILE), base = (v % TILE) * TILE;
      for (let u = x0; u < x0 + ww;) {
        const tx = Math.floor(u / TILE), rowActions = tiles.get(ty * across + tx)?.actions;
        const end = Math.min(x0 + ww, (tx + 1) * TILE);
        for (; u < end; u++) {
          const p = v * W + u, q = (v - y0) * ww + u - x0;
          const add = rowActions?.[base + u % TILE] === ADD;
          if (add) marks[q] = 1;
          if (mask[p] && !add) avoid[q] = 1;
          const samples = mask[p] && !add ? data : source.data;
          for (let c = 0; c < C; c++) colors[q * C + c] = samples[p * stride + c];
        }
      }
    }
    // The halo lets the grain-matched healer borrow nearby clean samples and
    // handle a continuous stroke across tile edges. Only the tile's own
    // selected pixels are copied back; already healed additions are never donors.
    await heal(colors, ww, hh, C, marks, null, null, tick, avoid);
    for (let dy = top; dy < bottom; dy++) for (let dx = left; dx < right; dx++) {
      if (actions[dy * TILE + dx] !== ADD) continue;
      const p = (y + dy) * W + x + dx, from = p * stride;
      const local = ((y + dy - y0) * ww + x + dx - x0) * C;
      if (differs(data, source.data, from, stride)) changedDelta--;
      if (!mask[p]) addedPixels++;
      mask[p] = 65535;
      for (let c = 0; c < C; c++) {
        const value = colors[local + c];
        data[from + c] = source.depth === 8 ? Math.round(value / 257) * 257 : value;
      }
      if (differs(data, source.data, from, stride)) changedDelta++;
    }
    await tick();
  }
  return { changedDelta, addedPixels, restoredPixels };
}

module.exports = { checkedStrokes, applyStrokes };
