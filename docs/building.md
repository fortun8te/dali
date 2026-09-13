# Build DALI

Supported build target: Apple Silicon and macOS 15 or later. You need full Xcode, its command-line tools, Homebrew, and Node.js 22 for extension tests.

```sh
git clone https://github.com/fortun8te/dali.git
cd dali
brew install xcodegen node automake autoconf libtool pkg-config gettext gperf bison flex \
  libunistring confuse libplist libwebsockets libevent libgcrypt json-c protobuf-c \
  libsodium openssl@3 ffmpeg sqlite
./scripts/check.sh
./scripts/build-engine.sh
./scripts/build-release.sh
```

The engine build uses the source snapshots included in this repository. It builds dependencies into the checkout and vendors the engine without sudo. It does not change a running DALI or a saved room. The current engine dependency recipe follows upstream macOS guidance; a fresh-machine build still needs validation and package versions can change.

`build/distribution/DALI-arm64.zip` contains the development app. The default signature is ad-hoc and the app is not notarized. Use it as a developer build; do not remove macOS security checks or describe it as ready for general download. See [release requirements](releasing.md) for Developer ID signing.

To compile the UI without building the engine:

```sh
xcodegen generate
xcodebuild -project DALI.xcodeproj -scheme DALI -configuration Release \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

To package just the Chrome extension:

```sh
python3 scripts/package-extension.py build/DALI-Video-Sync.zip
```

Do not use the historical personal `build-sign-install.sh` workflow for distribution. It is intentionally excluded from the public source release. There is no private signing identity or personal engine path required by the public scripts.
