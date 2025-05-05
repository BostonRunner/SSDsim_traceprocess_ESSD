#!/bin/bash
set -e

# 最大容器数支持
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
BLOCK_SIZE="10K"       # 写入粒度为10KB，制造非对齐写入
FILE_SIZE="1000K"      # 每个文件为1000KB
TOTAL_FILES=1024       # 总共1024个文件
FILES_PER_ROUND=64     # 每轮每容器写64个文件
TOTAL_ROUNDS=$((TOTAL_FILES / FILES_PER_ROUND))
TOTAL_PASSES=2         # 第一轮写入 + 第二轮覆盖写入

# 容器分两组交叉写入
GROUP1=()
GROUP2=()
for i in $(seq 1 $NUM_CONTAINERS); do
  if (( i % 2 == 1 )); then
    GROUP1+=($i)
  else
    GROUP2+=($i)
  fi
done

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
    docker exec "$name" dd if=/dev/zero of=$TEST_DIR/file${i}.dat bs=1000K count=1 status=none || true
  done
}

echo "[STEP 1] 并发准备容器..."
for i in $(seq 0 $((NUM_CONTAINERS - 1))); do
  prepare_container "$i" &
done
wait
echo "[STEP 1 DONE] 所有容器已准备完毕"
sleep 20

run_group_write_pass() {
  local group=("$@")
  for round in $(seq 0 $((TOTAL_ROUNDS - 1))); do
    for cid in "${group[@]}"; do
      (
        local container="${CONTAINER_PREFIX}${cid}"
        file_indices=()
        for j in $(seq 1 $FILES_PER_ROUND); do
          file_idx=$((round * FILES_PER_ROUND + j))
          file_indices+=($file_idx)
        done
        file_indices=($(shuf -e "${file_indices[@]}"))  # 打乱顺序
        for idx in "${file_indices[@]}"; do
          echo "[C$cid][F$idx] 覆盖写入中..."
          docker exec "$container" fio --name="c${cid}_f${idx}" \
            --filename=$TEST_DIR/file${idx}.dat \
            --rw=randwrite \
            --bs=$BLOCK_SIZE \
            --size=$FILE_SIZE \
            --ioengine=sync \
            --direct=1 \
            --numjobs=1 \
            --runtime=2 --time_based \
            --overwrite=1 \
            --randrepeat=0 \
            --random_generator=tausworthe
        done
      ) &
    done
    wait
    echo "[Round $((round + 1))] 完成：Group ${group[*]}"
  done
}

echo "[STEP 2] 开始两轮随机覆盖写..."
for pass in $(seq 1 $TOTAL_PASSES); do
  echo "==== Pass $pass: 第 $pass 轮完整写入 ===="
  run_group_write_pass "${GROUP1[@]}" &
  run_group_write_pass "${GROUP2[@]}" &
  wait
  echo "[PASS $pass DONE] ✔ 所有容器写入完成"
done

echo "[STEP 3] 写入完成，停止容器..."
for i in $(seq 1 $NUM_CONTAINERS); do
  docker stop "${CONTAINER_PREFIX}${i}" >/dev/null 2>&1 || true
done
echo "[DONE] 容器已关闭，实验完成"
