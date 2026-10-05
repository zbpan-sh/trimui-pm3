#!/bin/bash
# Run a remote command on the TrimUI over SSH with password auth (no sshpass / no root needed).
#
#   TRIMUI_PASS=tina ./rsh.sh <remote-command...>
#   TRIMUI_PASS=tina ./rsh.sh --stdin < local.sh
#
# Config (env or ~/.trimui-env):
#   TRIMUI_HOST (required - the handheld's IP or hostname; nothing is baked in)
#   TRIMUI_USER (default root)
#   TRIMUI_PASS (required unless a key is present)
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HOME/.trimui-env" ] && . "$HOME/.trimui-env"

HOST="${TRIMUI_HOST:-}"
USER="${TRIMUI_USER:-root}"
PORT="${TRIMUI_PORT:-22}"

if [ -z "$HOST" ]; then
  echo "rsh.sh: TRIMUI_HOST is not set." >&2
  echo "        export TRIMUI_HOST=<handheld-ip>   (or add it to ~/.trimui-env)" >&2
  exit 2
fi

OPTS=(
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$DIR/known_hosts"
  -o ConnectTimeout=10
  -o NumberOfPasswordPrompts=1
  -o LogLevel=ERROR
  -p "$PORT"
)

KEY="$DIR/id_ed25519"
[ -f "$KEY" ] && OPTS+=(-i "$KEY")

if [ -n "${TRIMUI_PASS:-}" ]; then
  SSH_PASS="$TRIMUI_PASS" SSH_ASKPASS="$DIR/askpass.sh" SSH_ASKPASS_REQUIRE=force \
    setsid -w ssh "${OPTS[@]}" "$USER@$HOST" "$@"
else
  ssh "${OPTS[@]}" -o BatchMode=yes "$USER@$HOST" "$@"
fi
