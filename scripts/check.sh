#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dali-check.XXXXXX")"
trap 'rm -rf "$CHECK_ROOT"' EXIT

run_check() {
  local label="$1"
  shift
  local began="$SECONDS"
  echo "Checking $label"
  "$@"
  echo "PASS: $label ($((SECONDS - began))s)"
}

run_check 'Swift backend regressions' swift test --scratch-path "$CHECK_ROOT/swift"
run_check 'Production capture lifecycle' bash scripts/tests/capture-lifecycle.sh
run_check 'System volume observer responsiveness' bash scripts/tests/system-volume.sh
run_check 'Actual app controller integration' bash scripts/tests/app-controller.sh
run_check 'Bundled engine source and patch hashes' python3 scripts/engine-source-provenance.py
run_check 'Production C engine regressions' env DALI_ENGINE_TEST_SOURCE="$PWD/third_party/owntone" node scripts/tests/airplay-backpressure.mjs
run_check 'Onboarding and managed extension update' bash scripts/tests/onboarding.sh
run_check 'Browser extension regressions' node --test --test-reporter=spec chrome-extension/tools/harness/regressions.mjs
run_check 'Complete unsigned app compile' bash scripts/tests/app-compile.sh
# A validation archive is created only after the preceding checks pass.
# Release packaging separately copies these validated assets into its app.
run_check 'Distributable extension validation' python3 scripts/package-extension.py "$CHECK_ROOT/DALI-Video-Sync.zip"
echo 'PASS: all automated checks; physical audio and distribution checks remain separate'
