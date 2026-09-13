#!/bin/bash
# Build included engine sources into this checkout, without sudo or installation.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BREW_PREFIX="$(brew --prefix)"
ENGINE_PREFIX="$ROOT/build/engine-install"
ENGINE_DEPS="$ROOT/build/engine-deps"
export PATH="$BREW_PREFIX/opt/bison/bin:$BREW_PREFIX/opt/flex/bin:$PATH"
export ACLOCAL_PATH="$BREW_PREFIX/share/gettext/m4${ACLOCAL_PATH:+:$ACLOCAL_PATH}"
export CFLAGS="-I$BREW_PREFIX/include -I$BREW_PREFIX/opt/sqlite/include -I$ENGINE_DEPS/include"
export LDFLAGS="-L$BREW_PREFIX/lib -L$BREW_PREFIX/opt/sqlite/lib -L$ENGINE_DEPS/lib"
export PKG_CONFIG_PATH="$ENGINE_DEPS/lib/pkgconfig:$BREW_PREFIX/lib/pkgconfig:$BREW_PREFIX/opt/openssl@3/lib/pkgconfig:$BREW_PREFIX/opt/sqlite/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export YACC="$BREW_PREFIX/opt/bison/bin/bison -y"
export LEX="$BREW_PREFIX/opt/flex/bin/flex"
[ -f third_party/owntone/configure.ac ] || { echo 'Included engine source missing. Use the public source checkout.'; exit 1; }
mkdir -p build/engine-src
# Configure generates files: isolate them from the published source snapshot.
rsync -a third_party/libinotify-kqueue/ build/engine-src/libinotify-kqueue/
rsync -a third_party/owntone/ build/engine-src/owntone/
(
  cd build/engine-src/libinotify-kqueue
  autoreconf -fvi
  ./configure --prefix="$ENGINE_DEPS"
  make -j4
  make install
)
(
  cd build/engine-src/owntone
  autoreconf -fi
  ./configure --prefix="$ENGINE_PREFIX" --sysconfdir="$ENGINE_PREFIX/etc" --localstatedir="$ENGINE_PREFIX/var"
  make -j4
)
./scripts/vendor-owntone.sh "$ROOT/build/engine-src/owntone/src/owntone"
echo 'Engine built and vendored. Nothing was installed or launched.'
