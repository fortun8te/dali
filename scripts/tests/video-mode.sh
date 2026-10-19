#!/bin/bash
# Compiles the production Desk-mode transitions against fake output devices.
set -euo pipefail
cd "$(dirname "$0")/../.."
TEST_DIR="$(mktemp -d /tmp/dali-video-mode.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
  Sources/DALI/VideoMode.swift scripts/tests/video-mode.swift \
  -o "$TEST_DIR/video-mode"
"$TEST_DIR/video-mode"
