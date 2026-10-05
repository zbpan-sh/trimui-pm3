#!/bin/bash
# Cross-compile the Iceman Proxmark3 *client* for the TrimUI Brick Pro (TG4040).
#
# Target : aarch64, Allwinner A133 (sun50iw10p1), TinaLinux 4.9.191
# Libc   : device has glibc 2.33; we link against the Linaro toolchain's glibc 2.25
#          (older == forward compatible, so the binary runs on 2.33)
# Deps   : zlib / bzip2 come from the TrimUI TG5040 SDK sysroot, whose SONAMEs
#          match the device exactly (libz.so.1, libbz2.so.1.0). LZ4 is NOT in the
#          SDK, so it is built statically from upstream source. Line editing uses
#          Iceman's bundled linenoise-ng (the device's libreadline.so.6.3 is not a
#          complete GNU readline). Everything else (jansson, lua, mbedtls, reveng,
#          tinycbor, mqtt, vec, cliparser, whereami) is vendored in-tree.
#
# Deliberately NOT used: the SDK's libm/libdl/libpthread/librt, which are glibc 2.23
# and would clash (GLIBC_PRIVATE) with the 2.25 libc we link against.
#
# NOHARDENING=1: Makefile.defs adds -fstack-clash-protection (GCC 8+) and
# _FORTIFY_SOURCE=3 (GCC 12+), neither of which Linaro GCC 7.5.0 understands.
# Upstream provides NOHARDENING=1 for exactly this case.
#
# cpu_arch=aarch64: deps/hardnested/Makefile autodetects SIMD support from
# `uname -m` (the *host*), so a cross build would otherwise compile x86
# MMX/SSE/AVX variants with -mavx and fail.
#
# WERRORFLAG keeps -Werror on but demotes two GCC 7.5 false positives
# (-Winline on the vendored jansson header, -Wformat-truncation on ansi.h).
#
# Usage: ./build-client.sh [clean]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TC="$ROOT/toolchain/aarch64-linux-gnu-7.5.0-linaro"
SDK="$ROOT/sysroot"
SRC="${PROXMARK3_SRC:-$ROOT/src/proxmark3}"
LZ4SRC="$ROOT/src/lz4-1.9.4"
EXTRA="$ROOT/extra"
WRAP="$ROOT/tcwrap"
JOBS="$(nproc)"

# ---------------------------------------------------------------- sanity checks
[ -x "$TC/bin/aarch64-linux-gnu-gcc" ] || { echo "missing toolchain at $TC"; exit 1; }
[ -d "$SDK/usr/include" ]              || { echo "missing SDK sysroot at $SDK"; exit 1; }
[ -d "$SRC/client" ]                   || { echo "missing proxmark3 source at $SRC"; exit 1; }
[ -d "$LZ4SRC/lib" ]                   || { echo "missing lz4 source at $LZ4SRC"; exit 1; }

echo "== target: $("$TC/bin/aarch64-linux-gnu-gcc" -dumpmachine) / gcc $("$TC/bin/aarch64-linux-gnu-gcc" -dumpversion)"

# --------------------------------------------------- 1. lz4 (static, not in SDK)
if [ ! -f "$EXTRA/lib/liblz4.a" ]; then
    echo "== building liblz4.a (static)"
    mkdir -p "$EXTRA/lib" "$EXTRA/obj"
    ( cd "$LZ4SRC/lib" && \
      "$TC/bin/aarch64-linux-gnu-gcc" -O3 -fPIC -I. \
        -c lz4.c lz4hc.c lz4frame.c xxhash.c && \
      "$TC/bin/aarch64-linux-gnu-ar" rcs "$EXTRA/lib/liblz4.a" \
        lz4.o lz4hc.o lz4frame.o xxhash.o && \
      rm -f lz4.o lz4hc.o lz4frame.o xxhash.o )
fi
ls -l "$EXTRA/lib/liblz4.a"

# ------------------------------- 2. curated include/lib (SDK third-party libs only)
mkdir -p "$EXTRA/include" "$EXTRA/lib"
for h in lz4.h lz4frame.h lz4hc.h; do
    ln -sf "$LZ4SRC/lib/$h" "$EXTRA/include/$h"
done
# Only the libs we actually need from the SDK -- NOT its glibc components.
for l in libz.so libbz2.so; do
    ln -sf "$SDK/usr/lib/$l" "$EXTRA/lib/$l"
done
echo "== curated extra libs:"; ls -l "$EXTRA/lib" | tail -n +2 | awk '{print "   "$9" -> "$11}'

# ------------------------------------------------------------------- 3. linenoise
# The device's libreadline.so.6.3 is not a complete GNU readline (it lacks e.g.
# rl_attempted_completion_function, rl_clear_visible_line), so we use Iceman's
# bundled linenoise-ng instead of linking readline.
if [ ! -f "$SRC/client/deps/linenoise/linenoise.cpp" ]; then
    echo "== unpacking bundled linenoise-ng"
    ( cd "$SRC/client/deps" && ./get_linenoise.sh )
fi

# ------------------------------------------------------------- 4. compiler wrappers
mkdir -p "$WRAP"
# Paths are resolved at run time from the wrapper's own location, so the tree can
# be moved or cloned anywhere without regenerating these.
for tool in gcc g++; do
    cat > "$WRAP/aarch64-trimui-$tool" <<EOF
#!/bin/bash
# Injects the TrimUI toolchain and sysroot paths into every compile/link call.
HERE="\$(cd "\$(dirname "\$0")" && pwd)"
CLIENT="\$(dirname "\$HERE")"
TC="\$CLIENT/toolchain/aarch64-linux-gnu-7.5.0-linaro"
SDK="\$CLIENT/sysroot"
EXTRA="\$CLIENT/extra"
exec "\$TC/bin/aarch64-linux-gnu-$tool" \\
  -I"\$EXTRA/include" \\
  -idirafter "\$SDK/usr/include" \\
  -L"\$EXTRA/lib" \\
  -Wl,-rpath-link,"\$EXTRA/lib" \\
  -Wl,-rpath,/usr/lib:/lib \\
  "\$@"
EOF
    chmod +x "$WRAP/aarch64-trimui-$tool"
done
echo "== wrappers ready in $WRAP"

# ------------------------------------------------------- 5. apply port patches
# Idempotent: a patch that is already applied (or does not belong to this
# Proxmark3 version) is reported and skipped rather than failing the build.
cd "$SRC"
for p in "$ROOT"/patches/*.patch; do
    [ -f "$p" ] || continue
    if patch -p1 -N --dry-run -s -f -i "$p" >/dev/null 2>&1; then
        echo "== applying $(basename "$p")"
        patch -p1 -N -s -f -i "$p"
    else
        echo "== $(basename "$p"): already applied or not applicable to this tree"
    fi
done

# ------------------------------------------------------------------- 6. build it
if [ "${1:-}" = "clean" ]; then
    make clean >/dev/null 2>&1 || true
    # make clean removes client/obj; pre-create it so a parallel build cannot
    # race the per-object `mkdir -p` for the first few objects.
    mkdir -p client/obj
fi

echo "== make client (j=$JOBS)"
make client -j"$JOBS" \
    CC="$WRAP/aarch64-trimui-gcc" \
    CXX="$WRAP/aarch64-trimui-g++" \
    PLATFORM=PM3GENERIC \
    NOHARDENING=1 \
    cpu_arch=aarch64 \
    SKIPREVENGTEST=1 \
    WERRORFLAG="-Werror -Wno-error=inline -Wno-error=format-truncation" \
    SKIPREADLINE=1 \
    SKIPQT=1 \
    SKIPGD=1 \
    SKIPBT=1 \
    SKIPPYTHON=1 \
    SKIPWHEREAMISYSTEM=1 \
    SKIPJANSSONSYSTEM=1 \
    SKIPLUASYSTEM=1 \
    "$@"

echo
echo "== built:"
ls -l "$SRC/client/proxmark3"
file "$SRC/client/proxmark3" 2>/dev/null || true
echo
echo "== needed shared libs:"
"$TC/bin/aarch64-linux-gnu-readelf" -d "$SRC/client/proxmark3" | grep NEEDED || true
echo
echo "== required glibc symbol versions:"
"$TC/bin/aarch64-linux-gnu-readelf" -V "$SRC/client/proxmark3" 2>/dev/null \
    | grep -oE 'GLIBC_[0-9.]+' | sort -Vu | tail -5 || true

# ------------------------------------------- 7. shareable artifact (client/out)
# So a built client can be handed to someone who does not want to build it.
TAG="$(git -C "$SRC" describe --tags --always 2>/dev/null || echo unknown)"
OUT="$ROOT/out"
mkdir -p "$OUT"
cp -f "$SRC/client/proxmark3" "$OUT/proxmark3-$TAG-aarch64-unstripped"
"$TC/bin/aarch64-linux-gnu-strip" -o "$OUT/proxmark3-$TAG-aarch64" "$SRC/client/proxmark3"
tar czf "$OUT/pm3-resources-$TAG.tar.gz" -C "$SRC/client" \
    dictionaries lualibs luascripts cmdscripts resources
echo
echo "== shareable artifacts in client/out (hand these to another machine):"
ls -lh "$OUT"/proxmark3-"$TAG"-aarch64 "$OUT"/pm3-resources-"$TAG".tar.gz | awk '{print "   "$5"  "$9}'
