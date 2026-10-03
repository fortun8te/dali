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
