#!/bin/bash
# stop_classify_v15a.sh -- stop the run that start_classify_v15a.sh started, and only
# that one: the process group in run/classify_v15a.pid, after checking that its
# leader is the expected command.
#
# Usage: scripts/stop_classify_v15a.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDFILE="$HERE/run/classify_v15a.pid"
LOG=${V15A_LOG:-$HOME/restore-plus-cerrado/run_v15a_samples/logs/classify_v15a.log}
EXPECT=${V15A_EXPECT:-classify_v15a.R}

[ -f "$PIDFILE" ] || { echo "stop_classify: no $PIDFILE; nothing started by start_classify_v15a.sh" >&2; exit 1; }
PGID=$(cat "$PIDFILE")
if ! kill -0 "-$PGID" 2>/dev/null; then
    echo "stop_classify: group $PGID is not running"
    exit 0
fi
# Refuse a group whose leader is not the classification: the pid may be reused.
if ! grep -q "$EXPECT" "/proc/$PGID/cmdline" 2>/dev/null; then
    echo "stop_classify: leader $PGID is not $EXPECT; not stopping it" >&2
    exit 1
fi
echo "$(date -u '+%Y-%m-%d %H:%M:%S') | stop_classify: TERM to group $PGID" >> "$LOG"
kill -TERM "-$PGID"
for _ in $(seq 30); do
    kill -0 "-$PGID" 2>/dev/null || { echo "stop_classify: group $PGID stopped"; exit 0; }
    sleep 1
done
echo "$(date -u '+%Y-%m-%d %H:%M:%S') | stop_classify: KILL to group $PGID" >> "$LOG"
kill -KILL "-$PGID" 2>/dev/null || true
echo "stop_classify: group $PGID killed after 30 s"
