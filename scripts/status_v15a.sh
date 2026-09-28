#!/bin/bash
# status_v15a.sh -- a short, read-only summary of the v15a classification,
# one key=value per line, for a watcher that compares two calls.
#
# Reads only: the run's pid file and log, the classification output_dir,
# nvidia-smi queries, ps, /sys/fs/cgroup/memory.current, run/memstat_v15a.txt.
# Errors are counted from the last start_classify line of the log, so a
# previous run in the same log does not count.
#
# Usage: scripts/status_v15a.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDFILE="$HERE/run/classify_v15a.pid"
LOG=${V15A_LOG:-$HOME/restore-plus-cerrado/run_v15a_samples/logs/classify_v15a.log}
OUT=${V15A_OUT:-$HOME/classification-cerrado/data/derived/classifications/tempcnn-cer-v15a-raster/2018}
TILES=78

echo "time=$(date -u '+%Y-%m-%d %H:%M:%S')"
if [ -f "$PIDFILE" ] && kill -0 "-$(cat "$PIDFILE")" 2>/dev/null; then
    echo "run=alive group=$(cat "$PIDFILE") elapsed=$(ps -o etime= -p "$(cat "$PIDFILE")" | tr -d ' ')"
else
    echo "run=stopped"
fi
if [ -f "$LOG" ]; then
    echo "log_age_min=$(( ($(date +%s) - $(stat -c %Y "$LOG")) / 60 ))"
    from=$(grep -n 'start_classify:' "$LOG" | tail -n 1 | cut -d: -f1)
    this_run() { tail -n "+${from:-1}" "$LOG"; }
    echo "errors=$(this_run | grep -ciE 'error|killed|out of memory')"
    echo "last=$(grep ' | ' "$LOG" | tail -n 1 | cut -c1-160)"
    this_run | grep -iE 'error|killed|out of memory' | tail -n 2 | cut -c1-160 | sed 's/^/last_error=/'
else
    echo "log=missing"
fi
# sits names results <sat>_<sensor>_<tile>_<start>_<end>_<band>_<version>.tif
for band in probs bayes class; do
    n=$(ls "$OUT" 2>/dev/null | grep -E "_${band}_.*\.tif$" | cut -d_ -f3 | sort -u | wc -l)
    echo "tiles_${band}=$n/$TILES"
done
# Mean time per tile over the whole run, so smoothing and labeling of
# finished chunks count; the mosaic is not in the forecast.
probs=$(ls "$OUT" 2>/dev/null | grep -E "_probs_.*\.tif$" | cut -d_ -f3 | sort -u | wc -l)
if [ -f "$PIDFILE" ] && [ "$probs" -gt 0 ] && kill -0 "-$(cat "$PIDFILE")" 2>/dev/null; then
    el=$(ps -o etimes= -p "$(cat "$PIDFILE")" | tr -d ' ')
    awk -v el="$el" -v n="$probs" 'BEGIN { printf "min_per_tile=%.1f\n", el / n / 60 }'
    echo "eta_probs_utc=$(date -u -d "@$(( $(date +%s) + (TILES - probs) * el / probs ))" '+%Y-%m-%d %H:%M')"
fi
echo "mosaic=$(ls "$OUT/mosaic" 2>/dev/null | grep -c '\.tif$')"
echo "gpu=$(nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader 2>/dev/null)"
echo "cgroup_mem_gb=$(awk '{printf "%.1f", $1 / 1e9}' /sys/fs/cgroup/memory.current 2>/dev/null)"
echo "r_procs=$(ps -eo stat,comm | awk '$2 == "R" {n++; if ($1 ~ /D/) d++} END {print n + 0 " (" d + 0 " on I/O)"}')"
[ -f "$HERE/run/memstat_v15a.txt" ] && cat "$HERE/run/memstat_v15a.txt"
