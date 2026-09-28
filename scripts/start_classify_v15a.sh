#!/bin/bash
# start_classify_v15a.sh -- start the v15a classification detached from the
# terminal, so a non-interactive SSH call returns and the run goes on.
#
# The run gets its own session (setsid); its process group id is written to
# run/classify_v15a.pid, which stop_classify_v15a.sh reads. Refuses to start when that
# group is still alive.
#
# Usage: scripts/start_classify_v15a.sh
# V15A_CMD overrides the command, for tests only.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
RUN="$HERE/run"
PIDFILE="$RUN/classify_v15a.pid"
LOG=${V15A_LOG:-$HOME/restore-plus-cerrado/run_v15a_samples/logs/classify_v15a.log}
CMD=${V15A_CMD:-"Rscript analysis/classification/classify_v15a.R"}
mkdir -p "$RUN" "$(dirname "$LOG")"

if [ -f "$PIDFILE" ] && kill -0 "-$(cat "$PIDFILE")" 2>/dev/null; then
    echo "start_classify: group $(cat "$PIDFILE") is still running; stop it first" >&2
    exit 1
fi

cd "$REPO"
echo "$(date -u '+%Y-%m-%d %H:%M:%S') | start_classify: $CMD (commit $(git rev-parse --short HEAD 2>/dev/null || echo unknown))" >> "$LOG"
# setsid makes the child a session and group leader: its pid is the group id.
setsid bash -c "exec $CMD" >> "$LOG" 2>&1 < /dev/null &
echo $! > "$PIDFILE"
sleep 2
if kill -0 "-$(cat "$PIDFILE")" 2>/dev/null; then
    echo "start_classify: running, group $(cat "$PIDFILE"), log $LOG"
else
    echo "start_classify: exited at once; see $LOG" >&2
    exit 1
fi
