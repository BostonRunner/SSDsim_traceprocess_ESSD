#!/bin/bash
# Orchestrator: runs tests for varying container counts, collects SSD info,
# samples docker CPU/mem stats, and organizes results.
set -euo pipefail

DEVICE="${DEVICE:-/dev/vdb}"          # SSD block device
COUNTS_CSV="${COUNTS:-6}"   # which container counts to test
MAX_CONTAINERS="${MAX_CONTAINERS:-6}" # hard cap to avoid surprises
ROOT_RESULT_DIR="${ROOT_RESULT_DIR:-./results_all}"

mkdir -p "$ROOT_RESULT_DIR"

docker system prune -af --volumes

# -------- SSD info (size + some queue params) --------
SSD_INFO_PATH="$ROOT_RESULT_DIR/ssd_info.txt"
{
  echo "=== SSD BASIC INFO ($(date -Is)) ==="
  if command -v lsblk >/dev/null 2>&1; then
    lsblk -bd -o NAME,SIZE,ROTA,MODEL,TRAN "$DEVICE" 2>/dev/null || true
  fi
  if command -v blockdev >/dev/null 2>&1; then
    echo "SIZE_BYTES=$(blockdev --getsize64 "$DEVICE" 2>/dev/null || echo unknown)"
  fi
  for k in rotational nr_requests read_ahead_kb queue_depth max_sectors_kb; do
    f="/sys/block/$(basename "$DEVICE")/queue/$k"
    [ -e "$f" ] && echo "$k=$(cat "$f")"
  done
} | tee "$SSD_INFO_PATH"

# -------- helper: start docker stats sampler in background --------
start_stats_sampler() {
  local out_csv=$1
  local prefix=$2
  {
    echo "ts_ms,name,cpu,mem,mem_pct,net_io,block_io,pids"
    while true; do
      # break when no matching containers remain
      local count
      count=$(docker ps --format '{{.Names}}' | grep -E "^${prefix}[0-9]+$" | wc -l || true)
      if [ "$count" -eq 0 ]; then
        break
      fi
      local ts
      ts=$(date +%s%3N)
      docker stats --no-stream --format '{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}},{{.NetIO}},{{.BlockIO}},{{.PIDs}}' \
        | grep -E "^${prefix}[0-9]+," \
        | sed "s/^/${ts},/g"
      sleep 1
    done
  } > "$out_csv" &
  echo $!
}

# -------- main loop over counts --------
IFS=',' read -r -a COUNTS <<< "$COUNTS_CSV"
for N in "${COUNTS[@]}"; do
  if ! [[ "$N" =~ ^[0-9]+$ ]]; then
    echo "[WARN] Skip invalid count '$N'"; continue
  fi
  if [ "$N" -gt "$MAX_CONTAINERS" ]; then
    echo "[WARN] Skip $N (over MAX_CONTAINERS=$MAX_CONTAINERS)"; continue
  fi

  RESULT_DIR="${ROOT_RESULT_DIR}/result${N}"
  rm -rf "$RESULT_DIR"
  mkdir -p "$RESULT_DIR"

  echo "[CLEAN] pruning old containers/networks to reduce noise..."
  docker rm -f $(docker ps -aq) >/dev/null 2>&1 || true
  docker network prune -f >/dev/null 2>&1 || true
  docker volume prune -f >/dev/null 2>&1 || true
  sleep 2

  echo "[RUN] N=$N -> RESULT_DIR=$RESULT_DIR"
  export USE_CONTAINERS="$N"
  export RESULT_DIR="$RESULT_DIR"

  # kick off sampler
  STATS_CSV="$RESULT_DIR/docker_stats.csv"
  STATS_PID=$(start_stats_sampler "$STATS_CSV" "docker_blktest")
  echo "[MON] docker stats sampler pid=$STATS_PID"

  # run the workload (prepares containers, writes files, runs fio, stops containers)
  ./IO.sh

  # wait sampler to finish (it exits by itself when containers stop)
  if ps -p "$STATS_PID" >/dev/null 2>&1; then
    wait "$STATS_PID" || true
  fi
  echo "[DONE] N=$N finished."
done

# -------- summarize --------
python3 summarize.py "$ROOT_RESULT_DIR"
echo "[ALL DONE] Results in $ROOT_RESULT_DIR. See $ROOT_RESULT_DIR/summary.csv and per-result dirs."
