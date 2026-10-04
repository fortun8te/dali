# V2 room volume and control

The system-audio master changes a common PCM gain before conversion to the pipe's signed 16-bit samples. Each receiver keeps a fixed calibrated operating point. Ordinary nonzero Mac volume changes therefore do not queue AirPlay/RTSP volume requests and cannot change the receiver command difference between room members. Per-speaker sliders and calibration gains still change receiver settings. App capture, Spotify Connect and library-player modes keep their existing per-speaker control semantics.

## Saved setting interpretation

Saved slider and gain values are retained. A system-audio receiver reference is `slider × gain × floor(ceiling) / 100`, capped once at the integer ceiling and rounded to the nearest command step. Other sources use `slider × gain`, capped once at the same ceiling. This preserves V1's full-master capped calibration. For example, raw references 160 and 20 with a ceiling of 40 become 40 and 20. A room-wide shift or compression would change that saved balance without a user adjustment and is unnecessary once the moving master is applied to PCM.

Disabling a speaker masks its receiver command to zero without changing its partner's reference. The command ceiling is floored before quantization, so a ceiling of 40.6 never produces 41.

The shared amplitude gain is `gain = master × master`, with master bounded to 0…1. It is independent of speaker sliders, calibration gains, the ceiling and room membership. At 1% master, amplitude is 0.0001; at the first ordinary Mac step (1/16), it is 0.00390625; at full master, it is one. These are sample amplitude ratios, not perceived loudness measurements. The previous receiver-dependent curve retained excessive amplitude near zero and allowed one speaker's slider to alter the common gain; it has been removed.

The capture layer smooths gain changes over 15 milliseconds, applies the gain before signed 16-bit quantization, and samples current desired gain at first-buffer admission. Desired gain survives capture replacement. Source-silence detection uses pre-gain audio, so master mute cannot trigger a stale-tap recovery.

Master zero also queues urgent receiver zero. The engine's V2 zero now emits protocol mute (-144 dB), which covers already buffered audio. Browser cuts and per-speaker disable use the same hardware mute path. Nonzero master gain changes become audible after the existing AirPlay pipeline, configured to about 0.9 seconds with the automatic buffer. There is no claim of immediate audible response or measured physical calibration.

## Ownership and asynchronous behavior

`RoomVolumeCoordinator` is the sole output-volume request owner. Startup silence, readiness restore, recovery, browser cuts and ordinary UI intent all use it. Desired values and engine-accepted values are separate. Sent requests drain; new intent replaces queued work. Session epochs reject stale receipts. A successful RTSP-backed HTTP response means control acceptance, not measured physical loudness. `/api/outputs` reports requested volume, so a matching poll never upgrades a failed or unknown write to acceptance.

Unknown writes retry at bounded cooldowns of 3, 6, 12, 24 and 30 seconds, with sparse 30-second retries thereafter. New intent and urgent mute wake cooldown/spacing sleeps without canceling a request on the wire. Setup waiters finish on cancellation or unknown receipt. An old write's failure cannot impose its cooldown on a newer target. Poll mismatch tolerance is one command step.

`RoomSessionController` owns the production mirror-session sequence, including whole-room selection, initial silence, capture admission, playback proof, readiness retries, one proven-total-failure reset and missing-member rejoin. The store retains presentation, discovery and ongoing per-speaker health policy. Source changes replace the session with a frozen source snapshot. Stop invalidates capture immediately; a teardown barrier drains startup and verifies the old Spotify child exited before any new producer can use the pipe. That handoff can incur the existing teardown/start-buffer delay. Watchdog rebuilds replace only an existing capture token; they never start a fresh tap after Stop. Offset assertions are also fenced by session and cache epoch.

`RoomTimingController` owns capture/progress observation validity and the existing bounded one-sided refill policy. Missing/slow progress, source silence, callback gaps, backpressure and discontinuities invalidate measurement instead of creating bidirectional rate corrections. A hard observation reset eases active refill toward unity; an explicit new-session reset clears its budget and ratio. The retired bidirectional controller and unused competing volume bookkeeping were removed from the store.

## Automated evidence

The unchanged V1 `effectiveVolume` implementation was extracted from the baseline source into `docs/v2/v1-volume-baseline.swift`, with only the surrounding model/context replaced by small stubs. Running `swift docs/v2/v1-volume-baseline.swift` intentionally exits 1:

```
Actual V1 function: master100 front-back=4, master25 front-back=2
FAIL: receiver calibration changes with master
```

The production V2 policy regression sweeps 1,000 nonzero master levels and holds the same receiver references at 20/16, a four-step difference. Additional production policy tests cover saved clipped-reference preservation, disabled-member invariance, fractional ceilings, finite input, continuous/monotonic low-end gain and exact mute. Regressions cover both speakers at 100 with master at 1% and 1/16 across ceilings 20/40/100, and ensure changing one speaker cannot alter common gain or its partner. Coordinator tests cover burst coalescing, late replies across stop/start, temporary silence/latest restore, stale observations, cancellation, unknown-write recovery, requested-poll confidence and cooldown wakeup. Actual store fixture checks are in the integrated validation gate; RoomSessionController tests execute the production startup/stop sequence with injected dependencies.

These checks verify commands, state and sample processing. They do not verify physical front/back loudness, capture behavior under macOS permission changes, long-run speaker stability or actual network control latency. The rebuilt app is installed at the user’s request; hardware acceptance remains unverified. No post-build app launch or playback check is performed.
