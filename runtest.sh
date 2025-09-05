#!/usr/bin/env bash
# Run single-container tests in 6 rounds.
# 每轮：
#   1) 自动确保 docker_blktest1..6 存在并运行（含镜像/卷）
#   2) 清空所有容器 /data
#   3) 仅对第 i 个容器跑一轮（固定工作负载映射）
#   4) （可选）归档/刷新 summary

set -euo pipefail

RESULT_ROOT="${RESULT_ROOT:-./results_all}"

# === 这里改镜像（按容器编号 1..6）===
# 若想所有容器用同一镜像： export IMAGE_ALL=ubuntu:22.04
IMAGES=(
  "${IMAGE_ALL:-ubuntu:22.04}"
  "${IMAGE_ALL:-debian:12}"
  "${IMAGE_ALL:-alpine:3.19}"
  "${IMAGE_ALL:-archlinux:latest}"
  "${IMAGE_ALL:-opensuse/leap:15.5}"
  "${IMAGE_ALL:-rockylinux:9}"
)
# ====================================

CONTAINER_PREFIX="docker_blktest"
DATA_VOL_PREFIX="${DATA_VOL_PREFIX:-blktest_data_c}"   # blktest_data_c1..c6
SLEEP_AFTER_CLEAR="${SLEEP_AFTER_CLEAR:-1}"

PY_ARCHIVER="${PY_ARCHIVER:-separate_storage.py}"   # 可选：你的归档/summary 生成脚本
ARCHIVE_MODE="${ARCHIVE_MODE:-single}"              # 对单容器分轮归档更合理：single

need(){ command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] missing: $1" >&2; exit 1; }; }
need docker

image_for(){
  local idx="$1"
  echo "${IMAGES[$((idx-1))]}"
}

ensure_container(){
  local idx="$1"
  local name="${CONTAINER_PREFIX}${idx}"
  local vol="${DATA_VOL_PREFIX}${idx}"
  local img; img="$(image_for "$idx")"

  # 卷
  if ! docker volume inspect "$vol" >/dev/null 2>&1; then
    echo "[VOLUME] create $vol"
    docker volume create "$vol" >/dev/null
  fi

  # 容器
  if ! docker inspect "$name" >/dev/null 2>&1; then
    echo "[INIT ] create ${name} (image=${img}, vol=${vol}:/data)"
    # 用 /data 命名卷；保持后台常驻
    docker run -d --name "$name" -v "$vol:/data" "$img" sh -c 'tail -f /dev/null' >/dev/null
  fi

  # 运行状态
  if [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" != "true" ]]; then
    echo "[START] start ${name}"
    docker start "$name" >/dev/null
  fi
}

ensure_all(){
  for i in $(seq 1 6); do ensure_container "$i"; done
}

clear_all_containers_data() {
  echo "[CLEAN] wipe /data in all containers"
  for j in $(seq 1 6); do
    cname="${CONTAINER_PREFIX}${j}"
    docker exec "$cname" sh -lc 'rm -rf /data/* || true' || true
  done
  sleep "$SLEEP_AFTER_CLEAR"
}

# ---- main ----
ensure_all

for i in $(seq 1 6); do
  echo "========== ROUND ${i}/6 =========="
  clear_all_containers_data
  ./test.sh "$i"

  # 可选：每轮后把结果汇总到 result_single_container，并生成/刷新 single 的 summary.csv
  if [[ -f "$PY_ARCHIVER" ]]; then
    echo "[ARCH] python3 $PY_ARCHIVER ${RESULT_ROOT} single"
    python3 "$PY_ARCHIVER" "${RESULT_ROOT}" "single" || echo "[WARN] archiver failed (skip)"
  fi
done

echo "[ALL DONE] Single-container 6 rounds finished. Raw results: ${RESULT_ROOT}/cN/"
