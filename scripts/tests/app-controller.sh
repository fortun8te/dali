#!/bin/bash
# Exercise the actual app controller with isolated preferences and injected I/O.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dali-app-controller.XXXXXX")"
trap 'rm -rf "$BIN_DIR"' EXIT
SOURCE_FILES=()
for source in Sources/BeamEngine/*.swift Sources/BeamCapture/*.swift \
  Sources/DALI/*.swift Sources/DALI/Theme/*.swift Sources/DALI/Views/*.swift; do
  if [ "$source" != 'Sources/DALI/DALIApp.swift' ]; then SOURCE_FILES+=("$source"); fi
done
xcrun swiftc -swift-version 6 -strict-concurrency=minimal -parse-as-library \
  -target "$(uname -m)-apple-macosx15.0" \
  "${SOURCE_FILES[@]}" scripts/tests/app-controller.swift \
  -o "$BIN_DIR/app-controller-tests"
"$BIN_DIR/app-controller-tests"
