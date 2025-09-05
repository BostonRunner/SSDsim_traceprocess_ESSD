#!/usr/bin/env bash
# 6 轮单容器顺序测试（与 IO.sh 风格一致）：
# 每轮 i：只拉该轮镜像 -> 起容器 -> 安装 fio（Ubuntu: 失败才换阿里云源） -> ./test.sh i
#        -> 解析 JSON 追加 CSV -> 删容器（下一轮干净）
set -euo pipefail

RESULT_ROOT="${RESULT_ROOT:-./results_all}"
CONTAINER_PREFIX="${CONTAINER_PREFIX:-docker_blktest}"
FILE_SIZE="${FILE_SIZE:-1G}"
RUNTIME="${RUNTIME:-30}"
TEST_DIR="${TEST_DIR:-/mnt/testdir}"

# 镜像清单（第一个是 ubuntu:22.04）
IMAGES=(
  "ubuntu:22.04"
  "opensuse/leap:15.5"
  "parrotsec/security"
  "debian:11"
  "alpine:3.18"
  "archlinux:latest"
)

# Ubuntu 专用：失败回退到阿里云源（固定为阿里云，满足你的要求）
UBUNTU_MIRROR_URL="${UBUNTU_MIRROR_URL:-https://mirrors.aliyun.com/ubuntu}"

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

create_round_container() {
  local idx="$1"
  local name="${CONTAINER_PREFIX}${idx}"
  local img; img="$(image_for "$idx")"
  docker rm -f "$name" >/dev/null 2>&1 || true

  echo "[RUN ] 启动 ${name} ($img) ..."
  if docker run -dit --name "$name" "$img" bash >/dev/null 2>&1; then
    echo "[INFO] $name started with bash"
  else
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -dit --name "$name" "$img" sh >/dev/null
    echo "[INFO] $name started with sh (fallback)"
  fi

  # 预创建测试目录
  docker exec "$name" sh -lc "mkdir -p '${TEST_DIR}'"
}

install_fio() {
  local cname="$1"; local image="$2"
  echo "[INSTALL] 在 ${cname} (${image}) 安装 fio：先 update，再 install ..."

  case "$image" in
    ubuntu:22.04|ubuntu:22.04@*|ubuntu:jammy*|ubuntu:22.*)
      # 1) 先尝试官方源（不改源；不写任何 apt 配置文件）
      set +e
      docker exec "$cname" bash -lc '
        set -e
        apt-get -o Acquire::ForceIPv4=true -o Acquire::Retries=3 -o Acquire::http::Timeout=20 update
        DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::ForceIPv4=true install -y fio
      '
      rc=$?
      set -e
      if [[ $rc -ne 0 ]]; then
        # 2) 仅 Ubuntu 失败时：回退到阿里云源再 update+install（仍然用 ForceIPv4 参数）
        echo "[FALLBACK] Ubuntu 官方源不可达，切换到阿里云源：${UBUNTU_MIRROR_URL}"
        docker exec "$cname" bash -lc "
          set -e
          CN=\$(. /etc/os-release; echo \${VERSION_CODENAME:-jammy})
          cat >/etc/apt/sources.list <<EOF
deb ${UBUNTU_MIRROR_URL} \${CN} main restricted universe multiverse
deb ${UBUNTU_MIRROR_URL} \${CN}-updates main restricted universe multiverse
deb ${UBUNTU_MIRROR_URL} \${CN}-backports main restricted universe multiverse
deb ${UBUNTU_MIRROR_URL} \${CN}-security main restricted universe multiverse
EOF
          apt-get clean
          apt-get -o Acquire::ForceIPv4=true -o Acquire::Retries=3 -o Acquire::http::Timeout=20 update
          DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::ForceIPv4=true install -y fio
        "
      fi
      ;;
    debian*|parrotsec*)
      docker exec "$cname" bash -lc "apt-get update -o Acquire::Retries=3 && DEBIAN_FRONTEND=noninteractive apt-get install -y fio"
      ;;
    alpine*)
      docker exec "$cname" sh   -lc "apk update && apk add --no-cache fio"
      ;;
    archlinux*)
      docker exec "$cname" bash -lc "pacman -Sy --noconfirm fio"
      ;;
    opensuse*|*leap*)
      docker exec "$cname" bash -lc "zypper --non-interactive refresh && zypper --non-interactive install -y fio"
      ;;
    *)
      # 兜底：按常见包管工具尝试
      docker exec "$cname" sh -lc "command -v apt-get >/dev/null && (apt-get update && apt-get install -y fio) || true"
      docker exec "$cname" sh -lc "command -v apk     >/dev/null && (apk update && apk add --no-cache fio) || true"
      docker exec "$cname" sh -lc "command -v pacman  >/dev/null && (pacman -Sy --noconfirm fio) || true"
      docker exec "$cname" sh -lc "command -v zypper  >/dev/null && (zypper --non-interactive refresh && zypper --non-interactive install -y fio) || true"
      ;;
  esac

  docker exec "$cname" sh -lc 'command -v fio >/dev/null 2>&1' || { echo "[ERROR] fio install failed in $cname"; exit 2; }
}

destroy_round_container() {
  local idx="$1"; local name="${CONTAINER_PREFIX}${idx}"
  echo "[CLEAN] 删除容器 ${name}"
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
  img="$(image_for "$i")"
  pull_if_missing "$img"
  create_round_container "$i"
  install_fio "${CONTAINER_PREFIX}${i}" "$img"

  RESULT_ROOT="$RESULT_ROOT" FILE_SIZE="$FILE_SIZE" RUNTIME="$RUNTIME" TEST_DIR="$TEST_DIR" ./test.sh "$i"

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
