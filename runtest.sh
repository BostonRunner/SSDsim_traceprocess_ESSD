#!/usr/bin/env bash
set -euo pipefail

RESULT_ROOT="${RESULT_ROOT:-./results_all}"
CONTAINER_PREFIX="${CONTAINER_PREFIX:-docker_blktest}"
DATA_VOL_PREFIX="${DATA_VOL_PREFIX:-blktest_data_c}"
FILE_SIZE="${FILE_SIZE:-1G}"
RUNTIME="${RUNTIME:-30}"

# 默认一轮拉一个镜像。可统一： export IMAGE_ALL=ubuntu:22.04
IMAGES=(
  "${IMAGE_ALL:-ubuntu:22.04}"
  "${IMAGE_ALL:-debian:12}"
  "${IMAGE_ALL:-alpine:3.19}"
  "${IMAGE_ALL:-archlinux:latest}"
  "${IMAGE_ALL:-opensuse/leap:15.5}"
  "${IMAGE_ALL:-rockylinux:9}"
)

# NEW: 默认用宿主网络，避免 bridge 出口受限；如需桥接： export DOCKER_NET=bridge
DOCKER_NET="${DOCKER_NET:-host}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] missing: $1" >&2; exit 1; }; }
need docker
need python3

image_for(){ local idx="$1"; echo "${IMAGES[$((idx-1))]}"; }

pull_if_missing() {
  local img="$1"
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    echo "[PULL] $img"
    docker pull "$img" >/dev/null
  else
    echo "[HAVE] $img"
  fi
}

# NEW: 透传宿主机代理到容器（如果设置了）
make_proxy_flags() {
  local -a flags=()
  for v in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
    if [ -n "${!v-}" ]; then
      flags+=("-e" "$v=${!v}")
    fi
  done
  echo "${flags[@]}"
}

create_round_container() {
  local idx="$1"
  local name="${CONTAINER_PREFIX}${idx}"
  local vol="${DATA_VOL_PREFIX}${idx}"
  local img; img="$(image_for "$idx")"

  docker rm -f "$name" >/dev/null 2>&1 || true
  docker volume rm "$vol" >/dev/null 2>&1 || true
  docker volume create "$vol" >/dev/null

  local proxy_flags; proxy_flags=$(make_proxy_flags)
  echo "[RUN ] container ${name} (image=${img}, vol=${vol}:/data, net=${DOCKER_NET})"
  # NEW: --network "${DOCKER_NET}" 并透传代理
  # shellcheck disable=SC2086
  docker run -d --name "$name" --network "${DOCKER_NET}" $proxy_flags \
    -v "$vol:/data" "$img" sh -c 'tail -f /dev/null' >/dev/null
}

destroy_round_container() {
  local idx="$1"
  local name="${CONTAINER_PREFIX}${idx}"
  local vol="${DATA_VOL_PREFIX}${idx}"
  echo "[CLEAN] remove ${name} and volume ${vol}"
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker volume rm "$vol" >/dev/null 2>&1 || true
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
    return 0.0

with open(jpath,'r') as f:
    data=json.load(f)
job=(data.get('jobs') or [{}])[0]
rd=job.get('read') or {}
wr=job.get('write') or {}
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

# ---------- main ----------
ensure_csv_header

for i in $(seq 1 6); do
  echo "========== ROUND ${i}/6 =========="
  img="$(image_for "$i")"
  pull_if_missing "$img"
  create_round_container "$i"

  RESULT_ROOT="$RESULT_ROOT" FILE_SIZE="$FILE_SIZE" RUNTIME="$RUNTIME" ./test.sh "$i"

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
