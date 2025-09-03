#!/bin/bash
set -e

MAX_CONTAINERS=6
USE_CONTAINERS=${USE_CONTAINERS:-$MAX_CONTAINERS}

IMAGES=(
  "ubuntu:22.04"
  "opensuse/leap:15.5"
  "parrotsec/security"
  "debian:11"
  "alpine:3.18"
  "archlinux:latest"
)
IMAGES=("${IMAGES[@]:0:$USE_CONTAINERS}")
NUM_CONTAINERS=${#IMAGES[@]}

CONTAINER_PREFIX="docker_blktest"
TEST_DIR="/mnt/testdir"
BLOCK_SIZE="10K"
FILES_PER_ROUND=8
TOTAL_SIZE=$((2 * 1024 * 1024 * 1024))  # 2GB
TOTAL_FILES=1024
TOTAL_PASSES=2  # 两大轮

WORKLOADS=(seqrw seqwrite randwrite hotrw hotwrite randrw)

echo "[CLEANUP] 清理旧容器..."
for i in $(seq 1 $NUM_CONTAINERS); do
  docker rm -f "${CONTAINER_PREFIX}${i}" >/dev/null 2>&1 || true &
done
wait

install_fio() {
  local container=$1
  local image=$2
  echo "[INSTALL] 安装 fio 到 $container ..."
  case "$image" in
    ubuntu*|debian*|parrotsec*) docker exec "$container" bash -c "apt-get update && apt-get install -y fio" ;;
    alpine*) docker exec "$container" sh -c "apk add --no-cache fio" ;;
    archlinux*) docker exec "$container" bash -c "pacman -Sy --noconfirm fio" ;;
    opensuse*) docker exec "$container" bash -c "zypper --non-interactive install fio" ;;
  esac
}

prepare_container() {
  local idx=$1
  local image=${IMAGES[$idx]}
  local name="${CONTAINER_PREFIX}$((idx+1))"
  echo "[INIT] 启动 $name ($image)..."
  if docker run -dit --name "$name" "$image" bash >/dev/null 2>&1; then
    echo "[INFO] $name 启动成功（bash）"
  else
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -dit --name "$name" "$image" sh >/dev/null
    echo "[INFO] $name 启动成功（sh fallback）"
  fi

  install_fio "$name" "$image"
  docker exec "$name" mkdir -p "$TEST_DIR"

  echo "[PREP] $name 初始化 $TOTAL_FILES 个文件"
  for i in $(seq 1 $TOTAL_FILES); do
    docker exec "$name" dd if=/dev/zero of=$TEST_DIR/file${i}.dat bs=1M count=1 status=none || true
  done
}

echo "[STEP 1] 准备容器..."
for i in $(seq 0 $((NUM_CONTAINERS - 1))); do
  prepare_container "$i" &
done
wait
echo "[STEP 1 DONE] 完成"
sleep 10

run_group_write() {
  local group=("$@")
  local round_idx=$1
  shift
  local containers=("$@")

  local shuffled=($(shuf -i 1-$TOTAL_FILES))

  local rounds=$((TOTAL_FILES / FILES_PER_ROUND))

  for round in $(seq 0 $((rounds - 1))); do
    echo 3 > /proc/sys/vm/drop_caches

    for cid in "${containers[@]}"; do
      (
        local container="${CONTAINER_PREFIX}${cid}"

        for j in $(seq 1 $FILES_PER_ROUND); do
          local file_idx=${shuffled[$((round * FILES_PER_ROUND + j - 1))]}
          local rand_kb=$((1800 + RANDOM % 401))
          echo "[Pass $round_idx][C$cid][F$file_idx] ${rand_kb}KB"

          # Log fio command and execute it
          case "${WORKLOADS[$((cid - 1))]}" in
            seqrw)
              echo "[DEBUG] Running fio for seqrw: container ${cid} file ${file_idx}"
              docker exec "$container" fio --name="c${cid}_f${file_idx}" --filename=$TEST_DIR/file${file_idx}.dat \
                --rw=readwrite --rwmixread=50 --bs=$BLOCK_SIZE --size="${rand_kb}K" --offset=0 --offset_increment=10K \
                --random_distribution=zipf --overwrite=1 --ioengine=sync --direct=1 --numjobs=1 --runtime=3 --time_based \
                --randrepeat=0 --random_generator=tausworthe --output-format=json
              ;;
            seqwrite)
              echo "[DEBUG] Running fio for seqwrite: container ${cid} file ${file_idx}"
              docker exec "$container" fio --name="c${cid}_f${file_idx}" --filename=$TEST_DIR/file${file_idx}.dat \
                --rw=write --bs=$BLOCK_SIZE --size="${rand_kb}K" --offset=0 --offset_increment=10K \
                --random_distribution=zipf --overwrite=1 --ioengine=sync --direct=1 --numjobs=1 --runtime=3 --time_based \
                --randrepeat=0 --random_generator=tausworthe --output-format=json
              ;;
            randwrite)
              echo "[DEBUG] Running fio for randwrite: container ${cid} file ${file_idx}"
              docker exec "$container" fio --name="c${cid}_f${file_idx}" --filename=$TEST_DIR/file${file_idx}.dat \
                --rw=randwrite --bs=$BLOCK_SIZE --size="${rand_kb}K" --offset=0 --offset_increment=10K \
                --random_distribution=zipf --overwrite=1 --ioengine=sync --direct=1 --numjobs=1 --runtime=3 --time_based \
                --randrepeat=0 --random_generator=tausworthe --output-format=json
              ;;
            hotrw)
              echo "[DEBUG] Running fio for hotrw: container ${cid} file ${file_idx}"
              docker exec "$container" fio --name="c${cid}_f${file_idx}" --filename=$TEST_DIR/file${file_idx}.dat \
                --rw=randrw --rwmixread=70 --bs=$BLOCK_SIZE --random_distribution=zipf:1.2 --randrepeat=0 \
                --random_generator=tausworthe --ioengine=sync --direct=1 --numjobs=1 --runtime=3 --time_based \
                --randrepeat=0 --random_generator=tausworthe --output-format=json
              ;;
            hotwrite)
              echo "[DEBUG] Running fio for hotwrite: container ${cid} file ${file_idx}"
              docker exec "$container" fio --name="c${cid}_f${file_idx}" --filename=$TEST_DIR/file${file_idx}.dat \
                --rw=randwrite --bs=$BLOCK_SIZE --random_distribution=zipf:1.2 --randrepeat=0 --random_generator=tausworthe \
                --ioengine=sync --direct=1 --numjobs=1 --runtime=3 --time_based --randrepeat=0 --output-format=json
              ;;
            randrw)
              echo "[DEBUG] Running fio for randrw: container ${cid} file ${file_idx}"
              docker exec "$container" fio --name="c${cid}_f${file_idx}" --filename=$TEST_DIR/file${file_idx}.dat \
                --rw=randrw --rwmixread=50 --bs=$BLOCK_SIZE --size="${rand_kb}K" --offset=0 --offset_increment=10K \
                --random_distribution=zipf --overwrite=1 --ioengine=sync --direct=1 --numjobs=1 --runtime=3 --time_based \
                --randrepeat=0 --random_generator=tausworthe --output-format=json
              ;;
          esac

        done
      ) & 
    done
    wait
    echo "[Round $((round + 1))] Group ${containers[*]} 完成"
  done
}

for pass in $(seq 1 $TOTAL_PASSES); do
  echo "========== 大轮 $pass 开始 =========="
  run_group_write "$pass" "${GROUP1[@]}" &
  run_group_write "$pass" "${GROUP2[@]}" &
  wait
  echo "========== 大轮 $pass 完成 =========="
done

echo "[STEP 3] 写入完成，停止容器..."
for i in $(seq 1 $NUM_CONTAINERS); do
  docker stop "${CONTAINER_PREFIX}${i}" >/dev/null 2>&1 || true
done

echo "[DONE] 所有容器关闭，实验结束"
