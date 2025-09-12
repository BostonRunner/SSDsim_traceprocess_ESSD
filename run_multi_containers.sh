#!/usr/bin/env bash
# 并发跑 + 安全清理（final layout）

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
for i in $(seq 1 6); do mkdir -p "${RESULT_ROOT}/multi/c${i}" "${MERGED_ROOT}/c${i}" "${UPPER_ROOT}/c${i}/"{upper,work} ; done

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
  mountpoint -q "${LOWER_ROOT}" || { echo "[FATAL] ${LOWER_ROOT} 未挂载（应为 /dev/vdb）"; exit 3; }
  for i in $(seq 1 6); do
    mountpoint -q "${UPPER_ROOT}/c${i}" || { echo "[FATAL] ${UPPER_ROOT}/c${i} 未挂载（应为 /dev/vdc..vdh）"; exit 3; }
    [ -d "${LOWER_ROOT}/c${i}" ] || { echo "[FATAL] 缺少目录：${LOWER_ROOT}/c${i}"; exit 3; }
    mkdir -p "${UPPER_ROOT}/c${i}/"{upper,work}
  done
}

trap 'for i in $(seq 1 6); do umount "${MERGED_ROOT}/c${i}" 2>/dev/null || true; done' EXIT

preflight_clean
check_mounts

# 1) 挂载 6 个 overlay
for i in $(seq 1 6); do umount "${MERGED_ROOT}/c${i}" >/dev/null 2>&1 || true; done
for i in $(seq 1 6); do
  upper_base="${UPPER_ROOT}/c${i}"
  upper="${upper_base}/upper"
  work="${upper_base}/work"
  lower="${LOWER_ROOT}/c${i}"
  merged="${MERGED_ROOT}/c${i}"
  for d in "$upper_base" "$lower" "$upper" "$work"; do [ -d "$d" ] || { echo "[ERROR] 缺少目录：$d"; exit 2; }; done
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

# 3) 卸载并清理
for i in $(seq 1 6); do umount "${MERGED_ROOT}/c${i}" >/dev/null 2>&1 || true; done
for i in $(seq 1 6); do
  upper="${UPPER_ROOT}/c${i}/upper"
  rm -rf "${upper}/_fio" 2>/dev/null || true
  rm -f  "${upper}/testfile" 2>/dev/null || true
  rm -rf "${MERGED_ROOT}/c${i}/_fio" 2>/dev/null || true
  rm -f  "${MERGED_ROOT}/c${i}/testfile" 2>/dev/null || true
done

echo "[DONE] 并发完成 -> ${summary_csv}"
