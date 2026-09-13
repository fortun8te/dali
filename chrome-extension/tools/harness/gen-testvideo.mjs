// Emit rawvideo rgb24 frames: solid colour encodes frame index mod 256,
// plus a big block-digit readout of the absolute frame index.
const W = 640, H = 360, FPS = 30, SECS = 180;
const total = FPS * SECS;
const GLYPH = {
 '0':['111','101','101','101','111'], '1':['010','010','010','010','010'],
 '2':['111','001','111','100','111'], '3':['111','001','111','001','111'],
 '4':['101','101','111','001','001'], '5':['111','100','111','001','111'],
 '6':['111','100','111','101','111'], '7':['111','001','001','001','001'],
 '8':['111','101','111','101','111'], '9':['111','101','111','001','111']
};
const SC = 12;               // pixel scale of a glyph cell
const GY = 250;              // top of the digit band (below the sample area)
function putDigit(buf, ch, ox) {
  const g = GLYPH[ch]; if (!g) return;
  for (let ry = 0; ry < 5; ry++) for (let rx = 0; rx < 3; rx++) {
    if (g[ry][rx] !== '1') continue;
    for (let y = 0; y < SC; y++) for (let x = 0; x < SC; x++) {
      const px = ox + rx * SC + x, py = GY + ry * SC + y;
      if (px < 0 || px >= W || py < 0 || py >= H) continue;
      const o = (py * W + px) * 3;
      buf[o] = 255; buf[o+1] = 255; buf[o+2] = 255;
    }
  }
}
for (let i = 0; i < total; i++) {
  const r = (i % 16) * 16 + 8;
  const g = (Math.floor(i / 16) % 16) * 16 + 8;
  const b = 128;
  const buf = Buffer.alloc(W * H * 3);
  for (let p = 0; p < W * H; p++) { buf[p*3] = r; buf[p*3+1] = g; buf[p*3+2] = b; }
  const s = String(i);
  let ox = Math.round((W - s.length * 4 * SC) / 2);
  for (const ch of s) { putDigit(buf, ch, ox); ox += 4 * SC; }
  if (!process.stdout.write(buf)) await new Promise(res => process.stdout.once('drain', res));
}
