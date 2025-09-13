#!/usr/bin/env bash
# run_multi_containers.sh (final layout, safe-clean, robust CSV)

set -euo pipefail

UPPER_ROOT="/mnt/docker/upper"
LOWER_ROOT="/mnt/docker/lower"
MERGED_ROOT="/mnt/docker/merged"
RESULT_ROOT="./results_split"

RUNTIME=90
TEST_FILE_SIZE="8G"
IOENGINE="libaio"
DIRECT=1

WORKLOADS=(seqrw seqwrite randwrite hotrw hotwrite randrw)
declare -A RW BS IODEPTH EXTRA
RW[seqrw]="readwrite";     BS[seqrw]="128k"; IODEPTH[seqrw]=1;  EXTRA[seqrw]="--rwmixread=50"
RW[seqwrite]="write";      BS[seqwrite]="128k"; IODEPTH[seqwrite]=1; EXTRA[seqwrite]=""
RW[randwrite]="randwrite"; BS[randwrite]="4k";  IODEPTH[randwrite]=32; EXTRA[randwrite]=""
RW[hotrw]="randrw";        BS[hotrw]="4k";  IODEPTH[hotrw]=32; EXTRA[hotrw]="--rwmixread=70 --random_distribution=zipf:1.2 --randrepeat=0"
RW[hotwrite]="randwrite";  BS[hotwrite]="4k";  IODEPTH[hotwrite]=32; EXTRA[hotwrite]="--random_distribution=zipf:1.2 --randrepeat=0"
RW[randrw]="randrw";       BS[randrw]="4k";  IODEPTH[randrw]=32; EXTRA[randrw]="--rwmixread=50"

need() { command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] 需要命令：$1"; exit 1; }; }
need fio; need mount; need umount; need mountpoint; need find

mkdir -p "${RESULT_ROOT}/multi" "${MERGED_ROOT}"
for i in $(seq 1 6); do mkdir -p "${RESULT_ROOT}/multi/c${i}" "${MERGED_ROOT}/c${i}" "${UPPER_ROOT}/c${i}"/{upper,work}; done

summary_csv="${RESULT_ROOT}/multi/summary.csv"
echo "round,container,workload,bw_MBps,iops,lat_ms,json_path,timestamp" > "${summary_csv}"

preflight_clean() {
  echo "[CLEAN] 卸载 overlay 并清空历史测试文件"
  for i in $(seq 1 6); do umount "${MERGED_ROOT}/c${i}" 2>/dev/null || true; done
  find "${MERGED_ROOT}" -xdev -type f -name 'testfile*' -delete 2>/dev/null || true
  find "${MERGED_ROOT}" -maxdepth 2 -type d -name '_fio' -exec rm -rf {} + 2>/dev/null || true
  for i in $(seq 1 6); do
    rm -f  "${UPPER_ROOT}/c${i}/upper/testfile" 2>/dev/null || true
    rm -rf "${UPPER_ROOT}/c${i}/upper/_fio"     2>/dev/null || true
  done
}

check_mounts() {
  mountpoint -q "${LOWER_ROOT}" || { echo "[FATAL] ${LOWER_ROOT} 未挂载（/dev/vdb）"; exit 3; }
  for i in $(seq 1 6); do
    mountpoint -q "${UPPER_ROOT}/c${i}" || { echo "[FATAL] ${UPPER_ROOT}/c${i} 未挂载（/dev/vdc..vdh）"; exit 3; }
    [ -d "${LOWER_ROOT}/c${i}" ] || { echo "[FATAL] 缺少目录：${LOWER_ROOT}/c${i}"; exit 3; }
    mkdir -p "${UPPER_ROOT}/c${i}"/{upper,work}
  done
}

# 统一的稳健汇总（Python → jq → awk）
parse_append() {
  local round="$1" cid="$2" wl="$3" jpath="$4" csv="$5"
  [ -s "$jpath" ] || return 0
  if command -v python3 >/dev/null 2>&1; then
python3 - "$round" "$cid" "$wl" "$jpath" "$csv" <<'PY' || true
import json,sys,datetime,os
r,cid,wl,jpath,csv=sys.argv[1:]
t=open(jpath,'rb').read().decode('utf-8','ignore')
data=None
try:
  data=json.loads(t)
except:
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
src=wr.get('clat_ns') or wr.get('lat_ns') or job.get('clat_ns') or job.get('lat_ns') or {}
lat=(float(src.get('mean',0))/1e6) if isinstance(src,dict) else 0.0
ts=datetime.datetime.now().isoformat(timespec='seconds')
with open(csv,'a') as f:
  f.write(f"{r},{cid},{wl},{bw/(1024*1024):.3f},{iops:.3f},{lat:.3f},{jpath},{ts}\n")
PY
    if [ $? -eq 0 ]; then return 0; fi
  fi
  if command -v jq >/dev/null 2>&1; then
    local BW IOPS LAT
    BW=$(jq -r '(.jobs[0].read.bw_bytes // 0) + (.jobs[0].write.bw_bytes // 0)' "$jpath" 2>/dev/null || echo 0)
    IOPS=$(jq -r '((.jobs[0].read.iops // 0) + (.jobs[0].write.iops // 0))' "$jpath" 2>/dev/null || echo 0)
    LAT=$(jq -r '(.jobs[0].write.clat_ns.mean // .jobs[0].lat_ns.mean // 0)' "$jpath" 2>/dev/null || echo 0)
    printf "%s,%s,%s,%.3f,%.3f,%.3f,%s,%s\n" \
      "$round" "$cid" "$wl" "$(awk -v b="$BW" 'BEGIN{print b/1024/1024}')" \
      "$IOPS" "$(awk -v n="$LAT" 'BEGIN{print n/1e6}')" \
      "$jpath" "$(date -Iseconds)" >> "$csv"
    return 0
  fi
  # 纯 Bash/awk 兜底
  local BW IOPS LAT
  BW=$(awk 'match($0,/"bw_bytes":[[:space:]]*([0-9]+)/,a){s+=a[1]} END{print s+0}' "$jpath" 2>/dev/null || echo 0)
  IOPS=$(awk 'match($0,/"iops":[[:space:]]*([0-9]+(\.[0-9]+)?)/,a){s+=a[1]} END{printf "%.3f\n", s+0}' "$jpath" 2>/dev/null || echo 0)
  LAT=$(awk 'match($0,/"clat_ns":[[:space:]]*{[^}]*"mean":[[:space:]]*([0-9]+)/,a){m=a[1]} END{print (m?m:0)}' "$jpath" 2>/dev/null || echo 0)
  printf "%s,%s,%s,%.3f,%.3f,%.3f,%s,%s\n" \
    "$round" "$cid" "$wl" "$(awk -v b="$BW" 'BEGIN{print b/1024/1024}')" \
    "$IOPS" "$(awk -v n="$LAT" 'BEGIN{print n/1e6}')" \
    "$jpath" "$(date -Iseconds)" >> "$csv"
}

trap 'for i in $(seq 1 6); do umount "${MERGED_ROOT}/c${i}" 2>/dev/null || true; done' EXIT

preflight_clean
check_mounts

# 1) 批量挂载
for i in $(seq 1 6); do umount "${MERGED_ROOT}/c${i}" >/dev/null 2>&1 || true; done
for i in $(seq 1 6); do
  base="${UPPER_ROOT}/c${i}"
  upper="${base}/upper"
  work="${base}/work"
  lower="${LOWER_ROOT}/c${i}"
  merged="${MERGED_ROOT}/c${i}"
  for d in "$base" "$lower" "$upper" "$work"; do [ -d "$d" ] || { echo "[ERROR] 缺少目录：$d"; exit 2; }; done
  rm -rf "${work}" 2>/dev/null || true; mkdir -p "${work}"
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

# 3) 汇总（稳健）
for i in $(seq 1 6); do
  wl="${WORKLOADS[$((i-1))]}"
  json="${RESULT_ROOT}/multi/c${i}/fio_${wl}.json"
  parse_append "$i" "$i" "$wl" "$json" "$summary_csv"
done

# 4) 卸载并清理
for i in $(seq 1 6); do umount "${MERGED_ROOT}/c${i}" >/dev/null 2>&1 || true; done
for i in $(seq 1 6); do
  rm -rf "${UPPER_ROOT}/c${i}/upper/_fio" 2>/dev/null || true
  rm -f  "${UPPER_ROOT}/c${i}/upper/testfile" 2>/dev/null || true
  rm -rf "${MERGED_ROOT}/c${i}/_fio" 2>/dev/null || true
  rm -f  "${MERGED_ROOT}/c${i}/testfile" 2>/dev/null || true
done

echo "[DONE] 并发完成 -> ${summary_csv}"
