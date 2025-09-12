#!/usr/bin/env bash
# run_multi_containers.sh (safe-clean, zero-parameter)
# 目录约定同上；一次性挂载 6 个 overlay 并发跑，结束后卸载并清理

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

mkdir -p "${RESULT_ROOT}/multi" "${WORK_ROOT}" "${MERGED_ROOT}"
for i in $(seq 1 6); do mkdir -p "${RESULT_ROOT}/multi/c${i}" "${WORK_ROOT}/c${i}" "${MERGED_ROOT}/c${i}"; done

summary_csv="${RESULT_ROOT}/multi/summary.csv"
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

trap 'for i in $(seq 1 6); do umount "${MERGED_ROOT}/c${i}" 2>/dev/null || true; done' EXIT

preflight_clean
check_mounts

# （提示）并发 6×8G 在 49G 盘上可能吃紧，这里只告警不强退
avail_mb=$(df -m --output=avail "${UPPER_ROOT}" | tail -1)
if [ "${avail_mb}" -lt 52000 ]; then
  echo "[WARN] upper 可用空间 ${avail_mb}MB 可能不足以并发 6×${TEST_FILE_SIZE}"
fi

# 1) 先卸载再挂载 overlay
for i in $(seq 1 6); do umount "${MERGED_ROOT}/c${i}" >/dev/null 2>&1 || true; done
for i in $(seq 1 6); do
  upper="${UPPER_ROOT}/c${i}"
  work="${WORK_ROOT}/c${i}"
  lower="${LOWER_ROOT}/c${i}"
  merged="${MERGED_ROOT}/c${i}"
  for d in "$upper" "$lower"; do [ -d "$d" ] || { echo "[ERROR] 缺少目录：$d"; exit 2; }; done
  mkdir -p "${work}"
  echo "MOUNT -> ${merged} (lower=${lower} upper=${upper} work=${work})"
  mount -t overlay overlay -o "lowerdir=${lower},upperdir=${upper},workdir=${work}" "$merged"
  mountpoint -q "$merged" || { echo "[FATAL] overlay mount failed: $merged"; exit 4; }
done

# 2) 并发 fio
pids=()
for i in $(seq 1 6); do
  merged="${MERGED_ROOT}/c${i}"
  outd="${RESULT_ROOT}/multi/c${i}"
  wl="${WORKLOADS[$((i-1))]}"
  rw="${RW[$wl]}"; bs="${BS[$wl]}"; iodepth="${IODEPTH[$wl]}"; extra="${EXTRA[$wl]}"
  mkdir -p "${merged}/_fio"
  echo "[FIO] c${i} wl=${wl} -> ${merged}/_fio/testfile"
  (
    fio --name="${wl}" --filename="${merged}/_fio/testfile" --size="${TEST_FILE_SIZE}" \
        --rw="${rw}" ${extra} --bs="${bs}" --iodepth="${iodepth}" \
        --ioengine="${IOENGINE}" --direct="${DIRECT}" --time_based --runtime="${RUNTIME}" \
        --group_reporting --output-format=json > "${outd}/fio_${wl}.json" 2> "${outd}/fio_${wl}.log"
  ) &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid"; done

# 3) 汇总（如有 python3）
for i in $(seq 1 6); do
  wl="${WORKLOADS[$((i-1))]}"
  json="${RESULT_ROOT}/multi/c${i}/fio_${wl}.json"
  if command -v python3 >/dev/null 2>&1 && [ -s "$json" ]; then
    python3 - "$i" "$i" "$json" "$summary_csv" <<'PY'
import json,sys,os,datetime,os.path
r,cid,jpath,csv=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
t=open(jpath,'rb').read().decode('utf-8','ignore')
data=json.loads(t)
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
done

# 4) 卸载并清理当次产生的文件
for i in $(seq 1 6); do umount "${MERGED_ROOT}/c${i}" >/dev/null 2>&1 || true; done
for i in $(seq 1 6); do
  rm -rf "${UPPER_ROOT}/c${i}/_fio" 2>/dev/null || true
  rm -f  "${UPPER_ROOT}/c${i}/testfile" 2>/dev/null || true
  rm -rf "${MERGED_ROOT}/c${i}/_fio" 2>/dev/null || true
  rm -f  "${MERGED_ROOT}/c${i}/testfile" 2>/dev/null || true
done

echo "[DONE] 并发完成 -> ${summary_csv}"
