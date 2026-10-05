#!/bin/bash
# Cross-compile pm3scan (SDL2 GUI) for the TrimUI Brick Pro.
#
# Reuses the aarch64 toolchain + TrimUI SDK sysroot prepared for the pm3 client
# build (client/). SDL2 / SDL2_ttf come from the SDK sysroot; the device provides
# SDL2 2.30.8 in /usr/trimui/lib (SONAME libSDL2-2.0.so.0), which is ABI-
# compatible with the 2.26.1 headers we compile against.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TC="$ROOT/client/toolchain/aarch64-linux-gnu-7.5.0-linaro"
SDK="$ROOT/client/sysroot"
EXTRA="$ROOT/client/extra"
WRAP="$ROOT/client/tcwrap"
OUT="$ROOT/app/out"
SRC="$ROOT/app/src"

if [ ! -x "$TC/bin/aarch64-linux-gnu-gcc" ] || [ ! -d "$SDK/usr/include/SDL2" ]; then
    cat >&2 <<'EOF'
build-app.sh: the TrimUI SDK sysroot and toolchain are not present.

  Fetch them (also builds the compiler wrappers this script uses):
      client/fetch-sources.sh
      client/build-client.sh

  The app links SDL2 from that sysroot; there is no system copy to fall back on.
EOF
    exit 1
fi
[ -x "$WRAP/aarch64-trimui-gcc" ] || {
    echo "build-app.sh: compiler wrappers missing -- run client/build-client.sh first" >&2
    exit 1
}

mkdir -p "$EXTRA/lib" "$OUT"

# Curated SDL2 link-time symlinks (same trick as the client build: never expose
# the SDK's glibc components, which are glibc 2.23 and would clash with 2.25).
for l in libSDL2.so libSDL2-2.0.so.0 libSDL2_ttf.so libSDL2_ttf-2.0.so.0 \
         libfreetype.so libfreetype.so.6; do
    [ -e "$SDK/usr/lib/$l" ] && ln -sf "$SDK/usr/lib/$l" "$EXTRA/lib/$l"
done

# The wrapper already adds: -I extra/include -idirafter SDK/usr/include
#                          -L extra/lib -Wl,-rpath,/usr/lib:/lib
CC="$WRAP/aarch64-trimui-gcc"

echo "== compiling pm3scan"
"$CC" -O2 -Wall -Wextra -Wno-unused-parameter \
      -o "$OUT/pm3scan" "$SRC/pm3scan.c" \
      -lSDL2 -lSDL2_ttf -lfreetype -lz -lbz2 -lm -lpthread -ldl \
      -Wl,-rpath,/usr/trimui/lib:/usr/lib:/lib

echo "== built:"
ls -l "$OUT/pm3scan"
file "$OUT/pm3scan"
echo "== NEEDED:"
"$TC/bin/aarch64-linux-gnu-readelf" -d "$OUT/pm3scan" | grep -E 'NEEDED|RPATH|RUNPATH'
