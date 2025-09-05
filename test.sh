#!/usr/bin/env bash
# Run FIO for a single container (by id 1..6 or full name docker_blktestN)
# 单轮只针对一个容器：准备 -> 安装fio(若无) -> 生成测试文件 -> 跑fio -> 回拷JSON/LOG
set -euo pipefail

# -------- Config (env可覆盖) ----------
RESULT_ROOT="${RESULT_ROOT:-./results_all}"
FILE_SIZE="${FILE_SIZE:-1G}"
RUNTIME="${RUNTIME:-30}"
DIRECT=1
# 顺序/随机参数
BS_SEQ="${BS_SEQ:-128k}"
IODEPTH_SEQ="${IODEPTH_SEQ:-1}"
BS_RAND="${BS_RAND:-16k}"
IODEPTH_RAND="${IODEPTH_RAND:-16}"
# 可自定义镜像源（默认阿里云 https）
APT_MIRROR="${APT_MIRROR:-https://mirrors.aliyun.com}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://mirrors.aliyun.com/debian}"
ALPINE_MIRROR_MAIN="${ALPINE_MIRROR_MAIN:-https://mirrors.aliyun.com/alpine/latest-stable/main}"
ALPINE_MIRROR_COMM="${ALPINE_MIRROR_COMM:-https://mirrors.aliyun.com/alpine/latest-stable/community}"
# --------------------------------------

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

# 映射：与并发6容器一致
case "$CID" in
  1) WL="seqrw";     FIO_OPS="--rw=readwrite --rwmixread=50 --bs=${BS_SEQ}  --iodepth=${IODEPTH_SEQ}" ;;
  2) WL="seqwrite";  FIO_OPS="--rw=write      --bs=${BS_SEQ}  --iodepth=${IODEPTH_SEQ}" ;;
  3) WL="randwrite"; FIO_OPS="--rw=randwrite  --bs=${BS_RAND} --iodepth=${IODEPTH_RAND}" ;;
  4) WL="hotrw";     FIO_OPS="--rw=randrw --rwmixread=70 --bs=${BS_RAND} --random_distribution=zipf:1.2 --randrepeat=0 --random_generator=tausworthe --iodepth=${IODEPTH_RAND}" ;;
  5) WL="hotwrite";  FIO_OPS="--rw=randwrite  --bs=${BS_RAND} --random_distribution=zipf:1.2 --randrepeat=0 --random_generator=tausworthe --iodepth=${IODEPTH_RAND}" ;;
  6) WL="randrw";    FIO_OPS="--rw=randrw --rwmixread=50 --bs=${BS_RAND} --iodepth=${IODEPTH_RAND}" ;;
  *) die "unsupported container id: $CID (expect 1..6)";;
esac

# ---- 在容器内安装 fio（自动切换阿里云镜像；已装则跳过） ----
echo "[INFO] (${CNAME}) ensure fio installed via Aliyun mirrors..."
docker exec "$CNAME" sh -s <<'EOS' || true
set -e
if command -v fio >/dev/null 2>&1; then exit 0; fi

ID=""; CODENAME=""
if [ -f /etc/os-release ]; then
  . /etc/os-release
fi

# 优先用 https，顺带强制 IPv4
if [ -d /etc/apt/apt.conf.d ]; then
  echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4 || true
fi

case "$ID" in
  ubuntu)
    CN="${VERSION_CODENAME:-jammy}"
    cat >/etc/apt/sources.list <<EOF
deb ${APT_MIRROR}/ubuntu ${CN} main restricted universe multiverse
deb ${APT_MIRROR}/ubuntu ${CN}-updates main restricted universe multiverse
deb ${APT_MIRROR}/ubuntu ${CN}-security main restricted universe multiverse
deb ${APT_MIRROR}/ubuntu ${CN}-backports main restricted universe multiverse
EOF
    apt-get clean
    apt-get update -o Acquire::Retries=3
    DEBIAN_FRONTEND=noninteractive apt-get install -y fio
    ;;
  debian)
    CN="${VERSION_CODENAME:-bookworm}"
    cat >/etc/apt/sources.list <<EOF
deb ${DEBIAN_MIRROR} ${CN} main contrib non-free non-free-firmware
deb ${DEBIAN_MIRROR} ${CN}-updates main contrib non-free non-free-firmware
deb ${DEBIAN_MIRROR}-security ${CN}-security main contrib non-free non-free-firmware
EOF
    apt-get clean
    apt-get update -o Acquire::Retries=3
    DEBIAN_FRONTEND=noninteractive apt-get install -y fio
    ;;
  alpine)
    printf "%s\n%s\n" "${ALPINE_MIRROR_MAIN}" "${ALPINE_MIRROR_COMM}" > /etc/apk/repositories
    apk update
    apk add --no-cache fio
    ;;
  rocky|rhel|centos|almalinux|fedora)
    if command -v dnf >/dev/null 2>&1; then dnf -y install fio || true; fi
    if command -v yum >/dev/null 2>&1; then yum -y install fio || true; fi
    ;;
  opensuse*|sles)
    zypper --non-interactive ref || true
    zypper --non-interactive in -y fio || true
    ;;
  arch)
    pacman -Sy --noconfirm fio || true
    ;;
  *)
    # 尝试常见包管工具
    (apt-get update -o Acquire::Retries=3 && DEBIAN_FRONTEND=noninteractive apt-get install -y fio) \
    || (apk add --no-cache fio) \
    || (zypper --non-interactive in -y fio) \
    || (dnf -y install fio || yum -y install fio || true) \
    || true
    ;;
esac
EOS

# 二次校验
if ! docker exec "$CNAME" sh -lc 'command -v fio >/dev/null 2>&1'; then
  die "fio not available in container ${CNAME} after mirror switch. Check egress or use an image自带fio。"
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

# 记录映射（可供别的汇总脚本使用）
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
