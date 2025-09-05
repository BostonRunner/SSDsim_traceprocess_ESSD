#!/usr/bin/env bash
# Sequential single-container test in 6 rounds, one image/container per round:
#   round i:
#     - pull image[i] only
#     - create fresh volume for /data
#     - run container docker_blktest{i} with that image
#     - run test.sh i (produces JSON/LOG under results_all/c{i}/)
#     - append metrics into results_all/single_summary.csv
#     - remove container+its volume to leave a "clean disk" for next round
set -euo pipefail

RESULT_ROOT="${RESULT_ROOT:-./results_all}"
CONTAINER_PREFIX="${CONTAINER_PREFIX:-docker_blktest}"
DATA_VOL_PREFIX="${DATA_VOL_PREFIX:-blktest_data_c}"   # e.g. blktest_data_c1
FILE_SIZE="${FILE_SIZE:-1G}"     # passed to test.sh via env if needed
RUNTIME="${RUNTIME:-30}"

# ===== per-round image list (1..6) =====
IMAGES=(
  "${IMAGE_ALL:-ubuntu:22.04}"
  "${IMAGE_ALL:-debian:12}"
  "${IMAGE_ALL:-alpine:3.19}"
  "${IMAGE_ALL:-archlinux:latest}"
  "${IMAGE_ALL:-opensuse/leap:15.5}"
  "${IMAGE_ALL:-rockylinux:9}"
)
# ======================================

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

create_fresh_container() {
  local idx="$1"
  local name="${CONTAINER_PREFIX}${idx}"
  local vol="${DATA_VOL_PREFIX}${idx}"
  local img; img="$(image_for "$idx")"

  # ensure fresh: remove leftovers if exist
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker volume rm "$vol" >/dev/null 2>&1 || true

  # fresh volume (clean disk for this round)
  docker volume create "$vol" >/dev/null

  # run container with /data mounted to named volume
  echo "[RUN ] container ${name} (image=${img}, vol=${vol}:/data)"
  docker run -d --name "$name" -v "$vol:/data" "$img" sh -c 'tail -f /dev/null' >/dev/null
}

destroy_container_and_volume() {
  local idx="$1"
  local name="${CONTAINER_PREFIX}${idx}"
  local vol="${DATA_VOL_PREFIX}${idx}"
  echo "[CLEAN] remove ${name} and its volume ${vol}"
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker volume rm "$vol" >/dev/null 2>&1 || true
}

# append/ensure CSV header
ensure_csv_header() {
  local csv="${RESULT_ROOT}/single_summary.csv"
  if [[ ! -f "$csv" ]]; then
    mkdir -p "$RESULT_ROOT"
    echo "round,container,workload,bw_MBps,iops,write_latency_ms,json_path,timestamp" > "$csv"
  fi
}

# parse one fio json and append metrics to CSV (robust to number/string/dict)
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
jobs=data.get('jobs') or [{}]
job=jobs[0]

rd=job.get('read') or {}
wr=job.get('write') or {}
def bw_bytes(sec): 
    if not isinstance(sec,dict): return 0.0
    if 'bw_bytes' in sec: return to_float(sec['bw_bytes'])
    return to_float(sec.get('bw',0))*1024.0
bw=bw_bytes(rd)+bw_bytes(wr)
iops=to_float(rd.get('iops',0))+to_float(wr.get('iops',0))

# workload name from json filename: fio_c{cid}_{wl}.json
wl=os.path.basename(jpath).split('.',1)[0].split('_')[-1]

# write latency prefer write.clat_ns.mean -> write.lat_ns.mean -> job-level
lat_ms=0.0
for src in (wr.get('clat_ns'), wr.get('lat_ns'), job.get('clat_ns'), job.get('lat_ns')):
    if src is not None:
        if isinstance(src,dict) and 'mean' in src:
            lat_ms=to_float(src['mean'])/1e6; break
        if isinstance(src,(int,float,str)):
            lat_ms=to_float(src)/1e6; break

ts=datetime.datetime.now().isoformat(timespec='seconds')
row=f"{round_},{cid},{wl},{bw/(1024*1024):.3f},{iops:.3f},{lat_ms:.3f},{jpath},{ts}\n"
# append
with open(csv,'a') as f: f.write(row)
print(row.strip())
PY
}

# ---------------- main loop ----------------
ensure_csv_header

for i in $(seq 1 6); do
  echo "========== ROUND ${i}/6 =========="

  img="$(image_for "$i")"
  pull_if_missing "$img"
  create_fresh_container "$i"

  # run single test for this container id
  CID="$i"
  CNAME="${CONTAINER_PREFIX}${CID}"
  export RESULT_ROOT FILE_SIZE RUNTIME
  ./test.sh "$CID"

  # locate the JSON just produced
  WL_JSON=$(ls -1 "${RESULT_ROOT}/c${CID}/fio_c${CID}_"*.json | tail -n 1)
  if [[ -z "${WL_JSON:-}" ]]; then
    echo "[WARN] no json found for c${CID}"
  else
    append_metrics_from_json "$i" "$CID" "$WL_JSON"
  fi

  # remove container & volume to keep disk clean for next round
  destroy_container_and_volume "$i"
done

echo "[ALL DONE] Single-container 6 rounds finished."
echo "CSV: ${RESULT_ROOT}/single_summary.csv"
