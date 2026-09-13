# Set up DALI

DALI is currently a developer preview. Build it using [these instructions](building.md). A signed public download and a Chrome Web Store listing are still pending.

1. Put DALI.app in Applications and open it. Keep the same app location and signing identity for future builds so macOS can recognize it consistently.
2. Follow the audio permission step. Open System Settings → Privacy & Security → Screen & System Audio Recording. The exact label can vary by macOS version. Drag the DALI app icon into the app list if macOS accepts it. Otherwise use **+** and choose DALI from Applications, then turn on its permission. DALI does not need Accessibility access.
3. Add the optional video extension. DALI copies its bundled extension to a stable folder and reveals it. In Chrome, open `chrome://extensions`, turn on Developer mode, choose **Load unpacked**, and select that folder. Chrome requires this manual step until a store version is available.
4. Keep the Mac and speakers on the same trusted network. Choose your speakers in DALI, start at a comfortable volume, and press the playback button.

Existing users skip setup automatically. Setup does not reset speaker choices, volume, delay calibration, or your selected audio source.

## Updates

App and extension compatibility is checked together before every packaged build. The extension can reconnect after an app restart and understands the previous status format. The app refreshes an already-installed stable extension folder when a new bundled version is available. The first upgrade from extension 1.0.x requires **Reload** on Chrome’s extensions page. From 1.1 onward, the extension can reload itself once when DALI advertises a newer bundled version. This works for the managed folder. Manually loaded source folders still need their files updated and may need Reload. The extension replaces older page scripts after loading. Store updates are not configured yet.

## If something needs attention

- No speakers: confirm the same network, allow Local Network access if macOS asks, and check speaker power and AirPlay availability.
- Silence: check System Audio Recording permission and the selected audio source. macOS permission cannot be inferred from a successful build or an enabled button.
- Video mismatch: confirm the extension is enabled, DALI is streaming, and you reloaded the extension after an update. Some protected players cannot use delayed video.
- A speaker drops out: look at its status and reduce network congestion. A green software state cannot prove audible output.

You can skip the optional browser step and return to it later. No cloud account is needed.
