#!/bin/bash
# stop_presmooth_v15a.sh -- stop the presmooth loop that start_presmooth_v15a.sh
# started, after checking that the group leader is presmooth_loop_v15a.sh.
#
# Usage: scripts/stop_presmooth_v15a.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDFILE="$HERE/run/presmooth_v15a.pid"

[ -f "$PIDFILE" ] || { echo "stop_presmooth: no $PIDFILE" >&2; exit 1; }
PGID=$(cat "$PIDFILE")
if ! kill -0 "-$PGID" 2>/dev/null; then
    echo "stop_presmooth: group $PGID is not running"
    exit 0
fi
# The pid may be reused by another command.
if ! grep -q presmooth_loop_v15a.sh "/proc/$PGID/cmdline" 2>/dev/null; then
    echo "stop_presmooth: leader $PGID is not presmooth_loop_v15a.sh; not stopping it" >&2
    exit 1
fi
kill -TERM "-$PGID"
echo "stop_presmooth: group $PGID stopped"
