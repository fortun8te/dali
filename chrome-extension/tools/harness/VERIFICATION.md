# Extension verification

Verified on September 13, 2026, for extension 1.1.0, build `2026-09-13.a`.

## Deterministic release checks

Command from the repository root:

```sh
node --test --test-reporter=spec chrome-extension/tools/harness/regressions.mjs
```

Result: **42 passed, 0 failed**. JavaScript syntax checks passed for
`content.js`, `background.js`, and `beacon.js`.

The new feed/update/cache scenarios were run against the original scripts
before fixing them: 8 failed while all original 15 tests passed. Additional
frame-age tests reproduced an extra-frame presentation lag before its fix.
The final suite checks 300, 900, and 2000 ms requested delays within one
captured frame, without changing source playback speed or pausing the source.

## Native Chrome picture check

Used a separate temporary headless Chrome profile, a muted synthetic MP4,
the local visual fixture with `?real=1`, native
`requestVideoFrameCallback`, native `createImageBitmap`, and the current
shipped content script. The fixture's MP4 was fetched into a blob because
its simple HTTP server stalled Chrome's media-range load. The DALI beacon
was simulated, with a requested picture delay of **900 ms**.

The picture's frame numbers were decoded from canvas pixels over 121 samples:

| Measurement | Result |
| --- | --- |
| Median delay | 900 ms |
| Mean delay | 901 ms |
| Minimum / maximum | 867 / 933 ms |
| Blank or unreadable samples | 0 |
| Peak live frame memory | 26.7 MB |
| Live bitmaps after teardown | 0 |
| Leftover overlays after teardown | 0 |
| Original video restored | Yes |

The temporary browser, fixture server, automation daemon, and profile were
removed afterward. No personal browser extension or running DALI app was
installed, reloaded, or reconfigured.

## Scope

This checks browser picture delay and controlled platform-like player
behavior. It does not establish physical speaker latency, live platform
compatibility for every account/layout, DRM support, or Chrome Web Store
approval. Those require separate release checks.
