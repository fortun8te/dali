#!/bin/bash
# Render Assets/AppIcon.svg to Assets/AppIcon.iconset/*.png and Assets/AppIcon.icns.
# SVG filters need a real browser: drives headless Chrome for Testing (own disposable
# profile, never the personal Chrome) over DevTools to capture a transparent 1024 master.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${CHROME:-}" || ! -x "$CHROME" ]]; then
  echo "Set CHROME to the Chrome for Testing executable." >&2
  exit 1
fi
export CHROME
SET="$ROOT/Assets/AppIcon.iconset"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SVG="$ROOT/Assets/AppIcon.svg" PROFILE="$TMP/profile" MASTER="$TMP/master.png"
mkdir -p "$SET"
node - <<'JS'
const { spawn } = require('child_process');
const fs = require('fs');
const sleep = ms => new Promise(r => setTimeout(r, ms));
(async () => {
  const chrome = spawn(process.env.CHROME, ['--headless=new', '--disable-gpu', '--no-first-run',
    '--disable-background-networking', '--hide-scrollbars', '--remote-debugging-port=0',
    '--default-background-color=00000000', '--force-device-scale-factor=1',
    `--user-data-dir=${process.env.PROFILE}`, 'about:blank'], { stdio: 'ignore' });
  try {
    const portFile = `${process.env.PROFILE}/DevToolsActivePort`;
    for (let i = 0; i < 100 && !fs.existsSync(portFile); i++) await sleep(100);
    const [port, path] = fs.readFileSync(portFile, 'utf8').trim().split('\n');
    const ws = new WebSocket(`ws://127.0.0.1:${port}${path}`);
    await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
    let id = 0; const pending = new Map();
    ws.onmessage = m => { const d = JSON.parse(m.data); if (d.id && pending.has(d.id)) pending.get(d.id)(d); };
    const send = (method, params = {}, sessionId) => new Promise(res => {
      const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method, params, sessionId }));
    });
    const { result: { targetId } } = await send('Target.createTarget', { url: 'about:blank' });
    const { result: { sessionId } } = await send('Target.attachToTarget', { targetId, flatten: true });
    await send('Emulation.setDeviceMetricsOverride', { width: 1024, height: 1024, deviceScaleFactor: 1, mobile: false }, sessionId);
    await send('Emulation.setDefaultBackgroundColorOverride', { color: { r: 0, g: 0, b: 0, a: 0 } }, sessionId);
    await send('Page.enable', {}, sessionId);
    await send('Page.navigate', { url: 'file://' + process.env.SVG }, sessionId);
    await sleep(2500);
    const shot = await send('Page.captureScreenshot', { format: 'png', fromSurface: true,
      clip: { x: 0, y: 0, width: 1024, height: 1024, scale: 1 } }, sessionId);
    fs.writeFileSync(process.env.MASTER, Buffer.from(shot.result.data, 'base64'));
    ws.close();
  } finally { chrome.kill(); }
  process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
JS
python3 - "$MASTER" "$SET" <<'PY'
import sys, cv2, numpy as np
src = cv2.imread(sys.argv[1], cv2.IMREAD_UNCHANGED)
assert src.shape == (1024, 1024, 4), src.shape
f = src.astype(np.float32) / 255.0
f[..., :3] *= f[..., 3:4]                      # premultiply, then area-downsample
sizes = {"16x16": 16, "16x16@2x": 32, "32x32": 32, "32x32@2x": 64,
         "128x128": 128, "128x128@2x": 256, "256x256": 256, "256x256@2x": 512,
         "512x512": 512, "512x512@2x": 1024}
for name, px in sizes.items():
    o = f if px == 1024 else cv2.resize(f, (px, px), interpolation=cv2.INTER_AREA)
    a = o[..., 3:4]
    rgb = np.where(a > 1e-6, o[..., :3] / np.maximum(a, 1e-6), 0)
    out = np.concatenate([np.clip(rgb, 0, 1), a], axis=2)
    cv2.imwrite(f"{sys.argv[2]}/icon_{name}.png", np.round(out * 255).astype(np.uint8))
PY
iconutil -c icns "$SET" -o "$ROOT/Assets/AppIcon.icns"
echo "Rendered $SET and Assets/AppIcon.icns"
