# Bundled engine review

The bundled OwnTone source and its generated patch both start from upstream
`84e3755198c44c36ddf91e9919634807d68f69f9`. They include the reviewed local
DALI changes and the V2 changes described here. The source inventory records
all 543 files and executable bits. The patch reconstructs that exact inventory
from the pinned upstream archive.

## Preserved behavior

- PTS bounds use the monotonic clock when a pipe marker is consumed. A marker's
  earlier capture timestamp does not reset the playback clock. Ahead-of-clock
  PTS is clamped after 5 ms. Behind drift of 100 to 250 ms receives the 100
  microsecond correction while timer debt is low. A larger lag is handed to
  the paced catch-up as debt (pts advances only as real audio is read); a lag
  beyond 5 s re-anchors pts to the monotonic clock.
- macOS playback timing: the player thread requests Mach time-constraint
  scheduling (2 ms of every 10 ms tick, preemptible) at user-interactive QoS,
  and the 10 ms tick is a persistent libevent timeout on that thread instead
  of SIGALRM/setitimer. Under a load average of about 328, a 60 s run showed
  zero late ticks and a worst debt of 4 ms (2026-10-19). The app launches the
  engine at user-interactive QoS and runs its FIFO writer and silence keepalive
  at user-interactive QoS.
- Fractional sample progress accumulates its remainder instead of losing a
  fraction of a millisecond on each short read.
- macOS catch-up uses elapsed wall time, sends at most three reads per callback,
  repays the remaining debt, and skips early coalesced callbacks. A scheduler
  stall shorter than 5 s is repaid at that paced rate; only a longer gap (sleep,
  debugger) discards its debt. Catch-up that finds the input empty drops the
  remaining debt. Discarding every stall of one second or more used to leave
  pts and the input buffer 1.2 to 2.5 s behind for hours (2026-10-18).
- Local UDP backpressure retains the session for less than 3 seconds. Exactly
  3 seconds takes the normal deferred failure path. (1.5 s failed both
  receivers during a 2 s Wi-Fi queue stall on 2026-10-19.) Successful sends reset
  the allowance. This grace exceeds the default presentation lead and does not
  promise uninterrupted sound while the local queue is full.
- Capture supplies forward-paced silence in the Swift transport. The engine's
  existing starvation handling remains. No engine change adds silence backfill.

## V2 changes

Zero percent now emits the AirPlay and RAOP protocol mute value, -144 dB.
Values 1 through 100 keep their existing mapping. The inverse rounds to the
nearest percent and rejects nonfinite or malformed values. A six-decimal
serialization round-trip preserves every percentage at each supported maximum
volume setting.

AirPlay's data socket is explicitly nonblocking. The existing transient
ENOBUFS/EAGAIN allowance can then protect the shared player loop without a
blocking UDP send stalling all speakers.

An isolated AirPlay volume timeout or immediate request creation/connect
failure retains media state. A separate output control-error flag reports
failure to the player command, so the existing HTTP volume endpoint returns
an error instead of success. Rejected RTSP volume replies and asynchronous
connection failures also report a control error; startup authentication retains
its existing response policy. A later successful output cannot erase an earlier
failure in a multi-output command. The flag is updated only if the device still
owns that session. Immediate failures complete on the next player-loop turn,
after the pending command is registered. A genuine delivery failure wins over
that deferred control completion.

The RTSP layer owns a request after enqueue even on an immediate failure. It
removes and frees a failed enqueue, so a retained session cannot later dispatch
that request through a freed sequence context.

The Linux timerfd path now repays catch-up debt on subsequent expirations. Its
old pacing cap accumulated that debt without consuming it. macOS timing policy
is unchanged.

Authored HTTP shutdown/worker admission fixes from local commits `8c426e2` and
`8e8b5d8` are retained. Admission rejects new work during shutdown; the HTTP and
worker loops stay available until admitted handlers finish. Rejected worker
queues release admission and send an error directly on the HTTP thread. The
unrelated generated GNU config.rpath replacement is excluded.

## Control delay and evidence limits

The player command queue is still serialized. An in-session AirPlay RTSP
request has a three-second timeout, while pairing/startup uses the upstream
longer timeout. The event loop continues media work while a player command is
pending, but status/control commands behind it can wait. The V2 app transport
bounds its own queue and avoids additional superseded work. This review does
not replace OwnTone's generic command infrastructure or claim instantaneous
speaker control.

A successful volume request means the control path completed. It does not
measure physical loudness. An inactive output only records the requested
volume locally. Legacy RAOP volume errors still use its existing media failure
path. Its explicit mute and inverse mapping are tested, but this change does
not claim RAOP has the same timeout retention policy as AirPlay 2.

## Automated checks

Run `node scripts/tests/airplay-backpressure.mjs`. It extracts production C
functions and the timer-accounting prefix of the actual playback callback,
then compiles them with address/undefined-behavior sanitizers. Clocks, network
sends, events and module boundaries are deterministic test substitutes. Both
macOS wall-clock and Linux timerfd branches compile and execute on the current
host; this is not a separate Linux-host integration run.

The C checks cover mute/inverse values, malformed input, backpressure boundaries
and recovery, normal and immediate volume failure, preserved media state,
command failure aggregation, deferred delivery-failure precedence, fractional
progress, consumption-time PTS bounds, catch-up debt, failed RTSP enqueue
ownership, rejected HTTP worker admission and shutdown drain. They never start
OwnTone or connect to a receiver.

Run `python3 scripts/engine-source-provenance.py` for offline source/patch hash
verification. Supply `--upstream /path/to/owntone-server` to additionally
reconstruct the exact source from the pinned upstream commit and patch. After
an intentional bundled source change, regenerate with `--update --upstream`.
The upstream checkout is read only.

Full engine compilation completed on 3 October 2026 through the public build
script, with a final exit status of zero. Every bundled C/header input matched
the isolated build tree. The final unvendored engine SHA-256 was
`6ad1e0d3b8f4b46d5600fe68e2fa8bc1e58673b75830b5936bdcc04da69bb716`;
the relocated/ad-hoc-signed checkout-local helper was
`6df9882bc3d0dee5a5ae56d6021d58dc982e2ef9cfdd2066c1741a74911606ef`.
The app was not signed or installed, and the engine was not launched.

The initial vendoring step omitted OwnTone's runtime-loaded SQLite extension.
The engine's compiled default also pointed into the checkout's install prefix,
which caused the observed database startup failure. Packaging now includes
`lib/owntone-sqlext.so` and its dependencies. The supervisor supplies OwnTone's
existing `-s` option with the extension beside the bundled executable, so app
relocation does not use that build prefix. Shared libraries use `@loader_path`
for their sibling dependencies. Release signing and architecture checks include
the `.so` module as well as dylibs. No bundled C source changed for this repair.

`python3 scripts/tests/engine-packaging.py` checks every bundled dependency,
copies the engine tree into a new temporary app path containing spaces, then
loads the relocated extension with the bundled SQLite library in a new
in-memory database. It verifies the extension's custom function, Unicode LIKE
and DAAP collation. It never starts OwnTone, opens the saved database, binds a
port or connects to a speaker. The Swift packaging and reaping checks cover
the exact launch arguments and safe recognition of the old and new process
generations.

The follow-up startup log exposed the same missing-resource problem for the
HTTP web root and cache directory. Vendoring now copies the complete original
`third_party/owntone/htdocs` assets from the corresponding isolated build tree,
excluding generated Makefiles. The existing HTTP thread requires this directory
before it will serve DALI's API. The bundled copy contains the original web UI,
JavaScript, CSS and images. Release packaging moves them into
`Contents/Resources/OwnTone`, where macOS signs them as resources. The supervisor
supplies `-w` with this resource directory for the app bundle and uses `htdocs`
beside the helper for a development tree. `general.cache_dir` points to the materialized persistent
`engine/var/cache` directory. The saved library database is unchanged.

The full prefix audit found seven active defaults. Config, SQLite extension
and web root are overridden with `-c`, `-s` and `-w`; database, logfile and cache
directory are overridden in the generated config; `-f` bypasses the background
PID file. Deprecated Spotify settings have no runtime reader. The packaging
check rejects new unreviewed prefix defaults and compares every web asset byte
with the published engine source before the vendor tree is replaced.

The host's system SQLite lacked unlock-notify support. Compile validation used
a copy of the prior development bundle's standalone SQLite dylib in the
ignored checkout-local dependency directory. Only that copy's install name and
ad-hoc signature changed. Other dependencies came from the host's full
Homebrew installation. This is a compile/link check, not a clean-machine
dependency reproduction or proof of corresponding source for that borrowed
library. Dependency provenance and hardware acceptance remain separate gates. No automated check here proves receiver audibility, long playback,
network changes, sleep/wake or recovery on physical speakers.

## SQLite module packaging repair

The first installed rebuild exposed a missing runtime-loaded `owntone-sqlext.so`; ordinary linked-library collection had missed it. The helper now carries that module in its `lib` directory and DALI passes `-s` with the binary-relative path. Shared-library dependencies use `@loader_path` so the module can relocate with the helper. Vendoring and release signing include the module. The relocated helper hash recorded above identifies the earlier bundle, before this packaging repair. The canonical C source and unvendored engine build did not change.

`python3 scripts/tests/engine-packaging.py` checks the helper tree and loads the module into a fresh in-memory database after relocation. It does not start OwnTone, use the saved database, or operate speakers.

## 17 October 2026 resend retry correction, source only

Live diagnosis found a brief shared ENOBUFS event on both receivers, while capture remained healthy. Separately, an actual-function regression reproduced a recovery defect: a failed retransmit was counted as sent and its request range cached for120ms, suppressing a healthy retry10ms later. packets_resend now counts successful sends and caches the range only when no send failed. Attempted sends still consume tokens; successful-request deduplication,80ms age gate, history gate, maximum request size and token limits remain. The separate overlapping-request policy is unchanged.

This source correction is not in the installed engine or current vendored binary. Source patch and manifest were regenerated and reconstructed against pinned upstream. It is not proof that retry suppression caused the observed live glitch, and no physical playback acceptance is claimed.

## Network-recovery integration, 17 October 2026

The source-only resend correction above is now rebuilt, installed and present in the vendor tree. The rebuilt executable uses the same dependency bytes as the preceding working app. Sanitized C regressions, source reconstruction and relocated runtime packaging pass. A sandboxed private startup test used a fresh empty database and no selected outputs; readiness was217ms. Live app playback subsequently connected both receivers in3.385s, with zero send errors in the recorded30s delivery window. Physical audibility/lip-sync remains separate. See build/network-recovery-20261017 receipts and the dated shared-project handoff.
