#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="${1:-/tmp/dali-onboarding-preview}"
BIN_DIR="$(mktemp -d /tmp/dali-onboarding-render.XXXXXX)"
trap 'rm -rf "$BIN_DIR"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
  Sources/DALI/OnboardingState.swift Sources/DALI/ExtensionInstaller.swift \
  Sources/DALI/Theme/Palette.swift Sources/DALI/Theme/Typography.swift \
  Sources/DALI/Views/SpeakerIcon.swift Sources/DALI/Views/OnboardingView.swift \
  scripts/onboarding-snapshot.swift -o "$BIN_DIR/onboarding-snapshot"
"$BIN_DIR/onboarding-snapshot" "$OUTPUT" "$PWD/Assets/AppIcon.icns"
