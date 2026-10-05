#!/bin/sh
# TrimUI stock-OS entry point for pm3scan.
# Launched by MainUI through /tmp/cmd_to_run.sh, which means the UI process has
# already exited and the display belongs to us.
echo $0 $*
progdir=`dirname "$0"`
cd $progdir

# SDL2 lives in /usr/trimui/lib, which is not in the default ld.so path.
export LD_LIBRARY_PATH=/usr/trimui/lib:$LD_LIBRARY_PATH

# Keep the SoC (and therefore the USB host port) awake for the whole session.
echo 1 > /tmp/stay_awake

./pm3scan "$@"
rc=$?

rm -f /tmp/stay_awake
exit $rc
