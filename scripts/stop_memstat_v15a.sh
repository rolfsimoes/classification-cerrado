#!/bin/bash
# stop_memstat_v15a.sh -- stop the sampler that start_memstat_v15a.sh started,
# after checking that the group leader is memstat_v15a.sh.
#
# Usage: scripts/stop_memstat_v15a.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDFILE="$HERE/run/memstat_v15a.pid"

[ -f "$PIDFILE" ] || { echo "stop_memstat: no $PIDFILE" >&2; exit 1; }
PGID=$(cat "$PIDFILE")
if ! kill -0 "-$PGID" 2>/dev/null; then
    echo "stop_memstat: group $PGID is not running"
    exit 0
fi
# The pid may be reused by another command.
if ! grep -q memstat_v15a.sh "/proc/$PGID/cmdline" 2>/dev/null; then
    echo "stop_memstat: leader $PGID is not memstat_v15a.sh; not stopping it" >&2
    exit 1
fi
kill -TERM "-$PGID"
echo "stop_memstat: group $PGID stopped"
