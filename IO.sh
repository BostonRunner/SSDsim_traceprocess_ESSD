#!/bin/bash
set -e

# 支持动态设定容器数量（最大为6）
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

# 动态生成两组容器编号
GROUP1=()
GROUP2=()
for i in $(seq 1 $NUM_CONTAINERS); do
  if (( i % 2 == 1 )); then
    GROUP1+=($i)
  else
    GROUP2+=($i)
  fi
done

# 清理旧容器
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

  echo "[PREP] $name 初始化 $TOTAL_FILES 个文件"
  docker exec "$name" mkdir -p "$TEST_DIR"
  for i in $(seq 1 $TOTAL_FILES); do
    docker exec "$name" dd if=/dev/zero of=$TEST_DIR/file${i}.dat bs=1M count=1 status=none || true
  done
}

echo "[STEP 1] 并发准备容器..."
for i in $(seq 0 $((NUM_CONTAINERS - 1))); do
  prepare_container "$i" &
done
wait
echo "[STEP 1 DONE] 容器准备完成"
sleep 10

run_group_write() {
  local group=("$@")
  local rounds=$((TOTAL_FILES / FILES_PER_ROUND))

  for round in $(seq 0 $((rounds - 1))); do
    echo 3 > /proc/sys/vm/drop_caches

    for cid in "${group[@]}"; do
      (
        local container="${CONTAINER_PREFIX}${cid}"
        file_indices=($(shuf -i 1-$TOTAL_FILES -n $FILES_PER_ROUND))

        for idx in "${file_indices[@]}"; do
          local rand_kb=$((1800 + RANDOM % 401))
          echo "[C$cid][F$idx] 写入 ${rand_kb}KB..."

          docker exec "$container" fio --name="c${cid}_f${idx}"             --filename=$TEST_DIR/file${idx}.dat             --rw=randwrite             --bs=$BLOCK_SIZE             --size="${rand_kb}K"             --overwrite=1             --ioengine=sync             --direct=1             --numjobs=1             --runtime=3 --time_based             --randrepeat=0             --random_generator=tausworthe
        done
      ) &
    done
    wait
    echo "Group ${group[*]} Round $((round + 1)) 完成"
  done
}

echo "[STEP 2] 开始并行写入"
run_group_write "${GROUP1[@]}" &
run_group_write "${GROUP2[@]}" &
wait
sleep 10

echo "[STEP 3] 写入完成，正在停止容器..."
for i in $(seq 1 $NUM_CONTAINERS); do
  docker stop "${CONTAINER_PREFIX}${i}" >/dev/null 2>&1 || true
done
echo "[DONE] 容器关闭，实验完成"
