# DALI V2 backend plan

> October 4 follow-up: the user rejected fixed-receiver software master behavior. Current volume control restores V1 hardware master response. The original balance-drift issue remains open; see VOLUME.md for the current contract. The plan below records the initial architecture, not a claim that its volume design was accepted.

Status: implementation plan, 3 October 2026. Target is the DALI macOS music app and its bundled OwnTone engine. This is not the unrelated Fortunate Leads project.

## Baseline and scope

The PR starts from public main b04c1cc. Commit 078769d preserves the newer local V1 full-room startup/readiness fixes, including uncommitted source fixes. The original checkout, installed app, runtime databases, saved preferences and speakers remain untouched. Public-source sanitization is retained. Existing engine binaries are not treated as source provenance.

Review all first-party code, bundled engine changes and the browser/UI contracts. Replace the backend control, volume and capture transport architecture while retaining the current interface, settings and proven AirPlay protocol engine. A ground-up replacement of the AirPlay protocol is not needed to remove the app's conflicting control paths.

## Findings driving the design

- A 4,291-line main-actor store mixes UI, lifecycle, polling, volume, recovery and timing diagnostics.
- V1 multiplies speaker volume by master volume and calibration gain before independently clipping. OwnTone maps output percentages to dB. This changes the difference between front and back across master levels.
- Multiple volume write paths, stale polls and coalesced writes reported as success can disagree about what was actually applied.
- Capture's FIFO queue can retain work before applying its eight-second cap, and late work can reopen a closed writer. ProcessTap's two-second join does not guarantee the callback stopped.
- Current source still includes a one-sided capture refill controller. Historic claims that capture always uses ratio 1.0 are no longer current evidence.
- Current local engine source and published source/patch may differ. Builds must use one documented source tree.
- Swift package tests do not compile the app controller. Existing capture lifecycle and C backpressure tests are not included in the standard check script.

## Implementation order and ownership

1. Volume and room controller. Introduce a pure room-volume policy with fixed calibrated receiver settings and a shared, ramped PCM gain for system-audio master volume. This holds the receivers at stable operating points even when their volume curves differ and removes network writes on normal volume-key changes. Freeze each receiver at its saved V1 full-master reference, capped by the existing ceiling; preserve true zero mute and bounded input handling. Muting a member must not change the remaining members' reference levels or shared gain. Gain changes reach the listener after the existing audio pipeline; do not describe them as instant audible changes. Preserve saved slider/gain values through a documented reference-level interpretation. Replace asynchronous volume ownership with one latest-intent coordinator. Extract lifecycle, recovery and diagnostics responsibilities from the store into clear backend components. Preserve stop-wins generations, full-room startup, unavailable remembered speakers, and per-speaker recovery.
2. Engine client and supervision. Rewrite the request scheduler as a bounded, testable shared transport. Preserve one in-flight request per engine and drain already-sent requests safely. Make supersession/cancellation explicit, prioritize current control without starving health reads, and reject obsolete queued session work. Serialize engine lifecycle and verify teardown before startup.
3. Capture transport. Replace retained queued writes with bounded storage and a single drain owner, close permanently, reject stale generations and bound retained audio age. Keep conversion off the real-time callback and make consumer shutdown/rebuild ownership explicit. Keep forward-paced silence and format continuity.
4. Bundled engine. Compare current local fixes with the published tree, retain applicable timing/delivery fixes, and test C paths without touching speakers. Make source and patch provenance agree. Isolated volume timeout must not tear down healthy media; catch-up and fractional progress protections must remain.
5. Integration and release gates. Keep UI and loopback bridge contracts stable. Run tests covering actual backend seams, compile the complete app unsigned, package only after checks. Review every agent diff and fix findings before opening the PR.

GPT-6.1 sol agents implement the separately owned areas after this plan. The parent agent reviews their changes and the integrated result. Shared-file changes are coordinated explicitly.

## Acceptance tests

- Sweep master volume and calibration, including zero, low values, ceiling, disabled speakers and nonfinite input. Receiver calibration must stay fixed while a shared PCM gain changes. Gain must approach zero continuously, mute must produce exact silence, and unmute/rebuild must not leak full-scale audio. Source silence detection must remain independent of master attenuation.
- Reproduce V1 balance drift with a regression that fails the original mapping.
- Burst slider changes, mute/unmute, delayed replies, out-of-order observations, cancellation and stop/start. Latest intent wins, obsolete commands cannot resurrect a stopped room, and request count stays bounded.
- FIFO slow/absent reader, source pause, close during pending work, late write after close and tap replacement. No unbounded queue, reopened stopped writer, mixed generation or old audio replay.
- Mock full-room startup, missing receiver, per-device retry, engine shutdown/restart and timeout. Distinguish unknown readiness from proven failure.
- Run all existing Swift, onboarding, extension, capture lifecycle and engine regression checks; compile the actual macOS app with signing disabled.
- Record measured automated command latency/queue behavior separately from physical speaker latency.

## Historical lessons retained

Playback progress is not a trustworthy wall-clock measurement under starvation or stalled control requests. Do not recreate the old bidirectional capture feedback loop. Preserve fractional sample progress and paced silence. A selected/connected session and successful UDP writes do not prove sound arrived. A healthy short run does not prove long-term stability. Preserve setup and do not force onboarding or change signing identity. Avoid concurrent old/new engine processes competing for PTP ports.

## Delivery and honest limits

Deliver a reviewed V2 PR, implementation notes, test results and remaining hardware acceptance steps. Do not install or claim production readiness from compilation alone. Physical front/back loudness across low/mid/high levels, long playback, receiver loss/rejoin, sleep/wake and network changes still require the candidate app on real hardware. AirPlay buffering cannot be eliminated by an app refactor; the goal is bounded control response and no avoidable stale audio/control backlog. Physical calibration still needs checking, although fixed receiver levels avoid changing their nonlinear operating points as master volume moves. Signing/notarization and clean-machine distribution remain explicit release gates.
