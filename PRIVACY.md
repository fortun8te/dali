# Privacy

DALI captures Mac audio locally and sends it to the AirPlay speakers you select. It does not upload audio to a DALI service. There is no DALI account, analytics service, or advertising SDK.

The optional Chrome extension runs on HTTP and HTTPS pages so it can find supported HTML video players. It checks a local DALI endpoint for playback timing. While active, it reports video playback state, page title, site hostname, and available cover-art URL to the app on the same Mac. It does not send browsing history to a remote DALI server. Cover images may be fetched directly from the publisher's server.

The app can ask running Spotify and Music apps what is playing. macOS may ask for Automation permission. System audio recording is needed to stream captured audio; Accessibility permission is not required.

The local OwnTone engine indexes the Music folder for library playback. Preferences, library data, and diagnostic logs remain in your user's Library folders. Logs can contain speaker names, local network addresses, file paths, and media titles. Review them before sharing.

Removing the extension stops its page access. Quitting DALI stops capture and its supervised engine. You can revoke audio permission in System Settings. Uninstalling the app does not automatically erase your saved preferences or library database.
