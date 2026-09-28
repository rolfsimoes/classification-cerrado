#!/bin/bash
# memstat_v15a.sh -- sample RAM and GPU while the v15a classification runs and
# keep only the statistics of the last window in run/memstat_v15a.txt.
#
# RAM is `anon` of the cgroup memory.stat: memory.current also counts page
# cache, which the kernel reclaims before it kills a process.
# Exits when the classification group in run/classify_v15a.pid ends.
# Reads only: memory.stat, nvidia-smi queries, the pid file.
#
# Usage: scripts/memstat_v15a.sh
# V15A_MEMSTAT_STEP, V15A_MEMSTAT_WINDOW (seconds) and V15A_CGROUP_STAT
# override the defaults, for tests only.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="$HERE/run"
PIDFILE="$RUN/classify_v15a.pid"
OUT="$RUN/memstat_v15a.txt"
SAMPLES="$RUN/memstat_v15a.samples"
STEP=${V15A_MEMSTAT_STEP:-5}
WINDOW=${V15A_MEMSTAT_WINDOW:-180}
STAT=${V15A_CGROUP_STAT:-/sys/fs/cgroup/memory.stat}

alive() { [ -f "$PIDFILE" ] && kill -0 "-$(cat "$PIDFILE")" 2>/dev/null; }

: > "$SAMPLES"
start=$(date +%s)
while alive; do
    # columns: RAM GB, GPU memory GB, GPU utilization %
    ram=$(awk '$1 == "anon" {printf "%.1f", $2 / 1e9}' "$STAT")
    gpu=$(nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader,nounits 2>/dev/null |
        awk -F', *' 'NR == 1 {printf "%.1f %d", $1 * 1048576 / 1e9, $2}')
    echo "$ram ${gpu:-NA NA}" >> "$SAMPLES"
    if [ $(( $(date +%s) - start )) -ge "$WINDOW" ]; then
        awk -v t="$(date -u '+%Y-%m-%d %H:%M:%S')" '
            function upd(i, v) { if (v == "NA") return; n[i]++; s[i] += v
                if (n[i] == 1 || v < lo[i]) lo[i] = v; if (n[i] == 1 || v > hi[i]) hi[i] = v }
            function line(k, i) { if (n[i]) printf "%s=%.1f %.1f %.1f\n", k, lo[i], hi[i], s[i] / n[i]
                                  else printf "%s=NA\n", k }
            { upd(1, $1); upd(2, $2); upd(3, $3) }
            END { print "memstat_time=" t " samples=" NR
                  line("ram_gb_min_max_mean", 1); line("gpu_mem_gb_min_max_mean", 2)
                  line("gpu_util_pct_min_max_mean", 3) }' "$SAMPLES" > "$OUT.tmp" &&
            mv "$OUT.tmp" "$OUT"
        : > "$SAMPLES"
        start=$(date +%s)
    fi
    sleep "$STEP"
done
rm -f "$SAMPLES"
