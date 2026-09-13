#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift test
bash scripts/tests/onboarding.sh
node --test --test-reporter=spec chrome-extension/tools/harness/regressions.mjs
python3 scripts/package-extension.py build/DALI-Video-Sync.zip
