#!/usr/bin/env bash
# 对单个容器（编号1..6或名字 docker_blktestN）执行一轮 fio：
# 1) 生成测试文件 -> 2) 跑 fio -> 3) 回拷 JSON/LOG
set -euo pipefail

RESULT_ROOT="${RESULT_ROOT:-./results_all}"
RUNTIME="${RUNTIME:-30}"
DIRECT=1
# 顺序/随机参数（与并发6容器一致）
BS_SEQ="${BS_SEQ:-128k}"; IODEPTH_SEQ="${IODEPTH_SEQ:-1}"
BS_RAND="${BS_RAND:-16k}"; IODEPTH_RAND="${IODEPTH_RAND:-16}"
TEST_DIR="${TEST_DIR:-/mnt/testdir}"     # 与 IO.sh 保持一致
TEST_FILE="${TEST_DIR}/testfile.dat"
FILE_SIZE="${FILE_SIZE:-1G}"             # 会用 fallocate / dd 创建

die(){ echo "[ERROR] $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need docker

# 参数：容器编号或容器名
if [[ $# -lt 1 ]]; then echo "Usage: $0 <container_id_or_name>"; exit 1; fi
ARG="$1"
if [[ "$ARG" =~ ^[0-9]+$ ]]; then CID="$ARG"; CNAME="docker_blktest${CID}"; else CNAME="$ARG"; [[ "$CNAME" =~ ([0-9]+)$ ]] || die "cannot infer id from name"; CID="${BASH_REMATCH[1]}"; fi

# 容器必须在运行
docker inspect -f '{{.State.Running}}' "$CNAME" >/dev/null 2>&1 || die "container not running: $CNAME"

OUT_DIR="${RESULT_ROOT}/c${CID}"; mkdir -p "$OUT_DIR"

# 固定 workload 映射（与多容器一致）
case "$CID" in
  1) WL="seqrw";     FIO_OPS="--rw=readwrite --rwmixread=50 --bs=${BS_SEQ}  --iodepth=${IODEPTH_SEQ}" ;;
  2) WL="seqwrite";  FIO_OPS="--rw=write      --bs=${BS_SEQ}  --iodepth=${IODEPTH_SEQ}" ;;
  3) WL="randwrite"; FIO_OPS="--rw=randwrite  --bs=${BS_RAND} --iodepth=${IODEPTH_RAND}" ;;
  4) WL="hotrw";     FIO_OPS="--rw=randrw --rwmixread=70 --bs=${BS_RAND} --random_distribution=zipf:1.2 --randrepeat=0 --random_generator=tausworthe --iodepth=${IODEPTH_RAND}" ;;
  5) WL="hotwrite";  FIO_OPS="--rw=randwrite  --bs=${BS_RAND} --random_distribution=zipf:1.2 --randrepeat=0 --random_generator=tausworthe --iodepth=${IODEPTH_RAND}" ;;
  6) WL="randrw";    FIO_OPS="--rw=randrw --rwmixread=50 --bs=${BS_RAND} --iodepth=${IODEPTH_RAND}" ;;
  *) die "unsupported id: $CID";;
esac

echo "[PREP] (${CNAME}) mkdir ${TEST_DIR} & create ${FILE_SIZE} file"
docker exec "$CNAME" sh -lc "mkdir -p '${TEST_DIR}' && (fallocate -l '${FILE_SIZE}' '${TEST_FILE}' 2>/dev/null || dd if=/dev/zero of='${TEST_FILE}' bs=1M count=$(( ${FILE_SIZE%G} * 1024 )) status=none)"

REMOTE_JSON="/tmp/fio_c${CID}_${WL}.json"
REMOTE_LOG="/tmp/fio_c${CID}_${WL}.log"

FIO_CMD="fio --name=${WL} --filename=${TEST_FILE} ${FIO_OPS} --ioengine=libaio --direct=${DIRECT} \
  --time_based --runtime=${RUNTIME} --numjobs=1 --group_reporting=1 \
  --output-format=json --output=${REMOTE_JSON}"

echo "[RUN ] (${CNAME}) workload=${WL} runtime=${RUNTIME}s"
docker exec "$CNAME" sh -lc "{ ${FIO_CMD}; } 2>&1 | tee ${REMOTE_LOG}"

# 回拷结果
docker cp "${CNAME}:${REMOTE_JSON}" "${OUT_DIR}/"
docker cp "${CNAME}:${REMOTE_LOG}"  "${OUT_DIR}/" || true
[[ -s "${OUT_DIR}/$(basename "$REMOTE_JSON")" ]] || die "empty result JSON: ${OUT_DIR}/$(basename "$REMOTE_JSON")"

# 写 workload 映射，便于后续解析
WORKLOADS_JSON="${RESULT_ROOT}/workloads_single.json"
python3 - "$WORKLOADS_JSON" "$CID" "$WL" <<'PY'
import json,sys,os
p,cid,wl=sys.argv[1],sys.argv[2],sys.argv[3]
d={}
if os.path.exists(p):
    try: d=json.load(open(p))
    except: d={}
d[f"c{cid}"]=wl
json.dump(d,open(p,'w'),ensure_ascii=False,indent=2)
print(f"[INFO] updated {p}: c{cid}->{wl}")
PY

echo "[DONE] (${CNAME}) -> ${OUT_DIR}"
