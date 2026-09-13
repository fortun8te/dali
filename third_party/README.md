# Engine source provenance

`owntone/` contains OwnTone 29.2 from upstream commit `84e3755198c44c36ddf91e9919634807d68f69f9`, with DALI's existing local source changes applied. Upstream: https://github.com/owntone/owntone-server. The original license is `owntone/COPYING`. The patch against that upstream commit is `../engine/patches/dali-owntone.patch`.

The changes concern pipe playback timing, fractional progress accounting, AirPlay/RAOP delivery recovery, diagnostics, per-speaker delay controls, and PTP. This source snapshot preserves the implementation used for DALI development. It is not proof that any previously installed binary exactly matches this tree.

`libinotify-kqueue/` is the unmodified upstream commit `fe1dd41dae510034e6366f98bb5e8a916ad209f2`, version 20240724, from https://github.com/libinotify-kqueue/libinotify-kqueue. Its license is included in that directory.

Build with `../scripts/build-engine.sh` from the repository root. No generated configure logs, personal runtime databases, compiled engine binaries, or local credentials are included.

Other engine dependencies are installed with Homebrew. Their versions and build flags vary with the installed formulae. Before distributing a bundled binary, generate an inventory from the actual linked files, include the correct licenses, and satisfy corresponding-source obligations for those exact versions. In particular, the development FFmpeg build enabled GPL and version-3 components; do not describe it as LGPL-only.
