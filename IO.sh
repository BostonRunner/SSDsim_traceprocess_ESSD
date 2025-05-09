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
INIT_FILE_SIZE="1000K"
TOTAL_FILES=1024
FILES_PER_ROUND=64
ROUNDS_PER_PASS=$((TOTAL_FILES / FILES_PER_ROUND))
TOTAL_PASSES=3

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
  echo "[PULL] 拉取镜像 $image"
  docker pull "$image" >/dev/null
  echo "[INIT] 启动 $name ($image)..."
  if docker run -dit --name "$name" "$image" bash >/dev/null 2>&1; then
    echo "[INFO] $name 启动成功（bash）"
  else
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -dit --name "$name" "$image" sh >/dev/null
    echo "[INFO] $name 启动成功（sh fallback）"
  fi
  until docker exec "$name" sh -c "echo ready" >/dev/null 2>&1; do
    sleep 1
  done
  install_fio "$name" "$image"
  docker exec "$name" mkdir -p "$TEST_DIR"
}

for i in $(seq 0 $((NUM_CONTAINERS - 1))); do
  prepare_container "$i" &
done
wait

echo "[PREP] 所有容器准备完成"
sleep 10

delete_files_for_container() {
  local container=$1
  echo "[DELETE] 清除 $container 中文件..."
  docker exec "$container" bash -c '
    for f in '"$TEST_DIR"'/file*.dat; do
      dd if=/dev/zero of="$f" bs=1M count=1 oflag=direct status=none || true
    done
    sync
    rm -f '"$TEST_DIR"'/file*.dat || true
  '
}

run_group_write_round() {
  local group=("$@")
  local round_id=$1
  local pass_id=$2

  for cid in "${group[@]}"; do
    (
      local container="${CONTAINER_PREFIX}${cid}"
      file_indices=($(shuf -i 1-$TOTAL_FILES -n $FILES_PER_ROUND))

      for idx in "${file_indices[@]}"; do
        local random_kb=$((1024 + RANDOM % 2049))
        local rand_suffix=$((RANDOM % 100000))
        local file_name="file${idx}_r${rand_suffix}.dat"
        echo "[PASS $pass_id][ROUND $round_id][C$cid] $file_name: ${random_kb}K"
        docker exec "$container" fio --name="c${cid}_${file_name}" \
          --filename=$TEST_DIR/$file_name \
          --rw=randwrite \
          --bs=$BLOCK_SIZE \
          --size="${random_kb}K" \
          --offset_increment=10K \
          --ioengine=sync \
          --direct=1 \
          --numjobs=1 \
          --time_based --runtime=1 \
          --overwrite=1 \
          --randrepeat=0 \
          --random_generator=tausworthe
      done
    ) &
  done
  wait
}

for pass in $(seq 1 $TOTAL_PASSES); do
  echo "==== 大轮 $pass 开始 ===="

  for round in $(seq 1 $ROUNDS_PER_PASS); do
    echo "---- 小轮 $round 开始 ----"
    run_group_write_round "$round" "$pass" "${GROUP1[@]}" &
    run_group_write_round "$round" "$pass" "${GROUP2[@]}" &
    wait
    echo "---- 小轮 $round 完成 ----"
  done

  echo "==== 大轮 $pass 文件删除 ===="
  for cid in $(seq 1 $NUM_CONTAINERS); do
    delete_files_for_container "${CONTAINER_PREFIX}${cid}" &
  done
  wait
  echo "==== 大轮 $pass 完成 ===="
done

echo "[CLOSE] 关闭所有容器..."
for i in $(seq 1 $NUM_CONTAINERS); do
  docker stop "${CONTAINER_PREFIX}${i}" >/dev/null 2>&1 || true
  docker rm -f "${CONTAINER_PREFIX}${i}" >/dev/null 2>&1 || true
done

echo "[DONE] 完全多轮重写高压力测试完成!"
