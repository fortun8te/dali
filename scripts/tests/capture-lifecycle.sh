#!/bin/bash
# Exercise production capture without HAL permission, installed app or live audio.
set -euo pipefail
cd "$(dirname "$0")/../.."
CAPTURE_TEST_DIR="$(mktemp -d /tmp/dali-capture-lifecycle.XXXXXX)"
trap 'rm -rf "$CAPTURE_TEST_DIR"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
  Sources/BeamCapture/*.swift Sources/DALI/CaptureController.swift \
  scripts/tests/capture-lifecycle.swift -o "$CAPTURE_TEST_DIR/capture-lifecycle"
"$CAPTURE_TEST_DIR/capture-lifecycle"
