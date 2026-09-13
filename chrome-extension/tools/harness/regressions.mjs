// Runs the shipped extension scripts with deterministic clocks and browser seams.
// No Chrome profile, extension installation, network, or audio hardware is touched.
// Usage: node chrome-extension/tools/harness/regressions.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { test } from 'node:test';

const source = (name) => readFileSync(new URL('../../' + name, import.meta.url), 'utf8');
const settle = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };

class Clock {
  now = 10000;
  next = 1;
  timers = new Map();
  set = (fn, delay, interval = false) => {
    const id = this.next++;
    this.timers.set(id, { fn, at: this.now + delay, interval: interval ? delay : 0 });
    return id;
  };
  clear = (id) => this.timers.delete(id);
  async advance(ms) {
    const end = this.now + ms;
    for (;;) {
      const next = [...this.timers].filter(([, t]) => t.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
      if (!next) break;
      const [id, timer] = next;
      this.now = timer.at;
      if (timer.interval) timer.at += timer.interval; else this.timers.delete(id);
      timer.fn();
      await settle();
    }
    this.now = end;
    await settle();
  }
  globals() {
    const clock = this;
    return {
      Date: class extends Date { static now() { return clock.now; } },
      performance: { now: () => this.now },
      setTimeout: this.set, clearTimeout: this.clear,
      setInterval: (fn, ms) => this.set(fn, ms, true), clearInterval: this.clear,
    };
  }
}

const event = () => ({ handlers: [], addListener(fn) { this.handlers.push(fn); } });
function worker() {
  const clock = new Clock();
  const calls = [];
  const pendingCuts = [];
  let holdCuts = false;
  let appReply = { app: 'DALI', streaming: true, delayMs: 900 };
  const localStorage = {};
  let reloads = 0;
  const runtime = { onMessage: event(), onInstalled: event(), onStartup: event(), onConnect: event(), getManifest: () => ({ version: '1.1.0' }), reload: () => { reloads++; } };
  const injections = [];
  const tabs = [{ id: 1 }, { id: 2 }, { id: 3 }];
  const context = vm.createContext({
    ...clock.globals(), console: { log() {} }, AbortController,
    chrome: { runtime, storage: { local: { get: async defaults => ({ ...defaults, ...localStorage }), set: async values => Object.assign(localStorage, values) }, onChanged: event() },
      tabs: { onRemoved: event(), query: async () => tabs },
      scripting: { executeScript: async (args) => { injections.push(args); if (args.target.tabId === 2) throw new Error('restricted page'); } } },
    fetch: async (url) => {
      const path = new URL(url).pathname;
      if (path !== '/') calls.push({ path, at: clock.now });
      if (path === '/cut' && holdCuts) await new Promise((resolve) => pendingCuts.push(resolve));
      return { ok: true, json: async () => appReply };
    },
  });
  context.self = context;
  context.importScripts = (file) => vm.runInContext(source(file), context);
  vm.runInContext(source('background.js'), context);
  return {
    clock, calls, pendingCuts, runtime, injections, holdCuts: () => { holdCuts = true; },
    appReply: patch => { appReply = { ...appReply, ...patch }; },
    get reloads() { return reloads; }, localStorage,
    async message(msg, tab = 1) {
      for (const fn of runtime.onMessage.handlers) fn(msg, { tab: { id: tab }, frameId: 0 }, () => {});
      await settle();
    },
    async status() { await vm.runInContext('readBeacon()', context); },
  };
}

class Target {
  handlers = new Map();
  addEventListener(name, fn) { if (!this.handlers.has(name)) this.handlers.set(name, []); this.handlers.get(name).push(fn); }
  removeEventListener(name, fn) { this.handlers.set(name, (this.handlers.get(name) || []).filter((f) => f !== fn)); }
  dispatch(name, target = this) { for (const fn of this.handlers.get(name) || []) fn({ type: name, target }); }
}

function content({ host = 'www.youtube.com' } = {}) {
  const clock = new Clock();
  const parent = { isConnected: true };
  const makeVideo = (overrides = {}) => Object.assign(new Target(), {
    tagName: 'VIDEO', nodeName: 'VIDEO', isConnected: true, parentElement: parent,
    paused: false, ended: false, seeking: false, readyState: 4, videoWidth: 1280, videoHeight: 720,
    currentTime: 20, duration: 200, playbackRate: 1, muted: false, volume: 1,
    style: { visibility: '' }, attrs: new Map(),
    rect: { width: 640, height: 360, left: 0, top: 0 },
    getBoundingClientRect() { return this.rect; },
    setAttribute(name, value) { this.attrs.set(name, value); }, removeAttribute(name) { this.attrs.delete(name); },
    getAttribute(name) { return this.attrs.get(name) ?? null; }, hasAttribute(name) { return this.attrs.has(name); },
    requestVideoFrameCallback: () => 1, cancelVideoFrameCallback() {},
    insertAdjacentElement(_position, canvas) { canvas.isConnected = true; },
  }, overrides);
  const video = makeVideo();
  const videos = [video];
  const document = Object.assign(new Target(), {
    visibilityState: 'visible', documentElement: {},
    querySelectorAll(selector) {
      if (selector === 'video' || selector === 'video, audio') return videos;
      if (selector === 'video[data-dali-sync-hidden]') return videos.filter(v => v.hasAttribute('data-dali-sync-hidden'));
      return [];
    },
    createElement: () => ({
      style: {}, width: 640, height: 360, isConnected: true, offsetParent: null,
      getContext: () => ({ clearRect() {}, drawImage() {} }), remove() { this.isConnected = false; },
    }),
  });
  const window = Object.assign(new Target(), { devicePixelRatio: 1, scrollX: 0, scrollY: 0, innerWidth: 1280, innerHeight: 900 });
  const messages = [];
  const ports = [];
  const runtime = {
    id: 'test',
    sendMessage: async (msg) => { messages.push(msg); return { running: true, streaming: true, delayMs: 900 }; },
    connect: () => {
      const port = { onDisconnect: event(), disconnected: false, disconnect() { this.disconnected = true; } };
      ports.push(port);
      return port;
    },
  };
  let captureError = null;
  let holdCapture = false;
  const pendingCaptures = [];
  const bitmaps = [];
  const context = vm.createContext({
    ...clock.globals(), console, document, window, location: { hostname: host, href: 'https://' + host + '/watch?v=test' },
    requestAnimationFrame: () => 1, cancelAnimationFrame() {},
    MutationObserver: class { observe() {} disconnect() {} }, ResizeObserver: class { observe() {} disconnect() {} },
    getComputedStyle: (el) => ({ zIndex: 'auto', objectFit: 'contain', borderRadius: '0px', display: 'block', visibility: el.style?.visibility || 'visible', opacity: '1', ...el.computed }),
    createImageBitmap: async () => {
      if (captureError) { const e = captureError; captureError = null; throw e; }
      if (holdCapture) await new Promise(resolve => pendingCaptures.push(resolve));
      const bitmap = { width: 640, height: 360, closed: false, close() { this.closed = true; } };
      bitmaps.push(bitmap);
      return bitmap;
    },
    chrome: {
      runtime,
      storage: { local: { get: async () => ({}) }, onChanged: event() },
    },
  });
  vm.runInContext(source('content.js'), context);
  window.__daliSync.applyStatus({ running: true, streaming: true, delayMs: 900 });
  window.__daliSync.evaluate();
  return {
    clock, video, videos, makeVideo, document, window, messages, runtime, ports, api: window.__daliSync,
    bitmaps, pendingCaptures, holdCapture: () => { holdCapture = true; },
    reinject: (script = source('content.js')) => vm.runInContext(script, context),
    failCapture: (name) => { captureError = Object.assign(new Error(name), { name }); },
    async capture() { window.__daliSync.S.pipeline.capture(); await settle(); },
    media(name, target = video) { document.dispatch(name, target); target.dispatch(name); },
  };
}

function disconnectWithCacheError(runtime, port) {
  let reads = 0;
  Object.defineProperty(runtime, 'lastError', { configurable: true, get() {
    reads++;
    return { message: 'The page keeping the extension port is moved into back/forward cache, so the message channel is closed.' };
  } });
  for (const fn of port.onDisconnect.handlers) fn(port);
  delete runtime.lastError;
  assert.ok(reads > 0, 'disconnect must consume the callback-scoped lastError even with debug logging off');
}

test('worker handles a cached-page port closure without an unchecked error', () => {
  const w = worker();
  const port = { name: 'dali-sync', sender: {}, onDisconnect: event() };
  for (const fn of w.runtime.onConnect.handlers) fn(port);
  disconnectWithCacheError(w.runtime, port);
});

test('content handles port closure and reconnects without replacing its video pipeline', async () => {
  const c = content();
  const pipeline = c.api.S.pipeline;
  disconnectWithCacheError(c.runtime, c.ports[0]);
  assert.equal(c.api.S.port, null);
  await c.clock.advance(1000);
  assert.equal(c.ports.length, 2);
  assert.equal(c.api.S.pipeline, pipeline);
});

test('returning from the page cache restores sync with a fresh port and pipeline', async () => {
  const c = content();
  const pipeline = c.api.S.pipeline;
  c.window.dispatch('pagehide');
  assert.equal(c.ports[0].disconnected, true);
  assert.equal(c.api.S.pipeline, null);
  c.window.dispatch('pageshow');
  await c.clock.advance(1000);
  assert.ok(c.api.S.pipeline);
  assert.notEqual(c.api.S.pipeline, pipeline);
  assert.equal(c.ports.length, 2);
});

test('a paused YouTube tab must not silence a room that was already playing Mac audio', async () => {
  const w = worker();
  await w.status();
  await w.message({ type: 'playstate', playing: false });
  await w.clock.advance(2000);
  assert.equal(w.calls.some((c) => c.path === '/cut'), false);
});

test('a throttled or vanished playing tab must not be treated as an explicit pause', async () => {
  const w = worker();
  await w.status();
  await w.message({ type: 'playstate', playing: true });
  await w.clock.advance(5000);
  await w.status();
  await w.clock.advance(3200);
  assert.equal(w.calls.some((c) => c.path === '/cut'), false);
});

test('a real pause cuts buffered sound but expires without muting unrelated audio forever', async () => {
  const w = worker();
  await w.status();
  await w.message({ type: 'playstate', playing: true });
  await w.message({ type: 'playstate', playing: false });
  await w.clock.advance(200);
  assert.equal(w.calls.some((c) => c.path === '/cut'), true);
  for (let i = 0; i < 5; i++) {
    await w.status();
    await w.message({ type: 'playstate', playing: false });
    await w.clock.advance(1000);
  }
  assert.equal(w.calls.at(-1).path, '/resume');
  assert.equal(w.calls.some((c) => c.path === '/cut' && c.at > 12000), false);
});

test('a slow cut cannot arrive after the resume that should cancel it', async () => {
  const w = worker();
  await w.status();
  await w.message({ type: 'playstate', playing: true });
  w.holdCuts();
  await w.message({ type: 'playstate', playing: false });
  await w.clock.advance(200);
  await w.message({ type: 'playstate', playing: true });
  assert.notEqual(w.calls.at(-1).path, '/resume', 'resume must wait for the already-sent cut');
  w.pendingCuts.shift()();
  await settle();
  assert.equal(w.calls.at(-1).path, '/resume');
});

test('YouTube buffering is still playback intent and must not request a room cut', async () => {
  const c = content();
  await c.clock.advance(1000);
  c.video.readyState = 1;
  c.media('playing');
  assert.equal(c.messages.filter((m) => m.type === 'playstate').at(-1).playing, true);
});

test('transient ImageBitmap readiness failure recovers on the next decoded frame', async () => {
  const c = content();
  for (let i = 0; i < 5; i++) {
    c.failCapture('InvalidStateError');
    await c.capture();
    await c.clock.advance(100);
    assert.ok(c.api.S.pipeline, 'a temporary decode race must not blacklist the video');
  }
  assert.ok(c.api.S.pipeline, 'a temporary decode race must not blacklist the video');
  await c.capture();
  assert.equal(c.api.S.pipeline.armed, true);
});

test('a new YouTube source clears capture failure on the reused video element', async () => {
  const c = content();
  c.failCapture('SecurityError');
  await c.capture();
  assert.equal(c.api.S.pipeline, null);
  c.media('emptied');
  c.media('loadstart');
  c.api.evaluate();
  assert.ok(c.api.S.pipeline, 'a failed ad source must not disable sync on the following video');
  await c.capture();
  assert.equal(c.api.S.pipeline.armed, true);
});

test('a long network rebuffer does not spend the self-heal budget or disable syncing', async () => {
  const c = content();
  await c.capture();
  const initial = c.api.S.pipeline;
  c.video.readyState = 2;
  await c.clock.advance(20000);
  assert.ok(c.api.S.pipeline === initial, 'network buffering must keep the same pipeline');
  assert.equal(c.api.S.rebuilds.get(c.video) || 0, 0);
});

test('pausing one tab while another plays never cuts either audio stream', async () => {
  const w = worker();
  await w.status();
  await w.message({ type: 'playstate', playing: true }, 1);
  await w.message({ type: 'playstate', playing: true }, 2);
  await w.message({ type: 'playstate', playing: false }, 1);
  await w.clock.advance(2000);
  assert.equal(w.calls.some((c) => c.path === '/cut'), false);
});

test('a quick pause/play inside the grace period sends no audio commands', async () => {
  const w = worker();
  await w.status();
  await w.message({ type: 'playstate', playing: true });
  await w.message({ type: 'playstate', playing: false });
  await w.clock.advance(60);
  await w.message({ type: 'playstate', playing: true });
  await w.clock.advance(1000);
  assert.equal(w.calls.length, 0);
});

test('navigating away is unknown playback state, not permission to mute the Mac', async () => {
  const w = worker();
  await w.status();
  await w.message({ type: 'playstate', playing: true });
  await w.message({ type: 'playstate', playing: false, gone: true });
  await w.clock.advance(2000);
  assert.equal(w.calls.some((c) => c.path === '/cut'), false);
});

test('a genuinely dead draw loop is still rebuilt when the source keeps advancing', async () => {
  const c = content();
  await c.capture();
  const initial = c.api.S.pipeline;
  for (let i = 0; i < 6; i++) {
    c.video.currentTime++;
    await c.clock.advance(1000);
  }
  assert.ok(c.api.S.pipeline !== initial, 'moving video with no presented frames must still self-heal');
  assert.equal(c.api.S.rebuilds.get(c.video), 1);
});

for (const host of ['www.youtube.com', 'www.tiktok.com', 'www.instagram.com']) {
  test(`${host}: swiping the feed selects the visible video instead of a larger offscreen player`, async () => {
    const c = content({ host });
    await c.capture();
    const old = c.api.S.pipeline;
    c.video.rect.top = -1000;
    const next = c.makeVideo({ rect: { width: 360, height: 640, left: 100, top: 0 } });
    c.videos.push(next);
    c.window.dispatch('scroll');
    await c.clock.advance(150);
    assert.equal(c.api.S.pipeline?.video, next);
    assert.equal(old.detached, true);
    assert.equal(c.video.style.visibility, '');
    assert.ok(c.bitmaps.every(b => b.closed), 'old feed frames must be released');
  });
}

test('a CSS-hidden player cannot win selection over the visible feed item', () => {
  const c = content();
  c.video.computed = { opacity: '0' };
  const next = c.makeVideo({ rect: { width: 320, height: 400, left: 10, top: 0 } });
  c.videos.push(next);
  c.api.evaluate();
  assert.equal(c.api.S.pipeline?.video, next);
});

test('scrolling the only video out of view releases its overlay and frame memory', async () => {
  const c = content();
  await c.capture();
  c.video.rect.top = 2000;
  c.window.dispatch('scroll');
  await c.clock.advance(150);
  assert.equal(c.api.S.pipeline, null);
  assert.equal(c.video.style.visibility, '');
  assert.ok(c.bitmaps.every(b => b.closed));
});

test('a newer content build replaces a live older build without needing a page refresh', async () => {
  const c = content();
  await c.capture();
  const old = c.api.S.pipeline;
  c.reinject(source('content.js').replace(/const BUILD = '[^']+';/, "const BUILD = 'regression-next';"));
  assert.equal(old.detached, true);
  assert.equal(c.window.__daliVideoSync.build, 'regression-next');
  assert.equal(c.video.style.visibility, '');
});

test('duplicate injection of the current build preserves the running pipeline', () => {
  const c = content();
  const old = c.api.S.pipeline;
  c.reinject();
  assert.equal(c.window.__daliSync.S.pipeline, old);
  assert.equal(old.detached, false);
});

test('a page cached during an outstanding beacon request stays inactive until pageshow', async () => {
  const c = content();
  c.window.dispatch('pagehide');
  await c.clock.advance(2000);
  assert.equal(c.api.S.pipeline, null);
  assert.equal(c.api.S.ticking, false);
  c.window.dispatch('pageshow');
  await c.clock.advance(150);
  assert.ok(c.api.S.pipeline);
});

test('teardown discards an in-flight decoded frame without hiding the restored video', async () => {
  const c = content();
  c.holdCapture();
  c.api.S.pipeline.capture();
  c.api.teardownAll('test-update');
  c.pendingCaptures.shift()();
  await settle();
  assert.equal(c.api.S.pipeline, null);
  assert.equal(c.video.style.visibility, '');
  assert.ok(c.bitmaps.every(b => b.closed));
});

test('browser startup reinjects open tabs and one restricted tab does not block the rest', async () => {
  const w = worker();
  for (const fn of w.runtime.onStartup.handlers) fn();
  await settle();
  assert.deepEqual(w.injections.map(x => x.target.tabId), [1, 2, 3]);
  assert.ok(w.injections.every(x => x.target.allFrames && x.files[0] === 'content.js'));
});

test('extension update reinjects open tabs including iframe players', async () => {
  const w = worker();
  for (const fn of w.runtime.onInstalled.handlers) fn({ reason: 'update' });
  await settle();
  assert.deepEqual(w.injections.map(x => x.target.tabId), [1, 2, 3]);
});

test('teardown restores the original inline video visibility', async () => {
  const c = content();
  c.video.style.visibility = 'visible';
  await c.capture();
  assert.equal(c.video.style.visibility, 'hidden');
  c.api.teardownAll('update');
  assert.equal(c.video.style.visibility, 'visible');
});

function beacon() {
  const clock = new Clock();
  const context = vm.createContext({ ...clock.globals(), AbortController });
  context.self = context;
  vm.runInContext(source('beacon.js'), context);
  return { clock, api: context.DALIBeacon };
}

test('beacon accepts legacy app replies and compatible protocol additions', () => {
  const { api } = beacon();
  for (const extra of [{}, { protocolVersion: 1, appVersion: '2.0', capabilities: ['video-sync'] }]) {
    const st = api.normalize({ app: 'DALI', streaming: true, delayMs: 942, ...extra });
    assert.equal(st.running, true);
    assert.equal(st.streaming, true);
    assert.equal(st.delayMs, 942);
  }
});

test('beacon refuses unsupported protocol versions instead of applying a guessed delay', () => {
  const { api } = beacon();
  for (const protocolVersion of [2, '1', null, -1, {}]) {
    assert.equal(api.normalize({ app: 'DALI', streaming: true, delayMs: 942, protocolVersion }).streaming, false);
  }
});

test('beacon requests identify the extension for the local app security boundary', async () => {
  const { api } = beacon();
  const requests = [];
  const fetcher = async (url, options) => {
    requests.push({ url, options });
    return { ok: true, json: async () => ({ app: 'DALI', streaming: true, delayMs: 900 }) };
  };
  await api.fetchStatus(fetcher);
  await api.signal('cut', fetcher);
  assert.equal(requests.length, 2);
  assert.ok(requests.every(r => r.options.headers?.['X-DALI-Client'] === 'chrome-extension'));
  assert.ok(requests.every(r => r.options.credentials === 'omit'));
});

test('a rejected app command is reported as failed', async () => {
  const { api } = beacon();
  assert.equal(await api.signal('cut', async () => ({ ok: false, status: 403 })), false);
});

test('the beacon deadline includes a stalled JSON response body', async () => {
  const { api, clock } = beacon();
  let aborted = false;
  const pending = api.fetchStatus(async (_url, options) => ({
    ok: true,
    json: () => new Promise((_resolve, reject) => options.signal.addEventListener('abort', () => {
      aborted = true;
      reject(new Error('body timeout'));
    })),
  }));
  await settle();
  await clock.advance(800);
  assert.equal(aborted, true);
  assert.equal((await pending).running, false);
});

test('managed extension updates reload once after a newer version is installed by the app', async () => {
  const w = worker();
  w.appReply({ extensionVersion: '1.2.0' });
  await w.status();
  await settle();
  assert.equal(w.reloads, 1);
  assert.equal(w.localStorage.managedExtensionReloadAttempt, '1.2.0');
  for (let i = 0; i < 3; i++) {
    await w.clock.advance(1000);
    await w.status();
  }
  assert.equal(w.reloads, 1, 'unmanaged old files must not cause a reload loop');
  w.appReply({ extensionVersion: '1.1.1' });
  await w.clock.advance(1000);
  await w.status();
  assert.equal(w.reloads, 1, 'an older attempted target must not restart the loop');
  w.appReply({ extensionVersion: '1.10.0' });
  await w.clock.advance(1000);
  await w.status();
  await settle();
  assert.equal(w.reloads, 2, 'numeric minor-version comparison must allow the next update');
});

test('matching, older, malformed and absent advertised versions leave Chrome running', async () => {
  for (const extensionVersion of ['1.1.0', '1.1', '1.0.9', '', 'next', '1.2beta', '999999', undefined]) {
    const w = worker();
    w.appReply({ extensionVersion });
    await w.status();
    await settle();
    assert.equal(w.reloads, 0, String(extensionVersion));
  }
});

test('a paused offscreen or unsynced video cannot request a room audio cut', async () => {
  const w = worker();
  await w.status();
  await w.message({ type: 'playstate', playing: true, cutEligible: false });
  await w.message({ type: 'playstate', playing: false, cutEligible: false });
  await w.clock.advance(2000);
  assert.equal(w.calls.some(c => c.path === '/cut'), false);
});

test('a muted feed preview is never eligible for a room-wide pause cut', async () => {
  const c = content({ host: 'www.instagram.com' });
  c.video.muted = true;
  await c.capture();
  await c.clock.advance(1000);
  assert.equal(c.messages.filter(m => m.type === 'playstate').at(-1).cutEligible, false);
});

for (const delayMs of [300, 900, 2000]) {
  test(`decoded-frame presentation follows the ${delayMs}ms beacon without changing source playback`, async () => {
    const c = content();
    await settle();
    c.runtime.sendMessage = async () => ({ running: true, streaming: true, delayMs });
    c.api.applyStatus({ running: true, streaming: true, delayMs });
    c.media('play');
    const p = c.api.S.pipeline;
    for (let i = 0; i < Math.ceil((delayMs + 1000) / 34); i++) {
      c.video.currentTime += .034;
      await c.clock.advance(34);
      await c.capture();
      p.drawTick();
    }
    assert.ok(p.current, 'a delayed frame is presented');
    assert.ok(Math.abs((c.clock.now - p.current.t) - delayMs) <= 35,
      `presentation stays within one captured frame: target=${delayMs}, actual=${c.clock.now - p.current.t}, effective=${p.eff}, active=${c.api.activeDelayMs()}`);
    assert.equal(c.video.playbackRate, 1);
    assert.equal(c.video.paused, false);
    assert.ok(p.bufferBytes <= 256 * 1024 * 1024);
  });
}

test('YouTube seek and a reused Instagram source discard stale decoded frames', async () => {
  const c = content({ host: 'www.instagram.com' });
  await c.capture();
  c.video.currentTime += 20;
  c.media('seeking');
  assert.equal(c.api.S.pipeline.armed, false);
  assert.ok(c.bitmaps.every(b => b.closed));
  await c.capture();
  c.media('loadstart');
  assert.equal(c.api.S.pipeline.armed, false);
  assert.ok(c.bitmaps.every(b => b.closed));
});

test('the app can stop and restart while the same page stays open', async () => {
  const c = content();
  await c.capture();
  c.api.applyStatus({ running: false, streaming: false, delayMs: 0 });
  c.api.evaluate();
  assert.equal(c.api.S.pipeline, null);
  assert.equal(c.video.style.visibility, '');
  c.api.applyStatus({ running: true, streaming: true, delayMs: 1200 });
  c.api.evaluate();
  await c.capture();
  assert.equal(c.api.S.pipeline.armed, true);
  assert.equal(c.api.activeDelayMs(), 1200);
});

test('release identity and bundled entrypoints stay consistent across app updates', () => {
  const manifest = JSON.parse(source('manifest.json'));
  const contentScript = source('content.js');
  const workerScript = source(manifest.background.service_worker);
  assert.equal(contentScript.match(/const VERSION = '([^']+)'/)[1], manifest.version);
  assert.equal(contentScript.match(/const BUILD = '([^']+)'/)[1], workerScript.match(/const BUILD = '([^']+)'/)[1]);
  for (const group of manifest.content_scripts) {
    for (const file of group.js) assert.ok(source(file).length > 0);
  }
  for (const match of workerScript.matchAll(/importScripts\('([^']+)'\)/g)) assert.ok(source(match[1]).length > 0);
  assert.equal(manifest.content_scripts[0].all_frames, true);
  assert.equal(manifest.content_scripts[0].match_about_blank, true);
});
