# DALI Video Sync

Chrome companion for the DALI macOS app. It delays the picture to match the
app's reported AirPlay audio delay. Your video's audio, playhead, playback
speed, and player controls stay with the website.

## Install

1. Open DALI's browser setup and reveal its Chrome extension folder.
2. Open `chrome://extensions`, turn on **Developer mode**, choose **Load
   unpacked**, and select that folder.
3. Play a video while DALI streams to your speakers.

For source installations, select this `chrome-extension` folder instead.
Chrome 110 or later is required. There is no popup or toolbar setting to
configure. The extension releases the picture when DALI is offline or idle.

## Updates

DALI's managed extension folder has a stable location. The app refreshes its
files during startup and advertises the bundled extension version. Extension
1.1.0 and later reloads itself once when it sees a newer version, then injects
its content script into open tabs and embedded players. Matching and older
versions do not trigger a reload. A saved attempt prevents repeated reloads
when an extension was loaded from a different folder.

**Upgrading an older extension needs one manual Reload in
`chrome://extensions`.** Source installations also need Reload after changing
files. The extension cannot silently install itself in Chrome, and automatic
Chrome Web Store distribution requires a separate store publication.

To check the active version, open the extension's **service worker** console
from `chrome://extensions`. This release prints:

```
[DALI Video Sync] v1.1.0  build 2026-09-13.a
```

## Video support

| Player | Behavior covered by regression tests |
| --- | --- |
| YouTube and Shorts | Normal playback, buffering, seeking, reused ad/video elements, feed changes, cached-page return |
| TikTok | Visible feed selection, swiping past an older playing video, replacing the video element |
| Instagram Reels | Visible feed selection, muted previews, changing the source on a reused video element |
| Other HTML video players | Standard video elements, embedded frames, open shadow-root discovery, source and layout changes |

These are tests of actual extension code against controlled browser and media
fixtures. They do not certify every layout or every account variant on the
live platforms. Platform changes can require a new compatibility test and fix.

Protected DRM video, closed shadow roots, native picture-in-picture windows,
and fullscreen modes that expose only the video element cannot use the canvas
overlay. In those cases the original player remains visible and undelayed.
YouTube's normal fullscreen player container can contain the overlay.

The delay comes from DALI's stable configured buffer, engine scheduling
allowance, and saved timing trim. Receiver-specific latency and network conditions can still
need in-room calibration. A clean browser test cannot prove speaker lip-sync.

## What changed in 1.1.0

- Feed selection uses the visible part of each player. Offscreen and CSS-hidden
  clips no longer keep sync attached to the previous item.
- Scrolling and nested feed containers trigger selection changes promptly and
  release old frame buffers.
- The presenter consumes a frame as soon as it reaches the delay target. It no
  longer waits an extra frame because of the following frame's timestamp.
- New builds replace old active scripts. Duplicate injections preserve the
  current pipeline. Browser startup and extension updates reinject open tabs.
- Cached pages stay suspended while earlier asynchronous requests finish, then
  resume when the page returns.
- Cleanup preserves the video's original inline visibility, and discards
  outstanding decoded frames safely during teardown.
- The beacon client accepts the original protocol and version 1 additions,
  leaves video alone for incompatible versions, and bounds the entire response
  read. Failed app commands are reported as failures.
- Pause-tail requests require an audible, visible video owned by sync. Muted
  previews, unsynced videos, vanished tabs, and navigation cannot begin a cut.
  Other playing browser frames also prevent a cut.

A pause-tail request affects DALI's captured room audio. The extension cannot
identify audio playing in an unrelated native Mac app. DALI expires these
requests after the reported delay plus a short margin, with an independent
app-side timeout as a backstop.

## Privacy and permissions

The extension has no external service, account, analytics, or remote code. It
reads video frames locally and sends playback state, tab title, host, and an
optional page thumbnail URL to the local DALI app. It does not upload the
frames. Local storage contains optional timing trims, a debug setting, and the
latest managed-update attempt.

Broad HTTP/HTTPS host access is needed to operate across video platforms and
embedded players. The scripting permission restores already-open pages after
updates. The only extension network client addresses `127.0.0.1:3697`.
Requests carry `X-DALI-Client: chrome-extension`; the app must reject ordinary
web origins and unauthorized preflights. This header is a browser origin
boundary, not a secret credential against other software on the Mac.

## Local app contract

```
GET http://127.0.0.1:3697/
{"app":"DALI","protocolVersion":1,"streaming":true,"delayMs":900,
 "extensionVersion":"1.1.0"}
```

Replies without `protocolVersion` remain compatible with version 1. The app
must advertise `extensionVersion` only after its managed extension export is
ready. `GET /cut`, `GET /resume`, and `GET /now?d=<encoded-json>` remain the
control endpoints. Status requests share a 750 ms cache; pages with media poll
about once per second. The request timeout covers response-body reading too.

## Verify a release

From the repository root, with Node 20 or later:

```sh
node --test --test-reporter=spec chrome-extension/tools/harness/regressions.mjs
```

The suite runs the shipped `content.js`, `background.js`, and `beacon.js` with
deterministic clocks, media objects, and extension APIs. It tests frame-age
selection at several delays, playback and navigation recovery, updates,
protocol compatibility, memory release, and cross-tab pause handling. It needs
no dependencies, Chrome profile, network connection, or speakers.

`tools/harness/index.html` is a separate visual fixture with a synthetic
frame-number video. `?real=1` keeps Chrome's native frame callbacks. Its older
full-suite driver includes exploratory scenarios and optional live-beacon
reads. Use the deterministic suite as the release gate, then perform browser
and in-room checks before claiming platform and speaker compatibility.
