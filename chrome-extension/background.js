// DALI Video Sync — service worker.
//
// Three jobs:
//   1. Poll the DALI app's sync beacon on 127.0.0.1:3697 and hand the answer to
//      any content script that asks. A page cannot fetch plain
//      http://127.0.0.1 from an https document, so the worker does the fetch.
//   2. Re-inject content.js into already-open tabs when the extension is
//      installed, updated or reloaded. Chrome does NOT do this by itself, so
//      without it a freshly loaded extension does nothing on any tab you
//      already had open until you reload each one.
//   3. Print the version and build stamp on startup, so there is a way to
//      confirm which code Chrome actually has loaded (chrome://extensions ->
//      "service worker"). That console line is the only UI this extension has.
//
// Answers are cached for a moment, so a page with twenty iframes still costs
// at most one request per second. Content scripts only ask while a tab
// actually has a video, so an ordinary browsing session costs nothing and the
// worker stays asleep.
//
// The old engine-port probing (3689 / 3695) is gone. Those are the audio
// engine's own API and carry no latency figure at all — /api/player,
// /api/outputs, /api/config, /api/queue and /api/settings were all checked and
// the only latency-ish field is a per-speaker offset_ms trim, which is a
// relative nudge between speakers rather than delay to the ear. Port 3697 is
// the single source of truth: the app measures the pipe itself and publishes
// the number.
//
// No badge, no toolbar button, no popup, no options page, no keyboard
// commands. There is nothing to see.

'use strict';

importScripts('beacon.js');

// Bump BUILD on every edit — it is what tells you whether Chrome is running
// the code you just wrote. Keep it in step with the same constant in content.js.
const BUILD = '2026-09-13.a';

// The app refreshes delayMs once a second, so caching for less than that is
// wasted work and caching for much more would lag a room going live.
const CACHE_MS = 750;

let cache = { at: 0, value: null, pending: null };

// The app refreshes the stable unpacked-extension folder before advertising
// its version. Chrome still needs to reload that folder to read changed files.
// Record the attempt first: an unmanaged installation may live elsewhere and
// must never become an endless reload loop.
const RELOAD_ATTEMPT_KEY = 'managedExtensionReloadAttempt';
let updateCheckPending = false;

function versionParts(version) {
  if (typeof version !== 'string' || !/^\d+(?:\.\d+){0,3}$/.test(version)) return null;
  const parts = version.split('.').map(Number);
  if (parts.some(p => p > 65535)) return null;
  while (parts.length < 4) parts.push(0);
  return parts;
}

function newerVersion(target, current) {
  const a = versionParts(target), b = versionParts(current);
  if (!a || !b) return false;
  for (let i = 0; i < 4; i++) {
    if (a[i] !== b[i]) return a[i] > b[i];
  }
  return false;
}

async function maybeReloadForUpdate(status) {
  const target = status && status.extensionVersion;
  if (updateCheckPending || !newerVersion(target, chrome.runtime.getManifest().version)) return;
  updateCheckPending = true;
  try {
    const stored = await chrome.storage.local.get({ [RELOAD_ATTEMPT_KEY]: '0' });
    if (!newerVersion(target, stored[RELOAD_ATTEMPT_KEY] || '0')) return;
    await chrome.storage.local.set({ [RELOAD_ATTEMPT_KEY]: target });
    chrome.runtime.reload();
  } catch (e) {
    log('managed update check unavailable');
  } finally {
    updateCheckPending = false;
  }
}

// The most recent reading we have of the app, kept SEPARATELY from the response
// cache above.
//
// THE BUG THIS FIXES (the cut that undid itself). setCutState() invalidates
// `cache` so the next content script gets a fresh answer — and evaluateCut()
// used to read the app's state out of that same `cache`. So the first thing
// that ran after a cut saw `cache.value === null`, read it as "no app", and
// immediately sent /resume: the instant cut-off cancelled itself a fraction of
// a second after firing, unless a content script's own poll happened to refill
// the cache in between. Two different questions — "what may I hand the next
// frame that asks" and "what do I know about the app" — were sharing one
// variable, and only one of them wanted it cleared.
let lastStatus = { value: null, at: 0 };
// How long a reading stays good enough to hold a cut on. Content scripts poll
// once a second while any frame has media, so this is six missed polls.
const STATUS_STALE_MS = 6000;

let debug = false;
chrome.storage.local.get({ debug: false }).then((v) => { debug = !!v.debug; }).catch(() => {});
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'local' && changes.debug) debug = !!changes.debug.newValue;
});

function log(...args) {
  if (debug) console.log('[DALISync bg]', ...args);
}

// -------------------------------------------------------------------------
// Which code is loaded?
//
// Printed unconditionally on every service-worker startup — including every
// revival after MV3 kills it. chrome://extensions -> "service worker" shows it.
// This is the documented way to check you are not looking at a cached build.

function banner(why) {
  const m = chrome.runtime.getManifest();
  console.log('[DALI Video Sync] v' + m.version + '  build ' + BUILD +
              '  (' + why + ' ' + new Date().toISOString() + ')');
}
banner('worker up');

// -------------------------------------------------------------------------
// Beacon

function readBeacon() {
  const now = Date.now();
  if (cache.value && now - cache.at < CACHE_MS) return Promise.resolve(cache.value);
  if (cache.pending) return cache.pending;
  cache.pending = DALIBeacon.fetchStatus().then((value) => {
    maybeReloadForUpdate(value);
    const prev = cache.value;
    cache = { at: Date.now(), value, pending: null };
    lastStatus = { value: value, at: Date.now() };
    if (!prev || prev.running !== value.running || prev.streaming !== value.streaming ||
        Math.abs((prev.delayMs || 0) - value.delayMs) > 20) {
      log('beacon', JSON.stringify(value));
    }
    return value;
  }).catch(() => {
    const value = DALIBeacon.offline();
    cache = { at: Date.now(), value, pending: null };
    lastStatus = { value: value, at: Date.now() };
    return value;
  });
  return cache.pending;
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg) return false;

  if (msg.type === 'beacon') {
    readBeacon().then(sendResponse).catch(() => sendResponse(DALIBeacon.offline()));
    return true; // async
  }

  // A content script reports whether a video is playing in ITS frame. The
  // worker owns the actual cut/resume DECISION across every frame — see
  // "Audio cut" below for why that has to live here and not in content.js.
  if (msg.type === 'playstate') {
    const key = frameKey(sender);
    const previous = frames.get(key);
    const stopped = !!(previous && previous.playing && previous.cutEligible && !msg.playing &&
      !msg.gone && Date.now() - previous.at <= FRAME_STALE_MS);
    if (msg.gone) frames.delete(key);
    else frames.set(key, { playing: !!msg.playing, at: Date.now(),
                           cutEligible: msg.cutEligible !== false,
                           title: msg.title || '', host: msg.host || '',
                           live: !!msg.live, held: !!msg.held, art: msg.art || '' });
    evaluateCut(stopped);
    publishNow(false);
    return false; // no response needed
  }

  return false;
});

// -------------------------------------------------------------------------
// Audio cut — aggregated across every tab and frame.
//
// THE BUG THIS FIXES. This used to be entirely inside content.js: each frame
// decided for itself, from only the video(s) it could see, whether the room
// should go silent — and kept re-asserting that decision on its own for up to
// 15 s after ITS video paused. A second tab is a completely separate isolated
// world with its own separate state. Pause a video in tab A, then play one in
// tab B: tab A kept telling the app "silence the room" every second because
// that is what ITS OWN state said, and tab B never told the app to resume,
// because as far as tab B's own state was concerned nothing had ever been
// cut. The room went silent while B was audibly playing, for up to 15 s (or
// longer if A kept re-triggering it) — with no speaker fault anywhere.
//
// The service worker is the one process every frame already talks to (it is
// how the beacon read happens at all — a page cannot reach 127.0.0.1 from an
// https document). So it is the only place a decision spanning every tab CAN
// be made correctly, and that is where it lives now. Each content-script
// instance's whole job became answering one honest, frequent question — "is a
// video playing in my frame?" — and this section unions the answers and owns
// the actual /cut and /resume calls to the app.

const FRAME_STALE_MS = 6000;   // a frame that stops reporting drops out of the union
const CUT_GRACE_MS = 120;      // collapses a feed swipe's stop-then-start into nothing
const CUT_REASSERT_MS = 900;   // keeps the app's ~4 s dead-man timer fed
const CUT_TAIL_MARGIN_MS = 300;

const frames = new Map();      // "tabId:frameId" -> { playing, at }
let cutState = false;          // what we last told the app
let cutGraceTimer = null;
let cutReassertTimer = null;
let cutExpiryTimer = null;
let cutUntil = 0;
let signalQueue = Promise.resolve();

function frameKey(sender) {
  const tabId = sender && sender.tab && sender.tab.id;
  const frameId = sender && typeof sender.frameId === 'number' ? sender.frameId : 0;
  return (tabId == null ? 'x' : tabId) + ':' + frameId;
}

// Purges stale entries as a side effect, so callers never have to sweep first.
function anyFramePlaying() {
  const now = Date.now();
  let any = false;
  for (const [key, f] of frames) {
    if (now - f.at > FRAME_STALE_MS) { frames.delete(key); continue; }
    if (f.playing) any = true;
  }
  return any;
}

function setCutState(on) {
  if (cutReassertTimer) { clearInterval(cutReassertTimer); cutReassertTimer = null; }
  if (cutState === on) {
    // Already in this state; still (re-)arm the reassert timer below if `on`.
  } else {
    cutState = on;
    // Invalidates the cached beacon reading: the app's own state just changed
    // because we changed it, and a stale "streaming, delay 1000" would be
    // handed to the next frame that asks.
    cache = { at: 0, value: null, pending: null };
    queueSignal(on);
  }
  if (on) {
    cutReassertTimer = setInterval(() => {
      if (Date.now() >= cutUntil) { releaseCut(); return; }
      queueSignal(true);
    }, CUT_REASSERT_MS);
  }
}

// A delayed /cut response must finish before /resume is sent. Otherwise a
// rapid pause/play can deliver the old cut last and mute the resumed video.
// Superseded operations that have not started are discarded.
function queueSignal(on) {
  signalQueue = signalQueue.catch(() => {}).then(() => {
    if (cutState !== on) return;
    return DALIBeacon.signal(on ? 'cut' : 'resume').then((ok) => {
      log(on ? 'cut' : 'resume', ok ? 'sent' : 'failed');
    });
  });
}

function releaseCut() {
  if (cutGraceTimer) { clearTimeout(cutGraceTimer); cutGraceTimer = null; }
  if (cutExpiryTimer) { clearTimeout(cutExpiryTimer); cutExpiryTimer = null; }
  cutUntil = 0;
  setCutState(false);
}

// Re-evaluate and re-assert. Called on every playstate report and on a slow
// sweep timer, so a frame that goes stale without ever sending a final
// "not playing" (tab killed, Chrome crash) still gets noticed.
function evaluateCut(stopped = false) {
  // Purges stale frames as a side effect, so it runs before anything reads
  // `frames.size` below.
  const playing = anyFramePlaying();

  // No point silencing a room that is not there — and never HOLD a room silent
  // on a reading we no longer have. Refresh, but only while frames are actually
  // reporting: an unprompted fetch every two seconds would keep this service
  // worker alive forever on a browser that is doing nothing.
  const dali = lastStatus.value;
  const fresh = dali && (Date.now() - lastStatus.at) < STATUS_STALE_MS;
  if (!fresh) {
    if (frames.size > 0) readBeacon();
    releaseCut();
    return;
  }
  if (!dali.running || !dali.streaming) {
    releaseCut();
    return;
  }
  if (playing) {
    releaseCut();
    return;
  }
  // Absence of a heartbeat is unknown, not a pause. Chrome throttles hidden
  // tabs, and a paused video can coexist with music from another Mac app.
  // Only an observed playing -> stopped transition may cut the buffered tail.
  if (!frames.size) { releaseCut(); return; }
  if (cutUntil && Date.now() >= cutUntil) { releaseCut(); return; }
  if (cutState || cutGraceTimer) return;   // already silent, or already waiting
  if (!stopped) return;
  cutUntil = Date.now() + Math.min(DALIBeacon.MAX_DELAY_MS, Math.max(0, dali.delayMs || 0)) + CUT_TAIL_MARGIN_MS;
  cutGraceTimer = setTimeout(() => {
    cutGraceTimer = null;
    if (anyFramePlaying() || !frames.size || Date.now() >= cutUntil ||
        !lastStatus.value || !lastStatus.value.streaming ||
        Date.now() - lastStatus.at >= STATUS_STALE_MS) {
      releaseCut();
      return;
    }
    setCutState(true);
    cutExpiryTimer = setTimeout(releaseCut, cutUntil - Date.now());
  }, CUT_GRACE_MS);
}

// -------------------------------------------------------------------------
// Now playing.
//
// The app's panel shows what the room is hearing. The frames map above already
// knows every playing frame's title, host, live flag and whether the picture
// is held; this unions them per TAB (an embedded player lives in an iframe,
// the page title lives in frame 0 — the lowest frame id wins the title, any
// frame's held/live flag counts) and hands the list to the beacon.
//
// Re-sent when it changes and every NOW_REASSERT_MS while non-empty, and once
// more, empty, when the last video stops — the app also expires a stale list
// on its own, so a dead worker cannot leave a title on the panel.

const NOW_REASSERT_MS = 4000;
let lastNowJSON = '[]';   // nothing has played yet: an empty list needs no sending
let lastNowAt = 0;

function nowList() {
  const now = Date.now();
  const byTab = new Map();
  for (const [key, f] of frames) {
    if (now - f.at > FRAME_STALE_MS || !f.playing || !f.title) continue;
    const parts = key.split(':');
    const tab = parts[0];
    const fid = Number(parts[1]) || 0;
    const cur = byTab.get(tab);
    if (!cur) {
      byTab.set(tab, { fid: fid, t: f.title, h: f.host, l: f.live ? 1 : 0, k: f.held ? 1 : 0, a: f.art });
    } else {
      if (fid < cur.fid) { cur.fid = fid; cur.t = f.title; cur.h = f.host; cur.a = f.art || cur.a; }
      cur.l = cur.l || (f.live ? 1 : 0);
      cur.k = cur.k || (f.held ? 1 : 0);
    }
  }
  return Array.from(byTab.values()).slice(0, 3)
    .map((e) => (e.a ? { t: e.t, h: e.h, l: e.l, k: e.k, a: e.a } : { t: e.t, h: e.h, l: e.l, k: e.k }));
}

// The beacon reads ONE chunk of the request and parses the first line out of
// it, so the whole "GET /now?d=… HTTP/1.1" line has to arrive in a single TCP
// segment. Three tabs each carrying a 300-char artwork URL encodes to ~1550
// bytes, which is over a 1460-byte MSS — the line would split, the app would
// parse a truncated path and drop the report. Shed artwork first (it is the
// least important field and the biggest), then titles, until it fits.
const NOW_MAX_ENCODED = 1000;

function fitNow(list) {
  const enc = (l) => encodeURIComponent(JSON.stringify(l)).length;
  if (enc(list) <= NOW_MAX_ENCODED) return list;
  let out = list.map((e) => Object.assign({}, e));
  for (let i = out.length - 1; i >= 0 && enc(out) > NOW_MAX_ENCODED; i--) delete out[i].a;
  for (let i = out.length - 1; i >= 0 && enc(out) > NOW_MAX_ENCODED; i--) {
    out[i].t = String(out[i].t || '').slice(0, 40);
  }
  while (out.length > 1 && enc(out) > NOW_MAX_ENCODED) out.pop();
  return out;
}

function publishNow(force) {
  const json = JSON.stringify(fitNow(nowList()));
  const now = Date.now();
  if (!force && json === lastNowJSON &&
      (json === '[]' || now - lastNowAt < NOW_REASSERT_MS)) return;
  lastNowJSON = json;
  lastNowAt = now;
  DALIBeacon.signal('now?d=' + encodeURIComponent(json)).then((ok) => {
    log('now', ok ? 'sent' : 'failed', json);
  });
}

// A tab closing should release the room instantly, not wait out
// FRAME_STALE_MS — a swipe-driven feed can plausibly close background tabs
// often enough that a multi-second lag here would be noticeable.
if (chrome.tabs && chrome.tabs.onRemoved) {
  chrome.tabs.onRemoved.addListener((tabId) => {
    let changed = false;
    for (const key of frames.keys()) {
      if (key.indexOf(tabId + ':') === 0) { frames.delete(key); changed = true; }
    }
    if (changed) { evaluateCut(); publishNow(false); }
  });
}

// Backstop sweep: evaluateCut() is otherwise only triggered BY a message, so
// a frame that goes silent without ever sending a final report needs this to
// be noticed at all.
setInterval(() => { evaluateCut(); publishNow(false); }, 2000);

// -------------------------------------------------------------------------
// Content-script port.
//
// A content script opens one only while it is actually delaying a video. Two
// effects, both wanted:
//   - the worker is kept alive for exactly as long as a video depends on it,
//     so there is no revival latency mid-playback;
//   - when the extension is reloaded, the port drops, and that is the content
//     script's only chance to un-hide the <video> before its world is
//     abandoned.
// There is nothing to do here; the listener just has to exist for connect() to
// succeed.

chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== 'dali-sync') return;
  log('port open from', port.sender && port.sender.url);
  port.onDisconnect.addListener(() => {
    // Chrome exposes navigation/BFCache closure errors only inside this callback.
    // Read even when debug logging is disabled to avoid an unchecked lastError.
    const error = chrome.runtime.lastError;
    log('port closed', error ? error.message : '');
  });
});

// -------------------------------------------------------------------------
// Re-inject into open tabs.
//
// Chrome only runs declared content scripts on navigation, so after "Load
// unpacked" or a reload every tab you already had open is left without one.
// The founder reloads this extension constantly; it has to start working
// immediately, on the tab that is already playing.

function reinject(why) {
  if (!chrome.scripting || !chrome.tabs) return;
  chrome.tabs.query({}).then((tabs) => {
    let n = 0;
    for (const tab of tabs) {
      if (!tab.id || tab.id < 0) continue;
      chrome.scripting.executeScript({
        target: { tabId: tab.id, allFrames: true },
        files: ['content.js'],
        injectImmediately: true
      }).then(() => { n++; }).catch(() => { /* chrome://, web store, no access */ });
    }
    log('re-injected after', why, '(' + tabs.length + ' tabs tried)');
  }).catch(() => {});
}

chrome.runtime.onInstalled.addListener((details) => {
  banner('installed: ' + (details && details.reason));
  reinject(details && details.reason);
});

chrome.runtime.onStartup.addListener(() => {
  banner('browser startup');
  reinject('browser startup');
});
