#!/usr/bin/env bash
set -euo pipefail

RESULT_ROOT="${RESULT_ROOT:-./results_all}"
FILE_SIZE="${FILE_SIZE:-1G}"
RUNTIME="${RUNTIME:-30}"
DIRECT=1
BS_SEQ="${BS_SEQ:-128k}"; IODEPTH_SEQ="${IODEPTH_SEQ:-1}"
BS_RAND="${BS_RAND:-16k}"; IODEPTH_RAND="${IODEPTH_RAND:-16}"

die(){ echo "[ERROR] $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need docker

if [[ $# -lt 1 ]]; then echo "Usage: $0 <container_id_or_name>"; exit 1; fi
ARG="$1"
if [[ "$ARG" =~ ^[0-9]+$ ]]; then CID="$ARG"; CNAME="docker_blktest${CID}"; else CNAME="$ARG"; [[ "$CNAME" =~ ([0-9]+)$ ]] || die "cannot infer id"; CID="${BASH_REMATCH[1]}"; fi
docker inspect -f '{{.State.Running}}' "$CNAME" >/dev/null 2>&1 || die "container not running: $CNAME"

OUT_DIR="${RESULT_ROOT}/c${CID}"; mkdir -p "$OUT_DIR"
TEST_FILE="/data/testfile.dat"

case "$CID" in
  1) WL="seqrw";     FIO_OPS="--rw=readwrite --rwmixread=50 --bs=${BS_SEQ}  --iodepth=${IODEPTH_SEQ}" ;;
  2) WL="seqwrite";  FIO_OPS="--rw=write      --bs=${BS_SEQ}  --iodepth=${IODEPTH_SEQ}" ;;
  3) WL="randwrite"; FIO_OPS="--rw=randwrite  --bs=${BS_RAND} --iodepth=${IODEPTH_RAND}" ;;
  4) WL="hotrw";     FIO_OPS="--rw=randrw --rwmixread=70 --bs=${BS_RAND} --random_distribution=zipf:1.2 --randrepeat=0 --random_generator=tausworthe --iodepth=${IODEPTH_RAND}" ;;
  5) WL="hotwrite";  FIO_OPS="--rw=randwrite  --bs=${BS_RAND} --random_distribution=zipf:1.2 --randrepeat=0 --random_generator=tausworthe --iodepth=${IODEPTH_RAND}" ;;
  6) WL="randrw";    FIO_OPS="--rw=randrw --rwmixread=50 --bs=${BS_RAND} --iodepth=${IODEPTH_RAND}" ;;
  *) die "unsupported id: $CID";;
esac

echo "[INFO] (${CNAME}) ensure fio installed (update first, then install; no mirror tweaks)..."
if ! docker exec "$CNAME" sh -lc 'command -v fio >/dev/null 2>&1'; then
  set +e
  docker exec "$CNAME" sh -lc '
    set -e
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -o Acquire::Retries=5 -o Acquire::ForceIPv4=true -o Acquire::http::Timeout=20
      DEBIAN_FRONTEND=noninteractive apt-get install -y fio
    elif command -v apk >/dev/null 2>&1; then
      apk update
      apk add --no-cache fio
    elif command -v dnf >/dev/null 2>&1; then
      dnf -y makecache
      dnf -y install fio
    elif command -v yum >/dev/null 2>&1; then
      yum -y makecache
      yum -y install fio
    elif command -v zypper >/dev/null 2>&1; then
      zypper --non-interactive refresh
      zypper --non-interactive install -y fio
    elif command -v pacman >/dev/null 2>&1; then
      pacman -Sy --noconfirm fio
    else
      exit 2
    fi
  '
  rc=$?
  set -e
  [[ $rc -eq 0 ]] || die "fio not available in ${CNAME} (install failed after update)"
fi

echo "[PREP] (${CNAME}) create ${FILE_SIZE} at ${TEST_FILE}"
docker exec "$CNAME" sh -lc "mkdir -p /data && (fallocate -l ${FILE_SIZE} ${TEST_FILE} 2>/dev/null || dd if=/dev/zero of=${TEST_FILE} bs=1M count=$(( ${FILE_SIZE%G} * 1024 )) status=none)"

REMOTE_JSON="/tmp/fio_c${CID}_${WL}.json"
REMOTE_LOG="/tmp/fio_c${CID}_${WL}.log"

FIO_CMD="fio --name=${WL} --filename=${TEST_FILE} ${FIO_OPS} --ioengine=libaio --direct=${DIRECT} \
  --time_based --runtime=${RUNTIME} --numjobs=1 --group_reporting=1 \
  --output-format=json --output=${REMOTE_JSON}"

echo "[RUN ] (${CNAME}) ${WL} ${RUNTIME}s"
docker exec "$CNAME" sh -lc "{ ${FIO_CMD}; } 2>&1 | tee ${REMOTE_LOG}"

docker cp "${CNAME}:${REMOTE_JSON}" "${OUT_DIR}/"
docker cp "${CNAME}:${REMOTE_LOG}"  "${OUT_DIR}/" || true
[[ -s "${OUT_DIR}/$(basename "$REMOTE_JSON")" ]] || die "empty result JSON: ${OUT_DIR}/$(basename "$REMOTE_JSON")"

WORKLOADS_JSON="${RESULT_ROOT}/workloads_single.json"
python3 - "$WORKLOADS_JSON" "$CID" "$WL" <<'PY'
import json,sys,os
p,cid,wl=sys.argv[1],sys.argv[2],sys.argv[3]
d={}
if os.path.exists(p):
  try: d=json.load(open(p))
  except Exception: d={}
d[f"c{cid}"]=wl
json.dump(d,open(p,'w'),ensure_ascii=False,indent=2)
print(f"[INFO] updated {p}: c{cid}->{wl}")
PY

echo "[DONE] (${CNAME}) -> ${OUT_DIR}"
