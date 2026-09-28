#!/bin/bash
# start_presmooth_v15a.sh -- start presmooth_loop_v15a.sh detached from the
# terminal. It stops by itself when the classification ends.
#
# Usage: scripts/start_presmooth_v15a.sh QML
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="$HERE/run"
PIDFILE="$RUN/presmooth_v15a.pid"
LOG="$RUN/presmooth_v15a.log"
QML=$(realpath "$1")
mkdir -p "$RUN"

if [ -f "$PIDFILE" ] && kill -0 "-$(cat "$PIDFILE")" 2>/dev/null; then
    echo "start_presmooth: group $(cat "$PIDFILE") is still running" >&2
    exit 1
fi

setsid bash "$HERE/presmooth_loop_v15a.sh" "$QML" >> "$LOG" 2>&1 < /dev/null &
echo $! > "$PIDFILE"
sleep 2
if kill -0 "-$(cat "$PIDFILE")" 2>/dev/null; then
    echo "start_presmooth: running, group $(cat "$PIDFILE"), log $LOG"
else
    echo "start_presmooth: exited at once; is the classification running? see $LOG" >&2
    exit 1
fi
