#!/bin/bash
# Compile the actual application without signing, launching, or installing it.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"
command -v xcodegen >/dev/null || { echo 'Install XcodeGen: brew install xcodegen'; exit 1; }
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dali-app-compile.XXXXXX")"
trap 'rm -rf "$BUILD_ROOT"' EXIT
mkdir -p "$BUILD_ROOT/project"
# XcodeGen resolves folder resources relative to the generated project even
# with --project-root. Keep that resource available inside the temporary tree.
ln -s "$ROOT/chrome-extension" "$BUILD_ROOT/project/chrome-extension"
xcodegen generate --quiet --spec "$ROOT/project.yml" \
  --project-root "$ROOT" --project "$BUILD_ROOT/project"
if ! xcodebuild -project "$BUILD_ROOT/project/DALI.xcodeproj" -scheme DALI \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$BUILD_ROOT/derived-data" \
  ARCHS="${DALI_ARCH:-arm64}" ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build > "$BUILD_ROOT/compile.log" 2>&1; then
  rg -n -B 3 -A 6 'error:|BUILD FAILED|The following build commands failed:' \
    "$BUILD_ROOT/compile.log" || tail -n 60 "$BUILD_ROOT/compile.log"
  exit 1
fi
APP="$BUILD_ROOT/derived-data/Build/Products/Release/DALI.app"
[ -x "$APP/Contents/MacOS/DALI" ] || { echo 'App executable missing after compilation'; exit 1; }
python3 scripts/tests/app-metadata.py "$APP/Contents/Info.plist" "$APP/Contents/Resources"
echo 'PASS: complete DALI app compiled unsigned, without launching or installing'
