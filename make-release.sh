#!/bin/bash
# Build the artifacts to attach to a GitHub release.
#
#   ./make-release.sh                # -> dist/release/
#
# Two assets, matching the two documented install routes:
#   trimui-pm3-<version>.tar.gz          sources + prebuilt binaries, installed
#                                        over SSH with install.sh
#   trimui-pm3-sdcard-<version>.zip      ready to copy onto the microSD card,
#                                        no SSH needed (zip, so Windows users can
#                                        just extract it)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

VERSION="${VERSION:-$(git describe --tags --exact-match 2>/dev/null \
                      || git describe --tags --always 2>/dev/null || echo dev)}"
OUT="$ROOT/dist/release"
mkdir -p "$OUT"

echo "== building the source+binary bundle"
VERSION="$VERSION" "$ROOT/make-bundle.sh"

echo
echo "== building the microSD card tree"
"$ROOT/make-sdcard.sh"

echo
echo "== packing the card tree as a zip"
python3 - "$ROOT/dist/sdcard" "$OUT/trimui-pm3-sdcard-$VERSION.zip" <<'PY'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for base, _dirs, files in os.walk(src):
        for name in files:
            full = os.path.join(base, name)
            z.write(full, os.path.relpath(full, src))
print("  wrote", dst)
PY

# keep the plain bundle next to the zip for convenience
BUNDLE="$ROOT/dist/trimui-pm3-$VERSION.tar.gz"
[ -f "$BUNDLE" ] && cp -f "$BUNDLE" "$OUT/"

echo
echo "== release assets in $OUT"
ls -lh "$OUT" | tail -n +2 | awk '{printf "   %-42s %s\n", $9, $5}'

cat <<EOF

Upload them to the release with:

    gh release create $VERSION --title "$VERSION" --notes-file <notes.md> \\
        $OUT/*

or attach them by hand at
    https://github.com/zbpan-sh/trimui-pm3/releases/new?tag=$VERSION
EOF
