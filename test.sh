#!/usr/bin/env bash
# 对单个容器（编号1..6或名字docker_blktestN）执行一轮fio：
# 1) 确保容器运行
# 2) 容器内先 update/refresh，再安装 fio（若未安装）
# 3) 生成测试文件 -> 跑 fio -> 回拷 JSON/LOG
set -euo pipefail

# -------- 可用环境变量覆盖 ----------
RESULT_ROOT="${RESULT_ROOT:-./results_all}"
FILE_SIZE="${FILE_SIZE:-1G}"
RUNTIME="${RUNTIME:-30}"
DIRECT=1
# 顺序/随机参数
BS_SEQ="${BS_SEQ:-128k}"
IODEPTH_SEQ="${IODEPTH_SEQ:-1}"
BS_RAND="${BS_RAND:-16k}"
IODEPTH_RAND="${IODEPTH_RAND:-16}"
# ------------------------------------

die(){ echo "[ERROR] $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need docker

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <container_id_or_name>"
  exit 1
fi

ARG="$1"
if [[ "$ARG" =~ ^[0-9]+$ ]]; then
  CID="$ARG"
  CNAME="docker_blktest${CID}"
else
  CNAME="$ARG"
  if [[ "$CNAME" =~ ([0-9]+)$ ]]; then
    CID="${BASH_REMATCH[1]}"
  else
    die "cannot infer container id from name: $CNAME"
  fi
fi

# 容器必须在运行
if ! docker inspect -f '{{.State.Running}}' "$CNAME" >/dev/null 2>&1; then
  die "container not running: $CNAME"
fi

OUT_DIR="${RESULT_ROOT}/c${CID}"
mkdir -p "$OUT_DIR"
TEST_FILE="/data/testfile.dat"

# 与并发6容器保持一致的 workload 映射
case "$CID" in
  1) WL="seqrw";     FIO_OPS="--rw=readwrite --rwmixread=50 --bs=${BS_SEQ}  --iodepth=${IODEPTH_SEQ}" ;;
  2) WL="seqwrite";  FIO_OPS="--rw=write      --bs=${BS_SEQ}  --iodepth=${IODEPTH_SEQ}" ;;
  3) WL="randwrite"; FIO_OPS="--rw=randwrite  --bs=${BS_RAND} --iodepth=${IODEPTH_RAND}" ;;
  4) WL="hotrw";     FIO_OPS="--rw=randrw --rwmixread=70 --bs=${BS_RAND} --random_distribution=zipf:1.2 --randrepeat=0 --random_generator=tausworthe --iodepth=${IODEPTH_RAND}" ;;
  5) WL="hotwrite";  FIO_OPS="--rw=randwrite  --bs=${BS_RAND} --random_distribution=zipf:1.2 --randrepeat=0 --random_generator=tausworthe --iodepth=${IODEPTH_RAND}" ;;
  6) WL="randrw";    FIO_OPS="--rw=randrw --rwmixread=50 --bs=${BS_RAND} --iodepth=${IODEPTH_RAND}" ;;
  *) die "unsupported container id: $CID (expect 1..6)";;
esac

# ---- 容器内先 update/refresh，再安装 fio（若未安装） ----
echo "[INFO] (${CNAME}) ensure fio installed (update first, then install)..."
if ! docker exec "$CNAME" sh -lc 'command -v fio >/dev/null 2>&1'; then
  set +e
  docker exec "$CNAME" sh -lc '
    set -e
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -o Acquire::Retries=3
      DEBIAN_FRONTEND=noninteractive apt-get install -y fio
    elif command -v apk >/dev/null 2>&1; then
      apk update
      apk add --no-cache fio
    elif command -v dnf >/dev/null 2>&1; then
      dnf -y makecache || true
      dnf -y install fio
    elif command -v yum >/dev/null 2>&1; then
      yum -y makecache || true
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
  if [[ $rc -ne 0 ]]; then
    die "fio not available in ${CNAME} (package install failed after update)."
  fi
fi

echo "[PREP] (${CNAME}) create test file ${FILE_SIZE} at ${TEST_FILE}"
docker exec "$CNAME" sh -lc "mkdir -p /data && (fallocate -l ${FILE_SIZE} ${TEST_FILE} 2>/dev/null || dd if=/dev/zero of=${TEST_FILE} bs=1M count=$(( ${FILE_SIZE%G} * 1024 )) status=none)"

REMOTE_JSON="/tmp/fio_c${CID}_${WL}.json"
REMOTE_LOG="/tmp/fio_c${CID}_${WL}.log"

FIO_CMD="fio --name=${WL} --filename=${TEST_FILE} ${FIO_OPS} --ioengine=libaio --direct=${DIRECT} \
  --time_based --runtime=${RUNTIME} --numjobs=1 --group_reporting=1 \
  --output-format=json --output=${REMOTE_JSON}"

echo "[RUN ] (${CNAME}) workload=${WL} runtime=${RUNTIME}s"
docker exec "$CNAME" sh -lc "{ ${FIO_CMD}; } 2>&1 | tee ${REMOTE_LOG}"

# 回拷结果
docker cp "${CNAME}:${REMOTE_JSON}" "${OUT_DIR}/" || die "failed to copy JSON from container"
docker cp "${CNAME}:${REMOTE_LOG}"  "${OUT_DIR}/" || true
[[ -s "${OUT_DIR}/$(basename "$REMOTE_JSON")" ]] || die "empty result JSON: ${OUT_DIR}/$(basename "$REMOTE_JSON")"

# 记录映射（供其它汇总脚本使用）
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

echo "[DONE] (${CNAME}) results -> ${OUT_DIR}"
