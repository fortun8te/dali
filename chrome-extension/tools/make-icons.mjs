// Generates icons/icon16.png, icon48.png, icon128.png with zero dependencies
// (pure Node: zlib for deflate, hand-rolled PNG chunks, per-pixel rasterizer).
//
//   node tools/make-icons.mjs
//
// Design: dark rounded tile, a dimmed blue "ghost" play triangle trailing a
// solid white one — the delayed frame following the live one.

import { deflateSync } from 'node:zlib';
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const OUT_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', 'icons');
const SIZES = [16, 48, 128];

// ---------------------------------------------------------------------------
// Minimal PNG encoder (8-bit RGBA, no interlace)

const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    t[n] = c;
  }
  return t;
})();

function crc32(buf) {
  let c = 0xFFFFFFFF;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xFF] ^ (c >>> 8);
  return (c ^ 0xFFFFFFFF) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const typeBuf = Buffer.from(type, 'ascii');
  const crcBuf = Buffer.alloc(4);
  crcBuf.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])), 0);
  return Buffer.concat([len, typeBuf, data, crcBuf]);
}

function encodePng(width, height, rgba) {
  const sig = Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;   // bit depth
  ihdr[9] = 6;   // color type RGBA
  ihdr[10] = 0;  // compression
  ihdr[11] = 0;  // filter
  ihdr[12] = 0;  // interlace
  const stride = width * 4;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (stride + 1)] = 0; // filter: none
    rgba.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  }
  return Buffer.concat([
    sig,
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0))
  ]);
}

// ---------------------------------------------------------------------------
// Rasterizer (normalized [0,1] coords, 4x4 supersampling)

const BG = [16, 19, 26];        // tile
const GHOST = [79, 142, 247];   // delayed "ghost" frame (accent blue)
const MAIN = [242, 244, 248];   // live frame (near white)
const GHOST_ALPHA = 0.5;

function inRoundedRect(x, y) {
  const inset = 0.04, r = 0.22;
  const x0 = inset, y0 = inset, x1 = 1 - inset, y1 = 1 - inset;
  if (x < x0 || x > x1 || y < y0 || y > y1) return false;
  const cx = Math.min(Math.max(x, x0 + r), x1 - r);
  const cy = Math.min(Math.max(y, y0 + r), y1 - r);
  const dx = x - cx, dy = y - cy;
  return dx * dx + dy * dy <= r * r;
}

function inTri(px, py, ax, ay, bx, by, cx, cy) {
  const d1 = (px - bx) * (ay - by) - (ax - bx) * (py - by);
  const d2 = (px - cx) * (by - cy) - (bx - cx) * (py - cy);
  const d3 = (px - ax) * (cy - ay) - (cx - ax) * (py - ay);
  const hasNeg = (d1 < 0) || (d2 < 0) || (d3 < 0);
  const hasPos = (d1 > 0) || (d2 > 0) || (d3 > 0);
  return !(hasNeg && hasPos);
}

// Play triangle vertices (normalized), and the ghost shifted left.
const TRI = [0.40, 0.30, 0.40, 0.70, 0.76, 0.50];
const GHOST_SHIFT = -0.14;

function sampleColor(x, y) {
  // returns [r, g, b, a] with a in 0..1
  if (!inRoundedRect(x, y)) return [0, 0, 0, 0];
  let r = BG[0], g = BG[1], b = BG[2];
  const gx = x - GHOST_SHIFT; // shift sample point instead of the triangle
  if (inTri(gx, y, TRI[0], TRI[1], TRI[2], TRI[3], TRI[4], TRI[5])) {
    r = r + (GHOST[0] - r) * GHOST_ALPHA;
    g = g + (GHOST[1] - g) * GHOST_ALPHA;
    b = b + (GHOST[2] - b) * GHOST_ALPHA;
  }
  if (inTri(x, y, TRI[0], TRI[1], TRI[2], TRI[3], TRI[4], TRI[5])) {
    r = MAIN[0]; g = MAIN[1]; b = MAIN[2];
  }
  return [r, g, b, 1];
}

function renderIcon(size) {
  const rgba = Buffer.alloc(size * size * 4);
  const SS = 4;
  for (let py = 0; py < size; py++) {
    for (let px = 0; px < size; px++) {
      let ar = 0, ag = 0, ab = 0, aa = 0;
      for (let sy = 0; sy < SS; sy++) {
        for (let sx = 0; sx < SS; sx++) {
          const x = (px + (sx + 0.5) / SS) / size;
          const y = (py + (sy + 0.5) / SS) / size;
          const [r, g, b, a] = sampleColor(x, y);
          ar += r * a; ag += g * a; ab += b * a; aa += a;
        }
      }
      const n = SS * SS;
      const alpha = aa / n;
      const i = (py * size + px) * 4;
      if (alpha > 0) {
        rgba[i] = Math.round(ar / aa);
        rgba[i + 1] = Math.round(ag / aa);
        rgba[i + 2] = Math.round(ab / aa);
        rgba[i + 3] = Math.round(alpha * 255);
      }
    }
  }
  return rgba;
}

// ---------------------------------------------------------------------------

mkdirSync(OUT_DIR, { recursive: true });
for (const size of SIZES) {
  const png = encodePng(size, size, renderIcon(size));
  const file = join(OUT_DIR, `icon${size}.png`);
  writeFileSync(file, png);
  console.log(`wrote ${file} (${png.length} bytes)`);
}
