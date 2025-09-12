#!/usr/bin/env bash
# run_single_containers.sh (safe-clean, zero-parameter)
# 目录约定（无需传参）：
#   upperdir : /mnt/docker/upper/c1..c6
#   workdir  : /mnt/docker/upper/work/c1..c6   （脚本自动创建；必须与 upper 同盘）
#   lowerdir : /mnt/docker/lower/c1..c6
#   merged   : /mnt/docker/merged/c1..c6       （挂载点，脚本自动创建）
# 仅依赖：fio、mount/umount、mountpoint；需 root 运行

set -euo pipefail

UPPER_ROOT="/mnt/docker/upper"
LOWER_ROOT="/mnt/docker/lower"
WORK_ROOT="/mnt/docker/upper/work"
MERGED_ROOT="/mnt/docker/merged"
RESULT_ROOT="./results_split"

RUNTIME=90
TEST_FILE_SIZE="8G"
IOENGINE="libaio"
DIRECT=1

WORKLOADS=(seqrw seqwrite randwrite hotrw hotwrite randrw)
declare -A RW BS IODEPTH EXTRA
RW[seqrw]="readwrite";    BS[seqrw]="128k"; IODEPTH[seqrw]=1;  EXTRA[seqrw]="--rwmixread=50"
RW[seqwrite]="write";     BS[seqwrite]="128k"; IODEPTH[seqwrite]=1; EXTRA[seqwrite]=""
RW[randwrite]="randwrite";BS[randwrite]="4k";  IODEPTH[randwrite]=32; EXTRA[randwrite]=""
RW[hotrw]="randrw";       BS[hotrw]="4k";  IODEPTH[hotrw]=32; EXTRA[hotrw]="--rwmixread=70 --random_distribution=zipf:1.2 --randrepeat=0"
RW[hotwrite]="randwrite"; BS[hotwrite]="4k"; IODEPTH[hotwrite]=32; EXTRA[hotwrite]="--random_distribution=zipf:1.2 --randrepeat=0"
RW[randrw]="randrw";      BS[randrw]="4k"; IODEPTH[randrw]=32; EXTRA[randrw]="--rwmixread=50"

need() { command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] 需要命令：$1"; exit 1; }; }
need fio; need mount; need umount; need mountpoint; need find

mkdir -p "${RESULT_ROOT}/single" "${WORK_ROOT}" "${MERGED_ROOT}"
for i in $(seq 1 6); do mkdir -p "${RESULT_ROOT}/single/c${i}" "${WORK_ROOT}/c${i}" "${MERGED_ROOT}/c${i}"; done

summary_csv="${RESULT_ROOT}/single/summary.csv"
echo "round,container,workload,bw_MBps,iops,lat_ms,json_path,timestamp" > "${summary_csv}"

preflight_clean() {
  echo "[CLEAN] 卸载 overlay 并清空历史测试文件"
  for i in $(seq 1 6); do umount "${MERGED_ROOT}/c${i}" 2>/dev/null || true; done
  find "${MERGED_ROOT}" -xdev -type f -name 'testfile*' -delete 2>/dev/null || true
  find "${MERGED_ROOT}" -maxdepth 2 -type d -name '_fio' -exec rm -rf {} + 2>/dev/null || true
  for i in $(seq 1 6); do
    rm -f  "${UPPER_ROOT}/c${i}/testfile" 2>/dev/null || true
    rm -rf "${UPPER_ROOT}/c${i}/_fio"     2>/dev/null || true
  done
}

check_mounts() {
  mountpoint -q "${UPPER_ROOT}" || { echo "[FATAL] ${UPPER_ROOT} 未挂载"; exit 3; }
  mountpoint -q "${LOWER_ROOT}" || { echo "[FATAL] ${LOWER_ROOT} 未挂载"; exit 3; }
}

parse_append() {
  local round="$1" cid="$2" jpath="$3" csv="$4"
  if command -v python3 >/dev/null 2>&1 && [ -s "$jpath" ]; then
    python3 - "$round" "$cid" "$jpath" "$csv" <<'PY'
import json,sys,os,datetime
r,cid,jpath,csv=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
t=open(jpath,'rb').read().decode('utf-8','ignore')
try: data=json.loads(t)
except: 
    data=None
    for i,ch in enumerate(t):
        if ch=='{':
            for j in range(len(t)-1,i,-1):
                if t[j]=='}':
                    try: data=json.loads(t[i:j+1]); break
                    except: pass
            if data: break
if not data: raise SystemExit(0)
job=(data.get('jobs') or [{}])[0]
rd=job.get('read') or {}; wr=job.get('write') or {}
def f(x): 
    try: return float(x)
    except: return 0.0
bw=(rd.get('bw_bytes') or 0)+(wr.get('bw_bytes') or 0)
if not bw: bw=(f(rd.get('bw',0))+f(wr.get('bw',0)))*1024
iops=f(rd.get('iops',0))+f(wr.get('iops',0))
src=wr.get('clat_ns') or wr.get('lat_ns') or job.get('clat_ns') or job.get('lat_ns')
lat=(float(src.get('mean',0))/1e6) if isinstance(src,dict) else 0.0
wl=os.path.basename(jpath).split('_')[-1].split('.')[0]
ts=datetime.datetime.now().isoformat(timespec='seconds')
with open(csv,'a') as f:
    f.write(f"{r},{cid},{wl},{bw/(1024*1024):.3f},{iops:.3f},{lat:.3f},{jpath},{ts}\n")
PY
  fi
}

trap 'for i in $(seq 1 6); do umount "${MERGED_ROOT}/c${i}" 2>/dev/null || true; done' EXIT

preflight_clean
check_mounts

for i in $(seq 1 6); do
  upper="${UPPER_ROOT}/c${i}"
  work="${WORK_ROOT}/c${i}"
  lower="${LOWER_ROOT}/c${i}"
  merged="${MERGED_ROOT}/c${i}"
  outd="${RESULT_ROOT}/single/c${i}"
  wl="${WORKLOADS[$((i-1))]}"
  rw="${RW[$wl]}"; bs="${BS[$wl]}"; iodepth="${IODEPTH[$wl]}"; extra="${EXTRA[$wl]}"

  for d in "$upper" "$lower"; do [ -d "$d" ] || { echo "[ERROR] 缺少目录：$d"; exit 2; }; done
  mkdir -p "${work}"

  umount "$merged" >/dev/null 2>&1 || true
  echo "===== [${i}/6] MOUNT -> ${merged} (lower=${lower} upper=${upper} work=${work}) ====="
  mount -t overlay overlay -o "lowerdir=${lower},upperdir=${upper},workdir=${work}" "$merged"
  mountpoint -q "$merged" || { echo "[FATAL] overlay mount failed: $merged"; exit 4; }

  mkdir -p "${merged}/_fio"
  echo "[FIO] c${i} wl=${wl} file=${merged}/_fio/testfile size=${TEST_FILE_SIZE} runtime=${RUNTIME}s"
  fio --name="${wl}" --filename="${merged}/_fio/testfile" --size="${TEST_FILE_SIZE}" \
      --rw="${rw}" ${extra} --bs="${bs}" --iodepth="${iodepth}" \
      --ioengine="${IOENGINE}" --direct="${DIRECT}" --time_based --runtime="${RUNTIME}" \
      --group_reporting --output-format=json > "${outd}/fio_${wl}.json" 2> "${outd}/fio_${wl}.log"

  parse_append "$i" "$i" "${outd}/fio_${wl}.json" "${summary_csv}"

  # 每轮结束后清理当轮文件，避免累计占用
  umount "$merged" || true
  rm -rf "${UPPER_ROOT}/c${i}/_fio" 2>/dev/null || true
  rm -f  "${UPPER_ROOT}/c${i}/testfile" 2>/dev/null || true
  rm -rf "${MERGED_ROOT}/c${i}/_fio" 2>/dev/null || true
  rm -f  "${MERGED_ROOT}/c${i}/testfile" 2>/dev/null || true
done

echo "[DONE] 单轮完成 -> ${summary_csv}"
