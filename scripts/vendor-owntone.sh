#!/bin/bash
# Vendors the locally-built owntone binary, SQLite module and non-system dylibs into
# vendor/owntone/ so DALI.app can bundle them under Contents/Helpers/.
# Rewrites the executable's libraries to @executable_path/lib/ and shared
# libraries' dependencies to @loader_path/ so runtime-loaded modules relocate.
#
# Pass the binary explicitly when you have just rebuilt the engine:
#   ./scripts/vendor-owntone.sh third_party/owntone/src/owntone
# The default ($HOME/.local/beam/sbin/owntone) is whatever `make install` last
# left there and is routinely months stale — build-sign-install.sh asserts the
# DALI patch marker afterwards for exactly that reason.
set -euo pipefail

SRC_BIN="${1:-$HOME/.local/beam/sbin/owntone}"
SRC_SQLITE_EXT="${2:-}"
OUT="$(cd "$(dirname "$0")/.." && pwd)/vendor/owntone"

# STAGE, THEN SWAP. This used to `rm -rf "$OUT"` up front and build in place, so
# any failure mid-run (a dep whose recorded path no longer exists — libinotify
# moved out of /usr/local/lib and killed a run) left vendor/owntone half-built:
# right binary, missing libs, no path rewriting, and `set -e` exiting before any
# of it was reported. build-sign-install.sh would then bundle that. Build into a
# temp tree and only replace the real one once everything below has succeeded.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/vendor-owntone.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
LIBDIR="$STAGE/lib"
mkdir -p "$LIBDIR"

[ -x "$SRC_BIN" ] || { echo "owntone binary not found at $SRC_BIN"; exit 1; }
if [ -z "$SRC_SQLITE_EXT" ]; then
  # Uninstalled build tree, installed prefix, or a previously vendored tree.
  for candidate in \
    "$(dirname "$SRC_BIN")/../sqlext/.libs/owntone-sqlext.so" \
    "$(dirname "$SRC_BIN")/../lib/owntone/owntone-sqlext.so" \
    "$(dirname "$SRC_BIN")/lib/owntone-sqlext.so"; do
    if [ -f "$candidate" ]; then SRC_SQLITE_EXT="$candidate"; break; fi
  done
fi
[ -f "$SRC_SQLITE_EXT" ] || {
  echo 'FATAL: OwnTone SQLite extension missing. Pass the matching built owntone-sqlext.so as argument 2.'
  exit 1
}
cp "$SRC_BIN" "$STAGE/owntone"
chmod u+w "$STAGE/owntone"
cp "$SRC_SQLITE_EXT" "$LIBDIR/owntone-sqlext.so"
chmod u+w "$LIBDIR/owntone-sqlext.so"

# Some deps record a path they are no longer installed at (Homebrew relocations,
# a deps prefix that moved). Look the basename up in the known prefixes before
# giving up, so one moved library can't fail the whole vendor.
SEARCH_DIRS=(
  "$(dirname "$SRC_BIN")/lib"
  "$(dirname "$SRC_SQLITE_EXT")"
  "$HOME/.local/beamdeps/lib"
  "$(cd "$(dirname "$0")/.." && pwd)/build/engine-deps/lib"
  "$(brew --prefix)/lib"
  /opt/homebrew/lib
  /usr/local/lib
)
resolve() { # $1 = recorded path -> prints a real path, or nothing
  [ -f "$1" ] && { echo "$1"; return; }
  local base; base="$(basename "$1")"
  local d
  for d in "${SEARCH_DIRS[@]}"; do
    [ -f "$d/$base" ] && { echo "$d/$base"; return; }
  done
}

# Collect non-system dylib deps recursively (anything not in /usr/lib or /System).
# NOTE: the `while read` loop runs in a subshell, so `seen` never persisted
# across calls — dedupe on the file already existing in $LIBDIR instead, which
# is what actually worked.
collect() {
  local dep base src
  while IFS= read -r dep; do
    case "$dep" in /usr/lib/*|/System/*) continue ;; esac
    base="$(basename "$dep")"
    [ -f "$LIBDIR/$base" ] && continue
    src="$(resolve "$dep")"
    if [ -z "$src" ]; then
      echo "FATAL: dependency not found anywhere: $dep (needed by $1)"
      echo "       searched: ${SEARCH_DIRS[*]}"
      exit 1
    fi
    cp "$src" "$LIBDIR/$base"
    chmod u+w "$LIBDIR/$base"
    collect "$LIBDIR/$base"
  done < <(otool -L "$1" | sed -n '2,$s/^[[:space:]]*\(.*\) (compatibility version.*$/\1/p')
}
collect "$STAGE/owntone"
collect "$LIBDIR/owntone-sqlext.so"
# Second pass: deps of deps may have been added after their parents were scanned.
shopt -s nullglob
for f in "$LIBDIR"/*.dylib "$LIBDIR"/*.so; do collect "$f"; done

fixup() {
  local dep base prefix
  prefix='@loader_path/'
  [ "$1" != "$STAGE/owntone" ] || prefix='@executable_path/lib/'
  while IFS= read -r dep; do
    case "$dep" in /usr/lib/*|/System/*) continue ;; esac
    base="$(basename "$dep")"
    install_name_tool -change "$dep" "$prefix$base" "$1" 2>/dev/null
  done < <(otool -L "$1" | sed -n '2,$s/^[[:space:]]*\(.*\) (compatibility version.*$/\1/p')
}
fixup "$STAGE/owntone"
for f in "$LIBDIR"/*.dylib; do
  install_name_tool -id "@loader_path/$(basename "$f")" "$f" 2>/dev/null
  fixup "$f"
done
fixup "$LIBDIR/owntone-sqlext.so"

codesign -f -s - "$LIBDIR"/*.dylib "$LIBDIR"/*.so "$STAGE/owntone"

# VERIFY BEFORE SWAPPING. Every non-system reference must now be an
# @executable_path/lib/ or @loader_path/ path whose target is present. A dangling one
# means the engine dies at launch with a dyld error and nothing upstream notices.
bad=0
for f in "$STAGE/owntone" "$LIBDIR"/*.dylib "$LIBDIR"/*.so; do
  while read -r d; do
    case "$d" in
      @executable_path/lib/*)
        [ -f "$LIBDIR/${d#@executable_path/lib/}" ] || { echo "DANGLING: $f -> $d"; bad=1; } ;;
      @loader_path/*)
        [ -f "$(dirname "$f")/${d#@loader_path/}" ] || { echo "DANGLING: $f -> $d"; bad=1; } ;;
      /usr/lib/*|/System/*) ;;
      *) echo "UNREWRITTEN: $f -> $d"; bad=1 ;;
    esac
  done < <(otool -L "$f" | sed -n '2,$s/^[[:space:]]*\(.*\) (compatibility version.*$/\1/p')
done
[ "$bad" -eq 0 ] || { echo "FATAL: vendored tree is broken — leaving $OUT untouched"; exit 1; }

# The whole point of this script: the engine carries LOCAL PATCHES. If the source
# binary predates them, vendoring silently ships an engine where Space does
# nothing and the sync diagnostics are gone.
# `strings X | grep -q` is WRONG under `set -o pipefail`: grep -q exits on the
# first match, strings takes SIGPIPE and reports 141, and the pipeline "fails"
# precisely when the marker IS present. It is a race (it passes whenever the
# output fits in the pipe buffer), which makes it worse, not better. grep -c
# drains stdin, so there is no signal to trip over.
if [ "$(strings "$STAGE/owntone" | grep -c "AI event=%s device='%s' divergence_ms=" || true)" -eq 0 ]; then
  echo "FATAL: $SRC_BIN is missing the DALI engine patches — leaving $OUT untouched"
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
cp -R "$STAGE" "$OUT"

echo "vendored: $OUT"
echo "binary deps now:"
otool -L "$OUT/owntone" | sed -n '1,8p'
echo "lib count: $(ls "$OUT/lib" | wc -l | tr -d ' ')"
