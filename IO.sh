#!/bin/bash
set -e

IMAGES=(
  "ubuntu:22.04"
  "opensuse/leap:15.5"
  "parrotsec/security"
  "debian:11"
  "alpine:3.18"
  "archlinux:latest"
)

CONTAINER_PREFIX="docker_blktest"
NUM_CONTAINERS=${#IMAGES[@]}
TEST_DIR="/mnt/testdir"
BLOCK_SIZE="4K"
FILE_SIZE="1M"
FILES_PER_ROUND=8
TOTAL_SIZE=$((2 * 1024 * 1024 * 1024))  # 2GB
TOTAL_FILES=$((TOTAL_SIZE / 1024 / 1024)) # 2048 files

# 分组
GROUP1=(1 2 3)
GROUP2=(4 5 6)

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
sleep 30

# 所有容器准备完毕后统一写入
echo "[STEP 2] 开始并行写入，每轮每容器写 $FILES_PER_ROUND 个文件，共 $TOTAL_FILES 个文件/容器"

run_group_write() {
  local group=("$@")
  local rounds=$((TOTAL_FILES / FILES_PER_ROUND))

  for round in $(seq 0 $((rounds - 1))); do
    for cid in "${group[@]}"; do
      (
        local container="${CONTAINER_PREFIX}${cid}"
        for j in $(seq 1 $FILES_PER_ROUND); do
          local file_idx=$((round * FILES_PER_ROUND + j))
          echo "[C$cid][F$file_idx] 开始写入"
          docker exec "$container" fio --name="c${cid}_f${file_idx}" \
            --filename=$TEST_DIR/file${file_idx}.dat \
            --rw=randwrite \
            --bs=$BLOCK_SIZE \
            --size=$FILE_SIZE \
            --ioengine=sync \
            --direct=1 \
            --numjobs=1 \
            --runtime=2 --time_based
        done
      ) &
    done
    wait
    echo "Group ${group[*]} Round $((round + 1)) 完成"
  done
}

# 并行执行两个容器组写入
run_group_write "${GROUP1[@]}" &
run_group_write "${GROUP2[@]}" &
wait
sleep 30

echo "[STEP 3] 写入完成，正在停止容器..."
for i in $(seq 1 $NUM_CONTAINERS); do
  docker stop "${CONTAINER_PREFIX}${i}" >/dev/null 2>&1 || true
done
echo "[DONE] 容器关闭，实验完成"
