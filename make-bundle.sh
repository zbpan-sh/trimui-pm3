#!/bin/bash
# Build a single tarball that a new user can unpack and install with one command.
#
#   ./make-bundle.sh                 # -> dist/trimui-pm3-<tag>.tar.gz
#
# The bundle is the tracked project (docs, scripts, sources) plus the built
# binaries from client/out and app/out, which are deliberately not committed. That
# keeps the repository free of build output while still letting you hand someone
# one ~15 MB file instead of asking them to download 600 MB and compile.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PM3_TAG="${PM3_TAG:-v4.23346}"          # Iceman tag of the bundled client
# The bundle is named after THIS project's version, not the Iceman tag it wraps.
VERSION="${VERSION:-$(git describe --tags --exact-match 2>/dev/null \
                      || git describe --tags --always 2>/dev/null || echo dev)}"
NAME="trimui-pm3-$VERSION"
DIST="$ROOT/dist"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cd "$ROOT"

echo "== checking that the binaries exist"
CLIENT="$ROOT/client/out/proxmark3-$PM3_TAG-aarch64"
RES="$ROOT/client/out/pm3-resources-$PM3_TAG.tar.gz"
APP="$ROOT/app/out/pm3scan"
missing=0
for f in "$CLIENT" "$RES" "$APP"; do
    if [ -f "$f" ]; then
        printf '   ok      %s (%s)\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)"
    else
        printf '   MISSING %s\n' "$f"; missing=1
    fi
done
if [ "$missing" -eq 1 ]; then
    cat >&2 <<EOF

Build them first:
    client/fetch-sources.sh
    PROXMARK3_SRC=\$PWD/client/src/proxmark3-$PM3_TAG client/build-client.sh
    app/build-app.sh
EOF
    exit 1
fi

echo "== laying out $NAME/"
mkdir -p "$TMP/$NAME"
git archive --format=tar HEAD | tar x -C "$TMP/$NAME"

echo "== adding build output (not in git)"
mkdir -p "$TMP/$NAME/client/out" "$TMP/$NAME/app/out"
cp "$CLIENT" "$RES" "$TMP/$NAME/client/out/"
cp "$APP"    "$TMP/$NAME/app/out/"
# firmware images, if they were built
for f in "$ROOT"/client/out/bootrom-*.elf "$ROOT"/client/out/fullimage-*.elf; do
    [ -f "$f" ] && cp "$f" "$TMP/$NAME/client/out/"
done

mkdir -p "$DIST"
OUT="$DIST/$NAME.tar.gz"
tar czf "$OUT" -C "$TMP" "$NAME"

echo
echo "== bundle: $OUT  ($(du -h "$OUT" | cut -f1))"
echo "   project version: $VERSION   bundled Iceman client: $PM3_TAG"
echo
echo "Give that file to the new user; they run:"
echo "    tar xzf $NAME.tar.gz && cd $NAME"
echo "    ./install.sh --host <handheld-ip> --restart-ui"
