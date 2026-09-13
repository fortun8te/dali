// Headless driver for the harness. No dependencies: it launches Chrome with
// the DevTools protocol on a throwaway profile, opens index.html, calls
// window.__runSuite() and prints the transcript.
//
//   node drive.mjs [--url URL] [--timeout SEC] [--keep] [--head]
//   node drive.mjs --probe FILE.js     # run one script on the loaded harness
//                                      # page instead of the suite, print its
//                                      # (awaited) result as JSON
//
// Exit code 0 only if every assertion passed.

import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, existsSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const args = process.argv.slice(2);
function arg(name, dflt) {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : dflt;
}
const URL_ = arg('--url', 'http://127.0.0.1:8777/index.html');
const TIMEOUT_S = Number(arg('--timeout', '420'));
const KEEP = args.includes('--keep');
const HEAD = args.includes('--head');

const CHROME = process.env.DALI_CHROME ||
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
if (!existsSync(CHROME)) {
  console.error('chrome not found at ' + CHROME + ' (set DALI_CHROME)');
  process.exit(2);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const profile = mkdtempSync(join(tmpdir(), 'dali-harness-'));

const chromeArgs = [
  '--remote-debugging-port=0',
  '--user-data-dir=' + profile,
  '--no-first-run',
  '--no-default-browser-check',
  '--disable-extensions',
  '--autoplay-policy=no-user-gesture-required',
  '--mute-audio',
  '--disable-background-timer-throttling',
  '--disable-backgrounding-occluded-windows',
  '--disable-renderer-backgrounding',
  '--disable-features=CalculateNativeWinOcclusion,MediaRouter',
  '--window-size=1280,900',
  'about:blank'
];
if (!HEAD) chromeArgs.unshift('--headless=new');

const chrome = spawn(CHROME, chromeArgs, { stdio: ['ignore', 'pipe', 'pipe'] });
let chromeErr = '';
chrome.stderr.on('data', (d) => { chromeErr += d.toString(); });

function cleanup() {
  try { chrome.kill('SIGKILL'); } catch (e) { /* ignore */ }
  if (!KEEP) { try { rmSync(profile, { recursive: true, force: true }); } catch (e) { /* ignore */ } }
}
process.on('exit', cleanup);
process.on('SIGINT', () => { cleanup(); process.exit(130); });

async function devtoolsPort() {
  const f = join(profile, 'DevToolsActivePort');
  for (let i = 0; i < 200; i++) {
    if (existsSync(f)) {
      const line = readFileSync(f, 'utf8').split('\n')[0].trim();
      if (line) return Number(line);
    }
    await sleep(100);
  }
  throw new Error('chrome never wrote DevToolsActivePort\n' + chromeErr.slice(-2000));
}

// --- tiny CDP client -------------------------------------------------------
class CDP {
  constructor(ws) {
    this.ws = ws;
    this.id = 0;
    this.waiting = new Map();
    this.onConsole = null;
    ws.addEventListener('message', (ev) => {
      let m;
      try { m = JSON.parse(ev.data); } catch (e) { return; }
      if (m.id && this.waiting.has(m.id)) {
        const { resolve, reject } = this.waiting.get(m.id);
        this.waiting.delete(m.id);
        if (m.error) reject(new Error(m.error.message));
        else resolve(m.result);
      } else if (m.method === 'Runtime.consoleAPICalled' && this.onConsole) {
        this.onConsole(m.params);
      } else if (m.method === 'Runtime.exceptionThrown' && this.onConsole) {
        this.onConsole({ type: 'exception', args: [{ value: m.params.exceptionDetails.text }] });
      }
    });
  }
  send(method, params) {
    const id = ++this.id;
    this.ws.send(JSON.stringify({ id, method, params: params || {} }));
    return new Promise((resolve, reject) => this.waiting.set(id, { resolve, reject }));
  }
  async eval(expr, awaitPromise) {
    const r = await this.send('Runtime.evaluate', {
      expression: expr, returnByValue: true, awaitPromise: !!awaitPromise
    });
    if (r.exceptionDetails) {
      throw new Error('page threw: ' + (r.exceptionDetails.exception
        ? (r.exceptionDetails.exception.description || r.exceptionDetails.exception.value)
        : r.exceptionDetails.text));
    }
    return r.result && r.result.value;
  }
}

function connect(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    ws.addEventListener('open', () => resolve(new CDP(ws)));
    ws.addEventListener('error', (e) => reject(new Error('ws error ' + url)));
  });
}

async function main() {
  const port = await devtoolsPort();
  const res = await fetch('http://127.0.0.1:' + port + '/json/new?' + encodeURIComponent(URL_),
    { method: 'PUT' });
  const target = await res.json();
  const cdp = await connect(target.webSocketDebuggerUrl);

  const consoleLines = [];
  cdp.onConsole = (p) => {
    const text = (p.args || []).map((a) => (a.value !== undefined ? a.value :
      (a.description || a.type))).join(' ');
    consoleLines.push('[' + p.type + '] ' + text);
  };
  await cdp.send('Runtime.enable');
  await cdp.send('Page.enable');

  // Wait for the harness to finish loading (video metadata included).
  let ready = false;
  for (let i = 0; i < 300; i++) {
    try {
      ready = await cdp.eval('!!(window.__runSuite && window.__daliSync && ' +
        'document.getElementById("v").readyState >= 1)');
    } catch (e) { ready = false; }
    if (ready) break;
    await sleep(200);
  }
  if (!ready) throw new Error('harness never became ready\n' + consoleLines.join('\n'));

  const vis = await cdp.eval('document.visibilityState + "/" + document.hidden');
  const rvfc = await cdp.eval('typeof document.getElementById("v").requestVideoFrameCallback');
  process.stderr.write('driver: page visibility=' + vis + ' rVFC=' + rvfc + '\n');

  const probe = arg('--probe', '');
  if (probe) {
    const src = readFileSync(probe, 'utf8');
    const val = await cdp.eval(src, true);
    process.stdout.write(JSON.stringify(val, null, 1) + '\n');
    if (consoleLines.length) process.stderr.write(consoleLines.slice(-25).join('\n') + '\n');
    return 0;
  }

  await cdp.eval('window.__runSuite()');

  const t0 = Date.now();
  let result = null;
  let lastLines = 0;
  while (Date.now() - t0 < TIMEOUT_S * 1000) {
    await sleep(1500);
    result = await cdp.eval('window.__suiteResult || null');
    if (result) break;
    const out = await cdp.eval('window.__out ? window.__out() : ""');
    const lines = out ? out.split('\n') : [];
    if (lines.length > lastLines) {
      process.stderr.write(lines.slice(lastLines).join('\n') + '\n');
      lastLines = lines.length;
    }
  }
  const out = await cdp.eval('window.__out ? window.__out() : ""');
  process.stdout.write(out + '\n');

  if (!result) {
    process.stdout.write('\nTIMEOUT after ' + TIMEOUT_S + 's\n');
    if (consoleLines.length) process.stdout.write(consoleLines.slice(-40).join('\n') + '\n');
    return 3;
  }
  const errs = consoleLines.filter((l) => l.startsWith('[error]') || l.startsWith('[exception]'));
  if (errs.length) {
    process.stdout.write('\npage errors:\n' + errs.slice(0, 20).join('\n') + '\n');
  }
  return result.fail === 0 && result.pass > 0 ? 0 : 1;
}

main().then((code) => { cleanup(); process.exit(code); },
  (e) => { console.error(e && e.stack || String(e)); cleanup(); process.exit(2); });
