#!/bin/bash
# Test single container to measure hardware IOPS limit with various workloads.
set -euo pipefail

RESULT_ROOT="${RESULT_ROOT:-./results_all}"
RUN_TAG="${RUN_TAG:-single_container_test}"
OUT_DIR="${RESULT_ROOT}/${RUN_TAG}"
IMAGE="${IMAGE:-ubuntu:22.04}"
CONTAINER_PREFIX="docker_blktest"
DATA_VOL_PREFIX="${DATA_VOL_PREFIX:-blktest_data_c}"   # e.g. blktest_data_c1
TEST_FILE="/data/testfile.dat"
FILE_SIZE="${FILE_SIZE:-1G}"
RUNTIME="${RUNTIME:-30}"

# fio knobs
BS_SEQ="${BS_SEQ:-128k}"
BS_RAND="${BS_RAND:-16k}"
IODEPTH_SEQ="${IODEPTH_SEQ:-1}"
IODEPTH_RAND="${IODEPTH_RAND:-16}"
DIRECT=1
IOENGINE_SEQ="libaio"
IOENGINE_RAND="libaio"

WORKLOADS=(seqrw seqwrite randwrite hotrw hotwrite randrw)

mkdir -p "${OUT_DIR}"
mkdir -p "${OUT_DIR}/c1"

# workload mapping for summarizer
{
  printf '{'
  for i in $(seq 1 1); do
    wl="${WORKLOADS[$((i-1))]}"
    printf '"c%d":"%s"' "$i" "$wl"
  done
  printf '}\n'
} > "${OUT_DIR}/workloads.json"

echo "[CLEANUP] removing old containers..."
docker rm -f "${CONTAINER_PREFIX}1" >/dev/null 2>&1 || true

# ensure named volume exists
vol="${DATA_VOL_PREFIX}1"
if ! docker volume inspect "$vol" >/dev/null 2>&1; then
  echo "[VOLUME] creating $vol"
  docker volume create "$vol" >/dev/null
fi

# Launch a single container
launch_container() {
  local idx=$1
  local name="${CONTAINER_PREFIX}${idx}"
  local mount_out="$(realpath "${OUT_DIR}/c${idx}")"
  local vol="${DATA_VOL_PREFIX}${idx}"
  echo "[INIT] launching ${name} (image=${IMAGE}, out->/out, volume ${vol}->/data)"
  if docker run -dit --name "${name}" -v "${mount_out}:/out" -v "${vol}:/data" "${IMAGE}" bash >/dev/null 2>&1; then :; else
    docker rm -f "${name}" >/dev/null 2>&1 || true
    docker run -dit --name "${name}" -v "${mount_out}:/out" -v "${vol}:/data" "${IMAGE}" sh >/dev/null
  fi
}

launch_container 1
echo "[STEP] container up: ${CONTAINER_PREFIX}1 (data on named volume)"

install_fio() {
  local name="$1"
  echo "[INSTALL] fio in ${name}"
  docker exec "${name}" bash -lc "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fio > /dev/null" \
    || docker exec "${name}" sh -lc "apk add --no-cache fio || ( zypper --non-interactive install fio || pacman -Sy --noconfirm fio ) || true"
}

prepare_file() {
  local name="$1"
  echo "[PREP] ${name}: ${FILE_SIZE} -> ${TEST_FILE}"
  docker exec "${name}" sh -lc "fallocate -l ${FILE_SIZE} ${TEST_FILE} 2>/dev/null || dd if=/dev/zero of=${TEST_FILE} bs=1M count=$(( ${FILE_SIZE%G} * 1024 )) status=none"
  # quick verify
  docker exec "${name}" sh -lc "ls -lh ${TEST_FILE} && stat -c '%s' ${TEST_FILE}" >/dev/null 2>&1 || true
}

install_fio "${CONTAINER_PREFIX}1"
prepare_file "${CONTAINER_PREFIX}1"
echo "[STEP] test file ready on /data (named volumes), direct=1 will be honored"

fio_cmd() {
  local wl="$1"
  case "$wl" in
    seqrw)
      echo "fio --name=seqrw --filename=${TEST_FILE} --rw=readwrite --rwmixread=50 --bs=${BS_SEQ} --ioengine=${IOENGINE_SEQ} --iodepth=${IODEPTH_SEQ} --direct=${DIRECT} --time_based --runtime=${RUNTIME} --numjobs=1 --group_reporting=1 --output-format=json"
      ;;
    seqwrite)
      echo "fio --name=seqwrite --filename=${TEST_FILE} --rw=write --bs=${BS_SEQ} --ioengine=${IOENGINE_SEQ} --iodepth=${IODEPTH_SEQ} --direct=${DIRECT} --time_based --runtime=${RUNTIME} --numjobs=1 --group_reporting=1 --output-format=json"
      ;;
    randwrite)
      echo "fio --name=randwrite --filename=${TEST_FILE} --rw=randwrite --bs=${BS_RAND} --ioengine=${IOENGINE_RAND} --iodepth=${IODEPTH_RAND} --direct=${DIRECT} --time_based --runtime=${RUNTIME} --numjobs=1 --group_reporting=1 --output-format=json"
      ;;
    hotrw)
      echo "fio --name=hotrw --filename=${TEST_FILE} --rw=randrw --rwmixread=70 --bs=${BS_RAND} --random_distribution=zipf:1.2 --randrepeat=0 --random_generator=tausworthe --ioengine=${IOENGINE_RAND} --iodepth=${IODEPTH_RAND} --direct=${DIRECT} --time_based --runtime=${RUNTIME} --numjobs=1 --group_reporting=1 --output-format=json"
      ;;
    hotwrite)
      echo "fio --name=hotwrite --filename=${TEST_FILE} --rw=randwrite --bs=${BS_RAND} --random_distribution=zipf:1.2 --randrepeat=0 --random_generator=tausworthe --ioengine=${IOENGINE_RAND} --iodepth=${IODEPTH_RAND} --direct=${DIRECT} --time_based --runtime=${RUNTIME} --numjobs=1 --group_reporting=1 --output-format=json"
      ;;
    randrw)
      echo "fio --name=randrw --filename=${TEST_FILE} --rw=randrw --rwmixread=50 --bs=${BS_RAND} --ioengine=${IOENGINE_RAND} --iodepth=${IODEPTH_RAND} --direct=${DIRECT} --time_based --runtime=${RUNTIME} --numjobs=1 --group_reporting=1 --output-format=json"
      ;;
  esac
}

# ---- docker stats sampler (starts only after fio begins writing) ----
start_stats() {
  local out="${OUT_DIR}/docker_stats.csv"
  echo "ts_ms,container,cpu_perc,mem_usage,mem_perc,net_io,block_io,pids" > "${out}"
  bash -c '
    while true; do
      docker stats --no-stream --format "{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}},{{.NetIO}},{{.BlockIO}},{{.PIDs}}" \
        '"${CONTAINER_PREFIX}"'1 \
      | while IFS= read -r line; do
          printf "%s,%s\n" "$(date +%s%3N)" "$line";
        done >> "'"${out}"'";
      sleep 1;
    done
  ' &
  STATS_PID=$!
  echo ${STATS_PID} > "${OUT_DIR}/docker_stats.pid"
  echo "[STATS] collector pid=${STATS_PID} -> ${out}"
}

stop_stats() {
  if [ -f "${OUT_DIR}/docker_stats.pid" ]; then
    STATS_PID=$(cat "${OUT_DIR}/docker_stats.pid" || true)
    if [ -n "${STATS_PID:-}" ]; then
      kill "${STATS_PID}" >/dev/null 2>&1 || true
      wait "${STATS_PID}" 2>/dev/null || true
      rm -f "${OUT_DIR}/docker_stats.pid"
      echo "[STATS] collector stopped"
    fi
  fi
}
trap stop_stats EXIT

# ---- synchronize container and start fio ----
start_fio() {
  echo "[STEP] starting fio (direct=1 on /data)"
  start_stats
  pids=()
  for i in $(seq 1 6); do
    wl="${WORKLOADS[$((i-1))]}"
    name="${CONTAINER_PREFIX}${i}"
    out_json="/out/fio_c${i}_${wl}.json"
    cmd="$(fio_cmd "${wl}") --output=${out_json}"
    echo "[RUN] ${name} -> ${wl} | output: ${out_json}"
    ( docker exec "${name}" sh -lc "${cmd}" ) > "${OUT_DIR}/c${i}/fio_c${i}_${wl}.log" 2>&1 & 
    pids+=($!)
  done
  for pid in "${pids[@]}"; do
    wait "$pid"
  done
  echo "[STEP] fio finished"
}

# ---- run fio concurrently ----
start_fio

# ---- verify JSONs ----
missing=0
for i in $(seq 1 6); do
  wl="${WORKLOADS[$((i-1))]}"
  f="${OUT_DIR}/c${i}/fio_c${i}_${wl}.json"
  if [ ! -s "$f" ]; then
    echo "[WARN] Missing or empty: $f"
    tail -n 50 "${OUT_DIR}/c${i}/fio_c${i}_${wl}.log" || true
    missing=$((missing+1))
  fi
done

stop_stats

echo "[STOP] stopping containers..."
for i in $(seq 1 6); do docker stop "${CONTAINER_PREFIX}${i}" >/dev/null 2>&1 || true & done
wait

if [ "$missing" -gt 0 ]; then
  echo "[DONE] Completed with ${missing} missing JSON outputs. See logs under ${OUT_DIR}/c*/"
else
  echo "[DONE] All JSON outputs present under ${OUT_DIR}/c*/"
fi
