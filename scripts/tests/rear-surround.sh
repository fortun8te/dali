#!/bin/bash
# Compile the production rear-surround DSP out of the engine source and test it.
set -euo pipefail
cd "$(dirname "$0")/../.."
DIR="$(mktemp -d "${TMPDIR:-/tmp}/dali-rear-surround.XXXXXX")"
trap 'rm -rf "$DIR"' EXIT
python3 - "$DIR/test.c" <<'PY'
import sys
src = open('third_party/owntone/src/outputs/airplay.c').read()
state = src[src.index('#define REAR_HISTORY_FRAMES'):src.index('struct airplay_master_session\n{')]
dsp = src[src.index('static void\nrear_state_init'):src.index('static void\nchannel_levels_add(')]
head = '#define _GNU_SOURCE\n' + ''.join(f'#include <{h}.h>\n' for h in ['stdint','stddef','stdio','string','stdlib','stdbool','assert','math'])
open(sys.argv[1], 'w').write(head + state + dsp + open('scripts/tests/rear-surround-test.c').read())
PY
cc -std=c11 -O2 -Wall -Wextra -fsanitize=address,undefined -o "$DIR/test" "$DIR/test.c" -lm
"$DIR/test"
