#!/bin/bash
# Install (or update) the PROXMARK3 tools app on a TrimUI handheld over SSH.
#
#   TRIMUI_HOST=<handheld-ip> TRIMUI_PASS=tina ./deploy-app.sh
#
# Installs to <sdcard>/Apps/Proxmark3Tools/ and registers it in Apps/show.json so
# stock MainUI lists it. Restart MainUI afterwards to pick up show.json.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${TRIMUI_HOST:-}"
USER="${TRIMUI_USER:-root}"
PASS="${TRIMUI_PASS:-tina}"
APPDIR="/mnt/SDCARD/Apps/Proxmark3Tools"
LABEL="PM3 tools"
# earlier names this app was installed under; cleaned up after a good install
LEGACY_DIRS="/mnt/SDCARD/Apps/ProxmarkScan"
LEGACY_LABELS="PROXMARK3 tools|PM3 Scan"
FONT="${FONT:-/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf}"

if [ -z "$HOST" ]; then
  echo "deploy-app.sh: TRIMUI_HOST is not set." >&2
  echo "               export TRIMUI_HOST=<handheld-ip>" >&2
  exit 2
fi

[ -x "$ROOT/device/rsh.sh" ] || { echo "missing device/rsh.sh"; exit 1; }
rsh() { TRIMUI_HOST="$HOST" TRIMUI_USER="$USER" TRIMUI_PASS="$PASS" "$ROOT/device/rsh.sh" "$@"; }

[ -f "$ROOT/app/out/pm3scan" ] || { echo "build first: app/build-app.sh"; exit 1; }
[ -f "$FONT" ] || { echo "font not found: $FONT (override with FONT=/path/to.ttf)"; exit 1; }

echo "== creating $APPDIR"
rsh "mkdir -p $APPDIR"

echo "== stopping any running copy"
# Overwriting a running executable fails with "Text file busy". busybox pgrep
# does not match the truncated comm name here, so resolve /proc/*/exe instead.
rsh 'for e in /proc/[0-9]*/exe; do
        case "$(readlink "$e" 2>/dev/null)" in
            */pm3scan) p=${e#/proc/}; p=${p%/exe}; echo "   stopping pid $p"; kill -9 "$p" 2>/dev/null ;;
        esac
     done; true'

echo "== pushing binary + font"
rsh "cat > $APPDIR/pm3scan && chmod +x $APPDIR/pm3scan" < "$ROOT/app/out/pm3scan"
rsh "cat > $APPDIR/DejaVuSans.ttf" < "$FONT"

echo "== pushing app metadata"
for f in config.json launch.sh icon.png; do
    rsh "cat > $APPDIR/$f" < "$ROOT/app/assets/$f"
done
rsh "chmod +x $APPDIR/launch.sh"

echo "== registering '$LABEL' in Apps/show.json"
# Parse and re-emit the registry here on the host: the device has no python, and
# hand-rolled text surgery on JSON is how you end up with a broken Apps menu.
TMP="$(mktemp)"
trap 'rm -f "$TMP" "$TMP.verify"' EXIT
if ! rsh "cat /mnt/SDCARD/Apps/show.json" > "$TMP" 2>/dev/null || [ ! -s "$TMP" ]; then
    echo "   WARNING: could not read show.json; skipping registration"
elif ! command -v python3 >/dev/null 2>&1; then
    echo "   WARNING: python3 not available on this host; skipping registration"
elif LABEL="$LABEL" LEGACY="$LEGACY_LABELS" python3 - "$TMP" <<'PY'
import json, os, sys
path, label = sys.argv[1], os.environ["LABEL"]
# drop our own entries under any name we have ever used (current + legacy),
# then append exactly one -- this must stay idempotent across re-runs
drop = set(os.environ["LEGACY"].split("|")) | {label}
try:
    data = json.load(open(path, encoding="utf-8"))
except Exception as e:
    sys.exit("unparseable show.json: %s" % e)
if not isinstance(data, list):
    sys.exit("show.json is not a JSON array")
data = [e for e in data
        if not (isinstance(e, dict) and str(e.get("label", "")) in drop)]
data.append({"label": label, "show": 1})
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=1)
    fh.write("\n")
PY
then
    rsh "cp -f /mnt/SDCARD/Apps/show.json /mnt/SDCARD/Apps/show.json.bak 2>/dev/null; cat > /mnt/SDCARD/Apps/show.json" < "$TMP"
    # read it back and prove it still parses before claiming success
    if rsh "cat /mnt/SDCARD/Apps/show.json" > "$TMP.verify" 2>/dev/null && \
       LABEL="$LABEL" python3 -c '
import json, os, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
labels = [e.get("label") for e in d if isinstance(e, dict)]
assert labels.count(os.environ["LABEL"]) == 1, "entry missing or duplicated"
assert "PM3 Scan" not in labels, "legacy entry still present"
print("   registered and re-parsed OK (%d entries)" % len(d))
' "$TMP.verify"; then
        echo "== removing legacy installs"
        for d in $LEGACY_DIRS; do
            rsh "if [ -d '$d' ]; then rm -rf '$d' && echo '   removed $d'; else echo '   (no $d)'; fi"
        done
    else
        echo "   WARNING: registration could not be verified; check Apps/show.json"
    fi
else
    echo "   WARNING: show.json could not be parsed; add '$LABEL' manually"
fi

echo "== installed:"
rsh "ls -l $APPDIR; echo; echo '--- show.json ---'; cat /mnt/SDCARD/Apps/show.json"
echo
echo "Restart MainUI to refresh the Apps list:"
echo "  TRIMUI_HOST=$HOST TRIMUI_PASS=$PASS $ROOT/device/rsh.sh 'kill -9 \$(pgrep -x MainUI)'"
