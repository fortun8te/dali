# Chrome sync repair, 17 October 2026

Extension 1.2.5, build `2026-10-17.d`. Canonical source is
`/Users/michael/Projects/dali-v2`, branch `claude/startup-hardening`.
The checkout was clean before this repair. No native app, engine, audio
preferences, speaker calibration, signing, or browser profile preferences
were changed.

## Reproduced defects and fixes

1. At a four-second target, 1280 × 2276 portrait frames could afford only
   23 buffered frames while capture stayed at ten frames per second. The
   buffer silently discarded history needed for the requested delay. The
   planner now reduces capture dimensions when necessary, and consistently
   reserves six frames of headroom.
2. Bitmap capture promises can finish out of order. Sorting pending frames
   alone allowed an older completion to rewind a newer displayed picture.
   Frames no newer than the displayed frame are now closed and discarded.
3. A pause-tail transition invalidated the status cache and forgot its pending
   request. Another read then started concurrently, allowing an older response
   to overwrite newer status. Cache invalidation now preserves ownership of
   the active request. The regression observed three status requests before
   the fix and one shared request afterward.

4. A site cloning an active video copied the hidden inline style. The new
   pipeline treated that inherited style as original, so stopping sync left
   the replacement invisible. Original visibility now travels with the video
   in a local DOM marker and is restored for clones and orphaned instances.
   Discovery also restores paused or unarmed clones before selection; it
   preserves the current active pipeline owner. Two additional regressions
   failed before that adoption fix and now pass.
   The native replacement test reproduced this before the deterministic test
   and fix were added.

5. Chrome implements automatic looping with native seeking/seeked events.
   Those were treated as manual skips, flushing the picture and restarting its
   delay at every wrap. A three-second native loop reproduced this twice.
   Narrow end-to-start wraps now keep the monotonic frame history. Manual
   rewinds, non-looping seeks, jumps elsewhere, and high-speed manual seeks
   retain their immediate cleanup. Native post-fix evidence shows two loops,
   281 samples, one pipeline generation, and an uninterrupted 700 ms target.
   The browser does not expose a separate automatic-loop event, so an exact
   manual end-to-start seek inside the narrow loop window is indistinguishable.

Each new regression failed against its previous implementation. All 78
extension tests pass after the fixes.

## Research and design decisions

Research used current primary browser documentation and standards, with
separate searches for frame timing, background throttling, media capture,
bitmap lifetime, and Manifest V3 worker lifecycle.

- [Google's video-frame callback guidance](https://web.dev/articles/requestvideoframecallback-rvfc)
  distinguishes compositor display deadlines from media timestamps. Keep
  the existing display-time clock and independent picture buffer. Seeking
  or slowing the real video also moves its audio and cannot cancel AirPlay
  audio delay.
- [Chrome worker lifecycle](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle)
  documents worker termination and notes that opening a port alone no longer
  resets the idle timer. The existing periodic messages and revival path are
  therefore necessary. Do not rely on a permanently open port.
- [Chrome timer throttling](https://developer.chrome.com/blog/timer-throttling-in-chrome-88)
  documents background timer limits. Preserve visibility teardown and fresh
  re-engagement rather than replaying stale history when a page returns.
- [The HTML ImageBitmap standard](https://html.spec.whatwg.org/multipage/imagebitmap-and-animations.html)
  defines asynchronous capture, resize options, and explicit resource closure.
  Resize to preserve the delay budget and release rejected completions.
- [Media capture from DOM elements](https://www.w3.org/TR/mediacapture-fromelement/)
  documents capture and origin constraints. CaptureStream is not a universal
  replacement for the existing independent frame buffer, especially for
  protected or inaccessible content.

- [HTML media playback](https://html.spec.whatwg.org/multipage/media.html#playing-the-media-resource)
  explicitly implements looping as a seek to the earliest possible position.
  This matches the native reproduction and explains why seeking alone cannot
  mean the source audio discontinuously changed.

Native Chrome tests confirmed that hiding the real video did not stop frame
callbacks in the tested Chrome for Testing 153.0.8010.12. No speculative change
was made to the compositor strategy.

## Verification

- Full `scripts/check.sh` passed, including Swift regressions, production
  capture lifecycle, volume responsiveness, 696 actual controller checks,
  engine provenance and C checks, 17 onboarding/install checks, extension
  tests, complete unsigned app compilation, and extension packaging.
- `native-check.py` runs actual production content code with native video
  frame callbacks and ImageBitmaps in a separate, muted Chrome for Testing
  profile. The app beacon and extension APIs are stubbed. It never contacts
  the running DALI app or attaches to personal Chrome.
- Requested 300, 700, and 2000 ms delays produced 50, 47, and 50 valid samples.
  Medians were 333, 733, and 2033 ms. No blank samples occurred. Frame
  quantization and sampling contribute to the observed extra frame.
- Native checks cover pause restoration, seek recovery, explicit app-off
  restoration and restart, cached-page return, video-element replacement,
  final overlay cleanup, and unhandled page errors.

The full gate was rerun for build `2026-10-17.d` and passed all 78 browser
regressions plus the native app, engine and installer checks. This run predates
the separate capture-recovery budget repair described below.

The additional real-MV3 run loads the actual manifest, background worker,
beacon client and isolated content script. Only its copied beacon endpoint
points to an isolated fake app. Three requested delays produced 51 samples
each, with medians 333, 733 and 2000 ms, and no blank samples. Actual pause/resume
requests, extension reload, app stop/restart and video replacement recovered.
The recorded runtime exception count was zero. See `mv3-check.json`.

Test setup research identified Chrome's restriction on reloading command-line
extensions with developer mode off. [Chromium issue 402532200](https://issues.chromium.org/issues/402532200)
documents the behavior. The final runner installs with the supported
[DevTools Extensions API](https://chromedevtools.github.io/devtools-protocol/tot/Extensions/)
and enables developer mode through Chrome's own API in the disposable profile.
Hand-written profile preferences and the CDP install marker alone did not
survive the exact Chrome 153 reload policy. Personal Chrome's developer mode
and security preferences were never changed.

Evidence and a distributable archive are under
`build/chrome-sync-20261017/`. The full check log is `full-check.log` and
native measurements are `native-check.json`.

## Actual integration

Chrome's registered unpacked extension is
`/Users/michael/Downloads/beam/chrome-extension`, extension ID
`poefoljlkpibenmclbekmpjhcmfkbdbj`. It is not the canonical source folder or
the managed extension folder. Before copying, all seven registered runtime
files were verified identical to canonical HEAD. Originals were backed up in
`build/chrome-sync-20261017/installed-extension-backup`.

Only those runtime files were replaced. The existing extension worker then
invoked its own reload through the existing debugger connection. The worker
re-injected content scripts without navigating, activating, or reloading
personal tabs. DALI's live beacon subsequently reported version 1.2.5 and
build `2026-10-17.d`. Readback from the active browser tab's four frames also
confirmed the new build was active.

The running native DALI app remains unchanged. The current app's older bundled
copy does not refresh this unmanaged legacy registration. Future native app
releases must package the canonical extension; this change is already in the
canonical packaging input. The signed installed bundle was not modified.

## Limits still requiring separate evidence

The 27 September user feedback said Instagram probably should not try sync,
then added that fixing it would be welcome. The bypass was an assistant's
pragmatic workaround, not a permanent user prohibition. It remains enabled
until live Reel behavior can be proved reliable; the loop and cloning fixes
remove two now-confirmed generic sources of feed instability.

No physical acoustic lip-sync result was obtained. The live app reports the
configured 700 ms scheduling estimate, not a microphone measurement. Current
logs showed no sustained queued-audio backlog and did not justify changing
that estimate or the user's timing trim.

Live platform/account compatibility is separate from synthetic fixtures.
Instagram retains its existing deliberate picture-delay bypass. DRM, native
picture-in-picture, closed shadow roots, and video-only fullscreen remain
unsupported by the overlay. The original video stays visible in those modes.
Do not describe these checks as proof that every website or speaker is synced.

## Separate native capture-recovery budget repair

Live logs recorded default-output changes at 16:22:23 and 16:22:49 host log time,
then no successfully converted/published buffers and three full room restarts.
A later window delivered healthy silent buffers again. This does not prove
that an audible source was lost or establish the underlying route-change cause.

A separate concrete defect was found in recovery acknowledgement: synthetic
start/rebuild timestamps could be mistaken for a real recovered buffer, clearing
the one-restart budget before any PCM was published. Source and isolated
regressions now pass, including 709 actual app-controller checks and the
production capture lifecycle fixture. Both new fixtures failed against the
previous synthetic-clock logic. The retained unsigned Release candidate built
successfully from unchanged source hashes. It preserves the installed engine
and approved icon byte-for-byte and bundles extension 1.2.5/build2026-10-17.d.
This native repair is not in the running app. Its guarded installer passed
read-only preflight and refuses to run while DALI is open. Approval has been
requested for applying it once DALI is closed; current app signing is ad-hoc with a CDHash designated
requirement, so an update can require granting System Audio Recording again.

The candidate is `build/chrome-sync-20261017/native-candidate/DALI.app`. Its
complete reviewed file manifest is `native-candidate/review.json`. The guarded
installer is `install-reviewed-native.py`; it requires explicit human approval
represented by `DALI_CONFIRM_ADHOC=yes`, verifies installed/candidate hashes,
keeps a full previous-app backup, and leaves the new app closed. A generated
review artifact or environment variable alone is not human approval.

## Follow-up evidence after live glitch reports

Live speaker connections after the quiet-floor app update failed despite direct shell TCP reachability. Exact previous app was restored without re-signing; refreshing its already-enabled macOS Local Network permission allowed the next actual UI retry to connect both receivers in4255ms. Separate audio capture was still producing zero callbacks, so stream_ready did not prove sound. Refresh of the existing System Audio Recording Only grant reached a macOS TouchID prompt and requires the user. No additional screen capture access was requested. Quiet-floor source correction is retained but no longer installed.

The rebuilt engine eventually completed its initial scan after43seconds rather than remaining permanently deadlocked. Its bundled SQLite changed3.53.4→3.54.0, but a private synthetic-schema A/B test with the actual OwnTone SQLite extension did not reproduce a version regression. Both libraries released a controlled shared-cache lock promptly. SQLite documents table locks lasting through the transaction: https://sqlite.org/sharedcache.html. Source still traverses directories/adds watches while a scan transaction is held even with file scan disabled; the exact live blocked statement remains unproven. Do not attribute the43s delay to SQLite without stronger evidence.

Further browser research confirms that requestVideoFrameCallback is compositor-driven and background behavior differs across engines; Chrome can stop these callbacks in background tabs. Sources: https://wicg.github.io/video-rvfc/ and its issue92 discussion https://github.com/WICG/video-rvfc/issues/92. Returning from a truly hidden tab requires new history; do not present a freshly emptied700ms picture buffer as already aligned. A disposable Chrome for Testing155.0.8059.85 was acquired from the official vendor to match the personal-browser version. The experimental real-hide probe could not establish hidden-page state in headless Chrome: tab activation/minimization left visibility visible, and a frozen page could not execute the inspection. That experimental flag/driver was removed rather than counted as passing coverage. Genuine background throttling/return remains a live acceptance gap.

Exact-version follow-up: default native155 check and real-MV3 integration both pass in official Chrome for Testing155.0.8059.85. For700ms target, native visible picture median733ms, min700/max733; real-MV3 result retained separately. Native capture/bitmaps, pause/seek, app stop/restart, extension reload, replacement and cleanup checks pass. These are muted private-browser tests, not physical speaker lip-sync acceptance.
