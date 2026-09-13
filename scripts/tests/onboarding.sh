#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN_DIR="$(mktemp -d /tmp/dali-onboarding-test.XXXXXX)"
trap 'rm -rf "$BIN_DIR"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
  Sources/DALI/OnboardingState.swift Sources/DALI/ExtensionInstaller.swift \
  scripts/tests/onboarding.swift -o "$BIN_DIR/onboarding-tests"
"$BIN_DIR/onboarding-tests"
