// Harness shim, loaded BEFORE the real content.js.
//
// 1. chrome.* stub so content.js runs on a plain page. The only two things the
//    production content script asks the browser for are chrome.storage.local
//    (the optional per-site trim) and a {type:'beacon'} message, so those are
//    the only two things stubbed.
// 2. A worker-driven requestAnimationFrame replacement. The automation browser
//    keeps this tab document.hidden, which kills real rAF and
//    requestVideoFrameCallback; a Worker heartbeat is not throttled, so the
//    pipeline can be exercised headlessly. Set ?real=1 to keep the native ones.
// 3. A controllable document.visibilityState, so the tab-switch tests are the
//    same whether the driver's tab is really on screen or not.
(() => {
  const local = { trims: {}, debug: false };
  const listeners = [];

  // --- controllable page visibility ----------------------------------------
  // content.js reads document.visibilityState; headless tabs can report either
  // value, so pin it and let the tests drive it.
  window.__visibility = 'visible';
  try {
    Object.defineProperty(document, 'visibilityState', {
      configurable: true, get: () => window.__visibility
    });
    Object.defineProperty(document, 'hidden', {
      configurable: true, get: () => window.__visibility !== 'visible'
    });
  } catch (e) { /* ignore */ }
  window.__setVisible = (visible) => {
    window.__visibility = visible ? 'visible' : 'hidden';
    document.dispatchEvent(new Event('visibilitychange'));
  };

  // What the fake service worker answers with. window.__setBeacon() drives the
  // engage / disengage tests; __useRealBeacon switches to the genuine
  // DALIBeacon.fetchStatus() against 127.0.0.1:3697, which is how the real
  // contract gets exercised end to end.
  window.__beacon = { running: false, streaming: false, delayMs: 0 };
  window.__useRealBeacon = false;
  window.__beaconCalls = 0;
  window.__setBeacon = (o) => { window.__beacon = Object.assign({}, window.__beacon, o); };

  // --- MV3 service-worker death --------------------------------------------
  // __workerDead = 'reject'  : sendMessage rejects, as it does when the worker
  //                            cannot be revived ("Could not establish
  //                            connection").
  // __workerDead = 'silent'  : sendMessage resolves with undefined, as it does
  //                            when the worker dies mid-handling.
  // Ports opened while dead disconnect immediately, exactly like the real
  // thing.
  window.__workerDead = false;
  window.__ports = [];
  window.__killWorker = (mode) => {
    window.__workerDead = mode === undefined ? 'reject' : mode;
    window.__ports.slice().forEach((p) => p.__drop());
  };
  window.__reviveWorker = () => { window.__workerDead = false; };

  // Audio cut/resume signals sent to the app. Production content.js no longer
  // decides this itself — it reports playstate to the background worker, and
  // the worker decides (see background.js "Audio cut"). This is a single-frame
  // simulation of that same grace/reassert logic, driven by the SAME
  // {type:'playstate'} messages content.js actually sends, so the U-series
  // tests below still exercise the real timing even though the harness never
  // loads background.js itself.
  window.__cutLog = [];
  window.__cuts = (type) => window.__cutLog.filter((e) => !type || e.type === type).length;
  window.__clearCuts = () => { window.__cutLog.length = 0; };

  let __simPlaying = false;
  let __simLastReportAt = 0;
  let __simCutState = false;
  let __simGraceTimer = null;
  let __simSweep = 0;
  const __SIM_CUT_GRACE_MS = 120;
  // The real worker ages a frame out of its union after this long without a
  // report and then reads the empty union as "nothing is playing anywhere".
  // The shim did NOT model that, which is precisely why it could not catch the
  // missing heartbeat in reportPlaystate: a video that played steadily reported
  // once, went quiet, and the simulation happily believed the stale `true`
  // forever while the real worker was cutting the room. Model it, and the
  // U4 test below fails the moment the heartbeat goes away again.
  const __SIM_FRAME_STALE_MS = 6000;
  function __setSimCut(on) {
    if (__simCutState === on) return;
    __simCutState = on;
    window.__cutLog.push({ type: on ? 'cut' : 'resume', at: Math.round(performance.now()) });
  }
  function __evalSimCut() {
    if (!(window.__beacon && window.__beacon.running && window.__beacon.streaming)) {
      if (__simGraceTimer) { clearTimeout(__simGraceTimer); __simGraceTimer = null; }
      __setSimCut(false);
      return;
    }
    if (__simPlaying && (Date.now() - __simLastReportAt) < __SIM_FRAME_STALE_MS) {
      if (__simGraceTimer) { clearTimeout(__simGraceTimer); __simGraceTimer = null; }
      __setSimCut(false);
      return;
    }
    if (__simCutState || __simGraceTimer) return;
    __simGraceTimer = setTimeout(() => {
      __simGraceTimer = null;
      if (!__simPlaying) __setSimCut(true);
    }, __SIM_CUT_GRACE_MS);
  }

  __simSweep = setInterval(__evalSimCut, 500);

  window.chrome = {
    runtime: {
      id: 'harness',
      sendMessage(msg) {
        if (msg && msg.type === 'beacon') {
          window.__beaconCalls++;
          if (window.__workerDead === 'reject') {
            return Promise.reject(new Error('Could not establish connection.'));
          }
          if (window.__workerDead) return Promise.resolve(undefined);
          if (window.__useRealBeacon && window.DALIBeacon) return window.DALIBeacon.fetchStatus();
          return Promise.resolve(Object.assign({}, window.__beacon));
        }
        // Real content.js reports playing state; the simulated aggregator
        // above decides whether that produces a cut or a resume, exactly like
        // the real background worker does across every tab.
        if (msg && msg.type === 'playstate') {
          __simPlaying = !!msg.playing;
          __simLastReportAt = Date.now();
          __evalSimCut();
          return Promise.resolve();
        }
        return Promise.resolve();
      },
      connect() {
        const subs = [];
        const port = {
          name: 'dali-sync',
          onDisconnect: { addListener: (fn) => subs.push(fn) },
          disconnect() { port.__drop(); },
          __drop() {
            const i = window.__ports.indexOf(port);
            if (i >= 0) window.__ports.splice(i, 1);
            subs.splice(0).forEach((fn) => { try { fn(port); } catch (e) { console.error(e); } });
          }
        };
        window.__ports.push(port);
        if (window.__workerDead) setTimeout(() => port.__drop(), 0);
        return port;
      },
      onMessage: { addListener: () => {} },
      onConnect: { addListener: () => {} },
      getURL: (p) => p
    },
    storage: {
      local: {
        get(defaults) {
          const out = {};
          for (const k of Object.keys(defaults || local)) {
            out[k] = (k in local) ? local[k] : defaults[k];
          }
          return Promise.resolve(out);
        },
        set(patch) {
          const changes = {};
          for (const k of Object.keys(patch)) {
            changes[k] = { oldValue: local[k], newValue: patch[k] };
            local[k] = patch[k];
          }
          listeners.forEach((fn) => { try { fn(changes, 'local'); } catch (e) { console.error(e); } });
          return Promise.resolve();
        }
      },
      onChanged: { addListener: (fn) => listeners.push(fn) }
    }
  };
  window.__local = local;
  window.__setTrim = (host, ms) => {
    const t = Object.assign({}, local.trims);
    if (ms === null) delete t[host]; else t[host] = ms;
    return window.chrome.storage.local.set({ trims: t });
  };

  // --- ImageBitmap accounting (memory bound + leak check) -------------------
  let created = 0, closed = 0, bytes = 0, peakLive = 0, peakBytes = 0;
  const realCIB = window.createImageBitmap;
  window.createImageBitmap = function (...args) {
    return realCIB.apply(window, args).then((b) => {
      created++;
      bytes += b.width * b.height * 4;
      peakLive = Math.max(peakLive, created - closed);
      peakBytes = Math.max(peakBytes, bytes);
      b.__bytes = b.width * b.height * 4;
      return b;
    });
  };
  const realClose = ImageBitmap.prototype.close;
  ImageBitmap.prototype.close = function () {
    if (!this.__closed) { this.__closed = true; closed++; bytes -= (this.__bytes || 0); }
    return realClose.call(this);
  };
  window.__bmp = () => ({ created, closed, live: created - closed,
    liveMB: +(bytes / 1e6).toFixed(1), peakLive, peakMB: +(peakBytes / 1e6).toFixed(1) });
  window.__bmpReset = () => { peakLive = created - closed; peakBytes = bytes; };

  // --- unthrottled rAF -----------------------------------------------------
  if (new URLSearchParams(location.search).get('real') === '1') { window.__realMode = true; return; }
  const src = 'setInterval(() => postMessage(0), 8);';
  const w = new Worker(URL.createObjectURL(new Blob([src], { type: 'text/javascript' })));
  let nextId = 1;
  let queue = new Map();
  w.onmessage = () => {
    if (!queue.size) return;
    const due = queue; queue = new Map();
    const t = performance.now();
    for (const cb of due.values()) { try { cb(t); } catch (e) { console.error(e); } }
  };
  window.__nativeRaf = window.requestAnimationFrame.bind(window);
  window.requestAnimationFrame = (cb) => { const id = nextId++; queue.set(id, cb); return id; };
  window.cancelAnimationFrame = (id) => { queue.delete(id); };

  // The native requestVideoFrameCallback is also suspended while hidden. ?raf=1
  // removes it so content.js takes its rAF fallback path; otherwise it is
  // re-implemented on top of the worker heartbeat so the PRODUCTION rVFC branch
  // (including its expectedDisplayTime handling) is what gets exercised.
  if (new URLSearchParams(location.search).get('raf') === '1') {
    try { delete HTMLVideoElement.prototype.requestVideoFrameCallback; } catch (e) { /* ignore */ }
    try { delete HTMLVideoElement.prototype.cancelVideoFrameCallback; } catch (e) { /* ignore */ }
    return;
  }
  const lastMediaTime = new WeakMap();
  const cancelled = new Set();
  let vfcId = 0;
  HTMLVideoElement.prototype.requestVideoFrameCallback = function (cb) {
    const v = this;
    const id = ++vfcId;
    const step = (t) => {
      if (cancelled.has(id)) { cancelled.delete(id); return; }
      if (v.readyState >= 2 && v.videoWidth && v.currentTime !== lastMediaTime.get(v)) {
        lastMediaTime.set(v, v.currentTime);
        cb(t, {
          expectedDisplayTime: t, mediaTime: v.currentTime,
          presentedFrames: id, width: v.videoWidth, height: v.videoHeight
        });
      } else {
        requestAnimationFrame(step);
      }
    };
    requestAnimationFrame(step);
    return id;
  };
  HTMLVideoElement.prototype.cancelVideoFrameCallback = function (id) { cancelled.add(id); };
})();
