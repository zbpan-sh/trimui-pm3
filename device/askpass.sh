#!/bin/sh
# SSH_ASKPASS helper so we can do password auth non-interactively (no sshpass / no root needed).
# Usage:  SSH_PASS='secret' askpass.sh <prompt>
printf '%s\n' "${SSH_PASS}"
