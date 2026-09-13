// DALI Video Sync — content script.
//
// The DALI macOS app streams your Mac's system audio to AirPlay speakers, which
// arrive roughly half a second to a second and a half late. This script holds
// the PICTURE back by the same amount so lips match again.
//
// Mechanism: overlay a <canvas> exactly on top of the page's main <video>,
// capture frames into a ring buffer of ImageBitmaps, and present each frame
// once it is `delayMs` old. The video element is made visibility:hidden, so
// layout is untouched. ITS AUDIO IS NEVER TOUCHED — it keeps playing normally
// and is captured system-wide by the app.
//
// There is nothing to configure. The app publishes its own measured delay on a
// loopback beacon (port 3697); the service worker polls it and this script
// applies the number. When DALI is not streaming, this script does exactly
// nothing to the page.
//
// Three rules run the whole thing:
//
//   1. ALWAYS CATCH UP. Every entry order works — extension loaded mid-video,
//      room started after playback began, worker suspended, tab backgrounded.
//      A watchdog rebuilds the pipeline if it ever believes it is presenting
//      but no frame has actually reached the screen.
//   2. EASE IN, NEVER JUMP. Engaging mid-playback means the buffer is empty, so
//      the delay is ramped in from zero instead of freezing the picture for a
//      second while it fills.
//   3. CUT OUT INSTANTLY. Pause, end, seek, tab switch, PiP, fullscreen that
//      breaks compositing, DOM removal, navigation — the buffer is dropped and
//      the real <video> is handed back in the same tick. The buffer is never
//      drained.

(() => {
  'use strict';

  // Bump BUILD on every edit. The service worker prints version + build on
  // startup (chrome://extensions -> "service worker"); that line is the only
  // way to confirm which code Chrome actually has loaded.
  const VERSION = '1.1.0';
  const BUILD = '2026-09-13.a';

  if (typeof chrome === 'undefined' || !chrome.runtime) return;

  function extensionAlive() {
    try { return !!(chrome.runtime && chrome.runtime.id); } catch (e) { return false; }
  }

  // Re-injection guard. The service worker re-injects this file into open tabs
  // after an install or reload, so a frame can be asked to run it twice:
  //  - a LIVE instance of the current build already owns the frame -> stand down.
  //  - an ORPHANED instance from the previous extension load (its chrome.* APIs
  //    are dead but its JS and its DOM changes are still there) -> tear it down
  //    and take over, so the page is never left with a hidden <video>.
  const prevInstance = window.__daliVideoSync;
  if (prevInstance && typeof prevInstance === 'object') {
    const live = typeof prevInstance.alive === 'function' && prevInstance.alive();
    const active = typeof prevInstance.active === 'function' ? prevInstance.active() : true;
    if (live && active && prevInstance.build === BUILD) return;
    try { prevInstance.teardown('replaced'); } catch (e) { /* ignore */ }
  }
  if (!extensionAlive()) return;

  const MAX_DELAY = 4000;
  // Below this, a delay is not worth a canvas: the round trip costs more than
  // it fixes.
  const MIN_ENGAGE_DELAY = 60;
  // Optional per-site trim, applied on top of the app's number. Never required.
  const MAX_TRIM = 2000;

  // Decoded frames are the only real memory cost. Budget, not frame count:
  // a 1280x720 bitmap is 3.7 MB, so 256 MB is ~70 frames at that size.
  const MAX_BUFFER_BYTES = 256 * 1024 * 1024;
  // Never capture wider than this, however big the video is.
  const MAX_CAPTURE_WIDTH = 1280;
  // Preferred capture rate. Lowered automatically if the byte budget cannot
  // hold `delay x fps` frames — dropping frame rate is far less bad than
  // silently shortening the delay.
  const TARGET_FPS = 30;
  const MIN_FPS = 10;
  // Consecutive createImageBitmap failures before giving up on a video.
  const MAX_CAPTURE_ERRORS = 4;
  // Ignore videos smaller than this on-screen area (px^2).
  const MIN_VIDEO_AREA = 2500;
  // A challenger video must beat the current one by this factor before we
  // switch, so two similar videos don't cause flapping.
  const SWITCH_HYSTERESIS = 1.5;
  // Presenting, playing, decoding, but nothing reaching the screen for this
  // long -> rebuild the pipeline rather than sit on a frozen canvas.
  const SELF_HEAL_MS = 1500;
  // ...and if rebuilding doesn't help this many times, hand the video back for
  // good rather than flapping forever.
  const MAX_REBUILDS = 3;
  // How often we ask the service worker for the beacon reading.
  const POLL_MS = 1000;
  const POLL_MIN_GAP_MS = 600;
  // The MV3 service worker is killed aggressively and revived by the next
  // message. A failed ask means "retry now", not "DALI is gone" — only give up
  // on the delay after this long with no answer at all.
  const BEACON_GRACE_MS = 4000;

  // A video that has been playing continuously for longer than this had its
  // audio already in flight when we engaged, so the delay has to be eased in.
  // Anything more recent (play, seek, source change) is a fresh audio start:
  // holding the first frame until its audio lands is exactly right. The window
  // is generous because arming lags the event by however long the first frame
  // takes to decode and capture.
  const FRESH_MS = 1200;
  // Ramp length = RAMP_FACTOR x delay, clamped. Factor 2 means the picture
  // runs at half speed while it eases into alignment; it never freezes and it
  // never jumps.
  const RAMP_FACTOR = 2;
  const RAMP_MIN_MS = 800;
  const RAMP_MAX_MS = 3000;
  // Live players nudge currentTime to hold the live edge. A jump smaller than
  // this on a live stream is not a user seek and must not tear the delay down,
  // or the player and the extension fight each other forever.
  const LIVE_SEEK_EPSILON_MS = 250;

  const CANVAS_CLASS = 'dali-sync-overlay';
  const HIDDEN_ATTR = 'data-dali-sync-hidden';
  const TRIM_KEY = 'trims';

  const S = {
    dead: false,           // torn down for good (extension reloaded / replaced)
    suspended: false,      // a cached page must not restart from pending async work
    dali: { running: false, streaming: false, delayMs: 0 },
    daliKnown: false,
    // Audio-cut state used to live here, per frame — see the "Audio cut —
    // reporting only" section below for why that was wrong and where the
    // decision lives now (the background worker, which sees every frame).
    trims: {},
    trim: 0,
    debug: false,
    pipeline: null,
    scanning: false,
    ticking: false,
    tickTimer: 0,
    tickRaf: 0,
    lastTickAt: 0,
    lastPollAt: 0,
    pollInflight: false,
    beaconFails: 0,
    beaconFailSince: 0,
    retryTimer: 0,
    port: null,
    mutationObserver: null,
    evalTimer: 0,
    reason: 'no-video',
    lastBest: null,
    lastBestArea: 0,
    videoIssues: new WeakMap(),  // video -> 'protected' | 'capture-failed'
    videoFresh: new WeakMap(),   // video -> performance.now() of last audio discontinuity
    rebuilds: new WeakMap()      // video -> self-heal attempts
  };

  function log(...args) {
    if (S.debug) console.log('[DALISync]', ...args);
  }

  function pageVisible() {
    return document.visibilityState === 'visible';
  }

  // -------------------------------------------------------------------------
  // The delay number.
  //
  // autoDelayMs comes from the app and is the whole answer; the trim is a
  // per-site nudge for someone whose speaker is unusual, and is zero unless
  // they went looking for it.

  function clampTrim(ms) {
    ms = Math.round(Number(ms));
    if (!Number.isFinite(ms)) return 0;
    return Math.min(MAX_TRIM, Math.max(-MAX_TRIM, ms));
  }

  function autoDelayMs() {
    return S.dali.streaming ? S.dali.delayMs : 0;
  }

  function activeDelayMs() {
    if (!S.dali.streaming) return 0;
    const ms = Math.round(autoDelayMs() + S.trim);
    return Math.min(MAX_DELAY, Math.max(0, ms));
  }

  function engageable() {
    return S.dali.streaming && activeDelayMs() >= MIN_ENGAGE_DELAY;
  }

  function idleReason() {
    if (!S.daliKnown) return 'checking';
    if (!S.dali.running) return 'no-dali';
    if (!S.dali.streaming) return 'dali-idle';
    if (activeDelayMs() < MIN_ENGAGE_DELAY) return 'no-delay';
    return 'idle';
  }

  // -------------------------------------------------------------------------
  // Cleanup of leftovers from a previous extension load (the extension was
  // reloaded while a page had an active overlay — the old isolated world is
  // gone and could not restore the page).

  function cleanupStaleArtifacts() {
    try {
      document.querySelectorAll('canvas.' + CANVAS_CLASS).forEach((c) => c.remove());
      document.querySelectorAll('video[' + HIDDEN_ATTR + ']').forEach((v) => {
        v.style.visibility = '';
        v.removeAttribute(HIDDEN_ATTR);
      });
    } catch (e) { /* ignore */ }
  }

  // -------------------------------------------------------------------------
  // Storage: the per-site trim and a debug flag. Nothing else is persisted —
  // there are no settings.

  function applyTrims(trims) {
    S.trims = trims || {};
    const next = clampTrim(S.trims[location.hostname]);
    if (next === S.trim) return false;
    S.trim = next;
    return true;
  }

  function loadStorage() {
    try {
      chrome.storage.local.get({ [TRIM_KEY]: {}, debug: false }).then((v) => {
        S.debug = !!v.debug;
        if (S.debug) log('v' + VERSION + ' build ' + BUILD, 'in', location.href);
        applyTrims(v[TRIM_KEY]);
        scheduleEvaluate();
      }).catch(() => {});
    } catch (e) { /* ignore */ }
  }

  try {
    chrome.storage.onChanged.addListener((changes, area) => {
      if (area !== 'local') return;
      if (changes.debug) S.debug = !!changes.debug.newValue;
      if (changes[TRIM_KEY] && applyTrims(changes[TRIM_KEY].newValue)) {
        log('trim ->', S.trim, 'ms');
        if (S.pipeline && !S.pipeline.detached) S.pipeline.planCapture();
        scheduleEvaluate();
      }
    });
  } catch (e) { /* ignore */ }

  // -------------------------------------------------------------------------
  // Video discovery

  function scoreVideo(v) {
    if (!v.isConnected) return 0;
    let rect;
    try { rect = v.getBoundingClientRect(); } catch (e) { return 0; }
    try {
      const cs = getComputedStyle(v);
      const ours = v.hasAttribute(HIDDEN_ATTR);
      if (cs.display === 'none' || cs.opacity === '0' ||
          ((cs.visibility === 'hidden' || cs.visibility === 'collapse') && !ours)) return 0;
    } catch (e) { /* geometry remains the fallback */ }
    // Feeds keep previous and preloaded videos alive offscreen. Only the
    // visible part may win, otherwise a large previous clip owns sync forever.
    const width = window.innerWidth || document.documentElement.clientWidth;
    const height = window.innerHeight || document.documentElement.clientHeight;
    const visibleWidth = width > 0
      ? Math.max(0, Math.min(rect.left + rect.width, width) - Math.max(rect.left, 0)) : rect.width;
    const visibleHeight = height > 0
      ? Math.max(0, Math.min(rect.top + rect.height, height) - Math.max(rect.top, 0)) : rect.height;
    const area = visibleWidth * visibleHeight;
    if (area < MIN_VIDEO_AREA) return 0;
    let score = area;
    if (!v.paused && !v.ended && v.readyState >= 2) score *= 8;
    else if (v.readyState >= 2) score *= 2;
    return score;
  }

  // Every <video> on the page, INCLUDING inside open shadow roots.
  //
  // document.querySelectorAll('video') does not pierce shadow DOM, so any site
  // whose player is a web component is simply invisible to it — the extension
  // reports "no video" on a page that is obviously playing one. YouTube and
  // TikTok both keep the element in the light DOM today, but that is a fact
  // about their current markup, not a guarantee, and plenty of embedded players
  // (and anything built on a component framework) do not. Walking open roots
  // costs one extra pass over elements that have one and makes the answer
  // correct everywhere instead of correct on the two sites we happened to try.
  //
  // Closed shadow roots are unreachable by design; nothing can be done there.
  function allVideos(root, out) {
    out = out || [];
    root = root || document;
    try {
      for (const v of root.querySelectorAll('video')) out.push(v);
      for (const el of root.querySelectorAll('*')) {
        if (el.shadowRoot) allVideos(el.shadowRoot, out);
      }
    } catch (e) { /* detached / cross-origin: skip this root */ }
    return out;
  }

  function findBestVideo() {
    let best = null, bestScore = 0, bestArea = 0;
    const vids = allVideos();
    for (const v of vids) {
      const score = scoreVideo(v);
      if (score > bestScore) {
        best = v;
        bestScore = score;
        try {
          const r = v.getBoundingClientRect();
          bestArea = r.width * r.height;
        } catch (e) { bestArea = 0; }
      }
    }
    return { video: best, score: bestScore, area: bestArea, any: vids.length > 0 };
  }

  function isProtected(v) {
    if (S.videoIssues.get(v) === 'protected') return true;
    try { if (v.mediaKeys) return true; } catch (e) { /* ignore */ }
    return false;
  }

  // YouTube Live / HLS: duration is Infinity (or NaN before metadata). Nothing
  // in the pipeline depends on duration — we never touch currentTime and never
  // touch playbackRate, so the player has no reason to fight back — but live
  // players DO nudge the playhead to hold the live edge, and those nudges must
  // not be mistaken for user seeks.
  function isLive(v) {
    const d = v.duration;
    return !(typeof d === 'number' && isFinite(d) && d > 0);
  }

  // Live or not, for the app's LIVE mark only — nothing in the pipeline
  // depends on it. isLive() misses YouTube (finite, growing duration during a
  // live event), so on youtube.com the player's own badge is consulted; Twitch
  // is live unless the URL is a VOD.
  function liveNow() {
    try {
      const h = String(location.hostname || '');
      if (/(^|\.)twitch\.tv$/.test(h)) return !/^\/videos\//.test(location.pathname || '');
      if (/(^|\.)youtube\.com$/.test(h) && typeof document.querySelector === 'function') {
        const badge = document.querySelector('.ytp-live-badge, .ytp-live');
        if (badge && badge.offsetParent !== null) return true;
      }
      for (const v of allMedia()) {
        if (v.tagName === 'VIDEO' && !v.paused && !v.ended && isLive(v)) return true;
      }
    } catch (e) { /* a stubbed or half-torn-down document: not live */ }
    return false;
  }

  // The page's own cover for the app's now-playing row: og:image, which
  // YouTube, Twitch and most players set to the thumbnail. https only.
  function pageArt() {
    try {
      if (typeof document.querySelector !== 'function') return '';
      const m = document.querySelector('meta[property="og:image"], meta[name="twitter:image"]');
      const u = m && m.content ? String(m.content).slice(0, 300) : '';
      return /^https:\/\//.test(u) ? u : '';
    } catch (e) { return ''; }
  }

  function markFresh(v) {
    if (v && v.tagName === 'VIDEO') S.videoFresh.set(v, performance.now());
  }

  function freshlyStarted(v) {
    const at = S.videoFresh.get(v);
    if (!at) return false;            // never seen a discontinuity: audio is mid-flight
    return performance.now() - at < FRESH_MS;
  }

  function failVideo(v, reason) {
    S.videoIssues.set(v, reason);
    if (S.pipeline && S.pipeline.video === v) detachPipeline();
    scheduleEvaluate();
  }

  // -------------------------------------------------------------------------
  // The delay pipeline

  class Pipeline {
    constructor(video) {
      this.video = video;
      this.parent = video.parentElement;
      this.canvas = null;
      this.ctx = null;
      this.buffer = [];       // [{ t, bmp, bytes }] sorted by capture time
      this.bufferBytes = 0;
      this.current = null;    // last presented frame (kept for redraw on resize)
      this.gen = 0;           // bumped on flush; discards in-flight captures
      this.inflight = 0;
      this.captureErrors = 0;
      this.captureCount = 0;
      this.lastCaptureTime = 0;
      this.lastFrameAt = 0;
      this.lastPresentAt = 0;
      this.armedAt = 0;
      this.lastMediaTime = -1;
      this.lastHealthMediaTime = video.currentTime;
      this.lastTimeSeen = -1;
      this.stallSince = 0;
      this.capW = 0;
      this.capH = 0;
      this.frameBytes = 0;
      this.capFps = TARGET_FPS;
      this.capacity = 8;
      this.vfcId = 0;
      this.rafCapId = 0;
      this.rafDrawId = 0;
      this.drawSuspended = false;
      this.detached = false;
      this.armed = false;     // video hidden + canvas authoritative
      // Ramp state: `eff` is the delay actually being presented with, which
      // walks up to activeDelayMs() at `rampRate` ms per ms instead of jumping.
      this.eff = 0;
      this.effAt = 0;
      this.rampRate = 0;
      this.ramped = false;
      this.lastRect = null;
      this.lastDpr = 0;
      this.objectFit = 'contain';
      this.savedVisibility = null;
      this.resizeObserver = null;
      this.listeners = [];
    }

    listen(target, type, fn, opts) {
      target.addEventListener(type, fn, opts);
      this.listeners.push([target, type, fn, opts]);
    }

    attach() {
      const v = this.video;
      if (!this.parent || !v.isConnected) return false;

      this.canvas = document.createElement('canvas');
      this.canvas.className = CANVAS_CLASS;
      const cs = this.canvas.style;
      cs.position = 'absolute';
      cs.left = '0px';
      cs.top = '0px';
      cs.display = 'none';     // only shown once armed
      cs.pointerEvents = 'none';
      cs.background = 'transparent';
      // Neutralise anything the page's own stylesheet might apply to a sibling
      // of the <video>; the overlay has to land pixel-exact on every site.
      cs.margin = '0';
      cs.padding = '0';
      cs.border = '0';
      cs.maxWidth = 'none';
      cs.maxHeight = 'none';
      cs.minWidth = '0';
      cs.minHeight = '0';
      cs.transform = 'none';
      cs.filter = 'none';
      cs.opacity = '1';
      cs.visibility = 'visible';
      cs.clipPath = 'none';
      cs.boxShadow = 'none';
      cs.outline = 'none';
      cs.transition = 'none';
      cs.animation = 'none';
      cs.float = 'none';
      cs.right = 'auto';
      cs.bottom = 'auto';
      try {
        const vcs = getComputedStyle(v);
        if (vcs.zIndex !== 'auto') cs.zIndex = vcs.zIndex;
        if (vcs.borderRadius && vcs.borderRadius !== '0px') cs.borderRadius = vcs.borderRadius;
      } catch (e) { /* ignore */ }

      try {
        v.insertAdjacentElement('afterend', this.canvas);
      } catch (e) {
        return false;
      }
      this.ctx = this.canvas.getContext('2d', { alpha: true });
      if (!this.ctx) {
        this.canvas.remove();
        return false;
      }

      this.lastTimeSeen = v.currentTime;
      this.syncGeometry(true);

      // NOTE: the video is deliberately NOT hidden yet. It is hidden in arm(),
      // after the first frame has actually been captured and drawn — that way a
      // DRM / cross-origin / unsupported video never leaves a blank canvas over
      // a hidden picture.

      // --- CUT OUT IMMEDIATELY --------------------------------------------
      // Every one of these means the audio the speakers are about to play is no
      // longer the audio our buffered picture belongs to. Draining the buffer
      // would keep the picture moving for another `delayMs` after the user
      // acted, which reads as a broken player. Drop everything and hand the
      // real <video> back this instant, so the frame on screen is the true one.
      this.listen(v, 'pause', () => this.cutOut('pause'));
      this.listen(v, 'ended', () => this.cutOut('ended'));
      // Source swap (SPA navigation, ad transitions): the decoded content is
      // genuinely gone, so buffered frames are meaningless.
      this.listen(v, 'emptied', () => this.cutOut('emptied'));
      this.listen(v, 'loadstart', () => { markFresh(v); this.cutOut('loadstart'); });
      // Any seek — playing or paused. The founder's rule: skipping ahead must
      // stop the delayed picture instantly, not play out the last second first.
      this.listen(v, 'seeking', () => this.onSeek());

      this.listen(v, 'seeked', () => { markFresh(v); this.lastTimeSeen = v.currentTime; });
      this.listen(v, 'play', () => { markFresh(v); this.resumeDraw(); });
      // NOT 'playing': that also fires when a stall ends, and a stall is not a
      // fresh audio start — the speakers are still working through the audio
      // that was already in the pipe, so the delay must be eased back in, not
      // taken in full.
      this.listen(v, 'playing', () => { this.resumeDraw(); });
      this.listen(v, 'loadeddata', () => { this.syncGeometry(true); });
      this.listen(v, 'resize', () => { this.syncGeometry(true); });

      try {
        this.resizeObserver = new ResizeObserver(() => this.syncGeometry(false));
        this.resizeObserver.observe(v);
      } catch (e) { /* draw loop syncs geometry anyway */ }

      this.startCapture();
      this.resumeDraw();
      return true;
    }

    // A seek is a discontinuity in the AUDIO too, so the buffered picture is
    // instantly worthless. Exception: a live player nudges currentTime by a
    // few frames to hold the live edge, and that must not tear the delay down
    // or the player and the extension fight each other forever.
    //
    // This USED to gate the exception on isLive(v), which infers liveness from
    // `duration` being non-finite. That is right for hls.js/dash.js/Shaka, but
    // YouTube's own player reports a FINITE, growing duration during a live
    // event (the IFrame API docs: getDuration() "will return the elapsed time
    // since the live video stream began"). Gated that way, every YouTube
    // live-edge nudge was misread as a user seek: cutOut() fired, the buffer
    // was dropped, and the next arm() took the full delay again — a visible
    // jump-forward then freeze, once per nudge.
    //
    // The gate does not need liveness at all. No one drags a seek bar by less
    // than a quarter second — a deliberate seek is seconds or minutes. A jump
    // under LIVE_SEEK_EPSILON_MS is the PLAYER correcting itself (live edge,
    // or a rebuffer micro-adjustment), on live or VOD alike, and holding
    // through it costs at most one quarter-second of staleness in the
    // vanishingly rare case it was ever something else.
    onSeek() {
      const v = this.video;
      markFresh(v);
      const jump = Math.abs(v.currentTime - this.lastTimeSeen) * 1000;
      if (this.lastTimeSeen >= 0 && jump < LIVE_SEEK_EPSILON_MS) {
        log('sub-threshold time jump', Math.round(jump) + 'ms — holding (not a seek)');
        return;
      }
      this.cutOut('seek');
    }

    // Hide the real video and let the canvas take over. Only ever called once
    // we hold a real captured frame, and never while playback is stopped.
    arm(bmp) {
      if (this.armed || this.detached) return;
      const v = this.video;
      if (v.paused || v.ended || v.seeking) return;
      // Picture is about to come back, so the room must too. Reported before the
      // handover rather than after, because the audio has a pipeline's worth of
      // head start on the first frame we are about to show. `true` forces the
      // report even if this frame's own playing state hasn't changed, so the
      // background worker re-checks its cross-frame union right away instead of
      // waiting for the next heartbeat.
      reportPlaystate(true);
      // Never take the picture over in a tab nobody is looking at: rAF and
      // requestVideoFrameCallback are suspended there, so the canvas would be
      // frozen the moment it took over.
      if (!pageVisible()) return;

      this.armed = true;
      this.armedAt = performance.now();
      this.lastPresentAt = this.armedAt;
      if (this.canvas) this.canvas.style.display = '';
      this.syncGeometry(true);
      this.drawSource(bmp);
      this.savedVisibility = v.style.visibility;
      v.style.visibility = 'hidden';
      v.setAttribute(HIDDEN_ATTR, '1');
      S.reason = 'ok';
      reportPlaystate(true);

      // --- the mid-playback transition ------------------------------------
      // Fresh start (play, seek, new source): the audio starts now and lands
      // `delayMs` later, so holding this first frame until then IS the correct
      // picture. Take the delay in full.
      //
      // Otherwise the audio has been in flight for a while — the room went live
      // under a playing video, or we were just loaded, or the tab came back.
      // The correct picture is already in the past and unrecoverable, so ease
      // into alignment: start at zero delay and let the picture run at
      // 1/RAMP_FACTOR speed until it has fallen the full delay behind. No
      // freeze, no jump, no black, and the video element is never touched.
      const target = activeDelayMs();
      if (freshlyStarted(v)) {
        this.eff = target;
        this.rampRate = 0;
        this.ramped = false;
      } else {
        const rampMs = Math.max(RAMP_MIN_MS, Math.min(RAMP_MAX_MS, RAMP_FACTOR * target));
        this.eff = 0;
        this.rampRate = target > 0 ? target / rampMs : 0;
        this.ramped = true;
      }
      this.effAt = this.armedAt;

      log('armed', this.capW + 'x' + this.capH, '@', this.capFps + 'fps',
          'cap', this.capacity, 'frames', 'delay', target + 'ms',
          this.ramped ? '(ramping in over ' + Math.round(target / this.rampRate) + 'ms)' : '(from a fresh start)',
          isLive(v) ? '[live]' : '');
    }

    // The delay we are actually presenting with right now. Walks up to the
    // target at rampRate; drops to it at once (a shorter delay just means
    // throwing away the oldest frames, which is never visible).
    effectiveDelayMs(now) {
      const target = activeDelayMs();
      if (!this.effAt) { this.eff = target; this.effAt = now; return target; }
      const dt = Math.max(0, now - this.effAt);
      this.effAt = now;
      if (this.eff > target) {
        this.eff = target;
      } else if (this.eff < target) {
        this.eff = this.rampRate > 0
          ? Math.min(target, this.eff + dt * this.rampRate)
          : target;
        if (this.eff >= target) this.rampRate = 0;   // ramp finished
      }
      return this.eff;
    }

    // Show the real video again without tearing the pipeline down.
    disarm() {
      if (!this.armed) {
        if (this.canvas) this.canvas.style.display = 'none';
        return;
      }
      this.armed = false;
      this.armedAt = 0;
      try {
        this.video.style.visibility = this.savedVisibility || '';
        this.video.removeAttribute(HIDDEN_ATTR);
      } catch (e) { /* ignore */ }
      this.savedVisibility = null;
      if (this.ctx && this.canvas) {
        try { this.ctx.clearRect(0, 0, this.canvas.width, this.canvas.height); } catch (e) { /* ignore */ }
      }
      if (this.canvas) this.canvas.style.display = 'none';
    }

    // Stop presenting NOW: throw the buffer away and give the page its own
    // video element back in the same tick.
    cutOut(why) {
      if (this.detached) return;
      const wasArmed = this.armed;
      this.flush(false);
      this.disarm();
      this.drawSuspended = true;
      this.eff = 0;
      this.effAt = 0;
      this.rampRate = 0;
      if (wasArmed) {
        log('cut out:', why);
        S.reason = engageable() ? 'ready' : idleReason();
        // The audio decision lives in the background worker now (see below),
        // driven by playback state across every tab rather than by whether
        // THIS frame happened to be presenting. Report here only so a pause
        // is acted on in this tick instead of waiting up to a second.
        reportPlaystate(true);
      }
    }

    // --- geometry -----------------------------------------------------------

    syncGeometry(force) {
      if (this.detached) return;
      const v = this.video;
      if (!v.isConnected || !this.canvas || !this.canvas.isConnected) return;

      let vr;
      try {
        vr = v.getBoundingClientRect();
      } catch (e) { return; }

      const dpr = window.devicePixelRatio || 1;
      if (!force && this.lastRect && this.lastDpr === dpr &&
          Math.abs(vr.left - this.lastRect.left) < 0.5 &&
          Math.abs(vr.top - this.lastRect.top) < 0.5 &&
          Math.abs(vr.width - this.lastRect.width) < 0.5 &&
          Math.abs(vr.height - this.lastRect.height) < 0.5) {
        return;
      }
      this.lastRect = { left: vr.left, top: vr.top, width: vr.width, height: vr.height };
      this.lastDpr = dpr;

      const cs = this.canvas.style;

      // A collapsed / detached video: hide the overlay rather than paint a
      // stray rectangle somewhere.
      if (vr.width < 1 || vr.height < 1) {
        cs.display = 'none';
        return;
      }
      cs.display = this.armed ? '' : 'none';

      // Position against the real containing block. We never mutate the page's
      // own styles: forcing position:relative onto the video's parent could
      // re-anchor an absolutely-positioned video and shift layout.
      const op = this.canvas.offsetParent;
      let positioned = false;
      if (op) {
        try { positioned = getComputedStyle(op).position !== 'static'; } catch (e) { /* ignore */ }
      }
      if (op && positioned) {
        const opr = op.getBoundingClientRect();
        cs.position = 'absolute';
        cs.left = (vr.left - opr.left - op.clientLeft + op.scrollLeft) + 'px';
        cs.top = (vr.top - opr.top - op.clientTop + op.scrollTop) + 'px';
      } else if (op) {
        // offsetParent is body/html but static: the containing block is the
        // initial containing block at the document origin.
        cs.position = 'absolute';
        cs.left = (vr.left + window.scrollX) + 'px';
        cs.top = (vr.top + window.scrollY) + 'px';
      } else {
        // No offsetParent (fixed-position context, or a display:none ancestor):
        // track the viewport.
        cs.position = 'fixed';
        cs.left = vr.left + 'px';
        cs.top = vr.top + 'px';
      }
      cs.width = vr.width + 'px';
      cs.height = vr.height + 'px';

      try {
        const of = getComputedStyle(v).objectFit;
        // <video> default painting letterboxes ("contain"); only 'cover' and
        // 'fill' need different math.
        this.objectFit = (of === 'cover' || of === 'fill') ? of : 'contain';
      } catch (e) { /* keep previous */ }

      // Backing store: CSS size x devicePixelRatio, never larger than the
      // source and never larger than the capture cap.
      let bw = Math.max(1, Math.round(vr.width * dpr));
      let bh = Math.max(1, Math.round(vr.height * dpr));
      const vw = v.videoWidth, vh = v.videoHeight;
      if (vw && vh) {
        const limit = Math.min(vw, MAX_CAPTURE_WIDTH);
        if (bw > limit) {
          bh = Math.max(1, Math.round(bh * (limit / bw)));
          bw = limit;
        }
      }
      if (this.canvas.width !== bw || this.canvas.height !== bh) {
        this.canvas.width = bw;
        this.canvas.height = bh;
        if (this.current) this.drawSource(this.current.bmp);
      }
      this.planCapture();
    }

    // Decide capture size, frame rate and ring capacity from the video size and
    // the current delay, under a fixed memory budget.
    planCapture() {
      const v = this.video;
      const vw = v.videoWidth, vh = v.videoHeight;
      if (!vw || !vh) return;
      const wantW = this.canvas ? this.canvas.width : vw;
      let w = Math.min(vw, MAX_CAPTURE_WIDTH, Math.max(160, wantW));
      w = Math.max(2, Math.round(w / 2) * 2);
      let h = Math.max(2, Math.round((w * vh) / vw / 2) * 2);
      const bytes = w * h * 4;
      // Size for the TARGET delay, not the ramped one: the ring has to be able
      // to hold the full delay by the time the ramp reaches it.
      const delaySec = Math.max(0.05, activeDelayMs() / 1000);

      let fps = TARGET_FPS;
      const affordable = Math.floor(MAX_BUFFER_BYTES / bytes);
      if (affordable < delaySec * fps + 4) {
        fps = Math.max(MIN_FPS, Math.floor((affordable - 4) / delaySec));
      }
      const capacity = Math.max(4, Math.min(affordable, Math.ceil(delaySec * fps) + 6));

      if (w !== this.capW || h !== this.capH || fps !== this.capFps || capacity !== this.capacity) {
        log('plan', w + 'x' + h, fps + 'fps', capacity + ' frames',
            Math.round(capacity * bytes / 1e6) + 'MB');
      }
      this.capW = w; this.capH = h; this.frameBytes = bytes;
      this.capFps = fps; this.capacity = capacity;
      this.trim();
    }

    trim() {
      while (this.buffer.length > this.capacity ||
             (this.buffer.length > 2 && this.bufferBytes > MAX_BUFFER_BYTES)) {
        const old = this.buffer.shift();
        this.bufferBytes -= old.bytes;
        try { old.bmp.close(); } catch (e) { /* ignore */ }
      }
    }

    // --- capture ------------------------------------------------------------

    startCapture() {
      const v = this.video;
      if (typeof v.requestVideoFrameCallback === 'function') {
        const step = (now, metadata) => {
          if (this.detached) return;
          this.capture(metadata && metadata.expectedDisplayTime);
          this.vfcId = v.requestVideoFrameCallback(step);
        };
        this.vfcId = v.requestVideoFrameCallback(step);
      } else {
        // rAF fallback for engines without requestVideoFrameCallback.
        const step = () => {
          if (this.detached) return;
          this.capture();
          this.rafCapId = requestAnimationFrame(step);
        };
        this.rafCapId = requestAnimationFrame(step);
      }
    }

    capture(displayTime) {
      const v = this.video;
      // Playback stopped: capture nothing, and make sure we are not still
      // presenting stale frames (belt and braces for the event listeners).
      if (v.paused || v.ended) {
        if (this.armed) this.cutOut('stopped');
        return;
      }
      // Mid-seek the element may still be showing pre-seek frames; grabbing one
      // would re-arm on content that is about to be replaced.
      if (v.seeking) return;
      if (v.readyState < 2 || !v.videoWidth || !v.videoHeight) return;
      if (!this.capW) this.planCapture();
      if (!this.capW || !this.capH) return;

      const now = performance.now();
      // The frame we are about to grab is the one on screen now. rVFC's
      // expectedDisplayTime is the same clock and is more accurate, but a
      // future value would report a frame as newer than it is — clamp it.
      let stamp = now;
      if (typeof displayTime === 'number' && isFinite(displayTime) &&
          displayTime <= now + 1 && now - displayTime < 200) {
        stamp = displayTime;
      }

      if (now - this.lastCaptureTime < (1000 / this.capFps) - 2) return;
      // Don't queue captures faster than they complete. Checked before the rate
      // limiter is armed, so the next callback retries immediately.
      if (this.inflight >= 3) return;
      this.lastCaptureTime = now;

      const gen = this.gen;
      let promise;
      try {
        promise = (v.videoWidth > this.capW)
          ? createImageBitmap(v, { resizeWidth: this.capW, resizeHeight: this.capH, resizeQuality: 'medium' })
          : createImageBitmap(v);
      } catch (e) {
        this.onCaptureError(e);
        return;
      }
      this.inflight++;
      promise.then((bmp) => {
        this.inflight--;
        if (this.detached || gen !== this.gen) {
          try { bmp.close(); } catch (e) { /* ignore */ }
          return;
        }
        this.captureErrors = 0;
        this.captureCount++;
        this.lastFrameAt = performance.now();
        if (!this.armed) {
          this.arm(bmp);
          if (!this.armed) { try { bmp.close(); } catch (e) { /* ignore */ } return; }
        }
        this.insertFrame({ t: stamp, bmp, bytes: (bmp.width || this.capW) * (bmp.height || this.capH) * 4 });
        if (this.drawSuspended) this.resumeDraw();
      }).catch((e) => {
        this.inflight--;
        if (!this.detached && gen === this.gen) this.onCaptureError(e);
      });
    }

    // createImageBitmap resolves asynchronously and can complete out of order;
    // keep the buffer sorted by capture time.
    insertFrame(frame) {
      const arr = this.buffer;
      let i = arr.length - 1;
      while (i >= 0 && arr[i].t > frame.t) i--;
      arr.splice(i + 1, 0, frame);
      this.bufferBytes += frame.bytes;
      this.trim();
    }

    onCaptureError(e) {
      this.captureErrors++;
      const name = e && e.name;
      log('capture error', this.captureErrors, name, e && e.message);
      if (name === 'InvalidStateError') {
        // Several consecutive callbacks can race one quality/ad transition.
        // They are not independent failures. Keep the visible source and wait
        // for a decoded frame; the watchdog covers an already-armed pipeline.
        this.captureErrors = 0;
        return;
      }
      // A SecurityError is deterministic (EME-protected or tainted
      // cross-origin frames): there is no point retrying, and the video has not
      // been hidden yet, so the page is already showing correctly.
      const fatal = name === 'SecurityError';
      if (fatal || this.captureErrors >= MAX_CAPTURE_ERRORS) {
        this.disarm();
        failVideo(this.video, fatal ? 'protected' : 'capture-failed');
      }
    }

    // --- draw ---------------------------------------------------------------

    resumeDraw() {
      if (this.detached || this.rafDrawId) return;
      this.drawSuspended = false;
      const loop = () => {
        this.rafDrawId = 0;
        if (this.detached) return;
        this.drawTick();
        if (!this.drawSuspended && !this.detached) this.rafDrawId = requestAnimationFrame(loop);
      };
      this.rafDrawId = requestAnimationFrame(loop);
    }

    drawTick() {
      const v = this.video;

      // Not presenting: the real <video> is on screen and correct. Idle out
      // rather than spin while playback is stopped.
      if (!this.armed) {
        if (v.paused || v.ended) this.drawSuspended = true;
        return;
      }
      // Playback stopped between callbacks — cut out in this very tick.
      if (v.paused || v.ended) {
        this.cutOut('stopped');
        return;
      }
      // The tab went away between callbacks (or the video left the document).
      if (!pageVisible()) { this.cutOut('hidden'); return; }
      if (!v.isConnected) { this.cutOut('removed'); return; }

      // Track the video's box every frame: sites animate players (theater
      // mode, fullscreen transitions, responsive layouts) without firing any
      // event we could listen for.
      this.syncGeometry(false);
      const now = performance.now();
      if (!v.seeking) this.lastTimeSeen = v.currentTime;
      if (this.watchdog(now)) return;

      const target = now - this.effectiveDelayMs(now);
      const buf = this.buffer;
      let frame = null;
      while (buf.length && buf[0].t <= target) {
        // Present the newest frame that has reached the delay target. Testing
        // the following frame before consuming this one leaves the previous
        // picture onscreen for an extra frame even when this frame is ready.
        if (frame) { this.bufferBytes -= frame.bytes; try { frame.bmp.close(); } catch (e) { /* ignore */ } }
        frame = buf.shift();
      }
      if (frame) {
        this.bufferBytes -= frame.bytes;
        if (this.current) { try { this.current.bmp.close(); } catch (e) { /* ignore */ } }
        this.current = frame;
        this.drawSource(frame.bmp);
        this.lastPresentAt = now;
        // A pipeline that has been presenting happily for a while has earned
        // its self-heal budget back.
        if (now - this.armedAt > 8000 && S.rebuilds.get(v)) S.rebuilds.delete(v);
      }
    }

    // Presenting, playing, decoding — but nothing is reaching the screen.
    // Something in the capture or draw path is broken in a way nothing
    // reported. Tear the pipeline down and build a new one rather than sit on
    // a frozen canvas over a hidden video. Returns true if it healed.
    watchdog(now) {
      const v = this.video;
      if (!this.armed || v.paused || v.ended || v.seeking || v.readyState < 3) {
        this.stallSince = 0;
        this.lastMediaTime = v.currentTime;
        return false;
      }
      const moving = v.currentTime !== this.lastMediaTime;
      this.lastMediaTime = v.currentTime;
      if (!moving) { this.stallSince = 0; return false; }   // buffering: audio stalls too

      // While the buffer is filling (a fresh start holds one frame for the
      // whole delay, by design) nothing is expected to be presented yet.
      const expectPresent = (now - this.armedAt) > (this.eff + 700);
      const captureDead = now - this.lastFrameAt > SELF_HEAL_MS;
      const presentDead = expectPresent && now - this.lastPresentAt > SELF_HEAL_MS;
      if (!captureDead && !presentDead) { this.stallSince = 0; return false; }
      if (!this.stallSince) { this.stallSince = now; return false; }
      if (now - this.stallSince < SELF_HEAL_MS) return false;

      this.heal(captureDead ? 'no frames captured' : 'nothing presented');
      return true;
    }

    heal(why) {
      const v = this.video;
      const n = (S.rebuilds.get(v) || 0) + 1;
      S.rebuilds.set(v, n);
      log('self-heal (' + why + ') attempt', n);
      this.disarm();
      if (n > MAX_REBUILDS) {
        // Rebuilding is not helping. Hand the video back for good; the page is
        // then exactly as it would be without the extension.
        failVideo(v, 'capture-failed');
        return;
      }
      detachPipeline();
      S.reason = 'healing';
      scheduleEvaluate();
    }

    drawSource(src) {
      const c = this.canvas, ctx = this.ctx;
      if (!c || !ctx || !c.width || !c.height) return;
      const sw = src.videoWidth || src.width;
      const sh = src.videoHeight || src.height;
      if (!sw || !sh) return;
      const cw = c.width, ch = c.height;
      let dw, dh;
      if (this.objectFit === 'fill') {
        dw = cw; dh = ch;
      } else {
        const scale = this.objectFit === 'cover'
          ? Math.max(cw / sw, ch / sh)
          : Math.min(cw / sw, ch / sh);
        dw = sw * scale; dh = sh * scale;
      }
      const dx = (cw - dw) / 2, dy = (ch - dh) / 2;
      ctx.clearRect(0, 0, cw, ch);
      try {
        ctx.drawImage(src, dx, dy, dw, dh);
      } catch (e) {
        log('draw failed', e && e.name);
      }
    }

    flush(resume) {
      this.gen++;
      for (const f of this.buffer) {
        try { f.bmp.close(); } catch (e) { /* ignore */ }
      }
      this.buffer.length = 0;
      this.bufferBytes = 0;
      this.lastCaptureTime = 0;
      // The presented frame is stale too — don't let a resize redraw it.
      if (this.current) {
        try { this.current.bmp.close(); } catch (e) { /* ignore */ }
        this.current = null;
      }
      if (resume !== false) this.resumeDraw();
    }

    // --- teardown -----------------------------------------------------------

    detach() {
      if (this.detached) return;
      this.detached = true;
      this.gen++;

      if (this.vfcId && typeof this.video.cancelVideoFrameCallback === 'function') {
        try { this.video.cancelVideoFrameCallback(this.vfcId); } catch (e) { /* ignore */ }
      }
      if (this.rafCapId) cancelAnimationFrame(this.rafCapId);
      if (this.rafDrawId) cancelAnimationFrame(this.rafDrawId);
      if (this.resizeObserver) {
        try { this.resizeObserver.disconnect(); } catch (e) { /* ignore */ }
      }
      for (const [target, type, fn, opts] of this.listeners) {
        try { target.removeEventListener(type, fn, opts); } catch (e) { /* ignore */ }
      }
      this.listeners.length = 0;

      for (const f of this.buffer) {
        try { f.bmp.close(); } catch (e) { /* ignore */ }
      }
      this.buffer.length = 0;
      this.bufferBytes = 0;
      if (this.current) {
        try { this.current.bmp.close(); } catch (e) { /* ignore */ }
        this.current = null;
      }

      // Restore the page exactly.
      this.disarm();

      if (this.canvas) {
        try { this.canvas.remove(); } catch (e) { /* ignore */ }
        this.canvas = null;
      }
    }

    healthCheck() {
      if (this.detached) return 'detached';
      const v = this.video;
      if (!v.isConnected) return 'gone';
      if (v.parentElement !== this.parent) return 'reparented';
      if (this.canvas && !this.canvas.isConnected) {
        // Site wiped its container's children; try to reinsert.
        try { v.insertAdjacentElement('afterend', this.canvas); } catch (e) { return 'gone'; }
      }
      this.syncGeometry(false);
      if (!this.rafDrawId && !this.drawSuspended) this.resumeDraw();

      // Second line of defence for the watchdog above: that one lives inside
      // the draw loop, so it cannot notice the draw loop itself dying. This
      // runs off the interval timer, which keeps firing regardless.
      const mediaAdvanced = v.currentTime !== this.lastHealthMediaTime;
      this.lastHealthMediaTime = v.currentTime;
      if (this.armed && !v.paused && !v.ended && !v.seeking &&
          v.readyState >= 3 && mediaAdvanced) {
        const now = performance.now();
        const quiet = now - Math.max(this.lastPresentAt, this.armedAt);
        if (quiet > this.eff + SELF_HEAL_MS + 1500) {
          this.heal('draw loop silent for ' + Math.round(quiet) + 'ms');
          return 'healing';
        }
      }
      return 'ok';
    }
  }

  // -------------------------------------------------------------------------
  // Beacon polling.
  //
  // The page cannot reach 127.0.0.1 over plain HTTP from an https document, so
  // the service worker does the fetch and we ask it for the answer. It caches,
  // so a page full of frames costs at most one request per second.
  //
  // MV3 kills the worker aggressively. A failed ask is almost always "the
  // worker was asleep", and the ask itself is what revives it — so failures
  // retry fast and the last known reading is kept for BEACON_GRACE_MS rather
  // than flapping the picture back and forth.

  function applyStatus(st) {
    const next = (st && typeof st === 'object')
      ? {
          running: !!st.running,
          streaming: !!st.streaming,
          delayMs: Math.max(0, Math.min(MAX_DELAY, Math.round(Number(st.delayMs) || 0)))
        }
      : { running: false, streaming: false, delayMs: 0 };

    const changed = !S.daliKnown ||
      next.running !== S.dali.running ||
      next.streaming !== S.dali.streaming ||
      next.delayMs !== S.dali.delayMs;
    S.daliKnown = true;
    S.dali = next;
    if (!changed) return;
    log('beacon', JSON.stringify(next), 'trim', S.trim);
    if (S.pipeline && !S.pipeline.detached) S.pipeline.planCapture();
    scheduleEvaluate();
  }

  function onBeaconFailure() {
    S.beaconFails++;
    if (!S.beaconFailSince) S.beaconFailSince = Date.now();
    const down = Date.now() - S.beaconFailSince;
    if (down < BEACON_GRACE_MS) {
      // Worker asleep / recycled: ask again straight away. The message is what
      // wakes it, so the next attempt usually succeeds.
      S.lastPollAt = 0;
      if (!S.retryTimer) {
        S.retryTimer = setTimeout(() => {
          S.retryTimer = 0;
          pollBeacon(true);
        }, Math.min(600, 120 * S.beaconFails));
      }
      return;
    }
    // Really gone. Stop delaying rather than holding the picture on a guess.
    log('beacon unreachable for', down + 'ms — standing down');
    applyStatus(null);
  }

  function pollBeacon(force) {
    if (S.dead || S.suspended || !extensionAlive()) return;
    if (S.pollInflight) return;
    const now = Date.now();
    if (!force && now - S.lastPollAt < POLL_MIN_GAP_MS) return;
    S.lastPollAt = now;
    S.pollInflight = true;
    let p;
    try {
      p = chrome.runtime.sendMessage({ type: 'beacon' });
    } catch (e) {
      S.pollInflight = false;
      onBeaconFailure();
      return;
    }
    if (!p || typeof p.then !== 'function') { S.pollInflight = false; onBeaconFailure(); return; }
    p.then((st) => {
      S.pollInflight = false;
      if (S.dead || S.suspended) return;
      // A dead worker resolves with undefined rather than rejecting.
      if (!st || typeof st !== 'object') { onBeaconFailure(); return; }
      S.beaconFails = 0;
      S.beaconFailSince = 0;
      applyStatus(st);
    }).catch(() => {
      S.pollInflight = false;
      if (S.dead || S.suspended) return;
      onBeaconFailure();
    });
  }

  // -------------------------------------------------------------------------
  // Worker port.
  //
  // Opened only while a pipeline exists, for two reasons:
  //   - it keeps the service worker alive for exactly as long as we depend on
  //     it, so there is no revival latency in the middle of a delayed video;
  //   - if the extension is reloaded, onDisconnect fires in this (now
  //     orphaned) world, which is the only chance we get to hand the page back
  //     before the isolated world is abandoned with a hidden <video> in it.

  function openPort() {
    if (S.port || !extensionAlive()) return;
    try {
      const port = chrome.runtime.connect({ name: 'dali-sync' });
      S.port = port;
      port.onDisconnect.addListener(() => {
        // Consume callback-scoped navigation errors before normal reconnect cleanup.
        const error = chrome.runtime.lastError;
        if (error) log('port closed', error.message);
        if (S.port === port) S.port = null;
        if (!extensionAlive()) {
          // The extension was reloaded or disabled out from under us.
          teardownAll('extension reloaded');
        }
      });
    } catch (e) {
      S.port = null;
    }
  }

  function closePort() {
    if (!S.port) return;
    try { S.port.disconnect(); } catch (e) { /* ignore */ }
    S.port = null;
  }

  // -------------------------------------------------------------------------
  // Ticking. setInterval is throttled hard in background tabs and rAF stops
  // when the tab is hidden, so both drive the same tick and whichever fires
  // first wins (the tick itself is rate-limited).

  // --- audio cut: REPORTING only ---------------------------------------------
  //
  // Tell the background worker whether a video is playing in THIS frame. The
  // DECISION — should the room be silent right now — is made in background.js,
  // not here. See the comment there for the full mechanism; the short version:
  //
  // THE BUG THIS REPLACES. Each frame used to decide for itself, from only the
  // video(s) it could see, and would keep re-asserting "silence the room" for
  // up to 15 s after ITS OWN video paused. A second tab is a completely
  // separate isolated world with its own separate state, so when it started
  // playing it saw "nothing has ever been cut here" and never sent /resume —
  // the room stayed silent while that second tab was audibly playing. The only
  // process that ever saw both tabs at once is the background worker, so the
  // decision has to live there.
  //
  // A content script's whole job now is to answer one question honestly and
  // often: is a video playing in my frame? `force` sends the report even if it
  // matches what was last sent, which matters for the heartbeat (see tick()) —
  // the background worker treats a frame that stops reporting as gone, so a
  // page that is silently doing nothing still has to check back in.

  let lastReportedPlaying = null;
  let lastReportAt = 0;

  // THE HEARTBEAT, AND THE BUG IT FIXES (rooms going silent mid-video).
  //
  // The worker drops a frame from its union after FRAME_STALE_MS (6 s) without
  // a report, and reads the resulting empty union as "nothing is playing
  // anywhere" — which cuts the room. So "playing" is not a fact this frame can
  // state once; it is a fact it has to keep restating.
  //
  // It didn't. tick() called reportPlaystate(false), and this function returned
  // early whenever the value matched the last one sent — so a video that simply
  // played, with no pause/seek/loadeddata to force a report, sent exactly ONE
  // message and then went quiet. Six seconds in, the worker aged the frame out,
  // found nobody playing, and told the app to silence the speakers. The room
  // went dead on a video that was still running, and stayed dead (the worker
  // re-asserts the cut every 900 ms) until some stray media event happened to
  // force a fresh report. That is the "sometimes a YouTube video has no audio".
  //
  // So the report is now also time-driven: same value or not, every frame that
  // has media checks in at least this often. 2 s against a 6 s staleness window
  // means two heartbeats can be lost entirely — to a busy main thread, a
  // throttled background tab, a sleeping worker — before anything changes.
  const REPORT_HEARTBEAT_MS = 2000;

  function reportPlaystate(force) {
    if (!extensionAlive()) return;
    const playing = anyPlayingMedia();
    const now = Date.now();
    if (!force && playing === lastReportedPlaying &&
        now - lastReportAt < REPORT_HEARTBEAT_MS) return;
    lastReportedPlaying = playing;
    lastReportAt = now;
    const p = S.pipeline;
    const msg = { type: 'playstate', playing: playing,
      cutEligible: !!(p && p.armed && !p.detached && pageVisible() &&
        scoreVideo(p.video) > 0 && !p.video.muted && p.video.volume > 0) };
    if (playing) {
      // For the app's now-playing line. The worker unions frames per tab and
      // forwards the list to the beacon; none of this touches the delay.
      msg.title = String(document.title || '').slice(0, 80);
      msg.host = location.hostname;
      msg.live = liveNow();
      msg.held = !!(S.pipeline && S.pipeline.armed && !S.pipeline.detached);
      msg.art = pageArt();
    }
    try {
      const p = chrome.runtime.sendMessage(msg);
      if (p && p.catch) p.catch(() => {});   // fire and forget
    } catch (e) { /* worker gone; our next tick (or its revival) retries */ }
  }

  // Explicit "I am gone" — used on teardown so the background worker's union
  // drops this frame immediately instead of waiting out its staleness window.
  function reportGone() {
    if (!extensionAlive()) return;
    lastReportedPlaying = false;
    lastReportAt = Date.now();
    try {
      const p = chrome.runtime.sendMessage({ type: 'playstate', playing: false, gone: true });
      if (p && p.catch) p.catch(() => {});
    } catch (e) { /* ignore */ }
  }

  // Is any media in this frame actually producing audio right now?
  //
  // <audio> counts. The question the worker unions across frames is "is the
  // browser making sound", not "is a picture moving" — and the answer decides
  // whether the room is silenced. Counting only <video> meant a tab playing
  // SoundCloud or a podcast player was invisible, so an unrelated paused video
  // in another tab could cut the room while it was audibly playing. The delay
  // pipeline still only ever attaches to <video>; this is a separate question.
  function allMedia() {
    const out = allVideos();
    try {
      for (const a of document.querySelectorAll('audio')) out.push(a);
    } catch (e) { /* detached */ }
    return out;
  }

  function anyPlayingMedia() {
    for (const v of allMedia()) {
      try {
        // Network buffering and seek/source transitions do not mean the user
        // paused. Cutting the room there discards audio already in flight and
        // races the next decoded YouTube segment. Keep playback intent alive.
        if (v.isConnected && !v.paused && !v.ended) return true;
      } catch (e) { /* detached */ }
    }
    return false;
  }

  function tick() {
    if (!extensionAlive()) { teardownAll('context invalidated'); return; }
    S.lastTickAt = performance.now();
    pollBeacon(false);
    reportPlaystate(false);
    healthTick();
  }

  function rafTick() {
    S.tickRaf = 0;
    if (!S.ticking) return;
    if (performance.now() - S.lastTickAt >= POLL_MS) tick();
    if (S.ticking) S.tickRaf = requestAnimationFrame(rafTick);
  }

  function startTicking() {
    if (S.ticking) return;
    S.ticking = true;
    S.tickTimer = setInterval(tick, POLL_MS);
    S.tickRaf = requestAnimationFrame(rafTick);
    pollBeacon(true);
  }

  function stopTicking() {
    if (!S.ticking) return;
    S.ticking = false;
    clearInterval(S.tickTimer);
    S.tickTimer = 0;
    if (S.tickRaf) cancelAnimationFrame(S.tickRaf);
    S.tickRaf = 0;
    if (S.retryTimer) { clearTimeout(S.retryTimer); S.retryTimer = 0; }
  }

  // -------------------------------------------------------------------------
  // Orchestration

  function detachPipeline() {
    if (S.pipeline) {
      S.pipeline.detach();
      S.pipeline = null;
    }
    closePort();
  }

  function scheduleEvaluate() {
    if (S.evalTimer || S.dead || S.suspended) return;
    S.evalTimer = setTimeout(() => {
      S.evalTimer = 0;
      evaluate();
    }, 100);
  }

  function evaluate() {
    if (S.dead || S.suspended) return;
    if (!extensionAlive()) { teardownAll('context invalidated'); return; }

    const best = findBestVideo();
    S.lastBest = best.video;
    S.lastBestArea = best.area;

    // A video ANYWHERE on the page is the reason to talk to the beacon — not
    // just a currently-eligible one. A player that is still zero-sized, or
    // behind an ad, or in a background tab, becomes eligible without firing any
    // event, and the tick is what notices.
    //
    // The tick is also this frame's heartbeat to the worker (see
    // reportPlaystate), so a frame that is only playing <audio> has to keep
    // ticking too — otherwise it ages out of the union and a paused video in
    // some other tab silences the room on top of it.
    if (best.any || anyPlayingMedia()) startTicking(); else stopTicking();

    if (!best.video) {
      detachPipeline();
      S.reason = 'no-video';
      return;
    }

    if (!engageable()) {
      detachPipeline();
      S.reason = idleReason();
      return;
    }

    // Hysteresis: keep the current video unless the challenger clearly wins.
    let target = best.video;
    if (S.pipeline && !S.pipeline.detached && S.pipeline.video !== best.video) {
      const curScore = scoreVideo(S.pipeline.video);
      if (curScore > 0 && best.score < curScore * SWITCH_HYSTERESIS) {
        target = S.pipeline.video;
      }
    }

    const issue = S.videoIssues.get(target);
    if (issue || isProtected(target)) {
      detachPipeline();
      S.reason = issue || 'protected';
      return;
    }
    if (document.pictureInPictureElement === target) {
      detachPipeline();
      S.reason = 'pip';
      return;
    }
    const fs = document.fullscreenElement || document.webkitFullscreenElement;
    if (fs === target) {
      // When the <video> element ITSELF is fullscreen, nothing else can be
      // composited over it — step aside (the video plays undelayed). YouTube
      // fullscreens the player container, so this doesn't apply there.
      detachPipeline();
      S.reason = 'fullscreen-video';
      return;
    }

    if (S.pipeline && !S.pipeline.detached && S.pipeline.video === target) {
      S.pipeline.planCapture();
      const want = S.pipeline.armed ? 'ok'
        : ((target.paused || target.ended) ? 'ready' : 'starting');
      S.reason = want;
      return;
    }

    detachPipeline();
    const p = new Pipeline(target);
    if (p.attach()) {
      S.pipeline = p;
      openPort();
      S.reason = (target.paused || target.ended) ? 'ready' : 'starting';
      log('attaching to', target.videoWidth + 'x' + target.videoHeight, '@', location.hostname);
    } else {
      p.detach();
      S.reason = 'attach-failed';
    }
  }

  function healthTick() {
    const p = S.pipeline;
    if (p && !p.detached) {
      if (!S.port) openPort();
      const status = p.healthCheck();
      if (status !== 'ok') {
        if (status !== 'healing') log('health:', status);
        detachPipeline();
        scheduleEvaluate();
        return;
      }
      const best = findBestVideo();
      S.lastBest = best.video;
      S.lastBestArea = best.area;
      if (best.video !== p.video) scheduleEvaluate();
    } else {
      evaluate();
    }
  }

  // --- page events ---------------------------------------------------------

  function onMediaEvent(e) {
    const v = e.target;
    // <audio> is here for the playstate report only (see anyPlayingMedia): an
    // audio element that starts playing has to wake this frame's heartbeat, or
    // a page that is only playing sound never checks in at all. markFresh and
    // the pipeline below stay video-only.
    if (!v || (v.tagName !== 'VIDEO' && v.tagName !== 'AUDIO')) return;
    if (v.tagName === 'AUDIO') { reportPlaystate(true); scheduleEvaluate(); return; }
    if (e.type === 'emptied' || e.type === 'loadstart') {
      // YouTube reuses one element for ads and the next watch-page source.
      // A failure belongs to that source, not to the element for its lifetime.
      S.videoIssues.delete(v);
      S.rebuilds.delete(v);
    }
    // Each of these means the audio restarts from a known point, so the picture
    // should hold the first frame until that audio lands rather than ease in.
    // (See arm().) 'playing' is deliberately absent — it also fires when a
    // rebuffer ends, and the speakers play straight through a rebuffer.
    if (e.type === 'play' || e.type === 'seeked' || e.type === 'emptied') {
      markFresh(v);
    }
    // These are capture-phase listeners on document, so they see EVERY video on
    // the page — including ones we are not attached to and ones added later.
    // That makes this the right place to report from: the room should follow
    // what is actually playing on the page, not just what we happen to be
    // presenting. `force` so a pause/play is reported this instant rather than
    // waiting for the next heartbeat.
    reportPlaystate(true);
    scheduleEvaluate();
  }

  function onEncrypted(e) {
    const v = e.target;
    if (v && v.tagName === 'VIDEO') {
      log('EME detected — protected video, cannot delay');
      failVideo(v, 'protected');
    }
  }

  function onPipChange() {
    // Entering PiP moves the picture to a window we cannot draw on: stop dead.
    if (S.pipeline && !S.pipeline.detached && document.pictureInPictureElement) {
      S.pipeline.cutOut('pip');
    }
    scheduleEvaluate();
  }

  function onFullscreenChange() {
    const p = S.pipeline;
    if (p && !p.detached) {
      const fs = document.fullscreenElement || document.webkitFullscreenElement;
      // Only the fullscreened subtree is composited. If our canvas is outside
      // it (most commonly: the <video> element itself went fullscreen) there is
      // no way to present, so hand the picture back in the same tick instead of
      // hiding the video behind an invisible canvas.
      if (fs && p.canvas && !fs.contains(p.canvas)) p.cutOut('fullscreen');
      else p.syncGeometry(true);
    }
    scheduleEvaluate();
  }

  function onWindowResize() {
    if (S.pipeline && !S.pipeline.detached) S.pipeline.syncGeometry(true);
    scheduleEvaluate();
  }

  function onScroll() {
    // Capture-phase scroll also sees nested Reels/Shorts feed containers.
    // Release an invisible source now; debounce selection during the swipe.
    const p = S.pipeline;
    if (p && !p.detached && scoreVideo(p.video) === 0) detachPipeline();
    scheduleEvaluate();
  }

  function onVisibilityChange() {
    if (!pageVisible()) {
      // Tab going away: stop presenting immediately, exactly as on pause. Held
      // frames would be stale by the time it came back anyway — rAF and
      // requestVideoFrameCallback are both suspended while hidden.
      if (S.pipeline && !S.pipeline.detached) S.pipeline.cutOut('hidden');
      return;
    }
    // Coming back: the beacon reading may be a minute old (setInterval is
    // throttled to a crawl in hidden tabs), so ask again before deciding.
    if (S.pipeline && !S.pipeline.detached) {
      S.pipeline.syncGeometry(true);
      S.pipeline.resumeDraw();
    }
    pollBeacon(true);
    scheduleEvaluate();
  }

  function onSpaNavigate() {
    // YouTube SPA navigation: same or swapped <video>. The old picture is gone,
    // so drop it in the same tick rather than playing it out over the new page.
    if (S.pipeline && !S.pipeline.detached) S.pipeline.cutOut('navigate');
    scheduleEvaluate();
  }

  function mutationTouchesVideo(mutations) {
    for (const m of mutations) {
      for (const n of m.addedNodes) {
        if (n.nodeName === 'VIDEO') return true;
        if (n.nodeType === 1 && n.querySelector && n.querySelector('video')) return true;
      }
      for (const n of m.removedNodes) {
        if (n.nodeName === 'VIDEO') return true;
        if (n.nodeType === 1 && n.querySelector && n.querySelector('video')) return true;
      }
    }
    return false;
  }

  function startScanning() {
    if (S.scanning) return;
    S.scanning = true;

    // Capture-phase listeners on document catch media events from any video,
    // including ones added later (media events don't bubble).
    document.addEventListener('play', onMediaEvent, true);
    document.addEventListener('playing', onMediaEvent, true);
    document.addEventListener('pause', onMediaEvent, true);
    document.addEventListener('seeked', onMediaEvent, true);
    document.addEventListener('emptied', onMediaEvent, true);
    document.addEventListener('loadstart', onMediaEvent, true);
    document.addEventListener('loadeddata', onMediaEvent, true);
    document.addEventListener('encrypted', onEncrypted, true);
    document.addEventListener('enterpictureinpicture', onPipChange, true);
    document.addEventListener('leavepictureinpicture', onPipChange, true);
    document.addEventListener('fullscreenchange', onFullscreenChange);
    document.addEventListener('webkitfullscreenchange', onFullscreenChange);
    document.addEventListener('visibilitychange', onVisibilityChange);
    window.addEventListener('resize', onWindowResize);
    window.addEventListener('scroll', onScroll, { capture: true, passive: true });
    // YouTube SPA navigation; harmless elsewhere. The MutationObserver below is
    // the generic fallback for element replacement.
    window.addEventListener('yt-navigate-start', onSpaNavigate, true);
    window.addEventListener('yt-navigate-finish', onSpaNavigate, true);
    window.addEventListener('popstate', onSpaNavigate);

    try {
      S.mutationObserver = new MutationObserver((mutations) => {
        // The video being ripped out of the DOM has to stop the picture in the
        // same tick, not on the next 1 s health tick.
        const p = S.pipeline;
        if (p && !p.detached && !p.video.isConnected) {
          p.cutOut('removed');
          detachPipeline();
        }
        if (mutationTouchesVideo(mutations)) scheduleEvaluate();
      });
      S.mutationObserver.observe(document.documentElement || document, {
        childList: true,
        subtree: true
      });
    } catch (e) { /* the tick timer covers it */ }

    log('scanning', location.hostname);
  }

  function stopScanning() {
    if (!S.scanning) return;
    S.scanning = false;

    document.removeEventListener('play', onMediaEvent, true);
    document.removeEventListener('playing', onMediaEvent, true);
    document.removeEventListener('pause', onMediaEvent, true);
    document.removeEventListener('seeked', onMediaEvent, true);
    document.removeEventListener('emptied', onMediaEvent, true);
    document.removeEventListener('loadstart', onMediaEvent, true);
    document.removeEventListener('loadeddata', onMediaEvent, true);
    document.removeEventListener('encrypted', onEncrypted, true);
    document.removeEventListener('enterpictureinpicture', onPipChange, true);
    document.removeEventListener('leavepictureinpicture', onPipChange, true);
    document.removeEventListener('fullscreenchange', onFullscreenChange);
    document.removeEventListener('webkitfullscreenchange', onFullscreenChange);
    document.removeEventListener('visibilitychange', onVisibilityChange);
    window.removeEventListener('resize', onWindowResize);
    window.removeEventListener('scroll', onScroll, true);
    window.removeEventListener('yt-navigate-start', onSpaNavigate, true);
    window.removeEventListener('yt-navigate-finish', onSpaNavigate, true);
    window.removeEventListener('popstate', onSpaNavigate);

    if (S.mutationObserver) {
      S.mutationObserver.disconnect();
      S.mutationObserver = null;
    }
    if (S.evalTimer) {
      clearTimeout(S.evalTimer);
      S.evalTimer = 0;
    }
  }

  // Hand the page back exactly as we found it and stop doing anything at all.
  // This instance never comes back: it is called when the extension has been
  // reloaded out from under us (our chrome.* APIs are dead but our JS and our
  // DOM changes are still here) or when a fresh injection takes over.
  function teardownAll(why) {
    if (S.dead) return;
    S.dead = true;
    log('teardown:', why);
    // Tell the background worker this frame is gone BEFORE tearing down, so
    // its cross-frame union drops us immediately rather than waiting out the
    // staleness window — the app's own ~4 s dead-man expiry is the backstop
    // for that, not the plan.
    reportGone();
    stopTicking();
    stopScanning();
    detachPipeline();
    closePort();
    cleanupStaleArtifacts();
  }

  // -------------------------------------------------------------------------
  // Boot

  window.addEventListener('pagehide', () => {
    if (S.dead) return;
    S.suspended = true;
    // Leaving the page: hand the picture back before anything is painted for
    // the next document. NOT once-only — a page can come back from the
    // back/forward cache, and it has to work when it does.
    if (S.pipeline && !S.pipeline.detached) S.pipeline.cutOut('pagehide');
    // Say so explicitly. Ticking stops here, so without this the frame's last
    // word to the worker is "playing", and the union keeps believing it for the
    // whole staleness window after the page is already gone.
    reportGone();
    stopTicking();
    stopScanning();
    detachPipeline();
  });

  window.addEventListener('pageshow', () => {
    // Restored from the back/forward cache: the document is alive again but no
    // content script is re-injected, so re-arm everything ourselves.
    if (S.dead || !extensionAlive()) return;
    S.suspended = false;
    startScanning();
    scheduleEvaluate();
  });

  window.__daliVideoSync = {
    version: VERSION,
    build: BUILD,
    alive: extensionAlive,
    active: () => S.scanning && !S.dead,
    teardown: teardownAll
  };

  cleanupStaleArtifacts();
  loadStorage();
  startScanning();
  scheduleEvaluate();

  // Test hook. A real page never sees this — content scripts live in an
  // isolated world — but the harness runs this file directly and needs it.
  window.__daliSync = {
    S, evaluate, applyStatus, activeDelayMs, engageable, teardownAll, allVideos,
    version: VERSION, build: BUILD,
    effDelayMs: () => (S.pipeline && !S.pipeline.detached ? S.pipeline.eff : 0),
    ramping: () => !!(S.pipeline && !S.pipeline.detached && S.pipeline.ramped &&
                      S.pipeline.rampRate > 0)
  };
})();
