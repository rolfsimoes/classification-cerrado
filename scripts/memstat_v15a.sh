#!/bin/bash
# memstat_v15a.sh -- sample RAM and GPU while the v15a classification runs and
# keep only the statistics of the last window in run/memstat_v15a.txt.
#
# RAM is `anon` of the cgroup memory.stat: memory.current also counts page
# cache, which the kernel reclaims before it kills a process.
# Read rate is the sum of `rchar` of /proc/<pid>/io over the process tree of
# the classification, per second between two samples; `read_bytes` misses
# network file systems such as BeeGFS, and `rchar` also counts page cache hits.
# Exits when the classification group in run/classify_v15a.pid ends.
# Reads only: memory.stat, /proc/<pid>/io, nvidia-smi queries, the pid file.
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

# Sets DELTA to the bytes read by the tree since the previous call; called
# without $( ), so that `seen` survives. A pid first seen counts in full,
# since it started after the previous call; on the first call nothing counts.
# Workers of the torch dataloader live one tile, so pids change. They run in
# their own sessions (callr), so the tree is used, not the process group.
tree_pids() {
    ps -eo pid=,ppid= | awk -v root="$1" '
        { kids[$2] = kids[$2] " " $1 }
        END { q[1] = root; n = 1
              for (i = 1; i <= n; i++) { print q[i]; m = split(kids[q[i]], k, " ")
                                         for (j = 1; j <= m; j++) q[++n] = k[j] } }'
}
declare -A seen=()
first=1
read_delta() {
    local pid now sum=0
    declare -A cur=()
    for pid in $(tree_pids "$(cat "$PIDFILE")"); do
        now=$(awk '$1 == "rchar:" {print $2}' "/proc/$pid/io" 2>/dev/null) || continue
        [ -n "$now" ] || continue
        cur[$pid]=$now
        [ "$first" = 1 ] || sum=$(( sum + now - ${seen[$pid]:-0} ))
    done
    seen=()
    for pid in "${!cur[@]}"; do seen[$pid]=${cur[$pid]}; done
    first=0
    DELTA=$sum
}

: > "$SAMPLES"
start=$(date +%s)
read_delta
prev=$(date +%s.%N)
while alive; do
    # columns: RAM GB, GPU memory GB, GPU utilization %, read MB/s
    read_delta
    now=$(date +%s.%N)
    rate=$(awk -v b="$DELTA" -v t="$(awk -v a="$now" -v p="$prev" 'BEGIN {print a - p}')" \
        'BEGIN {printf "%.1f", b / 1e6 / t}')
    prev=$now
    ram=$(awk '$1 == "anon" {printf "%.1f", $2 / 1e9}' "$STAT")
    gpu=$(nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader,nounits 2>/dev/null |
        awk -F', *' 'NR == 1 {printf "%.1f %d", $1 * 1048576 / 1e9, $2}')
    echo "$ram ${gpu:-NA NA} $rate" >> "$SAMPLES"
    if [ $(( $(date +%s) - start )) -ge "$WINDOW" ]; then
        awk -v t="$(date -u '+%Y-%m-%d %H:%M:%S')" '
            function upd(i, v) { if (v == "NA") return; n[i]++; s[i] += v
                if (n[i] == 1 || v < lo[i]) lo[i] = v; if (n[i] == 1 || v > hi[i]) hi[i] = v }
            function line(k, i) { if (n[i]) printf "%s=%.1f %.1f %.1f\n", k, lo[i], hi[i], s[i] / n[i]
                                  else printf "%s=NA\n", k }
            { upd(1, $1); upd(2, $2); upd(3, $3); upd(4, $4) }
            END { print "memstat_time=" t " samples=" NR
                  line("ram_gb_min_max_mean", 1); line("gpu_mem_gb_min_max_mean", 2)
                  line("gpu_util_pct_min_max_mean", 3); line("read_mb_s_min_max_mean", 4) }' "$SAMPLES" > "$OUT.tmp" &&
            mv "$OUT.tmp" "$OUT"
        : > "$SAMPLES"
        start=$(date +%s)
    fi
    sleep "$STEP"
done
rm -f "$SAMPLES"
