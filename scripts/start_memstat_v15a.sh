#!/bin/bash
# start_memstat_v15a.sh -- start memstat_v15a.sh detached from the terminal.
# It stops by itself when the classification ends.
#
# Usage: scripts/start_memstat_v15a.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="$HERE/run"
PIDFILE="$RUN/memstat_v15a.pid"
mkdir -p "$RUN"

if [ -f "$PIDFILE" ] && kill -0 "-$(cat "$PIDFILE")" 2>/dev/null; then
    echo "start_memstat: group $(cat "$PIDFILE") is still running" >&2
    exit 1
fi

setsid bash "$HERE/memstat_v15a.sh" > "$RUN/memstat_v15a.err" 2>&1 < /dev/null &
echo $! > "$PIDFILE"
sleep 2
if kill -0 "-$(cat "$PIDFILE")" 2>/dev/null; then
    echo "start_memstat: running, group $(cat "$PIDFILE"), output $RUN/memstat_v15a.txt"
else
    echo "start_memstat: exited at once; is the classification running? see $RUN/memstat_v15a.err" >&2
    exit 1
fi
