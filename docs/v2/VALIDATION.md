# V2 validation

Status: the complete automated gate passed on 3 October 2026, with a verified process exit status of zero. The requested follow-up rebuild then replaced the existing installed app as recorded below. Physical speaker behavior remains untested.

## Complete gate

```sh
bash scripts/check.sh
```

The gate stops on the first failure. It runs the checks below in temporary build directories and validates the extension package only after every test and the full app compile pass. `scripts/build-release.sh` calls the same gate before packaging an app.

| Check | What it verifies | Boundary |
| --- | --- | --- |
| `swift test` | Production backend policies, request scheduling, engine lifecycle, capture buffers and conversion, readiness, configuration, and room delay | No real AirPlay receiver, audio permission, or speaker loudness |
| `bash scripts/tests/capture-lifecycle.sh` | Production `CaptureController` lifecycle through an injected hardware boundary | No CoreAudio tap or live capture |
| `bash scripts/tests/app-controller.sh` | Actual `DALIStore` volume facade and coordinator, source gain/preference semantics, and timing controller using temporary preferences and recorded I/O | Backend startup and actual tap/Spotify source handoff are disabled; room orchestration is tested separately by the Swift suite |
| `python3 scripts/engine-source-provenance.py` | Bundled source-file bytes, executable modes, and patch hash match the committed provenance record | Full upstream-plus-patch reconstruction requires the optional upstream checkout check |
| `node scripts/tests/airplay-backpressure.mjs` | Extracted production engine C paths, compiled into isolated fixtures | No running OwnTone process or speaker network |
| `bash scripts/tests/onboarding.sh` | Production onboarding state and extension installer using temporary preferences and files | No owner's onboarding state or System Settings permission handoff |
| `node --test --test-reporter=spec chrome-extension/tools/harness/regressions.mjs` | Extension behavior against simulated browser players, feeds, and app status | No live YouTube, TikTok, or Instagram login |
| `bash scripts/tests/app-compile.sh` | Complete app, including `DALIStore`, capture controller, engine code, views, and loopback bridge, compiled unsigned for Apple Silicon | No launch, installation, engine linkage smoke test, or signing |
| `python3 scripts/package-extension.py` | Runtime-only extension files, manifest, entrypoints, and distributable archive | No Chrome Web Store upload or live installation |

The generated Xcode project and DerivedData live in a temporary directory. `swift test` also uses a temporary scratch directory. The C gate explicitly tests `third_party/owntone`, the source used by the engine build. The gate does not call a signing or installation script, change the owner's preferences, or connect to the installed engine.

## Recorded results

Before V2 implementation, the isolated onboarding/install checks passed all 17 assertions. The browser fixture suite passed 67 tests with zero failures. Its Instagram tests confirm deliberate picture-delay bypass and continued audio reporting. They do not confirm delayed Instagram picture playback.

The final combined `bash scripts/check.sh` run completed with exit status zero after source review and integration. Its durable local evidence is in the ignored `build/v2-validation.log` and `build/v2-validation.exit` files.

| Final check | Recorded result |
| --- | --- |
| Swift backend regressions | 113 tests passed: 86 engine/backend tests and 27 capture tests, zero failures |
| Production capture lifecycle | Passed lifecycle, stale conversion, mute/rebuild/source, stop latency, and paced-silence checks through the injected hardware boundary |
| Actual app controller | 652 regression assertions passed using actual store, coordinator, and timing code with isolated preferences and recorded volume transport |
| Engine source provenance | All 543 source-file hashes and executable modes matched the committed record |
| Engine C fixtures | All three sanitizer groups passed: wall-clock scheduler, timerfd scheduler, and ownership/admission paths |
| Onboarding and installer | 17 assertions passed |
| Browser fixtures | 67 tests passed, zero failures |
| Complete unsigned app | Apple Silicon Release app compiled successfully; final compile gate took 37 seconds |
| Extension archive | Runtime-only archive validated with seven files, after all preceding checks passed |

The first integrated attempt stopped at an inconsistent app fixture: it marked speakers live without populating the store's private readiness state. The corrected fixture applies decoded ready outputs through production `applyDiscoveredSpeakers` before asserting volume behavior. Production readiness requirements were preserved. That failed attempt remains in `build/v2-validation-attempt1.log` with its exit marker. A duplicate final run was canceled; the final log contains an overlapping app-controller label, and the parent-owned complete gate process independently returned exit status zero.

The final app fixture measured 0.252 ms from its initial intent to receipt by the injected volume transport, and 0.384 ms for its slider intent. These are local simulated-transport timings, not HTTP, RTSP, receiver, or audible latency measurements.

The exact bundled engine also compiled and linked through the public build script with exit status zero. Its isolated source inputs matched the committed inventory. The host lacked SQLite unlock-notify support, so that build used a copied standalone SQLite library from the prior development bundle in an ignored dependency directory. Only the copy's install name and ad-hoc signature changed; the app was not signed or installed and the engine was not launched. This verifies compilation and linkage on this host, while clean-machine dependency reproduction and corresponding-source provenance for that borrowed library remain unverified. See the [engine evidence record](ENGINE.md).

## Remaining release checks

The app-controller fixture records time from UI intent to receipt by its injected volume transport. It does not measure HTTP, RTSP, or time until sound changes at a physical speaker. Physical front/back loudness and timing remain unmeasured for V2.

System-master attenuation is applied to captured PCM and reaches the listener after the existing audio buffer. A quick local gain update does not imply an immediate audible volume change. The isolated app-controller fixture verifies source gain and preference behavior with backend startup disabled. It does not execute the real capture/Spotify producer handoff.

Before a public Mac release, test the candidate on real receivers across low, medium, and high master levels, mute/unmute, rapid controls, source pause/resume, receiver loss/rejoin, long playback, sleep/wake, and network changes. Confirm sound at each receiver rather than relying on selected/connected status or packet-send counters. Measure any hardware calibration separately from the command-level volume policy.

Live video testing must cover YouTube and Shorts, TikTok feed/source changes, and Instagram audio reporting with its picture-delay bypass. Verify app and extension stop/restart and updates while pages remain open.

Build and verify the exact bundled engine source and nested library architecture. Developer ID signing, notarization, final archive verification, Chrome Web Store distribution, and download/install/update on a clean Mac are separate release gates. See [release requirements](../releasing.md). Hosted CI is still inactive until a maintainer copies `docs/ci/ci.yml` into `.github/workflows/ci.yml` with the required workflow permission.

## Requested follow-up rebuild

On 3 October 2026, a bounded final source review found no additional high-impact issue. The unchanged application code was rebuilt successfully for Apple Silicon, bundled with the compiled V2 engine, and signed with the existing Michael Computer Use Signing identity. At the user's request, it replaced `/Applications/DALI.app` rather than installing a second app. The previous bundle was retained outside Applications for rollback. Saved settings were preserved.

The app was left closed. No post-build app verification, launch, UI check, speaker test, or playback measurement was performed, as requested. The successful build and signing command results establish those operations only; they do not establish runtime behavior.

## Packaging repair after reported startup failure

The user reported engine startup failure and a placeholder icon after the first installed rebuild. Existing engine logs identified a missing runtime-loaded SQLite extension and a compiled build-folder lookup path. The failed app metadata also lacked both the icon entry and the audio-capture permission description. The earlier compile and source checks had not covered these packaging requirements.

The repair adds an explicit source Info.plist, bundles and relocates the SQLite module and its dependencies, and passes a binary-relative module path to the engine. The metadata regression failed on the reported bundle and passed on the explicit source metadata; generated build settings selected that source plist. The module regression failed before repair and passed after relocating the helper tree, loading the extension into a fresh in-memory database, and exercising its custom function and collation. All 17 targeted Swift packaging, process-identity and lifecycle tests passed. Canonical engine source remained unchanged.

The corrected app compiled and signed successfully with the existing identity, replaced the existing installation, and had its app registration refreshed. It was left closed. No post-build app verification, app launch, live engine startup or speaker testing was performed. These targeted checks do not establish runtime startup or audibility in the installed app.

## Follow-up startup resource repair

The second reported failure was traced from existing user-run logs: SQLite loaded successfully, then HTTP startup failed because the compiled web root pointed into the engine build prefix. The cache path also pointed there. No app or live engine was launched during diagnosis.

The resource audit covers all seven active prefix defaults. The helper receives an explicit web root in `Contents/Resources/OwnTone`, while development helper trees retain their adjacent `htdocs`. The complete 14 original web assets are bundled; a regression compares their bytes with the matching engine source. Cache files use a newly materialized `engine/var/cache`; the saved database path and contents are preserved. `BeamAPIError` now supplies its actual message through localized errors instead of the generic numbered error shown in the screenshot.

The missing-resource and cache regressions failed before repair. The initial targeted run passed 18 Swift tests, and the resource/dependency audit and relocated in-memory SQLite check passed. The localized-error regression independently failed twice before its fix and passed afterward. The canonical 543-file engine inventory is unchanged.

The first signing attempt caught web assets in the executable-helper area; that candidate was not installed. The final packaging places them in the app resource area and updates launch paths and release packaging together.

Final checks after the resource-layout correction passed: 20 targeted Swift tests (including localized errors), the complete source-prefix/resource/dependency audit, isolated relocated SQLite loading, script syntax, and diff whitespace checks. The final Apple Silicon Release compilation and signing both succeeded. The existing `/Applications/DALI.app` was replaced with the same signing identity, and the prior bundle was preserved for rollback. No post-build app verification, launch, UI interaction, live engine startup, or speaker test was performed. Build success and these isolated checks do not establish installed runtime behavior.

## Startup and responsiveness follow-up

Existing user-run logs showed two restarts exhausting the six-second previous-session wait. OwnTone's stop endpoint intentionally retains flushed receiver connections for ten seconds. Room teardown now explicitly deselects outputs after stopping, so receiver teardown starts immediately; the connected-state check, 2.5-second safety floor, source barrier and cancellation checks remain. Failed startup, recovery resets and player-mode fallback use the same explicit release. Parent review retained idempotent fallback stop/release rather than relying on controller state to infer playback ownership.

The regression exercises the real RoomSessionController with a simulated warm connection: it failed at 8.5 simulated seconds before the fix and passed at 2.5 after it. Another regression verifies a replacement cannot pass an unfinished output-release request. These are simulated timings; existing live logs independently establish the two six-second waits, but no new receiver run measured the improvement.

Engine startup now keeps requests suspended until its TCP listener accepts, then checks the API and current child identity. It no longer waits an unconditional second. The disposable-child/injected-transport fixture improved from 1.010 seconds to 0.258 seconds, with additional delayed-listener, cancellation and early-death tests. PTP arbitration and prior-request draining remain unchanged.

A slow fake CoreAudio driver reproduced caller stalls in the original SystemVolumeObserver: approximately 379 ms construction, 126 ms reads and 65 ms writes. Initialization and HAL work now run on its serial queue; callers read cached effective volume and queued slider writes retain the latest intent. Store startup stays muted until the first hardware snapshot. The performance fixture measures responsiveness under controlled driver delays, not the user's actual hardware latency.

The combined Swift suite passed 124 tests, and the actual app-controller harness passed 652 assertions. The controller results use isolated preferences and injected transport, not real speakers. The first app compile caught an escaping callback mismatch in observer cleanup; its signature and the fake API were corrected before the successful final Release compile.

The slow-HAL harness passed responsiveness, initial mute, unmute, startup/latest-intent ordering, route changes, absent volume controls, transient read failure and asynchronous cleanup. In the final basic run, construction was 0.1 ms, cached reads and enqueueing a write rounded to 0.0 ms, and an 80-change slider burst returned in 0.1 ms while issuing two hardware writes. Parent review additionally required preserving the last successful scalar on transient read failure, resetting that fallback only when the output route changes.

The final transient-read follow-up harness passed in 5.4 seconds, with 0.2 ms initialization and slider-burst dispatch, zero rounded milliseconds for cached reads/cleanup, and two HAL writes. The exact reviewed sources then compiled successfully for Apple Silicon and were signed with the existing identity. The existing installation was replaced and its previous bundle retained for rollback. The original pre-V2 icon remains restored. No post-build app verification, app launch or playback test was performed. End-to-end startup, audible delay and subjective responsiveness remain unmeasured on the rebuilt installation.

## Silent playback investigation

During the user's 17:38:31 start, existing logs reached streaming at 17:38:33. API reads showed player progress and both room outputs selected, connected and streaming; receiver delivery counters had increased without recorded control failure. These establish engine activity, not audible sound. At 17:39:16 the log recorded zero software gain and zero references for both speakers. Subsequent read-only CoreAudio inspection found Spotify producing output and built-in Mac speakers at scalar zero with mute enabled. Unified logs showed normal application termination at 17:39:20, not a recorded crash. This later mute does not explain the earlier user-reported silence at nonzero master.

An isolated app-controller regression reproduced misleading Live/Playing labels at zero master. The UI now reports Muted, and per-speaker connected state is labeled Connected rather than promising sound. No automatic unmute or volume change was made. Passive diagnostics now record measured source and quantized output RMS, software gain and sample count. No samples is represented as unknown; no audio recordings are retained.

An actual converter fixture emits nonzero samples at the earlier logged 0.0921979 gain, and exact silence at zero while keeping source presence independent. Converter and capture lifecycle regressions passed. Both C volume fixture modes and two coordinator mute/restore regressions passed; no engine mute defect was reproduced. The full app compiled and 653 controller assertions passed. These changes correct status and close a diagnostic gap; they do not establish a fix for the earlier nonzero-master silence or end-to-end audibility.

## Quiet master volume attempt, superseded after user feedback

The first Mac master step (1/16), with both speakers at 100 and ceiling 20, previously retained 0.553447 sample amplitude. Two new regressions failed with 105 assertions before the fix. Shared PCM gain now equals master squared, independent of receiver references: 1% master gives 0.0001 amplitude and the first Mac step gives 0.00390625 at ceilings 20, 40 and 100. Speaker settings no longer alter the common master curve or another receiver’s reference. Full-master calibration and zero mute remain preserved.

All 128 Swift tests and 657 isolated actual app-controller checks passed. The parent reviewed the policy and integration; GPT-6.1 sol implemented the policy and its regressions. Release compilation and existing-identity signing succeeded. This verifies sample gain and control behavior, not perceived loudness or physical playback. The rebuilt installation is left closed without post-build app verification.

## V1 master response restoration

The user reported that the quadratic PCM-master change remained too loud or disconnected from the Mac master. Existing user-run flight data at the first Mac step showed gain 0.00390625, source approximately -18.8 dBFS and output -66.9 dBFS, with hardware references 100/84. This confirms signal attenuation, not appropriate physical response. Comparison with the preserved V1 checkout shows V1 changed actual receiver commands with master^0.7 and did not attenuate captured PCM.

The current policy restores that V1 arithmetic, including raw cap100 and ceiling before rounding. Positive master uses unity PCM; zero/cut retains PCM and receiver mute. This intentionally restores the requested V1 response and reopens the original balance-drift issue. No acoustic calibration or balance fix is claimed. The previous quadratic test suite checked an assumed curve, which did not establish the behavior the user wanted.

Independent differential tests failed against the rejected policy and now match V1 across 720 input combinations. A production app-controller regression also failed on the original half-master commands before restoration. The full Swift suite passes 125 tests. The final sources compile successfully. No app launch or post-build playback verification is performed.

Final integration passed 659 actual app-controller checks with isolated preferences and I/O. Existing-identity signing succeeded. The existing app is replaced with a rollback bundle retained and left closed. No live volume was set or post-build app test performed.
