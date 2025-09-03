#!/bin/bash
# 6 containers with fixed names; each runs a distinct workload.
# Designed to avoid the "no such container" issue and ensure fio writes actually happen.
# Default data mode writes to the container layer (overlay), which does NOT support O_DIRECT.
# For real-device/O_DIRECT tests, set DATA_MODE=bind to bind-mount a host dir at /data.
set -euo pipefail

RESULT_ROOT="${RESULT_ROOT:-./results_all}"
RUN_TAG="${RUN_TAG:-result6}"
OUT_DIR="${RESULT_ROOT}/${RUN_TAG}"
IMAGE="${IMAGE:-ubuntu:22.04}"

# Data placement mode: overlay | bind
DATA_MODE="${DATA_MODE:-overlay}"

# Paths inside container depending on mode
if [ "$DATA_MODE" = "bind" ]; then
  TEST_FILE="/data/testfile.dat"
  IOENGINE_SEQ="${IOENGINE_SEQ:-libaio}"
  IOENGINE_RAND="${IOENGINE_RAND:-libaio}"
  DIRECT="${DIRECT:-1}"
else
  TEST_FILE="/mnt/testfile.dat"
  IOENGINE_SEQ="${IOENGINE_SEQ:-sync}"
  IOENGINE_RAND="${IOENGINE_RAND:-sync}"
  DIRECT="${DIRECT:-0}"
fi

RUNTIME="${RUNTIME:-30}"
FILE_SIZE="${FILE_SIZE:-1G}"
BS_SEQ="${BS_SEQ:-128k}"
BS_RAND="${BS_RAND:-16k}"
IODEPTH_SEQ="${IODEPTH_SEQ:-1}"
IODEPTH_RAND="${IODEPTH_RAND:-16}"
CONTAINER_PREFIX="docker_blktest"
WORKLOADS=(seqrw seqwrite randwrite hotrw hotwrite randrw)

mkdir -p "${OUT_DIR}"
for i in $(seq 1 6); do
  mkdir -p "${OUT_DIR}/c${i}"
  # for bind mode, also create a data dir to mount
  if [ "$DATA_MODE" = "bind" ]; then
    mkdir -p "${OUT_DIR}/c${i}/data"
  fi
done

# Mapping file (host)
printf '{' > "${OUT_DIR}/workloads.json"
for i in $(seq 1 6); do
  wl="${WORKLOADS[$((i-1))]}"
  printf '"c%d":"%s"' "$i" "$wl" >> "${OUT_DIR}/workloads.json"
  if [ $i -lt 6 ]; then printf ',' >> "${OUT_DIR}/workloads.json"; fi
done
printf '}\n' >> "${OUT_DIR}/workloads.json"

echo "[CLEANUP] Removing old containers if present..."
for i in $(seq 1 6); do
  docker rm -f "${CONTAINER_PREFIX}${i}" >/dev/null 2>&1 || true &
done
wait

launch_container() {
  local idx=$1
  local name="${CONTAINER_PREFIX}${idx}"
  local mount_out="$(realpath "${OUT_DIR}/c${idx}")"
  if [ "$DATA_MODE" = "bind" ]; then
    local mount_data="$(realpath "${OUT_DIR}/c${idx}/data")"
    echo "[INIT] Launch ${name} (out->/out, data->/data)"
    if docker run -dit --name "${name}" -v "${mount_out}:/out" -v "${mount_data}:/data" "${IMAGE}" bash >/dev/null 2>&1; then :; else
      docker rm -f "${name}" >/dev/null 2>&1 || true
      docker run -dit --name "${name}" -v "${mount_out}:/out" -v "${mount_data}:/data" "${IMAGE}" sh >/dev/null
    fi
  else
    echo "[INIT] Launch ${name} (out->/out, using container layer for TEST_FILE)"
    if docker run -dit --name "${name}" -v "${mount_out}:/out" "${IMAGE}" bash >/dev/null 2>&1; then :; else
      docker rm -f "${name}" >/dev/null 2>&1 || true
      docker run -dit --name "${name}" -v "${mount_out}:/out" "${IMAGE}" sh >/dev/null
    fi
  fi
}

for i in $(seq 1 6); do launch_container "$i" & done
wait
echo "[STEP] Containers up: ${CONTAINER_PREFIX}1..6 (mode=${DATA_MODE})"

install_fio() {
  local name="$1"
  echo "[INSTALL] fio in ${name}"
  docker exec "${name}" bash -lc "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fio > /dev/null" || \
  docker exec "${name}" sh -lc "apk add --no-cache fio || ( zypper --non-interactive install fio || pacman -Sy --noconfirm fio ) || true"
}

prepare_file() {
  local name="$1"
  if [ "$DATA_MODE" = "bind" ]; then
    docker exec "${name}" sh -lc "fallocate -l ${FILE_SIZE} ${TEST_FILE} 2>/dev/null || dd if=/dev/zero of=${TEST_FILE} bs=1M count=$(( ${FILE_SIZE%G} * 1024 )) status=none"
  else
    docker exec "${name}" sh -lc "mkdir -p /mnt && (fallocate -l ${FILE_SIZE} ${TEST_FILE} 2>/dev/null || dd if=/dev/zero of=${TEST_FILE} bs=1M count=$(( ${FILE_SIZE%G} * 1024 )) status=none)"
  fi
  # Verify file
  docker exec "${name}" sh -lc "ls -lh ${TEST_FILE} && stat -c '%s' ${TEST_FILE} || true" | tee -a "${OUT_DIR}/$(basename ${name})_prep.log"
}

for i in $(seq 1 6); do
  cname="${CONTAINER_PREFIX}${i}"
  install_fio "${cname}" &
done
wait
for i in $(seq 1 6); do
  cname="${CONTAINER_PREFIX}${i}"
  echo "[PREP] ${cname}: create test file ${TEST_FILE} (${FILE_SIZE})"
  prepare_file "${cname}" &
done
wait
echo "[STEP] Test files prepared"

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

echo "[STEP] Launching 6 fio jobs (concurrent)..."
pids=()
for i in $(seq 1 6); do
  wl="${WORKLOADS[$((i-1))]}"
  name="${CONTAINER_PREFIX}${i}"
  out_json="${OUT_DIR}/c${i}/fio_c${i}_${wl}.json"
  out_log="${OUT_DIR}/c${i}/fio_c${i}_${wl}.log"
  cmd="$(fio_cmd "${wl}") --output=/out/$(basename "${out_json}")"
  echo "[RUN] ${name} -> ${wl} | ${cmd}" | tee -a "${out_log}"
  # Run and capture output (stdout/stderr) to log on host
  ( docker exec "${name}" sh -lc "${cmd}" ) > "${out_log}" 2>&1 &
  pids+=($!)
done

fail=0
for pid in "${pids[@]}"; do
  if ! wait "$pid"; then
    echo "[ERROR] One fio job failed"
    fail=1
  fi
done
echo "[STEP] Fio jobs finished (fail=${fail})"

# Verify JSON outputs exist and non-empty
echo "[VERIFY] Checking JSON outputs..."
missing=0
for i in $(seq 1 6); do
  wl="${WORKLOADS[$((i-1))]}"
  f="${OUT_DIR}/c${i}/fio_c${i}_${wl}.json"
  if [ ! -s "$f" ]; then
    echo "[WARN] Missing or empty: $f"
    echo "----- fio log (last 50 lines) c${i}/${wl} -----"
    tail -n 50 "${OUT_DIR}/c${i}/fio_c${i}_${wl}.log" || true
    echo "----------------------------------------------"
    missing=$((missing+1))
  fi
done

echo "[STOP] Stopping containers..."
for i in $(seq 1 6); do docker stop "${CONTAINER_PREFIX}${i}" >/dev/null 2>&1 || true & done
wait

if [ "$missing" -gt 0 ]; then
  echo "[DONE] Completed with ${missing} missing JSON outputs. See logs under ${OUT_DIR}/c*/"
else
  echo "[DONE] All JSON outputs present under ${OUT_DIR}/c*/"
fi
