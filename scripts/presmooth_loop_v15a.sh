#!/bin/bash
# presmooth_loop_v15a.sh -- run presmooth_v15a.R every minute while the v15a
# classification runs; exits when its group ends.
#
# Usage: scripts/presmooth_loop_v15a.sh QML
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDFILE="$HERE/run/classify_v15a.pid"
QML=$1

while [ -f "$PIDFILE" ] && kill -0 "-$(cat "$PIDFILE")" 2>/dev/null; do
    /usr/bin/Rscript "$HERE/presmooth_v15a.R" "$QML"
    sleep 60
done
