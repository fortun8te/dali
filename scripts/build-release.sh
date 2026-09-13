#!/bin/bash
# Builds a separate product. Never installs, launches, or changes saved settings.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
# Every distributable build must pass app, setup, and browser compatibility checks.
./scripts/check.sh
OUT="${DALI_RELEASE_DIR:-$ROOT/build/distribution}"
IDENTITY="${DALI_SIGN_IDENTITY:--}"
ARCH="${DALI_ARCH:-arm64}"
mkdir -p "$OUT"
# File Provider folders can reattach Finder metadata while code is signed.
# Build and sign in a temporary local directory, then export the archive.
BUILD_ROOT="$(mktemp -d /private/tmp/dali-release.XXXXXX)"
trap 'rm -rf "$BUILD_ROOT"' EXIT
command -v xcodegen >/dev/null || { echo 'Install XcodeGen: brew install xcodegen'; exit 1; }
[ -x vendor/owntone/owntone ] || { echo 'Build and vendor the engine first. See docs/building.md.'; exit 1; }
for binary in vendor/owntone/owntone vendor/owntone/lib/*.dylib; do
  lipo "$binary" -verify_arch "$ARCH" || { echo "Missing $ARCH in $binary"; exit 1; }
done
xcodegen generate
xcodebuild -project DALI.xcodeproj -scheme DALI -configuration Release \
  -destination 'platform=macOS' ARCHS="$ARCH" ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  SYMROOT="$BUILD_ROOT/products" build
APP="$BUILD_ROOT/products/Release/DALI.app"
[ -x "$APP/Contents/MacOS/DALI" ] || exit 1
mkdir -p "$APP/Contents/Helpers"
rm -rf "$APP/Contents/Helpers/owntone"
cp -R vendor/owntone "$APP/Contents/Helpers/owntone"
# Only executable extension assets are shipped, not tests and development notes.
rm -rf "$APP/Contents/Resources/chrome-extension" "$APP/Contents/Resources/ChromeExtension"
mkdir -p "$APP/Contents/Resources/ChromeExtension"
python3 scripts/package-extension.py "$APP/Contents/Resources/ChromeExtension"
if [ -d licenses ]; then cp -R licenses "$APP/Contents/Resources/ThirdPartyLicenses"; fi
/usr/bin/xattr -cr "$APP"
SIGN_ARGS=(--force --sign "$IDENTITY" --options runtime)
if [ "$IDENTITY" != '-' ]; then SIGN_ARGS+=(--timestamp); fi
for binary in "$APP/Contents/Helpers/owntone/lib/"*.dylib "$APP/Contents/Helpers/owntone/owntone"; do
  codesign "${SIGN_ARGS[@]}" "$binary"
done
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
ZIP="$OUT/DALI-$ARCH.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
if [ -n "${DALI_NOTARY_PROFILE:-}" ]; then
  [[ "$IDENTITY" == 'Developer ID Application:'* ]] || { echo 'Notarization requires Developer ID Application signing.'; exit 1; }
  xcrun notarytool submit "$ZIP" --keychain-profile "$DALI_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose "$APP"
  ditto -c -k --keepParent "$APP" "$ZIP"
else
  echo 'Development build only. Not notarized; do not describe as a public signed release.'
fi
shasum -a 256 "$ZIP" > "$ZIP.sha256"
echo "Built $ZIP. Your installed DALI and settings were untouched."
