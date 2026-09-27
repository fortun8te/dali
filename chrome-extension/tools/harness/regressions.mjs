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
  const urls = [];
  const pendingCuts = [];
  let holdCuts = false;
  let beaconFailure = false;
  let appReply = { app: 'DALI', streaming: true, delayMs: 900 };
  const localStorage = {};
  let reloads = 0;
  const runtime = { onMessage: event(), onInstalled: event(), onStartup: event(), onConnect: event(), getManifest: () => ({ version: '1.2.0' }), reload: () => { reloads++; } };
  const injections = [];
  const tabs = [{ id: 1 }, { id: 2 }, { id: 3 }];
  const context = vm.createContext({
    ...clock.globals(), console: { log() {} }, AbortController,
    chrome: { runtime, storage: { local: { get: async defaults => ({ ...defaults, ...localStorage }), set: async values => Object.assign(localStorage, values) }, onChanged: event() },
      tabs: { onRemoved: event(), query: async () => tabs },
      scripting: { executeScript: async (args) => { injections.push(args); if (args.target.tabId === 2) throw new Error('restricted page'); } } },
    fetch: async (url) => {
      const path = new URL(url).pathname;
      urls.push(url);
      if (path !== '/') calls.push({ path, at: clock.now });
      if (path === '/' && beaconFailure) throw new Error('beacon timeout');
      if (path === '/cut' && holdCuts) await new Promise((resolve) => pendingCuts.push(resolve));
      return { ok: true, json: async () => appReply };
    },
  });
  context.self = context;
  context.importScripts = (file) => vm.runInContext(source(file), context);
  vm.runInContext(source('background.js'), context);
  return {
    clock, calls, urls, pendingCuts, runtime, injections, holdCuts: () => { holdCuts = true; },
    appReply: patch => { appReply = { ...appReply, ...patch }; },
    failBeacon: value => { beaconFailure = value; },
    get reloads() { return reloads; }, localStorage,
    async message(msg, tab = 1) {
      for (const fn of runtime.onMessage.handlers) fn(msg, { tab: { id: tab }, frameId: 0 }, () => {});
      await settle();
    },
    async status() { return await vm.runInContext('readBeacon()', context); },
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
  let canvasesCreated = 0;
  const document = Object.assign(new Target(), {
    visibilityState: 'visible', documentElement: {},
    querySelectorAll(selector) {
      if (selector === 'video' || selector === 'video, audio') return videos;
      if (selector === 'video[data-dali-sync-hidden]') return videos.filter(v => v.hasAttribute('data-dali-sync-hidden'));
      return [];
    },
    createElement: () => (canvasesCreated++, {
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
    get canvasesCreated() { return canvasesCreated; },
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

for (const host of ['www.youtube.com', 'www.tiktok.com', 'feed.example.com']) {
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
  assert.equal(aborted, false, 'status polling tolerates transient browser scheduling delays');
  await clock.advance(4300);
  assert.equal(aborted, true);
  assert.equal((await pending).running, false);
});

test('managed extension updates reload once after a newer version is installed by the app', async () => {
  const w = worker();
  w.appReply({ bundledExtensionVersion: '1.3.0' });
  await w.status();
  await settle();
  assert.equal(w.reloads, 1);
  assert.equal(w.localStorage.managedExtensionReloadAttempt, '1.3.0');
  for (let i = 0; i < 3; i++) {
    await w.clock.advance(1000);
    await w.status();
  }
  assert.equal(w.reloads, 1, 'unmanaged old files must not cause a reload loop');
  w.appReply({ bundledExtensionVersion: '1.2.1' });
  await w.clock.advance(1000);
  await w.status();
  assert.equal(w.reloads, 1, 'an older attempted target must not restart the loop');
  w.appReply({ bundledExtensionVersion: '1.10.0' });
  await w.clock.advance(1000);
  await w.status();
  await settle();
  assert.equal(w.reloads, 2, 'numeric minor-version comparison must allow the next update');
});

test('matching, older, malformed and absent advertised versions leave Chrome running', async () => {
  for (const bundledExtensionVersion of ['1.2.0', '1.2', '1.1.9', '', 'next', '1.3beta', '999999', undefined]) {
    const w = worker();
    w.appReply({ bundledExtensionVersion });
    await w.status();
    await settle();
    assert.equal(w.reloads, 0, String(bundledExtensionVersion));
  }
});

test('the app echoing our own identity as extensionVersion is never an update offer', async () => {
  for (const extensionVersion of ['1.2.0', '9.9.9']) {
    const w = worker();
    w.appReply({ extensionVersion, bundledExtensionVersion: '' });
    await w.status();
    await settle();
    assert.equal(w.reloads, 0, extensionVersion);
  }
});

test('every request tells the app which extension build is running', async () => {
  const w = worker();
  await w.status();
  await w.message({ type: 'playstate', playing: true, audible: true, cutEligible: true, title: 't', host: 'h' });
  await w.message({ type: 'playstate', playing: false, cutEligible: true });
  await w.clock.advance(300);
  const build = source('background.js').match(/const BUILD = '([^']+)'/)[1];
  assert.ok(w.urls.length >= 3);
  for (const url of w.urls) {
    const q = new URL(url).searchParams;
    assert.equal(q.get('v'), '1.2.0', url);
    assert.equal(q.get('b'), build, url);
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
  const c = content({ host: 'feed.example.com' });
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

test('a seek and a reused feed source discard stale decoded frames', async () => {
  const c = content({ host: 'feed.example.com' });
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

// --- 1.2.0: live streams, every-site discovery, sync accuracy ---------------

async function runFrames(c, ms, { advance = true, step = 33 } = {}) {
  const p = c.api.S.pipeline;
  const errors = [];
  for (let t = 0; t < ms; t += step) {
    if (advance) c.video.currentTime += step / 1000;
    await c.clock.advance(step);
    if (advance) await c.capture();
    p.drawTick();
    if (p.current) errors.push((c.clock.now - p.current.t) - p.eff);
  }
  return errors;
}

test('live stream: picture stays within half a frame of the room across nudges, a stall and a quality switch', async () => {
  const c = content({ host: 'www.twitch.tv' });
  c.video.duration = Infinity;
  await settle();
  c.media('play');
  const p = c.api.S.pipeline;
  // Warm up past the delay, then measure for a minute of live playback.
  await runFrames(c, 1500);
  const all = [];
  for (let second = 0; second < 60; second++) {
    if (second % 7 === 3) {
      // The player holding the live edge: a sub-250 ms self-seek is not a user seek.
      c.video.currentTime += 0.12;
      c.media('seeking', c.video);
      c.media('seeked', c.video);
    }
    if (second === 20) {
      // Quality switch: one undecodable frame, then a new size.
      c.failCapture('InvalidStateError');
      c.video.videoWidth = 1920; c.video.videoHeight = 1080;
      c.media('resize', c.video);
    }
    if (second === 30) {
      // Rebuffer: nothing decodes for 3 s (the Mac's audio stalls with it).
      c.video.readyState = 2;
      await runFrames(c, 3000, { advance: false });
      c.video.readyState = 4;
      await runFrames(c, 1500);       // the room is still `delay` behind; settle
      continue;
    }
    const errs = await runFrames(c, 1000);
    all.push(...errs);
    assert.equal(p.armed, true, 'second ' + second);
  }
  const worst = Math.max(...all.map(Math.abs));
  const offFrame = all.filter(e => Math.abs(e) > 17).length;
  // Half a frame at 30 fps, except right after a frame that failed to decode
  // (the previous picture stays one frame longer): never beyond 40 ms.
  assert.ok(worst <= 40, 'worst live error ' + worst + 'ms');
  assert.ok(offFrame <= 2, offFrame + ' presentations outside ±17 ms');
  assert.equal(c.api.S.pipeline, p, 'no rebuild, no cut on a healthy live stream');
  assert.equal(c.video.playbackRate, 1, 'the player timeline is never touched');
  assert.equal(c.api.S.rebuilds.get(c.video) || 0, 0);
});

test('a longer delay from the app is eased in, never a frozen picture', async () => {
  const c = content();
  await settle();
  c.media('play');
  const p = c.api.S.pipeline;
  await runFrames(c, 2000);
  assert.equal(Math.round(p.eff), 900);
  c.runtime.sendMessage = async () => ({ running: true, streaming: true, delayMs: 1100 });
  c.api.applyStatus({ running: true, streaming: true, delayMs: 1100 });
  const before = p.current.t;
  await runFrames(c, 100);
  assert.ok(p.eff > 900 && p.eff < 1000, 'eff ramps at half speed, got ' + p.eff);
  assert.ok(p.current.t > before, 'the picture keeps moving while the delay grows');
  await runFrames(c, 1000);
  assert.equal(Math.round(p.eff), 1100);
});

test('videos inside open shadow roots are found and their media events heard', async () => {
  const c = content({ host: 'player.example.com' });
  const root = Object.assign(new Target(), {
    querySelectorAll(sel) { return sel === 'video' ? [inner] : []; },
  });
  const inner = c.makeVideo({ rect: { width: 1280, height: 720, left: 0, top: 0 } });
  const host = { shadowRoot: root };
  const base = c.document.querySelectorAll.bind(c.document);
  c.document.querySelectorAll = (sel) => (sel === '*' ? [host] : base(sel));
  c.api.evaluate();
  assert.ok(c.api.allVideos().includes(inner));
  assert.equal((root.handlers.get('pause') || []).length, 1, 'shadow root gets capture listeners');
  const before = c.messages.length;
  inner.paused = true;
  root.dispatch('pause', inner);
  assert.ok(c.messages.length > before, 'a pause inside the shadow root is reported at once');
  c.api.teardownAll('test');
  assert.equal((root.handlers.get('pause') || []).length, 0, 'listeners removed on teardown');
});

test('while DALI is idle the page is untouched and the beacon is asked rarely', async () => {
  const c = content();
  let asks = 0;
  c.runtime.sendMessage = async (msg) => {
    if (msg.type === 'beacon') asks++;
    return { running: true, streaming: false, delayMs: 0 };
  };
  c.api.applyStatus({ running: true, streaming: false, delayMs: 0 });
  c.api.evaluate();
  assert.equal(c.api.S.pipeline, null);
  assert.equal(c.video.style.visibility, '');
  await c.clock.advance(10000);
  assert.ok(asks <= 5, 'idle polling is throttled, asked ' + asks + ' times in 10 s');
  assert.equal(c.api.S.pipeline, null);
});


test('a transient beacon transport failure preserves validated sync for at most ten seconds', async () => {
  const w = worker();
  assert.equal((await w.status()).delayMs, 900);
  w.failBeacon(true);
  await w.clock.advance(1000);
  const brief = await w.status();
  assert.equal(brief.streaming, true, 'one timeout must not detach the video delay');
  assert.equal(brief.delayMs, 900);
  await w.clock.advance(8800);
  assert.equal((await w.status()).streaming, true);
  await w.clock.advance(200);
  assert.equal((await w.status()).running, false, 'cached fallback must expire at ten seconds');
  w.failBeacon(false);
  await w.clock.advance(800);
  assert.equal((await w.status()).streaming, true, 'a recovered app can engage sync again');
});

test('an explicit idle or incompatible app reply overrides transient grace immediately', async () => {
  const w = worker();
  await w.status();
  w.failBeacon(true);
  await w.clock.advance(800);
  await w.status();
  w.failBeacon(false);
  w.appReply({ streaming: false });
  await w.clock.advance(800);
  assert.equal((await w.status()).streaming, false);
  w.failBeacon(true);
  await w.clock.advance(800);
  assert.equal((await w.status()).streaming, false, 'idle state must never revive old streaming state');
  w.failBeacon(false);
  w.appReply({ streaming: true, protocolVersion: 2 });
  await w.clock.advance(800);
  assert.equal((await w.status()).running, false);
});


for (const host of ['instagram.com', 'www.instagram.com', 'reels.instagram.com']) {
  test(`${host}: leave Reels untouched while continuing audio playback reports`, async () => {
    const c = content({ host });
    c.media('play');
    await c.clock.advance(1100);
    assert.equal(c.api.S.pipeline, null);
    assert.equal(c.canvasesCreated, 0, 'never create a delayed-picture overlay');
    assert.equal(c.video.style.visibility, '');
    assert.equal(c.video.hasAttribute('data-dali-sync-hidden'), false);
    const playing = c.messages.filter(m => m.type === 'playstate').at(-1);
    assert.equal(playing.playing, true);
    assert.equal(playing.cutEligible, false);
    assert.equal(playing.held, false);
    const w = worker();
    await w.status();
    await w.message(playing, 2);
    await w.message({ type: 'playstate', playing: true, cutEligible: true }, 1);
    await w.message({ type: 'playstate', playing: false, cutEligible: true }, 1);
    await w.clock.advance(300);
    assert.equal(w.calls.some(x => x.path === '/cut'), false, 'a paused tab must not mute Instagram');
  });
}

test('the Instagram bypass does not match unrelated domains', async () => {
  for (const host of ['fakeinstagram.com', 'instagram.com.example.com']) {
    const c = content({ host });
    await c.capture();
    assert.equal(c.api.S.pipeline.armed, true, host);
    assert.equal(c.video.style.visibility, 'hidden', host);
  }
});


test('audio signals keep a short deadline independent of status polling', async () => {
  const { api, clock } = beacon();
  let aborted = false;
  const pending = api.signal('cut', async (_url, options) => new Promise((_resolve, reject) => {
    options.signal.addEventListener('abort', () => {
      aborted = true;
      reject(new Error('signal timeout'));
    });
  }));
  await settle();
  await clock.advance(699);
  assert.equal(aborted, false);
  await clock.advance(1);
  assert.equal(aborted, true);
  assert.equal(await pending, false);
});


test('a healthy status response may complete its body within the five-second deadline', async () => {
  const { api, clock } = beacon();
  let aborted = false;
  const pending = api.fetchStatus((_url, options) => new Promise((resolve, reject) => {
    options.signal.addEventListener('abort', () => { aborted = true; reject(new Error('header timeout')); });
    clock.set(() => resolve({
      ok: true,
      json: () => new Promise((resolveBody, rejectBody) => {
        options.signal.addEventListener('abort', () => rejectBody(new Error('body timeout')));
        clock.set(() => resolveBody({ app: 'DALI', streaming: true, delayMs: 700 }), 2000);
      }),
    }), 2000);
  }));
  await settle();
  await clock.advance(4000);
  const result = await pending;
  assert.equal(aborted, false, 'a scheduled body must complete within the full status deadline');
  assert.equal(result.streaming, true);
  assert.equal(result.delayMs, 700);
  await clock.advance(2000);
  assert.equal(aborted, false, 'completion clears the status timer');
});

test('a stalled body after slow headers still times out within five seconds total', async () => {
  const { api, clock } = beacon();
  let aborted = false;
  const pending = api.fetchStatus((_url, options) => new Promise(resolve => {
    clock.set(() => resolve({
      ok: true,
      json: () => new Promise((_resolve, reject) => {
        options.signal.addEventListener('abort', () => { aborted = true; reject(new Error('body timeout')); });
      }),
    }), 2000);
  }));
  await settle();
  await clock.advance(4400);
  assert.equal(aborted, false);
  await clock.advance(700);
  assert.equal(aborted, true);
  assert.equal((await pending).running, false);
});


test('activity excludes silent and inactive media without losing buffering intent', async () => {
  for (const patch of [{ paused: true }, { ended: true }, { readyState: 0 }, { readyState: 2 }, { muted: true }, { volume: 0 }, { seeking: true }]) {
    const c = content();
    c.document.title = 'Video';
    c.media('playing');
    assert.equal(c.messages.filter(m => m.type === 'playstate').at(-1).audible, true);
    Object.assign(c.video, patch);
    c.media(patch.paused ? 'pause' : patch.ended ? 'ended' : patch.muted || patch.volume === 0 ? 'volumechange' : 'waiting');
    const msg = c.messages.filter(m => m.type === 'playstate').at(-1);
    assert.equal(msg.audible, false, JSON.stringify(patch));
    assert.equal(msg.title, undefined);
    if (!patch.paused && !patch.ended) assert.equal(msg.playing, true, 'buffering still protects audio');
  }
});

test('pausing the audible video clears activity even when a muted preview keeps playing', async () => {
  const c = content();
  c.document.title = 'Video';
  c.videos.push(c.makeVideo({ muted: true }));
  const w = worker();
  c.media('playing');
  await w.message(c.messages.filter(m => m.type === 'playstate').at(-1));
  c.video.paused = true;
  c.media('pause');
  const msg = c.messages.filter(m => m.type === 'playstate').at(-1);
  assert.equal(msg.playing, true);
  assert.equal(msg.audible, false);
  await w.message(msg);
  const reports = w.urls.map(u => new URL(u)).filter(u => u.pathname === '/now');
  assert.equal(JSON.parse(reports[0].searchParams.get('d')).length, 1);
  assert.deepEqual(JSON.parse(reports.at(-1).searchParams.get('d')), []);
});

test('a 60fps source retains its cadence with a 700ms picture delay', async () => {
  const c = content();
  await settle();
  c.runtime.sendMessage = async () => ({ running: true, streaming: true, delayMs: 700 });
  c.api.applyStatus({ running: true, streaming: true, delayMs: 700 });
  c.media('play');
  const p = c.api.S.pipeline;
  await runFrames(c, 1000, { step: 1000 / 60 });
  assert.ok(p.captureCount >= 59, 'decoded frames must not be capped at thirty per second');
  assert.equal(p.capFps, 60);
  assert.ok(p.bufferBytes <= 256 * 1024 * 1024);
});

test('early and late decoded callbacks preserve 60fps cadence and presentation timestamps', async () => {
  const c = content();
  await settle();
  c.runtime.sendMessage = async () => ({ running: true, streaming: true, delayMs: 700 });
  c.api.applyStatus({ running: true, streaming: true, delayMs: 700 });
  c.media('play');
  const p = c.api.S.pipeline;
  const base = c.clock.now;
  const errors = [];
  for (let i = 1; i <= 120; i++) {
    const expectedDisplayTime = base + i * 1000 / 60;
    const callbackTime = expectedDisplayTime + (i % 2 ? -8 : 4);
    await c.clock.advance(callbackTime - c.clock.now);
    c.video.currentTime += 1 / 60;
    p.capture(expectedDisplayTime);
    await settle();
    p.drawTick();
    if (i > 60 && p.current) errors.push(Math.abs(c.clock.now - p.current.t - 700));
  }
  assert.equal(p.captureCount, 120, 'callback scheduling jitter must not discard decoded frames');
  assert.ok(Math.abs(p.sourceFrameInterval - 1000 / 60) < 0.01);
  assert.ok(Math.max(...errors) <= 1000 / 120 + 0.1, 'presentation follows decoded frame time within half a frame');
});
