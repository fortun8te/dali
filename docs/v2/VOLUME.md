# V2 room volume and control

## Current behavior: V1 master response restored

The user rejected the fixed-receiver, software-master behavior, including its later quadratic curve. System-audio master volume now uses the original V1 receiver calculation: `round(min(slider × master^0.7 × ceiling / 100 × gain, 100, ceiling))`. Bounds and invalid-input protection remain explicit. Positive system master leaves captured PCM at unity; zero master or an explicit cut mutes both PCM and receiver commands. App capture, Spotify Connect and library-player modes retain their existing direct speaker control semantics.

Mac volume changes again lower and raise the actual speaker commands through the V2 serialized coordinator. Full-master saved speaker settings are retained. Disabling a speaker cannot increase its partner's command. This deliberately restores V1 volume response rather than approximating native receiver behavior with an assumed dB curve.

**Known limitation:** V1 multiplies each receiver reference separately, so the front/back command difference changes across master levels. Restoring V1 behavior does not solve the original balance-drift complaint. The fixed-reference architecture avoided that command drift, but its physical volume response was rejected by the user. There is no verified device-specific calibration table for this pair, and constant protocol differences alone do not prove constant acoustic balance. A later balance correction must be grounded in receiver behavior rather than another speculative curve.

V2 zero emits protocol mute (-144 dB). The existing 15 ms PCM ramp remains for mute/cut transitions. Source-silence detection uses pre-gain audio, so master mute cannot trigger stale-tap recovery. Control acceptance is not proof of sound or physical response time.

## Visible speaker adjustments

A non-neutral saved gain is shown beside the main front/back slider and in the speaker list as an adjustment percentage, with a per-speaker Reset action. Reset sets that gain to one through the existing coordinator, preserving the slider, other speakers and Mac master. Fine tuning uses the same rounded percentage instead of a one-decimal multiplier. These percentages describe saved settings, not measured acoustic output. No general preference migration or master-curve change is performed.

## Ownership and asynchronous behavior

`RoomVolumeCoordinator` is the sole output-volume request owner. Startup silence, readiness restore, recovery, browser cuts and ordinary UI intent all use it. Desired values and engine-accepted values are separate. Sent requests drain; new intent replaces queued work. Session epochs reject stale receipts. A successful RTSP-backed HTTP response means control acceptance, not measured physical loudness. `/api/outputs` reports requested volume, so a matching poll never upgrades a failed or unknown write to acceptance.

Unknown writes retry at bounded cooldowns of 3, 6, 12, 24 and 30 seconds, with sparse 30-second retries thereafter. New intent and urgent mute wake cooldown/spacing sleeps without canceling a request on the wire. Setup waiters finish on cancellation or unknown receipt. An old write's failure cannot impose its cooldown on a newer target. Poll mismatch tolerance is one command step.

`RoomSessionController` owns the production mirror-session sequence, including whole-room selection, initial silence, capture admission, playback proof, readiness retries, one proven-total-failure reset and missing-member rejoin. The store retains presentation, discovery and ongoing per-speaker health policy. Source changes replace the session with a frozen source snapshot. Stop invalidates capture immediately; a teardown barrier drains startup and verifies the old Spotify child exited before any new producer can use the pipe. That handoff can incur the existing teardown/start-buffer delay. Watchdog rebuilds replace only an existing capture token; they never start a fresh tap after Stop. Offset assertions are also fenced by session and cache epoch.

`RoomTimingController` owns capture/progress observation validity and the existing bounded one-sided refill policy. Missing/slow progress, source silence, callback gaps, backpressure and discontinuities invalidate measurement instead of creating bidirectional rate corrections. A hard observation reset eases active refill toward unity; an explicit new-session reset clears its budget and ratio. The retired bidirectional controller and unused competing volume bookkeeping were removed from the store.

## Automated evidence

Policy tests compare against an independent extraction of V1's original arithmetic across master, ceiling, slider and calibration values, including clipping and fractional ceilings. The actual app-controller fixture verifies master changes submit the expected V1 receiver commands through the production coordinator, rather than merely changing a local calculated gain. Zero master, explicit cuts, disabled speakers, source changes and invalid inputs remain covered.

The historical `docs/v2/v1-volume-baseline.swift` reproduces the original balance drift and still intentionally exits with failure. That issue is acknowledged, not relabeled as fixed. Tests and compilation establish code behavior, not physical loudness or receiver latency. Installation follows the user's request with no post-build app launch or playback test.
