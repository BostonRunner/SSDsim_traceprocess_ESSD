#!/usr/bin/env bash
# 6 轮单容器顺序测试（与 IO.sh 同步的镜像与安装逻辑）：
#   每轮 i：只拉对应镜像 -> docker run -dit (bash||sh) -> 按镜像类型 update 再 install fio
#           -> ./test.sh i 产出 JSON/LOG -> 解析 JSON 追加 CSV -> 删除容器（干净盘）
set -euo pipefail

RESULT_ROOT="${RESULT_ROOT:-./results_all}"
CONTAINER_PREFIX="${CONTAINER_PREFIX:-docker_blktest}"
FILE_SIZE="${FILE_SIZE:-1G}"
RUNTIME="${RUNTIME:-30}"
TEST_DIR="${TEST_DIR:-/mnt/testdir}"

# 与 IO.sh 相同的镜像顺序
IMAGES=(
  "ubuntu:22.04"
  "opensuse/leap:15.5"
  "parrotsec/security"
  "debian:11"
  "alpine:3.18"
  "archlinux:latest"
)

need(){ command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] missing: $1" >&2; exit 1; }; }
need docker
need python3

image_for(){ local idx="$1"; echo "${IMAGES[$((idx-1))]}"; }

pull_if_missing() {
  local img="$1"
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    echo "[PULL] $img"; docker pull "$img" >/dev/null
  else
    echo "[HAVE] $img"
  fi
}

install_fio() {
  local cname="$1"; local image="$2"
  echo "[INSTALL] 在 ${cname} (${image}) 安装 fio（update -> install）..."
  case "$image" in
    ubuntu*|debian*|parrotsec*)
      docker exec "$cname" bash -lc "apt-get update -o Acquire::Retries=3 && DEBIAN_FRONTEND=noninteractive apt-get install -y fio" ;;
    alpine*)
      docker exec "$cname" sh   -lc "apk update && apk add --no-cache fio" ;;
    archlinux*)
      docker exec "$cname" bash -lc "pacman -Sy --noconfirm fio" ;;
    opensuse*|opensuse/*|*leap*)
      docker exec "$cname" bash -lc "zypper --non-interactive refresh && zypper --non-interactive install -y fio" ;;
    *)  # 兜底再尝试一遍
      docker exec "$cname" sh -lc "command -v apt-get >/dev/null && (apt-get update && apt-get install -y fio) || true"
      docker exec "$cname" sh -lc "command -v apk     >/dev/null && (apk update && apk add --no-cache fio) || true"
      docker exec "$cname" sh -lc "command -v pacman  >/dev/null && (pacman -Sy --noconfirm fio) || true"
      docker exec "$cname" sh -lc "command -v zypper  >/dev/null && (zypper --non-interactive refresh && zypper --non-interactive install -y fio) || true"
      ;;
  esac
  docker exec "$cname" sh -lc 'command -v fio >/dev/null 2>&1' || { echo "[ERROR] fio install failed in $cname"; exit 2; }
}

create_round_container() {
  local idx="$1"
  local name="${CONTAINER_PREFIX}${idx}"
  local img; img="$(image_for "$idx")"

  # 清理残留
  docker rm -f "$name" >/dev/null 2>&1 || true

  echo "[RUN ] 启动 ${name} ($img) ..."
  if docker run -dit --name "$name" "$img" bash >/dev/null 2>&1; then
    echo "[INFO] $name started with bash"
  else
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -dit --name "$name" "$img" sh >/dev/null
    echo "[INFO] $name started with sh (fallback)"
  fi

  install_fio "$name" "$img"
  docker exec "$name" sh -lc "mkdir -p '${TEST_DIR}'"
}

destroy_round_container() {
  local idx="$1"; local name="${CONTAINER_PREFIX}${idx}"
  echo "[CLEAN] 删除容器 ${name}（不留卷，下一轮干净盘）"
  docker rm -f "$name" >/dev/null 2>&1 || true
}

ensure_csv_header() {
  local csv="${RESULT_ROOT}/single_summary.csv"
  if [[ ! -f "$csv" ]]; then
    mkdir -p "$RESULT_ROOT"
    echo "round,container,workload,bw_MBps,iops,write_latency_ms,json_path,timestamp" > "$csv"
  fi
}

append_metrics_from_json() {
  local round="$1" cid="$2" json_path="$3" csv="${RESULT_ROOT}/single_summary.csv"
  python3 - "$round" "$cid" "$json_path" "$csv" <<'PY'
import json,sys,os,datetime
round_,cid,jpath,csv=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
def to_float(v):
    if isinstance(v,(int,float)): return float(v)
    if isinstance(v,str):
        try: return float(v)
        except: return 0.0
    if isinstance(v,dict):
        for k in ("mean","value","avg"):
            if k in v: return to_float(v[k])
    return 0.0
with open(jpath,'r') as f:
    data=json.load(f)
job=(data.get('jobs') or [{}])[0]
rd=job.get('read') or {}; wr=job.get('write') or {}
def bw_bytes(sec):
    if not isinstance(sec,dict): return 0.0
    if 'bw_bytes' in sec: return to_float(sec['bw_bytes'])
    return to_float(sec.get('bw',0))*1024.0
bw=bw_bytes(rd)+bw_bytes(wr)
iops=to_float(rd.get('iops',0))+to_float(wr.get('iops',0))
wl=os.path.basename(jpath).split('.',1)[0].split('_')[-1]
lat_ms=0.0
for src in (wr.get('clat_ns'), wr.get('lat_ns'), job.get('clat_ns'), job.get('lat_ns')):
    if src is not None:
        if isinstance(src,dict) and 'mean' in src:
            lat_ms=to_float(src['mean'])/1e6; break
        if isinstance(src,(int,float,str)):
            lat_ms=to_float(src)/1e6; break
ts=datetime.datetime.now().isoformat(timespec='seconds')
with open(csv,'a') as f:
    f.write(f"{round_},{cid},{wl},{bw/(1024*1024):.3f},{iops:.3f},{lat_ms:.3f},{jpath},{ts}\n")
PY
}

# ---------- 主流程：6 轮 ----------
ensure_csv_header
for i in $(seq 1 6); do
  echo "========== ROUND ${i}/6 =========="
  pull_if_missing "$(image_for "$i")"
  create_round_container "$i"

  # 传入必要环境变量（与 IO.sh 对齐的 TEST_DIR）
  RESULT_ROOT="$RESULT_ROOT" FILE_SIZE="$FILE_SIZE" RUNTIME="$RUNTIME" TEST_DIR="$TEST_DIR" ./test.sh "$i"

  # 找到此轮 JSON 并追加到 CSV
  WL_JSON=$(ls -1 "${RESULT_ROOT}/c${i}/fio_c${i}_"*.json | tail -n 1 || true)
  if [[ -n "${WL_JSON:-}" && -s "${WL_JSON}" ]]; then
    append_metrics_from_json "$i" "$i" "$WL_JSON"
  else
    echo "[WARN] no json for c${i}, skip CSV append"
  fi

  destroy_round_container "$i"
done

echo "[ALL DONE] Single-container 6 rounds finished."
echo "CSV: ${RESULT_ROOT}/single_summary.csv"
