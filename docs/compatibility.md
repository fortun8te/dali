# App and extension compatibility

The loopback status endpoint is `http://127.0.0.1:3697/`. Protocol 1 preserves the legacy `app`, `streaming`, and `delayMs` fields and adds `protocolVersion`, `appVersion`, and `capabilities`. Consumers must ignore unknown additive fields. Explicitly unsupported major versions should leave video in normal playback.

Control routes `/cut`, `/resume`, and `/now` accept GET from an extension origin or a client carrying `X-DALI-Client: chrome-extension` with no web origin. Arbitrary page origins, cross-origin preflights, unsupported methods, duplicate headers, unknown routes, and nonlocal Host values are rejected. TCP headers are buffered up to 16 KiB and connections time out after five seconds. The bridge is read-only except for audio gating and local now-playing state; it exposes no command execution.

A custom header is a browser-origin defense, not authentication against software already running on the computer. Do not expose this endpoint through a network proxy.

Regression tests cover playback timing, update reinjection, page lifecycle cleanup, active feed video selection, stale/invalid app status, and app restart recovery. The Swift suite covers request validation, speaker readiness, capture buffers, and configuration. Run the checks on every app or extension release.

The engine JSON control API trusts localhost only and its WebSocket interface uses loopback. General engine binding remains on the network because AirPlay and PTP need speaker communication. Other OwnTone media endpoints are not claimed to be fully isolated. Use DALI on a trusted local network.
