#!/bin/bash
# Fetch everything needed to build the aarch64 PM3 client and the GUI app.
#
#   ./fetch-sources.sh
#
# Idempotent: anything already present is skipped, so it is safe to re-run.
# Total download is roughly 600 MB. If GitHub is slow from your network, set a
# proxy first -- this project measured 27 KB/s direct vs 2.25 MB/s through one:
#
#   https_proxy=http://127.0.0.1:3128 ./fetch-sources.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$ROOT/client/sdk"
CURL=(curl -fL --retry 3 --retry-delay 2 -C -)

SDK_BASE="https://github.com/trimui/toolchain_sdk_smartpro/releases/download/20231018"
PM3_TAG="v4.23346"          # keep in sync with client/build-client.sh / docs/FIRMWARE.md
LZ4_TAG="v1.9.4"

mkdir -p "$SDK" "$ROOT/client/src"

fetch() {   # fetch <url> <destination>
    local url="$1" dest="$2"
    if [ -s "$dest" ]; then
        echo "   have    $(basename "$dest")"
        return
    fi
    echo "   get     $(basename "$dest")"
    "${CURL[@]}" -o "$dest" "$url"
}

echo "== TrimUI SDK and toolchain  -> client/sdk"
fetch "$SDK_BASE/aarch64-linux-gnu-7.5.0-linaro.tgz" "$SDK/aarch64-linux-gnu-7.5.0-linaro.tgz"
fetch "$SDK_BASE/SDK_usr_tg5040_a133p.tgz"           "$SDK/SDK_usr_tg5040_a133p.tgz"
fetch "$SDK_BASE/SDL2-2.26.1.GE8300.tgz"             "$SDK/SDL2-2.26.1.GE8300.tgz"

echo "== extracting"
if [ -x "$ROOT/client/toolchain/aarch64-linux-gnu-7.5.0-linaro/bin/aarch64-linux-gnu-gcc" ]; then
    echo "   have    client/toolchain"
else
    mkdir -p "$ROOT/client/toolchain"
    tar xzf "$SDK/aarch64-linux-gnu-7.5.0-linaro.tgz" -C "$ROOT/client/toolchain"
fi
if [ -d "$ROOT/client/sysroot/usr/include" ]; then
    echo "   have    client/sysroot"
else
    mkdir -p "$ROOT/client/sysroot"
    tar xzf "$SDK/SDK_usr_tg5040_a133p.tgz" -C "$ROOT/client/sysroot"
fi

echo "== lz4 $LZ4_TAG (built statically; not shipped by the SDK)"
if [ -d "$ROOT/client/src/lz4-1.9.4/lib" ]; then
    echo "   have    lz4-1.9.4"
else
    fetch "https://github.com/lz4/lz4/archive/refs/tags/$LZ4_TAG.tar.gz" "$ROOT/client/src/lz4.tar.gz"
    tar xzf "$ROOT/client/src/lz4.tar.gz" -C "$ROOT/client/src"
fi

echo "== Iceman proxmark3 $PM3_TAG"
if [ -d "$ROOT/client/src/proxmark3-$PM3_TAG/client" ]; then
    echo "   have    proxmark3-$PM3_TAG"
else
    git clone --depth 1 --branch "$PM3_TAG" \
        https://github.com/RfidResearchGroup/proxmark3.git \
        "$ROOT/client/src/proxmark3-$PM3_TAG"
fi

cat <<EOF

Done. Next:

  client/build-client.sh                                   # aarch64 PM3 client
  PROXMARK3_SRC=\$PWD/client/src/proxmark3-$PM3_TAG client/build-client.sh
  app/build-app.sh                                      # GUI app

then

  ./install.sh --host <handheld-ip>

To flash matching firmware onto the Proxmark3 itself, see docs/FIRMWARE.md -- the
client and the PM3 firmware must come from the same tag ($PM3_TAG).
EOF
