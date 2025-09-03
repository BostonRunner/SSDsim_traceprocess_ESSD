#!/bin/bash
# Launch exactly 6 containers, each running a distinct I/O strategy concurrently.
# Strategies (in order of container index):
# 1: seqrw      -> 顺序读写（50/50）
# 2: seqwrite   -> 连续写
# 3: randwrite  -> 随机写
# 4: hotrw      -> 热点读写（Zipf，读多写少）
# 5: hotwrite   -> 热点写（Zipf）
# 6: randrw     -> 随机读写（50/50）

set -euo pipefail

RESULT_DIR="${RESULT_DIR:-./results}"
CONTAINER_PREFIX="docker_blktest"
TEST_FILE="/mnt/testfile.dat"

# Workload parameters
RUNTIME="${RUNTIME:-60}"                 # seconds per container
FILE_SIZE="${FILE_SIZE:-1G}"             # size of the test file
BS_SEQ="${BS_SEQ:-128k}"
BS_RAND="${BS_RAND:-16k}"
IODEPTH_SEQ="${IODEPTH_SEQ:-1}"
IODEPTH_RAND="${IODEPTH_RAND:-16}"
RWMIXREAD_SEQ="${RWMIXREAD_SEQ:-50}"     # for seqrw
RWMIXREAD_RAND="${RWMIXREAD_RAND:-50}"   # for randrw

# Use six images (diverse distros)
IMAGES=(
  "ubuntu:22.04"
  "debian:12"
  "alpine:3.20"
  "opensuse/leap:15.5"
  "archlinux:latest"
  "debian:11"
)
NUM_CONTAINERS=6

WORKLOADS=(seqrw seqwrite randwrite hotrw hotwrite randrw)

mkdir -p "$RESULT_DIR"
for i in $(seq 1 $NUM_CONTAINERS); do
  mkdir -p "$RESULT_DIR/c${i}"
done

# Helpful mapping file for summarizer/plots
cat > "$RESULT_DIR/workloads.json" <<EOF
{ $(for i in $(seq 1 $NUM_CONTAINERS); do idx=$((i-1)); wl=${WORKLOADS[$idx]}; printf "\"c%d\":\"%s\"" "$i" "$wl"; if [ $i -lt $NUM_CONTAINERS ]; then printf ", "; fi; done) }
EOF

echo "[CLEANUP] Remove old test containers..."
for i in $(seq 1 $NUM_CONTAINERS); do
  docker rm -f "${CONTAINER_PREFIX}${i}" >/dev/null 2>&1 || true &
done
wait

install_fio() {
  local container=$1
  local image=$2
  echo "[INSTALL] fio -> $container ($image)"
  case "$image" in
    ubuntu*|debian*)
      docker exec "$container" bash -lc "apt-get update && apt-get install -y fio" ;;
    alpine*)
      docker exec "$container" sh -lc "apk add --no-cache fio" ;;
    archlinux*)
      docker exec "$container" bash -lc "pacman -Sy --noconfirm fio" ;;
    opensuse*)
      docker exec "$container" bash -lc "zypper --non-interactive install fio" ;;
    *)
      docker exec "$container" sh -lc "apk add --no-cache fio || (apt-get update && apt-get install -y fio) || true" ;;
  esac
}

prepare_container() {
  local idx=$1  # 0-based
  local image=${IMAGES[$idx]}
  local name="${CONTAINER_PREFIX}$((idx+1))"
  local out_mount="$(pwd)/$RESULT_DIR/c$((idx+1))"

  echo "[INIT] $name ($image)"
  # prefer bash shell
  if docker run -dit --name "$name" -v "$out_mount":/out "$image" bash >/dev/null 2>&1; then
    :
  else
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -dit --name "$name" -v "$out_mount":/out "$image" sh >/dev/null
  fi

  install_fio "$name" "$image"

  echo "[PREP] $name create test file $FILE_SIZE at $TEST_FILE"
  docker exec "$name" sh -lc "which fallocate >/dev/null 2>&1 && fallocate -l $FILE_SIZE $TEST_FILE || dd if=/dev/zero of=$TEST_FILE bs=1M count=$(( ${FILE_SIZE%G} * 1024 )) status=none || true"
}

fio_cmd_for_workload() {
  local wl="$1"
  case "$wl" in
    seqrw)
      echo "fio --name=seqrw --filename=${TEST_FILE} --rw=readwrite --rwmixread=${RWMIXREAD_SEQ} --bs=${BS_SEQ} --ioengine=libaio --iodepth=${IODEPTH_SEQ} --direct=1 --time_based --runtime=${RUNTIME} --numjobs=1 --group_reporting=1 --output-format=json"
      ;;
    seqwrite)
      echo "fio --name=seqwrite --filename=${TEST_FILE} --rw=write --bs=${BS_SEQ} --ioengine=libaio --iodepth=${IODEPTH_SEQ} --direct=1 --time_based --runtime=${RUNTIME} --numjobs=1 --group_reporting=1 --output-format=json"
      ;;
    randwrite)
      echo "fio --name=randwrite --filename=${TEST_FILE} --rw=randwrite --bs=${BS_RAND} --ioengine=libaio --iodepth=${IODEPTH_RAND} --direct=1 --time_based --runtime=${RUNTIME} --numjobs=1 --group_reporting=1 --output-format=json"
      ;;
    hotrw)
      echo "fio --name=hotrw --filename=${TEST_FILE} --rw=randrw --rwmixread=70 --bs=${BS_RAND} --random_distribution=zipf:1.2 --randrepeat=0 --random_generator=tausworthe --ioengine=libaio --iodepth=${IODEPTH_RAND} --direct=1 --time_based --runtime=${RUNTIME} --numjobs=1 --group_reporting=1 --output-format=json"
      ;;
    hotwrite)
      echo "fio --name=hotwrite --filename=${TEST_FILE} --rw=randwrite --bs=${BS_RAND} --random_distribution=zipf:1.2 --randrepeat=0 --random_generator=tausworthe --ioengine=libaio --iodepth=${IODEPTH_RAND} --direct=1 --time_based --runtime=${RUNTIME} --numjobs=1 --group_reporting=1 --output-format=json"
      ;;
    randrw)
      echo "fio --name=randrw --filename=${TEST_FILE} --rw=randrw --rwmixread=${RWMIXREAD_RAND} --bs=${BS_RAND} --ioengine=libaio --iodepth=${IODEPTH_RAND} --direct=1 --time_based --runtime=${RUNTIME} --numjobs=1 --group_reporting=1 --output-format=json"
      ;;
    *)
      echo "echo 'Unknown workload: ${wl}'; exit 1"
      ;;
  esac
}

echo "[STEP 1] Prepare 6 containers..."
for i in $(seq 0 $((NUM_CONTAINERS - 1))); do
  prepare_container "$i" &
done
wait
echo "[STEP 1 DONE]"

echo "[STEP 2] Launch concurrent workloads..."
pids=()
for i in $(seq 1 $NUM_CONTAINERS); do
  wl="${WORKLOADS[$((i-1))]}"
  name="${CONTAINER_PREFIX}${i}"
  out="/out/fio_c${i}_${wl}.json"
  cmd="$(fio_cmd_for_workload "$wl") --output=${out}"
  echo "[RUN] c${i} -> ${wl}"
  # run in background
  docker exec "$name" sh -lc "$cmd" >/dev/null 2>&1 & 
  pids+=($!)
done

# wait for all
for pid in "${pids[@]}"; do
  wait "$pid" || true
done
echo "[STEP 2 DONE]"

echo "[STOP] stopping containers..."
for i in $(seq 1 $NUM_CONTAINERS); do
  docker stop "${CONTAINER_PREFIX}${i}" >/dev/null 2>&1 || true
done
echo "[DONE] 6 workloads finished."
