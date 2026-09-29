# DALI Video Sync

Chrome companion for the DALI macOS app. DALI plays the Mac's audio on the
AirPlay speakers about 0.5 to 1 s late. This extension holds the video picture
back by the same amount, so lips match again. The site's audio, playhead,
speed and controls are left alone.

## Install or reload

1. Open `chrome://extensions` and turn on **Developer mode**.
2. First install: choose **Load unpacked** and select this `chrome-extension`
   folder, or the folder DALI reveals during browser setup.
3. After an update: click the **reload** arrow on the *DALI Video Sync* card.
   Open tabs pick up the new script by themselves. You don't need to refresh
   them.
4. To check the version: click **service worker** on the card. The console
   prints `[DALI Video Sync] v1.2.1  build 2026-09-27.a`. While DALI runs,
   `curl -s http://127.0.0.1:3697/` shows `"extensionVersion":"1.2.1"` within
   30 s.

Chrome 120 or later is required. There are no settings. When DALI is off or
idle, the extension does nothing to any page.

## Version 1.2.1

Brief connection failures to DALI no longer drop video sync immediately.
The extension keeps the last confirmed status for up to ten seconds; an explicit
stop still takes effect immediately.

Instagram is excluded from picture delay. Reels and feed videos play normally,
and their audio still goes through DALI. Other supported sites retain automatic sync.

## How sync works

**Why the picture is buffered.** DALI captures the Mac's audio, and that audio
comes from the same `<video>` element. Seeking the element back, pausing it at
the start or changing `playbackRate` would move its audio by the same amount.
The room would still be late. So the extension draws a delayed copy of the
frames on a `<canvas>` placed exactly over the video, and hides the real
element (`visibility: hidden`, so the layout does not change). The element
keeps playing and keeps making the sound.

**Timing.** Each frame is stamped with its `requestVideoFrameCallback` display
time. The frame nearest to `now − delayMs` is shown. The error stays within
half a frame (±17 ms at 30 fps). Frames are timed one by one, so the error
cannot build up.

**VOD.** On play, seek or a new source, the first frame is held until its
audio reaches the room. If sync starts mid-video, the delay eases in at half
speed. Pause, end, seek, tab switch, PiP and navigation hand the real video
back in the same tick.

**Live (Twitch, YouTube Live, HLS/DASH).** It works the same way. Nothing
seeks, so there is no live edge to fight and no extra rebuffering. When the
player adjusts itself by less than 250 ms, sync holds. During stalls the
buffered picture plays out as the room plays out its audio, then waits. Ads,
source changes and quality switches only change which frames arrive. The
regression suite checks a minute of live playback with nudges, a 3 s stall and
a quality switch. The error stays at ±17 ms, and at most 40 ms on a frame that
failed to decode.

**Delay changes.** The service worker reads DALI's beacon about once per
second while it is streaming, and every 2.5 s while it is idle. A shorter
delay applies at once. A longer one eases in without freezing the picture.

**Every site.** The content script runs in all frames, including
about:blank, blob: and srcdoc frames. It finds videos added later
(MutationObserver, Navigation API, a 4 s sweep) and videos inside open shadow
roots, where it also listens for media events. When a page has several videos,
it picks the visible one that is playing and audible, preferring the larger
one, with hysteresis.

**Limits.** In these cases the page plays undelayed, as it would without the
extension: DRM/EME video (Netflix, Prime, Disney+, and similar sites), closed
shadow roots, and a `<video>` element that itself goes fullscreen or into
picture-in-picture. YouTube and Twitch fullscreen their player container, and
sync works there.

## Local app contract

```
GET http://127.0.0.1:3697/?t=<ms>&v=<version>&b=<build>
{"app":"DALI","protocolVersion":1,"streaming":true,"delayMs":900,
 "extensionVersion":"1.2.1","extensionBuild":"2026-09-23.a",
 "bundledExtensionVersion":""}
```

- Every request carries `v`/`b`, and the app echoes the running extension as
  `extensionVersion`. This field is empty after 70 s of silence. The worker
  checks in every 30 s by alarm, even when no video is open.
- `bundledExtensionVersion` is the version in DALI's managed folder. 1.2+
  reloads itself once when this is newer than its manifest.
- Controls are `/cut`, `/resume` (the pause tail, decided across all tabs in
  the worker) and `/now?d=<json>` (the now-playing line, up to 1000 encoded
  chars).

## Verify

```sh
node --test chrome-extension/tools/harness/regressions.mjs
```

This runs the shipped scripts with deterministic clocks and stub media. It
needs no Chrome, network or speakers. Check lip sync in the room afterwards.

## Version 1.2.2

Preserves browser presentation timestamps when a decoded-frame callback arrives early. In the deterministic 60 fps callback-jitter regression, capture improved from 61/120 to 120/120 frames, with presentation error at most 8.4 ms against the requested delay. All 61 regression checks pass. These simulated timings do not measure physical speaker lip-sync. Build: `2026-09-27.b`.
