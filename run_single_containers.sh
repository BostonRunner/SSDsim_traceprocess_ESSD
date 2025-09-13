#!/usr/bin/env bash
# run_single_containers.sh - single-container sequential tests (clean disk before each), runtime=90s
# All fio tests use --size=8G as requested.
set -euo pipefail

RESULT_ROOT="${RESULT_ROOT:-./results_all}"
TEST_ROOT_HOST="${TEST_ROOT_HOST:-/mnt/docker_tmp}"
OUT_SHARED_DIR="${TEST_ROOT_HOST}/fio_out"
CONTAINER_PREFIX="${CONTAINER_PREFIX:-docker_blktest}"
RUNTIME=${RUNTIME:-90}
FIO_LOCAL_BIN="${FIO_LOCAL_BIN:-./tools/fio}"
DEVICE="/dev/vdb"

IMAGES=(
  "ubuntu:22.04"
  "opensuse/leap:15.5"
  "debian:11"
  "alpine:3.18"
  "archlinux:latest"
  "rockylinux:9"
)
WORKLOAD_MAP=(seqrw seqwrite randwrite hotrw hotwrite randrw)

# per-workload parameters
declare -A RW BS IODEPTH EXTRA
RW[seqrw]="readwrite";  BS[seqrw]="128k"; IODEPTH[seqrw]=1;  EXTRA[seqrw]="--rwmixread=50"
RW[seqwrite]="write";    BS[seqwrite]="128k"; IODEPTH[seqwrite]=1; EXTRA[seqwrite]=""
RW[randwrite]="randwrite"; BS[randwrite]="4k"; IODEPTH[randwrite]=32; EXTRA[randwrite]=""
RW[hotrw]="randrw";      BS[hotrw]="4k"; IODEPTH[hotrw]=32; EXTRA[hotrw]="--rwmixread=70 --random_distribution=zipf:1.2 --randrepeat=0"
RW[hotwrite]="randwrite"; BS[hotwrite]="4k"; IODEPTH[hotwrite]=32; EXTRA[hotwrite]="--random_distribution=zipf:1.2 --randrepeat=0"
RW[randrw]="randrw";     BS[randrw]="4k"; IODEPTH[randrw]=32; EXTRA[randrw]="--rwmixread=50"

# fixed test file size (per your request)
TEST_FILE_SIZE="8G"

# checks
command -v docker >/dev/null 2>&1 || { echo "[ERROR] docker missing"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "[ERROR] python3 missing"; exit 1; }

mkdir -p "${RESULT_ROOT}"
mkdir -p "${OUT_SHARED_DIR}"

pull_if_missing(){
  img="$1"
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    echo "[PULL] $img"
    docker pull "$img"
  else
    echo "[HAVE] $img"
  fi
}

# install_fio: try package managers, then install libaio packages, and fallback to local fio binary if provided.
install_fio(){
  local cname="$1" img="$2" cid=""
  if [[ "$cname" =~ ([0-9]+)$ ]]; then cid="${BASH_REMATCH[1]}"; fi
  local outdir="${RESULT_ROOT}/c${cid}"; mkdir -p "$outdir"
  echo "[INSTALL] ensure fio in ${cname} (${img})..."
  if docker exec "$cname" sh -lc 'command -v fio >/dev/null 2>&1'; then
    echo "[OK] fio already present"
    return 0
  fi
  docker exec "$cname" sh -lc "mkdir -p /out" >/dev/null 2>&1 || true
  local remote_log="/out/install_fio.log"
  docker exec "$cname" sh -lc "rm -f ${remote_log} >/dev/null 2>&1 || true"

  set +e
  # apt
  docker exec "$cname" sh -lc 'command -v apt-get >/dev/null 2>&1' \
    && docker exec "$cname" sh -lc "apt-get -o Acquire::Retries=3 update >>${remote_log} 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y fio libaio1 >>${remote_log} 2>&1"
  # apk
  docker exec "$cname" sh -lc 'command -v apk >/dev/null 2>&1' \
    && docker exec "$cname" sh -lc "apk update >>${remote_log} 2>&1 && apk add --no-cache fio libaio >>${remote_log} 2>&1 || apk add --no-cache fio >>${remote_log} 2>&1"
  # dnf
  docker exec "$cname" sh -lc 'command -v dnf >/dev/null 2>&1' \
    && docker exec "$cname" sh -lc "dnf -y install fio libaio >>${remote_log} 2>&1 || (dnf -y install epel-release >>${remote_log} 2>&1 && dnf -y install fio libaio >>${remote_log} 2>&1)"
  # yum
  docker exec "$cname" sh -lc 'command -v yum >/dev/null 2>&1' \
    && docker exec "$cname" sh -lc "yum -y install fio libaio >>${remote_log} 2>&1 || (yum -y install epel-release >>${remote_log} 2>&1 && yum -y install fio libaio >>${remote_log} 2>&1)"
  # zypper
  docker exec "$cname" sh -lc 'command -v zypper >/dev/null 2>&1' \
    && docker exec "$cname" sh -lc "zypper --non-interactive refresh >>${remote_log} 2>&1 && zypper --non-interactive install -y fio libaio >>${remote_log} 2>&1"
  # pacman
  docker exec "$cname" sh -lc 'command -v pacman >/dev/null 2>&1' \
    && docker exec "$cname" sh -lc "pacman -Sy --noconfirm fio libaio >>${remote_log} 2>&1 || pacman -Sy --noconfirm fio >>${remote_log} 2>&1"
  set -e

  # copy install log back
  docker cp "${cname}:${remote_log}" "${outdir}/install_fio.log" >/dev/null 2>&1 || true

  # check presence
  if docker exec "$cname" sh -lc 'command -v fio >/dev/null 2>&1'; then
    echo "[OK] fio installed"
    return 0
  fi

  # fallback: inject local fio binary if provided
  if [[ -n "${FIO_LOCAL_BIN:-}" && -x "${FIO_LOCAL_BIN}" ]]; then
    echo "[FALLBACK] copy local fio into ${cname}"
    docker cp "${FIO_LOCAL_BIN}" "${cname}:/usr/local/bin/fio" || true
    docker exec "$cname" sh -lc "chmod +x /usr/local/bin/fio" || true
    if docker exec "$cname" sh -lc 'command -v fio >/dev/null 2>&1'; then
      echo "[OK] injected local fio"
      return 0
    fi
  fi

  echo "[ERROR] fio not available in ${cname}; check ${outdir}/install_fio.log"
  return 2
}

# JSON parse & append (robust)
append_metrics_from_json(){
  round="$1"; cid="$2"; json_path="$3"; csv="${RESULT_ROOT}/single_summary.csv"
  python3 - "$round" "$cid" "$json_path" "$csv" <<'PY'
import json,sys,os,datetime
round_,cid,jpath,csv=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
def try_load_json_text(text):
    try: return json.loads(text)
    except: pass
    opens=[i for i,ch in enumerate(text) if ch=='{']; closes=[i for i,ch in enumerate(text) if ch=='}']
    for start in opens:
        for end in reversed(closes):
            if end<=start: continue
            chunk=text[start:end+1]
            try: return json.loads(chunk)
            except: continue
    return None
def to_float(v):
    if isinstance(v,(int,float)): return float(v)
    if isinstance(v,str):
        try: return float(v)
        except: return 0.0
    if isinstance(v,dict):
        for k in ("mean","value","avg"):
            if k in v: return to_float(v[k])
    return 0.0
if not os.path.exists(jpath):
    print("[WARN] missing", jpath); sys.exit(0)
text=open(jpath,'rb').read().decode('utf-8',errors='ignore')
data=try_load_json_text(text)
if data is None:
    print("[ERROR] cannot parse JSON", jpath); sys.exit(0)
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
print("APPENDED", round_, cid, wl)
PY
}

# ensure header
if [[ ! -f "${RESULT_ROOT}/single_summary.csv" ]]; then
  mkdir -p "${RESULT_ROOT}"
  echo "round,container,workload,bw_MBps,iops,write_latency_ms,json_path,timestamp" > "${RESULT_ROOT}/single_summary.csv"
fi

# main loop
for i in $(seq 1 6); do
  echo "========== ROUND ${i}/6 (single-container) =========="
  img="${IMAGES[$i-1]}"
  wl="${WORKLOAD_MAP[$i-1]}"
  cname="${CONTAINER_PREFIX}${i}"
  host_test_dir="${TEST_ROOT_HOST}/test_c${i}"
  outdir="${RESULT_ROOT}/c${i}"
  mkdir -p "$outdir" "$host_test_dir"

  echo "[CLEAN] clearing ${host_test_dir}"
  rm -rf "${host_test_dir:?}/"* || true
  sync
  if [[ -w /proc/sys/vm/drop_caches ]]; then echo 3 > /proc/sys/vm/drop_caches || true; fi

  pull_if_missing "$img"

  docker rm -f "$cname" >/dev/null 2>&1 || true
  echo "[RUN] starting ${cname} (image=${img}) bind ${host_test_dir}:/data, ${OUT_SHARED_DIR}:/out"
  docker run -d --name "$cname" -v "${host_test_dir}:/data" -v "${OUT_SHARED_DIR}:/out" "$img" sh -c 'tail -f /dev/null'

  install_fio "$cname" "$img" || { echo "[ERROR] install_fio failed for ${cname}, skipping"; docker cp "${cname}:/out/install_fio.log" "${outdir}/install_fio.log" >/dev/null 2>&1 || true; docker rm -f "$cname" >/dev/null 2>&1 || true; continue; }

  # prepare fio params on host
  rw="${RW[$wl]}"
  bs="${BS[$wl]}"
  iodepth="${IODEPTH[$wl]}"
  extra="${EXTRA[$wl]}"

  # start iostat if available
  iostat_log="${outdir}/iostat_vdb.log"
  if command -v iostat >/dev/null 2>&1; then
    echo "[Iostat] starting iostat for ${DEVICE} -> ${iostat_log}"
    iostat -x -k 1 ${DEVICE} > "${iostat_log}" 2>&1 & echo $! > "${outdir}/iostat_pid"
  fi

  echo "[FIO] running ${wl} on ${cname} for ${RUNTIME}s (rw=${rw}, bs=${bs}, iodepth=${iodepth}, size=${TEST_FILE_SIZE})"
  cmd="fio --name='${wl}' --filename=/data/testfile --size=${TEST_FILE_SIZE} --rw='${rw}' ${extra} --bs='${bs}' --iodepth=${iodepth} --ioengine=libaio --direct=1 --invalidate=1 --time_based --runtime=${RUNTIME} --group_reporting --output-format=json >/out/fio_${wl}.json 2>/out/fio_${wl}.log"
  docker exec "$cname" sh -lc "$cmd"

  sleep 2
  # move outputs
  if [[ -f "${OUT_SHARED_DIR}/fio_${wl}.json" ]]; then mv "${OUT_SHARED_DIR}/fio_${wl}.json" "${outdir}/fio_c${i}_${wl}.json"; fi
  if [[ -f "${OUT_SHARED_DIR}/fio_${wl}.log" ]]; then mv "${OUT_SHARED_DIR}/fio_${wl}.log" "${outdir}/"; fi
  for f in "${OUT_SHARED_DIR}"/iops_${wl}* ; do [[ -e "$f" ]] && mv "$f" "${outdir}/" 2>/dev/null|| true; done

  # stop iostat
  if [[ -f "${outdir}/iostat_pid" ]]; then kill "$(cat "${outdir}/iostat_pid")" 2>/dev/null || true; rm -f "${outdir}/iostat_pid"; fi

  WL_JSON=$(ls -1 "${outdir}/fio_c${i}_"*.json 2>/dev/null | tail -n1 || true)
  if [[ -n "$WL_JSON" && -s "$WL_JSON" ]]; then
    append_metrics_from_json "$i" "$i" "$WL_JSON"
  else
    echo "[WARN] no json for c${i}, check ${outdir}"
  fi

  echo "[CLEANUP] removing ${cname}"
  docker rm -f "$cname" >/dev/null 2>&1 || true
done

echo "[ALL DONE] Single-container rounds finished. Summary: ${RESULT_ROOT}/single_summary.csv"
