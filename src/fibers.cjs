'use strict';

const { gaussianBlur } = require('../vendor/film-dust/engine/filters');
const { heal } = require('../vendor/film-dust/engine/heal');
const { lumaFromU16 } = require('../vendor/film-dust/engine/maps');

const PAD = 160;
const STEP = 4;
const TURN = Math.PI / 15;
// [Claude 2026-11-08] A fibre used to be traced inside one 2*PAD window anchored on its
// seed, so nothing longer than about 2*(PAD-18) px could be followed and a long curly hair
// was cut off mid-track. The track now carries image coordinates and the window slides to
// the tip, so length is bounded by the fibre itself. Every point still has to pass the same
// ridge() test, so no new kind of evidence is admitted — only the window stops cutting in.
const EDGE_ROOM = 24;        // re-anchor once the tip comes this close to a window edge
const MAX_REACH = 900;       // cap on one direction's travel, px
const MAX_REPAIR_PIXELS = 4_000_000;   // cap on the patch a single fibre is healed in
const SEEDS_PER_MP = 4;      // seeds past the base, per megapixel (a 50MP scan qualifies more)
const MIN_SEEDS = 128;

// [Claude 2026-11-08] Seeds read from the image itself. The engine cuts a long fibre into
// short pieces that rarely qualify as seeds (on a user-corrected 50MP night scan, 6 of 110
// pieces lying on missed fibres did), yet the fibres stand 10-100x above the local noise.
// A thin ridge brighter than both shoulders, on a smooth surround, nearly neutral and well
// above the noise, starts a track; the tracer's own tests still decide what is repaired.
const LEARNED_MIN = 128;       // learned map: probability 0.5 on its 0-255 scale
const LEARNED_MIN_PIXELS = 20; // and a piece at least this big, so single grains do not seed
const LEARNED_WIDTH = 0.85;    // a learned seed must lead to a slightly narrower line: the map is a
                              // hint, the image itself has to show a crisp line
const RIDGE_SNR = 8;          // ridge height over the local noise
const RIDGE_MIN = 0.02;       // and over the shoulders, in luma
const RIDGE_EDGE_MAX = 1.6;   // surround gradient / surround noise: photo structure scores 2-4
const RIDGE_SAT_MAX = 0.3;    // dust is near neutral; a printed date or a coloured edge is not
const RIDGE_MIN_PIXELS = 12;  // half-resolution pixels in one ridge piece
const RIDGE_FRAME_ROOM = 48;  // px kept clear of the film rebate edge
const RIDGE_MAX_SEEDS = 3000;
const FIBRE_PASSES = 3;      // trace, repair, look again (see enhanceFibers)
const TANGLE_REACH = 160;     // px at REFERENCE_SIDE: how far from a repaired fibre a later pass may start (it must still touch one)
const OUTSHONE = 2.5;         // a later-pass track beside something this many times brighter is a rim, not a fibre
const SURROUND_MAX = 0.3;     // a track from an image seed: busier side's gradient / ridge height
const BALANCE_MAX = 0.8;      // and |one side - other side| / ridge height (fibres up to 0.43)
const SPREAD_MAX = 4;         // and (90th - 10th pct.) / median ridge height along the track (fibres up to 3.0)
// Dust lies on the film at the scanner's focus, so a fibre is among the finest, crispest
// lines in a scan: 10-30 um across, about 3-5 px FWHM on a 8660 px wide 35 mm scan. A line
// in the picture (paving joints, seams, a trim) is drawn through the camera lens and the
// film and comes out wider. The limit scales with the scan's long side.
const FWHM_AT_REFERENCE = 6;  // px, for a long side of REFERENCE_SIDE
const REFERENCE_SIDE = 8660;

// Image seeds start on any clean thin ridge, so a track they start is held to more tests
// than an engine-seeded one (surround and crossWidth):
// - the picture 14-22 px out must be quiet relative to the ridge on both sides: a highlight
//   along a glass rim or a trim beside a hem has structure of its own on one side;
// - the two sides 8-12 px out must be about as bright as each other: dust lies on whatever
//   is behind it, while a bright line on a step is an edge (the rim of the film holder, a
//   frame), whose sides differ by more than the line's own height;
// - the ridge must keep roughly its height along the track: a glint off a watch glass or a
//   rim flares at one point and fades along the curve, a fibre in the film plane does not;
// - the fibre must be as fine as dust on film (crossWidth).
// Calibrated on two user-corrected 50MP night frames (66% of the corrected defect pixels
// found, against 50% and 61% before) and a 10MP daylight frame with paving joints and seams
// (no repairs added). Over the 72 image-seeded tracks on real fibres in the night frames,
// the side difference reached 0.43 and the spread 3.0; the two lines that were not dust
// scored 1.3 (a frame edge) and 5.6 (a watch glass).
// Median full width at half maximum of the fibre's cross profile, on the unblurred luma.
function crossWidth(original, W, H, C, track) {
  const xs = track.map(q => q.x), ys = track.map(q => q.y);
  const x0 = Math.max(0, Math.floor(Math.min(...xs)) - 16), y0 = Math.max(0, Math.floor(Math.min(...ys)) - 16);
  const w = Math.min(W, Math.ceil(Math.max(...xs)) + 17) - x0, h = Math.min(H, Math.ceil(Math.max(...ys)) + 17) - y0;
  if (w < 8 || h < 8 || w * h > MAX_REPAIR_PIXELS) return Infinity;
  const luma = lumaFromU16(patch(original, W, C, x0, y0, w, h), w, h, C);
  const bilinear = (x, y) => {
    x = Math.max(0, Math.min(w - 1.001, x - x0)); y = Math.max(0, Math.min(h - 1.001, y - y0));
    const ix = Math.floor(x), iy = Math.floor(y), fx = x - ix, fy = y - iy, i = iy * w + ix;
    return (luma[i] * (1 - fx) + luma[i + 1] * fx) * (1 - fy) + (luma[i + w] * (1 - fx) + luma[i + w + 1] * fx) * fy;
  };
  const widths = [];
  // -12..+12 px at half-pixel steps; the baseline is read 9-12 px out, clear of a wide line.
  const prof = new Float64Array(49);
  for (let i = 0; i < track.length; i++) {
    const a = track[Math.max(0, i - 2)], b = track[Math.min(track.length - 1, i + 2)];
    const len = Math.hypot(b.x - a.x, b.y - a.y) || 1, nx = -(b.y - a.y) / len, ny = (b.x - a.x) / len;
    for (let k = 0; k < 49; k++) { const d = -12 + 0.5 * k; prof[k] = bilinear(track[i].x + nx * d, track[i].y + ny * d); }
    let c = 18;
    for (let k = 19; k < 31; k++) if (prof[k] > prof[c]) c = k;
    const ends = arr => { const s = [...arr].sort((p, q) => p - q); return s[s.length >> 1]; };
    const base = 0.5 * (ends(prof.slice(0, 7)) + ends(prof.slice(42)));
    const peak = prof[c] - base;
    if (peak <= 0.01) continue;
    let l = c, r = c;
    while (l > 0 && prof[l - 1] - base >= 0.5 * peak) l--;
    while (r < 48 && prof[r + 1] - base >= 0.5 * peak) r++;
    widths.push((r - l + 1) * 0.5);
  }
  if (!widths.length) return Infinity;
  widths.sort((p, q) => p - q);
  return widths[widths.length >> 1];
}

// Medians over the track, on the luma blurred as for tracing: the busier side's gradient
// 14-22 px out, the two sides' difference 8-12 px out, both over the ridge's height above
// its higher side; and the spread of that height along the track. Null if too big to read.
function touches(traced, W, H, points) {
  for (const q of points) {
    const r = Math.ceil(q.radius) + 3;
    for (let y = Math.max(0, Math.floor(q.y) - r); y <= Math.min(H - 1, Math.ceil(q.y) + r); y++)
      for (let x = Math.max(0, Math.floor(q.x) - r); x <= Math.min(W - 1, Math.ceil(q.x) + r); x++)
        if (traced[y * W + x] && (x - q.x) ** 2 + (y - q.y) ** 2 <= r * r) return true;
  }
  return false;
}

function outshone(img, W, H, C, track) {
  const xs = track.map(q => q.x), ys = track.map(q => q.y);
  const x0 = Math.max(0, Math.floor(Math.min(...xs)) - 24), y0 = Math.max(0, Math.floor(Math.min(...ys)) - 24);
  const w = Math.min(W, Math.ceil(Math.max(...xs)) + 25) - x0, h = Math.min(H, Math.ceil(Math.max(...ys)) + 25) - y0;
  if (w < 1 || h < 1 || w * h > MAX_REPAIR_PIXELS) return true;
  const luma = lumaFromU16(patch(img, W, C, x0, y0, w, h), w, h, C);
  const near = Float32Array.from(luma).sort();
  const on = track.map(q => luma[Math.round(q.y - y0) * w + Math.round(q.x - x0)]).sort((a, b) => a - b);
  return near[Math.floor(0.99 * (near.length - 1))] > OUTSHONE * on[on.length >> 1];
}

function surround(original, W, H, C, track) {
  const xs = track.map(q => q.x), ys = track.map(q => q.y);
  const x0 = Math.max(0, Math.floor(Math.min(...xs)) - 30), y0 = Math.max(0, Math.floor(Math.min(...ys)) - 30);
  const w = Math.min(W, Math.ceil(Math.max(...xs)) + 31) - x0, h = Math.min(H, Math.ceil(Math.max(...ys)) + 31) - y0;
  if (w < 8 || h < 8 || w * h > MAX_REPAIR_PIXELS) return null;
  const luma = gaussianBlur(lumaFromU16(patch(original, W, C, x0, y0, w, h), w, h, C), w, h, 1.35);
  const at = (x, y) => luma[Math.max(0, Math.min(h - 1, Math.round(y - y0))) * w + Math.max(0, Math.min(w - 1, Math.round(x - x0)))];
  const busy = [], balance = [], rises = [];
  for (let i = 0; i < track.length; i++) {
    const a = track[Math.max(0, i - 2)], b = track[Math.min(track.length - 1, i + 2)];
    const len = Math.hypot(b.x - a.x, b.y - a.y) || 1, nx = -(b.y - a.y) / len, ny = (b.x - a.x) / len;
    const { x, y } = track[i], c = at(x, y);
    const side = s => (at(x + s * nx * 8, y + s * ny * 8) + at(x + s * nx * 10, y + s * ny * 10) + at(x + s * nx * 12, y + s * ny * 12)) / 3;
    const one = side(1), other = side(-1);
    const rise = Math.max(c - Math.max(one, other), 1e-3);
    // Structure is usually on one side (the rim beside a highlight, the hem beside a trim),
    // so each side is read on its own and the busier one counts.
    let busier = 0;
    for (const s of [1, -1]) {
      const g = [14, 18, 22].map(d => {
        const px = x + s * nx * d, py = y + s * ny * d;
        return Math.abs(at(px + 1, py) - at(px - 1, py)) + Math.abs(at(px, py + 1) - at(px, py - 1));
      }).sort((p, q) => p - q);
      busier = Math.max(busier, g[1]);
    }
    busy.push(busier / rise);
    balance.push(Math.abs(one - other) / rise);
    rises.push(rise);
  }
  for (const list of [busy, balance, rises]) list.sort((p, q) => p - q);
  const median = list => list[list.length >> 1];
  const at90 = rises[Math.min(rises.length - 1, Math.floor(0.9 * rises.length))];
  const at10 = rises[Math.floor(0.1 * rises.length)];
  return { busy: median(busy), balance: median(balance), spread: (at90 - at10) / median(rises) };
}

const { label: labelRegions, findObjects } = require('../vendor/film-dust/engine/regions');

function ridgeSeeds({ original, W, H, C, signs, frame }) {
  const w = W >> 1, h = H >> 1;
  if (w < 64 || h < 64) return [];
  const half = new Float32Array(w * h);
  const lum = j => (C === 1 ? original[j] : 0.2126 * original[j] + 0.7152 * original[j + 1] + 0.0722 * original[j + 2]);
  for (let y = 0; y < h; y++) {
    const top = 2 * y * W * C, bottom = (2 * y + 1) * W * C;
    for (let x = 0; x < w; x++) {
      const j = 2 * x * C;
      // Same order as summing (0,0), (0,1), (1,0), (1,1).
      let sum = 0;
      sum += lum(top + j); sum += lum(top + j + C); sum += lum(bottom + j); sum += lum(bottom + j + C);
      half[y * w + x] = sum / (4 * 65535);
    }
  }
  const smooth = gaussianBlur(half, w, h, 0.8);
  // Local noise: median absolute deviation from a 3x3 mean, per 32x32 block.
  const B = 32, bw = Math.ceil(w / B), bh = Math.ceil(h / B), noise = new Float32Array(bw * bh);
  const residual = new Float32Array(w * h);
  for (let y = 1; y < h - 1; y++) for (let x = 1; x < w - 1; x++) {
    const i = y * w + x, u = i - w, d = i + w;
    let s = 0;
    s += half[u - 1]; s += half[u]; s += half[u + 1];
    s += half[i - 1]; s += half[i]; s += half[i + 1];
    s += half[d - 1]; s += half[d]; s += half[d + 1];
    residual[i] = Math.abs(half[i] - s / 9);
  }
  for (let by = 0; by < bh; by++) for (let bx = 0; bx < bw; bx++) {
    const vals = [];
    for (let y = by * B; y < Math.min(h, by * B + B); y += 2) for (let x = bx * B; x < Math.min(w, bx * B + B); x += 2) vals.push(residual[y * w + x]);
    vals.sort((a, b) => a - b);
    noise[by * bw + bx] = Math.max(0.002, 1.4826 * (vals[vals.length >> 1] ?? 0));
  }
  const at = (x, y) => smooth[Math.max(0, Math.min(h - 1, y)) * w + Math.max(0, Math.min(w - 1, x))];
  const seeds = [];
  for (const sign of signs) {
    const height = new Float32Array(w * h), cand = new Uint8Array(w * h);
    // Shoulder offsets as index steps: across a horizontal, vertical and both diagonal lines,
    // at 3 and 4 px (2 and 3 px diagonally). Inside a 4 px border no index needs clamping.
    const steps = [[3, 0], [0, 3], [2, 2], [2, -2]].map(([oy, ox]) => {
      const uy = Math.sign(oy), ux = Math.sign(ox);
      return [oy * w + ox, (oy + uy) * w + ox + ux];
    });
    for (let y = 4; y < h - 4; y++) for (let x = 4; x < w - 4; x++) {
      const i = y * w + x, c = smooth[i];
      let best = -1;
      for (let k = 0; k < 4; k++) {
        const near = steps[k][0], far = steps[k][1];
        const a = sign * (c - 0.5 * (smooth[i + near] + smooth[i + far]));
        const b = sign * (c - 0.5 * (smooth[i - near] + smooth[i - far]));
        const rise = a < b ? a : b;
        if (rise > best) best = rise;
      }
      height[y * w + x] = best;
      if (best >= RIDGE_MIN && best >= RIDGE_SNR * noise[((y / B) | 0) * bw + ((x / B) | 0)]) cand[y * w + x] = 1;
    }
    const { lab, n } = labelRegions(cand, w, h, 8);
    if (!n) continue;
    const boxes = findObjects(lab, w, h, n);
    for (let id = 1; id <= n; id++) {
      const b = boxes[id - 1];
      if (!b) continue;
      const x0 = Math.max(1, b.x0 - 10), y0 = Math.max(1, b.y0 - 10), x1 = Math.min(w - 1, b.x1 + 10), y1 = Math.min(h - 1, b.y1 + 10);
      let size = 0, peak = -1, px = 0, py = 0;
      const sats = [];
      for (let y = b.y0; y < b.y1; y++) for (let x = b.x0; x < b.x1; x++) {
        if (lab[y * w + x] !== id) continue;
        size++;
        const v = height[y * w + x];
        if (v > peak) { peak = v; px = x; py = y; }
        if (C >= 3) {
          const j = ((2 * y) * W + 2 * x) * C, r = original[j], g = original[j + 1], bl = original[j + 2];
          const mx = Math.max(r, g, bl);
          sats.push(mx ? (mx - Math.min(r, g, bl)) / mx : 0);
        }
      }
      if (size < RIDGE_MIN_PIXELS) continue;
      if (sats.length) { sats.sort((p, q) => p - q); if (sats[sats.length >> 1] > RIDGE_SAT_MAX) continue; }
      // Surround: the window around the piece, minus the piece and two pixels of margin.
      const grads = [], devs = [];
      for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
        let near = false;
        for (let dy = -2; dy <= 2 && !near; dy++) for (let dx = -2; dx <= 2; dx++) {
          const yy = y + dy, xx = x + dx;
          if (yy >= 0 && yy < h && xx >= 0 && xx < w && lab[yy * w + xx] === id) { near = true; break; }
        }
        if (near) continue;
        const gx = smooth[y * w + x + 1] - smooth[y * w + x - 1], gy = smooth[(y + 1) * w + x] - smooth[(y - 1) * w + x];
        grads.push(Math.hypot(gx, gy) * 0.5);
        devs.push(residual[y * w + x]);
      }
      if (grads.length < 20) continue;
      grads.sort((p, q) => p - q); devs.sort((p, q) => p - q);
      const edge = grads[grads.length >> 1] / Math.max(devs[devs.length >> 1], 1e-3);
      if (edge > RIDGE_EDGE_MAX) continue;
      const cx = 2 * px + 0.5, cy = 2 * py + 0.5;
      if (frame) {
        let clear = true;
        for (const [dx, dy] of [[0, 0], [RIDGE_FRAME_ROOM, 0], [-RIDGE_FRAME_ROOM, 0], [0, RIDGE_FRAME_ROOM], [0, -RIDGE_FRAME_ROOM]]) {
          const xx = Math.max(0, Math.min(W - 1, Math.round(cx + dx))), yy = Math.max(0, Math.min(H - 1, Math.round(cy + dy)));
          if (frame.protects(yy * W + xx)) { clear = false; break; }
        }
        if (!clear) continue;
      }
      seeds.push({ cx, cy, x0: cx - 3, x1: cx + 3, y0: cy - 3, y1: cy + 3, z: peak / noise[((py / B) | 0) * bw + ((px / B) | 0)],
        polarity: sign > 0 ? 'bright' : 'dark', ridgeSeed: true });
    }
  }
  return seeds.sort((a, b) => b.z - a.z).slice(0, RIDGE_MAX_SEEDS);
}
const MAX_SEED_CAP = 512;

// [Claude 2026-11-08] Starting points from the learned dust/fibre map (FibreNet, trained on
// the user's corrected frames): one per connected piece at or above 0.5, at its most certain
// pixel. On grainy or coloured ground a fibre falls apart into pieces too small for the
// hand-written ridge detector; the model still sees it whole. These seeds go through the
// same tracer and the same scene tests (surround, width, frame) as the others.
const CURLED_LIMIT = 2.6;      // track length / span allowed where the learned map is sure
const CURLED_PROB = 96;        // map value the surest quarter of a track must average (probability 0.38);
                               // a track from a learned seed (a sure piece of >= 20 px) qualifies anyway

// Whether the learned map takes a track for a defect: each point reads the highest value
// within a pixel of it (a track and the map's band need not sit exactly on one another), and
// the surest quarter of the track has to average CURLED_PROB. The map is often
// sure of one part of a curled fibre and doubtful of the faint rest.
function learnedAlong(prob, W, H, points) {
  if (!prob || prob.length !== W * H) return false;
  const values = [];
  for (const q of points) {
    const cx = Math.round(q.x), cy = Math.round(q.y);
    let best = 0;
    for (let y = cy - 1; y <= cy + 1; y++) for (let x = cx - 1; x <= cx + 1; x++) {
      if (x >= 0 && y >= 0 && x < W && y < H && prob[y * W + x] > best) best = prob[y * W + x];
    }
    values.push(best);
  }
  if (!values.length) return false;
  values.sort((a, b) => b - a);
  const top = values.slice(0, Math.max(1, Math.ceil(values.length / 4)));
  return top.reduce((a, b) => a + b, 0) / top.length >= CURLED_PROB;
}

function learnedSeeds(prob, W, H, signs, frame) {
  const cand = new Uint8Array(W * H);
  for (let i = 0; i < W * H; i++) if (prob[i] >= LEARNED_MIN) cand[i] = 1;
  const { lab, n } = labelRegions(cand, W, H, 8);
  if (!n) return [];
  const best = new Int32Array(n + 1).fill(-1), size = new Int32Array(n + 1);
  for (let i = 0; i < W * H; i++) {
    const id = lab[i];
    if (!id) continue;
    size[id]++;
    if (best[id] < 0 || prob[i] > prob[best[id]]) best[id] = i;
  }
  const polarity = !signs.length || signs.includes(1) ? 'bright' : 'dark', seeds = [];
  for (let id = 1; id <= n; id++) {
    if (size[id] < LEARNED_MIN_PIXELS) continue;
    const i = best[id], cx = i % W, cy = (i / W) | 0;
    if (frame && frame.protects(i)) continue;
    seeds.push({ cx, cy, x0: cx - 3, x1: cx + 3, y0: cy - 3, y1: cy + 3, z: size[id], polarity, ridgeSeed: true, learned: true });
  }
  return seeds.sort((a, b) => b.z - a.z).slice(0, RIDGE_MAX_SEEDS);
}

function quietBrightRidge(mark) {
  return mark.quietBrightRidge === true && mark.verdict === 'keep-photo' && mark.scene >= 4;
}

function usefulSeed(mark, minimumSeed) {
  const line = mark.line;
  const scene = mark.scene ?? -Infinity;
  const quiet = quietBrightRidge(mark);
  const softSceneRidge = mark.verdict === 'keep-photo' && mark.why?.startsWith('not crisp') && scene < 0
    && line?.half_w >= 6.5 && mark.crisp_rel <= 0.75;
  // A very strong, symmetric profile can seed a track on a cropped scan,
  // where the scene model can be uncertain. A broad, soft profile that the
  // model already reads as photo detail can be a fold or specular seam.
  const supported = scene >= 0.7 || (!softSceneRidge && scene >= -1 && mark.z >= 24 && line?.one_med <= 0.15);
  return line && !mark.frame && !mark.print && !mark.zone && mark.pass !== 2
    && (quiet || mark.verdict === 'defect' || mark.verdict === 'not-selected' || (mark.verdict === 'keep-photo'
      && (mark.kind === 'hair/fibre' || mark.why?.startsWith('not crisp')) && supported))
    && mark.length >= 25 && mark.length <= 180 && mark.width <= 25 && mark.length >= 2.5 * mark.width
    && mark.z >= minimumSeed * (quiet ? 0.8 : 1) && mark.white >= 0.55 && line.one_med <= 0.38 && line.one_frac <= 0.35
    && (line.per ?? 0) <= (quiet ? 0.45 : 0.38) && (line.hf ?? 0) <= 0.4;
}

function patch(src, W, C, x0, y0, w, h) {
  const data = new Uint16Array(w * h * C);
  for (let y = 0; y < h; y++) {
    const start = ((y0 + y) * W + x0) * C;
    data.set(src.subarray(start, start + w * C), y * w * C);
  }
  return data;
}

function sample(luma, w, x, y) {
  const ix = Math.floor(x), iy = Math.floor(y), fx = x - ix, fy = y - iy;
  const i = iy * w + ix;
  return (1 - fy) * (luma[i] * (1 - fx) + luma[i + 1] * fx)
    + fy * (luma[i + w] * (1 - fx) + luma[i + w + 1] * fx);
}

function ridge(luma, w, h, x, y, angle, sign, minimumRise) {
  if (x < 15 || y < 15 || x >= w - 15 || y >= h - 15) return null;
  const nx = -Math.sin(angle), ny = Math.cos(angle);
  const across = d => sample(luma, w, x + nx * d, y + ny * d);
  const core = across(0);
  const a = sign * (core - (across(-10) + across(-13)) * 0.5);
  const b = sign * (core - (across(10) + across(13)) * 0.5);
  const rise = (a + b) * 0.5;
  if (rise < minimumRise || Math.min(a, b) < 0.38 * Math.max(a, b)) return null;

  // A narrow ridge falls back to the ground on both sides. A broad painted
  // stripe or a single edge gives no such pair of shoulders near its core.
  for (const d of [3, 5, 7, 9]) {
    if (sign * (core - across(-d)) >= a * 0.76 && sign * (core - across(d)) >= b * 0.76) {
      return { x, y, angle, radius: d, score: Math.min(a, b) };
    }
  }
  return null;
}

function trace(luma, w, h, start, angle, sign, minimumRise, limit = PAD - 18) {
  const points = [];
  let { x, y } = start;
  let misses = 0;
  for (let travel = 0; travel < limit; travel += STEP) {
    let best = null, bestScore = 0;
    for (const turn of [-1, 0, 1]) {
      const heading = angle + turn * TURN;
      const vx = Math.cos(heading), vy = Math.sin(heading);
      for (const shift of [-2, -1, 0, 1, 2]) {
        const q = ridge(luma, w, h, x + vx * STEP - vy * shift, y + vy * STEP + vx * shift, heading, sign, minimumRise);
        if (!q) continue;
        const score = q.score - 0.001 * (Math.abs(shift) + Math.abs(turn));
        if (score > bestScore) { best = q; bestScore = score; }
      }
    }
    if (!best) {
      if (++misses === 3) break;
      x += Math.cos(angle) * STEP;
      y += Math.sin(angle) * STEP;
      continue;
    }
    // A short weak gap can reconnect a track, while only the supported
    // points contribute their own footprints to the repair mask.
    angle += 0.65 * (best.angle - angle);
    x = best.x; y = best.y;
    points.push(best);
    misses = 0;
  }
  return points;
}

// A luma window over the scan that can be re-anchored on a moving tip. Only one window's
// luma is held at a time, so following a long fibre costs no more memory than before.
function traceWindow(original, W, H, C) {
  const win = { luma: null, w: 0, h: 0, x0: 0, y0: 0 };
  win.recenter = (gx, gy) => {
    const cx = Math.round(gx), cy = Math.round(gy);
    const x0 = Math.max(0, Math.min(Math.max(0, W - 2 * PAD - 1), cx - PAD));
    const y0 = Math.max(0, Math.min(Math.max(0, H - 2 * PAD - 1), cy - PAD));
    const x1 = Math.min(W, x0 + 2 * PAD + 1), y1 = Math.min(H, y0 + 2 * PAD + 1);
    if (win.luma && x0 === win.x0 && y0 === win.y0 && x1 - x0 === win.w && y1 - y0 === win.h) return false;
    win.x0 = x0; win.y0 = y0; win.w = x1 - x0; win.h = y1 - y0;
    const data = patch(original, W, C, win.x0, win.y0, win.w, win.h);
    win.luma = gaussianBlur(lumaFromU16(data, win.w, win.h, C), win.w, win.h, 1.35);
    return true;
  };
  // Room to keep tracing: the point is far enough inside the window, or the window
  // already sits against that edge of the scan and sliding it would gain nothing.
  win.roomy = (gx, gy) => {
    const lx = gx - win.x0, ly = gy - win.y0;
    return (lx >= EDGE_ROOM || win.x0 === 0) && (ly >= EDGE_ROOM || win.y0 === 0)
      && (win.w - lx >= EDGE_ROOM || win.x0 + win.w === W) && (win.h - ly >= EDGE_ROOM || win.y0 + win.h === H);
  };
  return win;
}

// trace(), but the track may leave the starting window. Points come back in image
// coordinates; `start` is in image coordinates too.
function traceAcross(win, start, angle, sign, minimumRise, limit = MAX_REACH) {
  const points = [];
  let x = start.x, y = start.y, misses = 0;
  for (let travel = 0; travel < limit; travel += STEP) {
    if (!win.roomy(x, y) && !win.recenter(x, y)) break;
    const { luma, w, h, x0, y0 } = win;
    let best = null, bestScore = 0;
    for (const turn of [-1, 0, 1]) {
      const heading = angle + turn * TURN;
      const vx = Math.cos(heading), vy = Math.sin(heading);
      for (const shift of [-2, -1, 0, 1, 2]) {
        const q = ridge(luma, w, h, x - x0 + vx * STEP - vy * shift, y - y0 + vy * STEP + vx * shift,
          heading, sign, minimumRise);
        if (!q) continue;
        const score = q.score - 0.001 * (Math.abs(shift) + Math.abs(turn));
        if (score > bestScore) { best = q; bestScore = score; }
      }
    }
    if (!best) {
      if (++misses === 3) break;
      x += Math.cos(angle) * STEP;
      y += Math.sin(angle) * STEP;
      continue;
    }
    angle += 0.65 * (best.angle - angle);
    x = best.x + x0; y = best.y + y0;
    points.push({ ...best, x, y });
    misses = 0;
  }
  return points;
}

// turnAtTip around a tip given in image coordinates, with the window moved there first.
function turnAcross(win, track, sign, minimumRise) {
  if (track.length < 5) return [];
  const tip = track.at(-1);
  if (!win.roomy(tip.x, tip.y)) win.recenter(tip.x, tip.y);
  const { luma, w, h, x0, y0 } = win;
  // The whole track is carried over so the tail still cannot double back onto any
  // part of the body; only the tip itself has to lie inside this window.
  const local = track.map(q => ({ ...q, x: q.x - x0, y: q.y - y0 }));
  const end = local.at(-1);
  if (end.x < 0 || end.y < 0 || end.x >= w || end.y >= h) return [];
  return turnAtTip(luma, w, h, local, sign, minimumRise).map(q => ({ ...q, x: q.x + x0, y: q.y + y0 }));
}

function turnAtTip(luma, w, h, track, sign, minimumRise) {
  if (track.length < 5) return [];
  const tip = track.at(-1), prior = track.at(-4);
  const heading = Math.atan2(tip.y - prior.y, tip.x - prior.x);
  const tx = Math.cos(heading), ty = Math.sin(heading);
  // Normal tracking can lose both shoulders right at a tight turn. Look
  // for a nearby ridge heading away from the tip and require three checks
  // on that ridge before attempting to follow it.
  const proposals = [];
  for (let along = 4; along <= 20; along += 4) for (let across = -12; across <= 12; across += 3) {
    const gap = Math.hypot(along, across);
    if (gap > 22) continue;
    const dx = tx * along - ty * across, dy = ty * along + tx * across;
    for (let j = -7; j <= 7; j++) {
      if (Math.abs(j) < 2) continue;
      const angle = heading + j * Math.PI / 12;
      const vx = Math.cos(angle), vy = Math.sin(angle);
      if (vx * dx + vy * dy < 0.35 * gap) continue;
      const q = ridge(luma, w, h, tip.x + dx, tip.y + dy, angle, sign, minimumRise);
      if (!q) continue;
      const a = ridge(luma, w, h, q.x + 4 * vx, q.y + 4 * vy, angle, sign, minimumRise);
      const b = ridge(luma, w, h, q.x + 8 * vx, q.y + 8 * vy, angle, sign, minimumRise);
      if (a && b) proposals.push({ q, gap, strength: Math.min(q.score, a.score, b.score) });
    }
  }
  proposals.sort((a, b) => b.strength - a.strength);
  let best = [], bestScore = 0;
  for (const { q, gap } of proposals.slice(0, 10)) {
    const tail = [q, ...trace(luma, w, h, q, q.angle, sign, minimumRise, 92)];
    if (tail.length < 6 || gap > tip.radius + q.radius + 5) continue;
    const end = tail.at(-1);
    if (Math.hypot(end.x - tip.x, end.y - tip.y) < 26) continue;
    if (tail.some(p => track.some(s => Math.hypot(p.x - s.x, p.y - s.y) < 4))) continue;
    const strength = tail.reduce((sum, p) => sum + Math.min(p.score, 0.04), 0);
    const score = strength - 0.012 * gap;
    if (score > bestScore) { best = tail; bestScore = score; }
  }
  return best;
}

function startRidge(luma, w, h, x, y, sign, minimumRise) {
  let best = null, score = 0;
  for (let dy = -6; dy <= 6; dy += 3) for (let dx = -6; dx <= 6; dx += 3) {
    const cx = x + dx, cy = y + dy;
    for (let i = 0; i < 12; i++) {
      const angle = i * Math.PI / 12;
      const q = ridge(luma, w, h, cx, cy, angle, sign, minimumRise);
      if (!q) continue;
      const vx = Math.cos(angle) * 6, vy = Math.sin(angle) * 6;
      const a = ridge(luma, w, h, cx - vx, cy - vy, angle, sign, minimumRise);
      const b = ridge(luma, w, h, cx + vx, cy + vy, angle, sign, minimumRise);
      if (!a || !b) continue;
      const s = Math.min(a.score, q.score, b.score) - 0.00025 * (Math.abs(dx) + Math.abs(dy));
      if (s > score) { best = q; score = s; }
    }
  }
  return best;
}

function footprint(points, w, h, x0, y0, W, mask) {
  const add = new Uint8Array(w * h);
  let left = w, right = 0, top = h, bottom = 0, area = 0;
  for (const { x, y, radius } of points) {
    for (let iy = Math.ceil(y - radius); iy <= Math.floor(y + radius); iy++) {
      for (let ix = Math.ceil(x - radius); ix <= Math.floor(x + radius); ix++) {
        const i = iy * w + ix, global = (y0 + iy) * W + x0 + ix;
        if (add[i] || mask[global] || (ix - x) ** 2 + (iy - y) ** 2 > radius ** 2) continue;
        add[i] = 1;
        area++;
        left = Math.min(left, ix); right = Math.max(right, ix);
        top = Math.min(top, iy); bottom = Math.max(bottom, iy);
      }
    }
  }
  return { add, left, right, top, bottom, area };
}

async function enhanceFibers({ original, repaired, mask, W, H, C, marks, polarity = 'auto', sensitivity = 1,
  frame = null, imageSeeds = true, probability = null, curl = 1, softness = 1, tick = async () => {} }) {
  // [Claude 2026-11-09] User controls, 0.5-2 (1 = the tested defaults). curl: how curled and how
  // short a track may be; softness: how wide (soft) a line may be, here and in the direct repair.
  curl = Number.isFinite(curl) ? Math.min(2, Math.max(0.5, curl)) : 1;
  softness = Number.isFinite(softness) ? Math.min(2, Math.max(0.5, softness)) : 1;
  const minimumSeed = 12 / sensitivity;
  // A 50MP scan offers far more qualifying seeds than the old flat 128; the cap is a
  // cost limit, not a quality gate, so it follows the scan's size. Tracing across
  // windows also makes each long fibre swallow its own extra seeds by the test below.
  const seedCap = Math.min(MAX_SEED_CAP, Math.max(MIN_SEEDS, Math.round(SEEDS_PER_MP * W * H / 1e6)));
  const seeds = marks.filter(mark => usefulSeed(mark, minimumSeed) && (polarity === 'auto' || mark.polarity === polarity))
    .sort((a, b) => b.z - a.z).slice(0, seedCap);
  // Only the polarity the engine found dust in: on an inverted negative the dust is
  // bright, and a dark thin line is far more often picture (hair, a seam, a shadow).
  const polarities = new Set(marks.filter(m => m.verdict === 'defect' && m.polarity).map(m => m.polarity));
  const signs = polarity === 'bright' ? [1] : polarity === 'dark' ? [-1]
    : [...polarities].map(p => (p === 'dark' ? -1 : 1));
  if (imageSeeds) {
    await tick();
    seeds.push(...ridgeSeeds({ original, W, H, C, signs, frame }));
    if (probability && probability.length === W * H) seeds.push(...learnedSeeds(probability, W, H, signs, frame));
  }
  const found = [];
  let pixels = 0;
  // [Claude 2026-11-08] Tangles are taken apart over several passes, the way they are by
  // hand: each pass traces what is clear and repairs it, and the next pass looks for ridges
  // again in what the earlier ones left. Where one fibre crossed another and broke it into
  // pieces, the other now runs whole and clean. Later passes trace on that repaired image.
  let source = original, passSeeds = seeds;
  const traced = new Uint8Array(W * H);   // pixels this tracer repaired, for the touch test below
  for (let pass = 0; pass < FIBRE_PASSES; pass++) {
  if (pass > 0) {
    if (!imageSeeds) break;
    source = Uint16Array.from(repaired);
    await tick();
    // Only where a tangle is: near a fibre the last pass repaired. Elsewhere one pass
    // stands. The tracks found there must also touch a repaired fibre (see below).
    const near = TANGLE_REACH * Math.max(W, H) / REFERENCE_SIDE;
    const last = found.filter(mark => mark.pass === pass - 1);
    passSeeds = ridgeSeeds({ original: source, W, H, C, signs, frame }).filter(seed => last.some(mark =>
      seed.x1 >= mark.x0 - near && seed.x0 <= mark.x1 + near && seed.y1 >= mark.y0 - near && seed.y0 <= mark.y1 + near));
    if (!passSeeds.length) break;
  }
  const before = found.length, passFound = [];
  const win = traceWindow(source, W, H, C);
  for (const seed of passSeeds) {
    await tick();
    if (passFound.some(mark => seed.cx >= mark.x0 && seed.cx <= mark.x1 && seed.cy >= mark.y0 && seed.cy <= mark.y1)) continue;
    win.recenter(seed.cx, seed.cy);
    const sign = seed.polarity === 'dark' ? -1 : 1;
    const minimumRise = (quietBrightRidge(seed) ? 0.0096 : 0.012) / sensitivity;
    const seedStart = startRidge(win.luma, win.w, win.h, seed.cx - win.x0, seed.cy - win.y0, sign, minimumRise);
    if (!seedStart) continue;
    const start = { ...seedStart, x: seedStart.x + win.x0, y: seedStart.y + win.y0 };
    const backward = traceAcross(win, start, start.angle + Math.PI, sign, minimumRise);
    const forward = traceAcross(win, start, start.angle, sign, minimumRise);
    const points = [...backward.slice().reverse(), start, ...forward];
    const first = points[0], last = points[points.length - 1];
    const dx = last.x - first.x, dy = last.y - first.y, length = Math.hypot(dx, dy);
    // [Claude 2026-11-09] A track much longer than its span is usually picture (a curl of
    // hair, a fold's edge), so it is let go. A fibre the learned map is sure of may curl far
    // more - a "C" or a hook - and keeps a looser limit.
    if (points.length < Math.max(7, Math.round(14 / curl)) || length < 44 / curl) continue;
    const curlLimit = seed.learned || learnedAlong(probability, W, H, points) ? CURLED_LIMIT : 1.65;
    if (points.length * STEP > (1 + (curlLimit - 1) * curl) * length) continue;
    const bend = Math.max(...points.map(q => Math.abs(dy * (q.x - first.x) - dx * (q.y - first.y)))) / (length * length);
    if (bend < 0.03 || !points.some(q => q.x < seed.x0 - 5 || q.x > seed.x1 + 5
      || q.y < seed.y0 - 5 || q.y > seed.y1 + 5)) continue;
    // A later pass only finishes a tangle: its fibre has to run into or across one an
    // earlier pass repaired. A track that merely starts nearby is open picture.
    if (pass > 0 && !touches(traced, W, H, points)) continue;
    // A fibre over a tangle is the brightest thing near it. A line found again beside a far
    // brighter highlight is that highlight's rim, uncovered once the first pass repaired it.
    if (pass > 0 && outshone(source, W, H, C, points)) continue;
    if (seed.ridgeSeed) {
      const around = surround(source, W, H, C, points);
      if (!around || around.busy > SURROUND_MAX || around.balance > BALANCE_MAX || around.spread > SPREAD_MAX
        || crossWidth(source, W, H, C, points) > softness * (seed.learned ? LEARNED_WIDTH : 1) * FWHM_AT_REFERENCE * Math.max(W, H) / REFERENCE_SIDE) continue;
    }

    const tail = [...turnAcross(win, backward, sign, minimumRise), ...turnAcross(win, forward, sign, minimumRise)];
    let changed = 0, trackLength = length;
    let boxX0 = W, boxY0 = H, boxX1 = 0, boxY1 = 0;
    // Each part is repaired in a patch of its own, sized to that part's track wherever it
    // ran. Keeping the patches separate means a recovered tip's donors and mask cannot
    // change the already healed body, including where it crosses an edge.
    for (const [which, track] of [['body', points], ['tail', tail]]) {
      if (!track.length) continue;
      // Room for each point's own radius: footprint() writes inside the patch
      // without a bounds check of its own.
      const margin = Math.ceil(Math.max(...track.map(q => q.radius))) + 4;
      const x0 = Math.max(0, Math.floor(Math.min(...track.map(q => q.x))) - margin);
      const y0 = Math.max(0, Math.floor(Math.min(...track.map(q => q.y))) - margin);
      const w = Math.min(W, Math.ceil(Math.max(...track.map(q => q.x))) + margin + 1) - x0;
      const h = Math.min(H, Math.ceil(Math.max(...track.map(q => q.y))) + margin + 1) - y0;
      if (w < 1 || h < 1 || w * h > MAX_REPAIR_PIXELS) continue;
      const part = track.map(q => ({ ...q, x: q.x - x0, y: q.y - y0 }));
      const { add, left, right, top, bottom, area } = footprint(part, w, h, x0, y0, W, mask);
      if (area < 35) continue;
      const previous = new Uint8Array(w * h);
      for (let y = 0; y < h; y++) previous.set(mask.subarray((y0 + y) * W + x0, (y0 + y) * W + x0 + w), y * w);
      const healed = patch(repaired, W, C, x0, y0, w, h);
      await heal(healed, w, h, C, add, null, null, tick, previous);
      const before = changed;
      for (let y = top; y <= bottom; y++) for (let x = left; x <= right; x++) {
        const local = y * w + x, global = (y0 + y) * W + x0 + x;
        if (!add[local]) continue;
        let differs = false;
        for (let c = 0; c < C; c++) differs ||= healed[local * C + c] !== original[global * C + c];
        if (!differs) continue;
        repaired.set(healed.subarray(local * C, (local + 1) * C), global * C);
        mask[global] = 1;
        traced[global] = 1;
        changed++;
      }
      if (changed === before) continue;
      boxX0 = Math.min(boxX0, x0 + left); boxY0 = Math.min(boxY0, y0 + top);
      boxX1 = Math.max(boxX1, x0 + right); boxY1 = Math.max(boxY1, y0 + bottom);
      if (which === 'tail') trackLength += tail.length * STEP;
    }
    if (changed) {
      pixels += changed;
      passFound.push({ x0: boxX0, x1: boxX1, y0: boxY0, y1: boxY1 });
      found.push({ pass, id: -3, kind: 'hair/fibre', verdict: 'defect', why: seed.ridgeSeed ? 'a narrow curved fibre traced from a thin ridge' : 'a narrow curved fibre traced from a detected fragment',
        origin: seed.ridgeSeed ? 'ridge' : 'engine',
        polarity: seed.polarity, x0: boxX0, x1: boxX1, y0: boxY0, y1: boxY1,
        cx: Math.round(seed.cx), cy: Math.round(seed.cy), area: changed, width: 2 * start.radius, length: Math.round(trackLength) });
    }
  }
  if (found.length === before) break;
  }
  if (probability && probability.length === W * H) {
    const direct = await repairLearned({ original, repaired, mask, W, H, C, probability, signs, frame, sensitivity, softness, tick });
    found.push(...direct.marks);
    pixels += direct.pixels;
  }
  return { marks: found, pixels };
}

// [Claude 2026-11-09] Direct repair of what the learned map is sure of. The tracer needs a
// line brighter than its surround all the way along; a fibre crossing from a dark background
// onto skin, or lying beside a highlight, or wider than the tracer allows, is lost there
// although the map marks it plainly. A piece the map is sure of (DIRECT_MIN, which follows
// the fibre sensitivity) and that is large enough is healed as the map draws it, widened by
// DIRECT_GROW px for the soft edge. Measured on four held-out frames: 0.86 / 60 px finds 96
// of the 179 areas users had to paint in, for 42 repairs nobody wanted (about 10 a frame).
const DIRECT_MIN = 220;          // probability 0.86 at sensitivity 100 %
const DIRECT_MIN_PIXELS = 60;
const DIRECT_MAX_PIXELS = 40_000; // a larger "piece" is picture the map got wrong, not a fibre
const DIRECT_GROW = 2;
const DIRECT_GROW_DROP = 124;    // grown down to the threshold minus this (220 -> 96, probability 0.38)
const DIRECT_CORE_PIXELS = 60;   // sure pixels a piece must contain (its width is measured on them)
const DIRECT_WIDTH = 10;         // px, mean width a piece may have (times the softness). The map's band is a
                                 // few px wide whatever the scan size; on four held-out frames the pieces users
                                 // kept had a median width of 7-9 px, the unwanted ones 4-6 px.

async function repairLearned({ original, repaired, mask, W, H, C, probability, signs, frame, sensitivity = 1, softness = 1, tick }) {
  const threshold = Math.max(160, Math.min(245, Math.round(DIRECT_MIN - 40 * (sensitivity - 1))));
  // [Claude 2026-11-09] Grown from the sure core along what the map still takes for a defect
  // (DIRECT_GROW_PROB), the way an edge is followed from its strong part: a fibre the map is
  // sure of on one stretch and doubtful of on the faint rest is repaired whole. A piece with no
  // sure core is left alone.
  const low = Math.max(48, threshold - DIRECT_GROW_DROP);
  const cand = new Uint8Array(W * H);
  for (let i = 0; i < W * H; i++) if (probability[i] >= low) cand[i] = 1;
  const { lab, n } = labelRegions(cand, W, H, 8);
  if (!n) return { marks: [], pixels: 0 };
  const size = new Int32Array(n + 1), done = new Int32Array(n + 1), core = new Int32Array(n + 1);
  const bx0 = new Int32Array(n + 1).fill(W), by0 = new Int32Array(n + 1).fill(H), bx1 = new Int32Array(n + 1), by1 = new Int32Array(n + 1);
  for (let i = 0; i < W * H; i++) {
    const id = lab[i];
    if (!id) continue;
    size[id]++;
    if (probability[i] >= threshold) core[id]++;
    if (mask[i]) done[id]++;
    const x = i % W, y = (i / W) | 0;
    if (x < bx0[id]) bx0[id] = x; if (x > bx1[id]) bx1[id] = x;
    if (y < by0[id]) by0[id] = y; if (y > by1[id]) by1[id] = y;
  }
  const bright = !signs.length || signs.includes(1), dark = signs.includes(-1);
  const marks = [];
  let pixels = 0;
  for (let id = 1; id <= n; id++) {
    if (core[id] < DIRECT_CORE_PIXELS || size[id] < DIRECT_MIN_PIXELS || size[id] > DIRECT_MAX_PIXELS || done[id] * 2 >= size[id]) continue;
    await tick();
    const margin = DIRECT_GROW + 6;
    const x0 = Math.max(0, bx0[id] - margin), y0 = Math.max(0, by0[id] - margin);
    const w = Math.min(W, bx1[id] + margin + 1) - x0, h = Math.min(H, by1[id] + margin + 1) - y0;
    if (w * h > MAX_REPAIR_PIXELS) continue;
    // The piece, grown, inside the patch; and its brightness against a ring around it.
    const add = new Uint8Array(w * h);
    let inside = 0, insideN = 0, ring = 0, ringN = 0, protectedPx = 0;
    const luma = i => C === 1 ? original[i] : 0.2126 * original[i * C] + 0.7152 * original[i * C + 1] + 0.0722 * original[i * C + 2];
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      const g = (y0 + y) * W + x0 + x;
      if (lab[g] !== id) continue;
      inside += luma(g); insideN++;
      if (frame && frame.protects(g)) protectedPx++;
      for (let dy = -DIRECT_GROW; dy <= DIRECT_GROW; dy++) for (let dx = -DIRECT_GROW; dx <= DIRECT_GROW; dx++) {
        const yy = y + dy, xx = x + dx;
        if (yy >= 0 && xx >= 0 && yy < h && xx < w) add[yy * w + xx] = 1;
      }
    }
    if (protectedPx * 2 > insideN) continue;
    // A fibre is thin: the width of the piece's sure core (peeled a layer at a time until
    // nothing is left: 2 x layers - 1) may be at most DIRECT_WIDTH px times the softness.
    let layer = new Uint8Array(w * h), cells = 0;
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      const g = (y0 + y) * W + x0 + x;
      if (lab[g] === id && probability[g] >= threshold) { layer[y * w + x] = 1; cells++; }   // the sure core
    }
    let layers = 0;
    const widest = Math.ceil((softness * DIRECT_WIDTH + 1) / 2);
    while (cells && layers <= widest) {
      const next = new Uint8Array(w * h);
      cells = 0;
      for (let y = 1; y < h - 1; y++) for (let x = 1; x < w - 1; x++) {
        const i = y * w + x;
        if (layer[i] && layer[i - 1] && layer[i + 1] && layer[i - w] && layer[i + w]) { next[i] = 1; cells++; }
      }
      layer = next; layers++;
    }
    if (2 * layers - 1 > softness * DIRECT_WIDTH) continue;
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      if (add[y * w + x]) continue;
      const near = x >= 2 && y >= 2 && x < w - 2 && y < h - 2;
      if (!near) continue;
      let touch = false;
      for (let d = -3; d <= 3 && !touch; d++) touch = (add[(y + d) * w + x] || add[y * w + x + d]) === 1;
      if (touch) { ring += luma((y0 + y) * W + x0 + x); ringN++; }
    }
    if (!insideN || !ringN) continue;
    const brighter = inside / insideN > ring / ringN;
    // Only the polarity the engine found dust in (see enhanceFibers).
    if ((brighter && !bright) || (!brighter && !dark)) continue;
    const previous = new Uint8Array(w * h);
    for (let y = 0; y < h; y++) previous.set(mask.subarray((y0 + y) * W + x0, (y0 + y) * W + x0 + w), y * w);
    const healed = patch(repaired, W, C, x0, y0, w, h);
    await heal(healed, w, h, C, add, null, null, tick, previous);
    let changed = 0;
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      const local = y * w + x, global = (y0 + y) * W + x0 + x;
      if (!add[local]) continue;
      let differs = false;
      for (let c = 0; c < C; c++) differs ||= healed[local * C + c] !== original[global * C + c];
      if (!differs) continue;
      repaired.set(healed.subarray(local * C, (local + 1) * C), global * C);
      mask[global] = 1;
      changed++;
    }
    if (!changed) continue;
    pixels += changed;
    marks.push({ id: -4, kind: 'hair/fibre', verdict: 'defect', origin: 'learned',
      why: 'a piece the learned dust/fibre map is sure of, repaired as the map draws it',
      polarity: brighter ? 'bright' : 'dark', x0: bx0[id], x1: bx1[id], y0: by0[id], y1: by1[id],
      cx: Math.round((bx0[id] + bx1[id]) / 2), cy: Math.round((by0[id] + by1[id]) / 2), area: changed });
  }
  return { marks, pixels };
}

module.exports = { enhanceFibers };
