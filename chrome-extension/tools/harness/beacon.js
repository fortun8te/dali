// DALI sync beacon client.
//
// The macOS app (Sources/DALI/SyncBeacon.swift) serves one JSON object on
// loopback port 3697:
//
//     {"app":"DALI","streaming":true,"delayMs":890}
//
//   streaming — whether a room is live right now.
//   delayMs   — the app's own measured end-to-end audio delay (engine backlog
//               + receiver buffer estimate), refreshed once a second.
//
// That number is the whole point of this extension: it is the amount the
// picture has to be held back. Nothing else on the machine reports it.
//
// This file is shared by the service worker (importScripts) and by the test
// harness (<script src>), so the parsing that ships is the parsing that is
// tested.

(function (root) {
  'use strict';

  var URL_ = 'http://127.0.0.1:3697/';
  var TIMEOUT_MS = 700;
  var MAX_DELAY_MS = 4000;
  var PROTOCOL_VERSION = 1;

  var OFFLINE = { running: false, streaming: false, delayMs: 0 };

  function offline() {
    return { running: false, streaming: false, delayMs: 0 };
  }

  // Anything that is not unmistakably DALI is treated as "not running": port
  // 3697 could in principle be answered by something else entirely, and acting
  // on a stranger's JSON would delay the picture for no reason.
  function normalize(data) {
    if (!data || typeof data !== 'object' || data.app !== 'DALI') return offline();
    // Older DALI builds have no version field and speak protocol 1. A future
    // incompatible protocol must leave the original video visible.
    if ('protocolVersion' in data && data.protocolVersion !== PROTOCOL_VERSION) return offline();
    var streaming = data.streaming === true;
    var ms = Number(data.delayMs);
    if (!isFinite(ms) || ms < 0) ms = 0;
    ms = Math.min(MAX_DELAY_MS, Math.round(ms));
    var result = { running: true, streaming: streaming, delayMs: streaming ? ms : 0 };
    if (typeof data.extensionVersion === 'string') result.extensionVersion = data.extensionVersion;
    return result;
  }

  // `fetchImpl` exists so the harness can inject a fetch; production passes
  // nothing and uses the worker's own.
  function fetchStatus(fetchImpl) {
    var f = fetchImpl || function (u, o) { return fetch(u, o); };
    var ctrl = (typeof AbortController === 'function') ? new AbortController() : null;
    var timer = ctrl ? setTimeout(function () { ctrl.abort(); }, TIMEOUT_MS) : 0;
    var opts = { cache: 'no-store', credentials: 'omit', headers: { 'X-DALI-Client': 'chrome-extension' } };
    if (ctrl) opts.signal = ctrl.signal;
    // Cache-buster: the beacon says no-store, but a stale value here would mean
    // a stale delay.
    return Promise.resolve().then(function () { return f(URL_ + '?t=' + Date.now(), opts); }).then(function (res) {
      if (!res || !res.ok) return offline();
      return res.json().then(normalize, offline);
    }).catch(function () {
      return offline();
    }).finally(function () {
      if (timer) clearTimeout(timer);
    });
  }

  // INSTANT CUT-OFF.
  //
  // Hiding the picture is not enough: when a video stops, the second of audio
  // already inside the pipe and the speakers' own buffers keeps playing. The
  // extension cannot reach it — only the app can, by dropping the speakers to
  // silence, which the receivers apply to audio they have already buffered.
  //
  // Fire-and-forget: a failed cut must never block handing the video back, and
  // the app expires a cut by itself after ~4 s if we stop re-arming it (browser
  // crash, tab closed, extension disabled), so nothing here can leave a room
  // permanently silent.
  function signal(kind, fetchImpl) {
    var f = fetchImpl || function (u, o) { return fetch(u, o); };
    var ctrl = (typeof AbortController === 'function') ? new AbortController() : null;
    var timer = ctrl ? setTimeout(function () { ctrl.abort(); }, TIMEOUT_MS) : 0;
    var opts = { cache: 'no-store', credentials: 'omit', headers: { 'X-DALI-Client': 'chrome-extension' } };
    if (ctrl) opts.signal = ctrl.signal;
    // `kind` may already carry a query (/now?d=…): join with & then.
    var sep = kind.indexOf('?') >= 0 ? '&' : '?';
    return Promise.resolve().then(function () { return f(URL_ + kind + sep + 't=' + Date.now(), opts); }).then(function (res) {
      if (timer) clearTimeout(timer);
      return !!(res && res.ok);
    }).catch(function () {
      if (timer) clearTimeout(timer);
      return false;
    });
  }

  root.DALIBeacon = {
    URL: URL_,
    signal: signal,
    MAX_DELAY_MS: MAX_DELAY_MS,
    OFFLINE: OFFLINE,
    offline: offline,
    normalize: normalize,
    fetchStatus: fetchStatus
  };
})(typeof self !== 'undefined' ? self : this);
