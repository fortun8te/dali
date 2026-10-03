# App and extension compatibility

The loopback status endpoint is `http://127.0.0.1:3697/`. Protocol 1 preserves the legacy `app`, `streaming`, and `delayMs` fields and adds `protocolVersion`, `appVersion`, and `capabilities`. Consumers must ignore unknown additive fields. Explicitly unsupported major versions should leave video in normal playback.

Control routes `/cut`, `/resume`, and `/now` accept GET from an extension origin or a client carrying `X-DALI-Client: chrome-extension` with no web origin. Arbitrary page origins, cross-origin preflights, unsupported methods, duplicate headers, unknown routes, and nonlocal Host values are rejected. TCP headers are buffered up to 16 KiB and connections time out after five seconds. The bridge is read-only except for audio gating and local now-playing state; it exposes no command execution.

A custom header is a browser-origin defense, not authentication against software already running on the computer. Do not expose this endpoint through a network proxy.

Regression tests cover playback timing, update reinjection, page lifecycle cleanup, active feed video selection, stale/invalid app status, and app restart recovery. YouTube, Shorts, and TikTok have simulated player/feed coverage. Instagram deliberately bypasses picture delay while still reporting audio activity. Its regression tests verify that bypass, not delayed Reels playback. These fixtures do not establish compatibility with live, logged-in sites.

Run `bash scripts/check.sh` before every app or extension release. The gate combines Swift backend tests, production capture-controller lifecycle tests, extracted production C engine tests, isolated onboarding/install tests, browser fixtures, and a complete unsigned app compile. Swift package tests alone do not compile `Sources/DALI/DALIStore.swift` or the SwiftUI app. Extension package validation happens after those checks pass. Build outputs and test state are temporary; the gate never launches or installs the app.

The [V2 validation record](v2/VALIDATION.md) separates current automated results from physical speaker and distribution checks. A ready engine session, successful control reply, or successful local packet send is not proof that a receiver produced sound.

The engine JSON control API trusts localhost only and its WebSocket interface uses loopback. General engine binding remains on the network because AirPlay and PTP need speaker communication. Other OwnTone media endpoints are not claimed to be fully isolated. Use DALI on a trusted local network.
