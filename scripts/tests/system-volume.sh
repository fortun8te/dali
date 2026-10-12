#!/bin/bash
# Exercise the production observer with fake HAL calls, without audio hardware.
set -euo pipefail
cd "$(dirname "$0")/../.."
VOLUME_TEST_DIR="$(mktemp -d /tmp/dali-system-volume.XXXXXX)"
trap 'rm -rf "$VOLUME_TEST_DIR"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
  Sources/DALI/SystemVolumeObserver.swift scripts/tests/system-volume.swift \
  -o "$VOLUME_TEST_DIR/system-volume"
"$VOLUME_TEST_DIR/system-volume"
