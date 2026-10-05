#!/bin/bash
# One-command install of PM3 tools onto a TrimUI handheld over SSH.
#
#   ./install.sh --host 192.168.1.50
#
# Pushes two things:
#   /mnt/UDISK/pm3-v423346/              aarch64 proxmark3 client + its resources
#   /mnt/SDCARD/Apps/Proxmark3Tools/     the GUI app, registered in the Apps menu
#
# Binaries must already be built (see QUICKSTART.md); use --build to fetch and
# build them in one go. Everything is idempotent -- re-running just updates.
#
# Options:
#   --host <ip|name>   handheld address (or set TRIMUI_HOST)   [required]
#   --user <name>      SSH user                                [default: root]
#   --pass <password>  SSH password                            [default: tina]
#   --build            fetch sources and build first if needed
#   --skip-client      do not touch the PM3 client
#   --skip-app         do not touch the GUI app
#   --force            re-push resources even if already present
#   --restart-ui       restart MainUI at the end so the app shows up now
#                      (the launcher only re-reads the Apps list on startup)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
HOST="${TRIMUI_HOST:-}"
USER="${TRIMUI_USER:-root}"
PASS="${TRIMUI_PASS:-tina}"
BUILD=0
SKIP_CLIENT=0
SKIP_APP=0
FORCE=0
RESTART_UI=0

PM3_TAG="v4.23346"                                  # keep in sync with client/fetch-sources.sh
PM3_DIR="/mnt/UDISK/pm3-v423346"
PM3_SRC="$ROOT/client/src/proxmark3-$PM3_TAG"
RESOURCES=(dictionaries lualibs luascripts cmdscripts resources)

while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST="${2:?}"; shift 2 ;;
        --user) USER="${2:?}"; shift 2 ;;
        --pass) PASS="${2:?}"; shift 2 ;;
        --build) BUILD=1; shift ;;
        --skip-client) SKIP_CLIENT=1; shift ;;
        --skip-app) SKIP_APP=1; shift ;;
        --force) FORCE=1; shift ;;
        --restart-ui) RESTART_UI=1; shift ;;
        -h|--help) awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$HOST" ]; then
    echo "install.sh: no device address." >&2
    echo "            ./install.sh --host <handheld-ip>    (or export TRIMUI_HOST=...)" >&2
    exit 2
fi

rsh() { TRIMUI_HOST="$HOST" TRIMUI_USER="$USER" TRIMUI_PASS="$PASS" "$ROOT/device/rsh.sh" "$@"; }

# --------------------------------------------------------------- 1. reachability
echo "== checking $USER@$HOST"
if ! rsh 'echo ok' >/dev/null 2>&1; then
    cat >&2 <<EOF
install.sh: cannot run commands on $USER@$HOST.
  - is the handheld awake and on the same network?
  - is SSH enabled on it? (stock firmware: Settings -> check for an SSH option)
  - find its address under Settings -> Device Info
  - the stock password is 'tina' for user 'root' (override with --pass)
EOF
    exit 1
fi

rsh 'uname -m; [ -d /mnt/SDCARD/Apps ] && echo SD_OK || echo SD_MISSING; [ -d /mnt/UDISK ] && echo UDISK_OK || echo UDISK_MISSING'
rsh '[ -d /mnt/SDCARD/Apps ]' || { echo "install.sh: no /mnt/SDCARD/Apps -- is this a TrimUI stock OS?" >&2; exit 1; }

# ------------------------------------------------------------------- 2. build
need_client=0
if [ "$SKIP_CLIENT" -eq 0 ] \
   && [ ! -x "$ROOT/client/out/proxmark3-$PM3_TAG-aarch64" ] \
   && [ ! -x "$PM3_SRC/client/proxmark3" ]; then
    need_client=1
fi
need_app=0
[ "$SKIP_APP" -eq 1 ] || [ -x "$ROOT/app/out/pm3scan" ] || need_app=1

if [ "$BUILD" -eq 1 ] && { [ "$need_client" -eq 1 ] || [ "$need_app" -eq 1 ]; }; then
    echo "== fetching build inputs"
    "$ROOT/client/fetch-sources.sh"
    if [ "$need_client" -eq 1 ]; then
        echo "== building the aarch64 PM3 client"
        PROXMARK3_SRC="$PM3_SRC" "$ROOT/client/build-client.sh"
    fi
    if [ "$need_app" -eq 1 ]; then
        echo "== building the GUI app"
        "$ROOT/app/build-app.sh"
    fi
fi

# --------------------------------------------------------------- 3. PM3 client
if [ "$SKIP_CLIENT" -eq 0 ]; then
    # Prefer the packaged artifacts in client/out: they let someone who was handed a
    # prebuilt client install without downloading the SDK and building anything.
    CLIENT_BIN="$ROOT/client/out/proxmark3-$PM3_TAG-aarch64"
    RES_TAR="$ROOT/client/out/pm3-resources-$PM3_TAG.tar.gz"
    if [ ! -x "$CLIENT_BIN" ]; then
        CLIENT_BIN="$PM3_SRC/client/proxmark3"
        RES_TAR=""
    fi

    if [ ! -x "$CLIENT_BIN" ]; then
        cat >&2 <<EOF
install.sh: the aarch64 PM3 client is not available.

  Looked for:
      $ROOT/client/out/proxmark3-$PM3_TAG-aarch64      (prebuilt artifact)
      $PM3_SRC/client/proxmark3                    (build tree)

  Either build it (downloads ~600 MB the first time):
      ./install.sh --host $HOST --build
  or drop a prebuilt pair into client/out/:
      proxmark3-$PM3_TAG-aarch64
      pm3-resources-$PM3_TAG.tar.gz
EOF
        exit 1
    fi

    echo "== pushing the PM3 client to $PM3_DIR  ($(basename "$CLIENT_BIN"))"
    rsh "mkdir -p '$PM3_DIR'"
    # a client left running (e.g. an interactive ssh session) would make the
    # write fail with "Text file busy"
    rsh 'for e in /proc/[0-9]*/exe; do
            case "$(readlink "$e" 2>/dev/null)" in
                */pm3-v423346/proxmark3) p=${e#/proc/}; p=${p%/exe}; echo "   stopping running client (pid $p)"; kill -9 "$p" 2>/dev/null ;;
            esac
         done; true'
    rsh "cat > '$PM3_DIR/proxmark3' && chmod +x '$PM3_DIR/proxmark3'" < "$CLIENT_BIN"

    if [ "$FORCE" -eq 1 ] || ! rsh "[ -d '$PM3_DIR/dictionaries' ]"; then
        echo "== pushing resources (dictionaries, lua, scripts)"
        if [ -n "$RES_TAR" ]; then
            rsh "tar xzf - -C '$PM3_DIR'" < "$RES_TAR"
        else
            ( cd "$PM3_SRC/client" && tar cf - "${RESOURCES[@]}" ) \
                | rsh "tar xf - -C '$PM3_DIR'"
        fi
    else
        echo "== resources already present (use --force to re-push)"
    fi
fi

# ------------------------------------------------------------------- 4. GUI app
if [ "$SKIP_APP" -eq 0 ]; then
    if [ ! -x "$ROOT/app/out/pm3scan" ]; then
        echo "install.sh: the GUI app is not built yet -- run app/build-app.sh, or --build" >&2
        exit 1
    fi
    echo
    TRIMUI_HOST="$HOST" TRIMUI_USER="$USER" TRIMUI_PASS="$PASS" "$ROOT/app/deploy-app.sh"
fi

# -------------------------------------------------------------------- 5. verify
echo
echo "== verifying on the device"
if [ "$SKIP_CLIENT" -eq 0 ]; then
    rsh "cd '$PM3_DIR' && ./proxmark3 -v 2>&1 | head -3"
fi
if [ "$SKIP_APP" -eq 0 ]; then
    rsh "cd /mnt/SDCARD/Apps/Proxmark3Tools && ./pm3scan --help 2>&1 | head -2"
fi

if [ "$RESTART_UI" -eq 1 ] && [ "$SKIP_APP" -eq 0 ]; then
    echo
    echo "== restarting MainUI so the app appears"
    rsh 'kill -9 $(pgrep -x MainUI) 2>/dev/null; sleep 6; pgrep -x MainUI >/dev/null && echo "   MainUI back up" || echo "   MainUI is starting"'
fi

cat <<EOF

== installed

On the handheld, launch "PM3 tools" from the Apps menu (restart the device if it
does not appear yet). Scanning needs the Proxmark3 plugged into the TOP USB-C port.

If the client reports a capabilities mismatch, the PM3 firmware is a different
version than this client ($PM3_TAG) -- see docs/FIRMWARE.md to flash a matching build.

Command line, if you prefer:
    ssh $USER@$HOST
    cd $PM3_DIR && ./proxmark3 /dev/ttyACM0 -c "hf search"
EOF
