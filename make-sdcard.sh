#!/bin/bash
# Build a self-contained folder that is installed by copying it onto the microSD
# card -- no SSH, no network, no compiler.
#
#   ./make-sdcard.sh                 # -> dist/sdcard/
#
# Everything the app needs travels with it, including the Iceman client, which it
# finds in its own pm3/ subdirectory. Copy the Apps folder to the card root, put
# the card in the handheld, done.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PM3_TAG="${PM3_TAG:-v4.23346}"
NAME="Proxmark3Tools"
OUT="$ROOT/dist/sdcard"
APP="$OUT/Apps/$NAME"

CLIENT="$ROOT/client/out/proxmark3-$PM3_TAG-aarch64"
RES="$ROOT/client/out/pm3-resources-$PM3_TAG.tar.gz"
BIN="$ROOT/app/out/pm3scan"
FONT="${FONT:-/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf}"

missing=0
for f in "$CLIENT" "$RES" "$BIN"; do
    if [ -f "$f" ]; then
        printf '== have    %-42s %s\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)"
    else
        printf '== MISSING %s\n' "$f"; missing=1
    fi
done
[ -f "$FONT" ] || { echo "== MISSING font $FONT"; missing=1; }
if [ "$missing" -eq 1 ]; then
    cat >&2 <<EOF

Build them first:
    client/fetch-sources.sh
    PROXMARK3_SRC=\$PWD/client/src/proxmark3-$PM3_TAG client/build-client.sh
    app/build-app.sh
EOF
    exit 1
fi

echo "== assembling $OUT"
rm -rf "$OUT"
mkdir -p "$APP/pm3"

cp "$BIN" "$APP/pm3scan"
cp "$FONT" "$APP/DejaVuSans.ttf"
for f in config.json launch.sh icon.png; do cp "$ROOT/app/assets/$f" "$APP/$f"; done
chmod +x "$APP/pm3scan" "$APP/launch.sh"

# The client lives inside the app folder; pm3scan looks for it there first, so
# the app keeps working with no internal storage involved at all.
cp "$CLIENT" "$APP/pm3/proxmark3"
chmod +x "$APP/pm3/proxmark3"
tar xzf "$RES" -C "$APP/pm3"

cat > "$OUT/HOW-TO-INSTALL.txt" <<'EOF'
PM3 tools — install by copying to the microSD card
==================================================

No SSH, no network and no compiler are needed.

1. Power the handheld off and take out the microSD card.
2. Insert it in your computer.
3. Copy the whole "Apps" folder from this directory onto the card, merging it
   with the "Apps" folder that is already there. You should end up with:

       <card>/Apps/Proxmark3Tools/pm3scan
       <card>/Apps/Proxmark3Tools/pm3/proxmark3
       <card>/Apps/Proxmark3Tools/pm3/dictionaries/...
       ...

4. Eject the card, put it back, power the handheld on.
5. "PM3 tools" should be in the Apps menu. If it is not listed, see the note
   below, then reboot.

Plug the Proxmark3 into the TOP USB-C port before scanning.
Scanning also needs the Proxmark3 to run firmware from the same Iceman release
as the client (v4.23346 here) -- see docs/FIRMWARE.md.


If the app does not appear in the Apps menu
-------------------------------------------
The launcher keeps a visibility list in <card>/Apps/show.json. MainUI scans the
Apps folders itself and rewrites that file, but if the entry is missing, add it
by hand: open show.json in any text editor and add this object inside the [ ]
array, separated from the previous one by a comma:

    {
     "label": "PM3 tools",
     "show": 1
    }

Keep the file valid JSON (it is an array of objects). A backup copy of the
original is worth keeping until it works.


Removing it
-----------
Delete <card>/Apps/Proxmark3Tools and remove its entry from show.json.
EOF

echo
echo "== ready: $OUT"
du -sh "$OUT" | awk '{print "   size: "$1}'
find "$OUT" -maxdepth 3 -type d | sed "s|$OUT|   |g"
echo
echo "Copy the 'Apps' folder onto the microSD card, merging with the existing one."
