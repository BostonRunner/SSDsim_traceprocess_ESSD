#!/usr/bin/env bash
# run_multi_containers.sh  (修正版)
# 修复要点：
#  - 为每个容器保存自己的 FIO_TARGET / DOCKER_DEVICE_ARG，arm/wait 时按容器索引使用
#  - 若某容器 install_fio 失败则跳过该容器（记录日志），不让全体任务中断
#  - fio 使用 --direct=1, size=8G, time_based runtime
set -euo pipefail

ROOT="$(pwd)"
RESULT_ROOT="${RESULT_ROOT:-${ROOT}/results_all}"
TEST_ROOT_HOST="${TEST_ROOT_HOST:-/mnt/docker_tmp}"
OUT_SHARED_DIR="${OUT_SHARED_DIR:-${TEST_ROOT_HOST}/fio_out}"
CONTAINER_PREFIX="${CONTAINER_PREFIX:-docker_blktest}"
RUNTIME="${RUNTIME:-90}"
TEST_FILE_SIZE="${TEST_FILE_SIZE:-8G}"
FIO_LOCAL_BIN="${FIO_LOCAL_BIN:-./tools/fio}"
DEVICE="${DEVICE:-/dev/vdb}"

IMAGES=(
  "ubuntu:22.04"
  "opensuse/leap:15.5"
  "debian:11"
  "alpine:3.18"
  "archlinux:latest"
  "rockylinux:9"
)
WORKLOAD_MAP=(seqrw seqwrite randwrite hotrw hotwrite randrw)

declare -A RW BS IODEPTH EXTRA
RW[seqrw]="readwrite";  BS[seqrw]="128k"; IODEPTH[seqrw]=1;  EXTRA[seqrw]="--rwmixread=50"
RW[seqwrite]="write";    BS[seqwrite]="128k"; IODEPTH[seqwrite]=1; EXTRA[seqwrite]=""
RW[randwrite]="randwrite"; BS[randwrite]="4k"; IODEPTH[randwrite]=32; EXTRA[randwrite]=""
RW[hotrw]="randrw";      BS[hotrw]="4k"; IODEPTH[hotrw]=32; EXTRA[hotrw]="--rwmixread=70 --random_distribution=zipf:1.2 --randrepeat=0"
RW[hotwrite]="randwrite"; BS[hotwrite]="4k"; IODEPTH[hotwrite]=32; EXTRA[hotwrite]="--random_distribution=zipf:1.2 --randrepeat=0"
RW[randrw]="randrw";     BS[randrw]="4k"; IODEPTH[randrw]=32; EXTRA[randrw]="--rwmixread=50"

command -v docker >/dev/null 2>&1 || { echo "[ERROR] docker required"; exit 1; }
command -v python3 >/dev/null 2>&1 || echo "[WARN] python3 missing; summarizer will be skipped"

mkdir -p "${RESULT_ROOT}" "${OUT_SHARED_DIR}"

get_backing_source(){
  local host_dir="$1"
  if command -v findmnt >/dev/null 2>&1; then
    findmnt -n -o SOURCE --target "$host_dir" 2>/dev/null || true
  else
    df -P "$host_dir" 2>/dev/null | awk 'NR==2{print $1}'
  fi
}

pull_if_missing(){
  img="$1"
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    echo "[PULL] $img"
    docker pull "$img"
  else
    echo "[HAVE] $img"
  fi
}

# Robust install_fio from your version (keeps local binary injection fallback)
install_fio() {
  local cname="$1"
  local image="$2"
  local cid=""
  if [[ "$cname" =~ ([0-9]+)$ ]]; then cid="${BASH_REMATCH[1]}"; fi
  local outdir="${RESULT_ROOT}/c${cid}"
  mkdir -p "$outdir"

  echo "[INSTALL] try install fio in ${cname} (${image})..."
  local remote_log="/out/install_fio.log"
  docker exec "$cname" sh -lc "mkdir -p /out" >/dev/null 2>&1 || true
  docker exec "$cname" sh -lc "rm -f ${remote_log} || true" >/dev/null 2>&1 || true

  if [[ -n "${FIO_LOCAL_BIN:-}" && -x "${FIO_LOCAL_BIN}" ]]; then
    echo "[FALLBACK-FIRST] injecting local fio binary into ${cname}..."
    docker cp "${FIO_LOCAL_BIN}" "${cname}:/usr/local/bin/fio" >/dev/null 2>&1 || true
    docker exec "$cname" sh -lc "chmod +x /usr/local/bin/fio || true"
    docker cp "${cname}:${remote_log}" "${outdir}/install_fio.log" >/dev/null 2>&1 || true
    if docker exec "$cname" sh -lc 'command -v fio >/dev/null 2>&1'; then
      echo "[OK] injected local fio into ${cname}"
      return 0
    fi
    echo "[WARN] injected binary not usable in ${cname}, will try package managers"
  fi

  set +e
  docker exec "$cname" sh -lc "command -v apt-get >/dev/null 2>&1 && (apt-get -o Acquire::Retries=3 update >>${remote_log} 2>&1 || true; DEBIAN_FRONTEND=noninteractive apt-get install -y fio libaio1 >>${remote_log} 2>&1 || true)" >/dev/null 2>&1
  docker exec "$cname" sh -lc "command -v apk >/dev/null 2>&1 && (apk update >>${remote_log} 2>&1 || true; apk add --no-cache fio libaio >>${remote_log} 2>&1 || true)" >/dev/null 2>&1
  docker exec "$cname" sh -lc "command -v dnf >/dev/null 2>&1 && (dnf -y install fio libaio >>${remote_log} 2>&1 || (dnf -y install epel-release >>${remote_log} 2>&1 && dnf -y install fio libaio >>${remote_log} 2>&1) || true)" >/dev/null 2>&1
  docker exec "$cname" sh -lc "command -v microdnf >/dev/null 2>&1 && (microdnf -y install fio >>${remote_log} 2>&1 || true)" >/dev/null 2>&1
  docker exec "$cname" sh -lc "command -v yum >/dev/null 2>&1 && (yum -y install fio libaio >>${remote_log} 2>&1 || (yum -y install epel-release >>${remote_log} 2>&1 && yum -y install fio libaio >>${remote_log} 2>&1) || true)" >/dev/null 2>&1
  docker exec "$cname" sh -lc "command -v zypper >/dev/null 2>&1 && (zypper --non-interactive refresh >>${remote_log} 2>&1 || true; zypper --non-interactive install -y fio libaio >>${remote_log} 2>&1 || true)" >/dev/null 2>&1

  # pacman special handling
  docker exec "$cname" sh -lc "command -v pacman >/dev/null 2>&1 && (pacman -Sy --noconfirm --noprogressbar fio >>${remote_log} 2>&1 || (pacman -Syu --noconfirm --noprogressbar >>${remote_log} 2>&1 || true; pacman-key --init >>${remote_log} 2>&1 || true; pacman-key --populate archlinux >>${remote_log} 2>&1 || true; pacman -Sy --noconfirm --noprogressbar fio >>${remote_log} 2>&1 || true))" >/dev/null 2>&1 || true

  docker cp "${cname}:${remote_log}" "${outdir}/install_fio.log" >/dev/null 2>&1 || true
  docker exec "$cname" sh -lc 'command -v fio >/dev/null 2>&1'
  rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    echo "[OK] fio installed in ${cname}"
    return 0
  fi

  if [[ -n "${FIO_LOCAL_BIN:-}" && -x "${FIO_LOCAL_BIN}" ]]; then
    echo "[LAST-RESORT] try inject local fio binary again..."
    docker cp "${FIO_LOCAL_BIN}" "${cname}:/usr/local/bin/fio" >/dev/null 2>&1 || true
    docker exec "$cname" sh -lc "chmod +x /usr/local/bin/fio || true"
    docker cp "${cname}:${remote_log}" "${outdir}/install_fio.log" >/dev/null 2>&1 || true
    if docker exec "$cname" sh -lc 'command -v fio >/dev/null 2>&1'; then
      echo "[OK] injected local fio into ${cname}"
      return 0
    fi
  fi

  echo "[ERROR] fio not available in ${cname} after install attempts"
  echo "[NOTE] copied remote log (if any) to ${outdir}/install_fio.log"
  return 2
}

# prepare per-container arrays
declare -A CONTAINER_FIO_TARGET
declare -A CONTAINER_DEVICE_ARG
declare -A CONTAINER_IMG
declare -A CONTAINER_WORKLOAD
declare -A CONTAINER_ENABLED

# prepare containers
for i in $(seq 1 6); do
  img="${IMAGES[$i-1]}"
  wl="${WORKLOAD_MAP[$i-1]}"
  cname="${CONTAINER_PREFIX}${i}"
  host_test_dir="${TEST_ROOT_HOST}/test_c${i}"
  outdir="${RESULT_ROOT}/${cname}"
  mkdir -p "${host_test_dir}" "${outdir}"
  rm -rf "${host_test_dir:?}/"* || true

  pull_if_missing "$img"

  docker rm -f "$cname" >/dev/null 2>&1 || true

  backing=$(get_backing_source "${host_test_dir}")
  DOCKER_DEVICE_ARG=""
  FIO_TARGET="/data/testfile"
  if [[ -n "$backing" && "$backing" =~ ^/dev/ ]]; then
    DOCKER_DEVICE_ARG="--device=${backing}:${backing}"
    FIO_TARGET="${backing}"
    echo "[INFO] host dir ${host_test_dir} backed by ${backing} -> exposing ${backing} into ${cname}"
  else
    echo "[INFO] host dir ${host_test_dir} not backed by block device; using file target /data/testfile for ${cname}"
  fi

  echo "[RUN] starting ${cname} (image=${img})"
  docker run -d --name "$cname" ${DOCKER_DEVICE_ARG} -v "${host_test_dir}:/data" -v "${OUT_SHARED_DIR}:/out" "$img" sh -c 'tail -f /dev/null'
  # record per-container values
  CONTAINER_FIO_TARGET[$i]="$FIO_TARGET"
  CONTAINER_DEVICE_ARG[$i]="$DOCKER_DEVICE_ARG"
  CONTAINER_IMG[$i]="$img"
  CONTAINER_WORKLOAD[$i]="$wl"
  CONTAINER_ENABLED[$i]=1

  # ensure fio; if failed, mark disabled and continue
  if ! install_fio "$cname" "$img" "${outdir}"; then
    echo "[ERROR] install_fio failed for ${cname}, see ${outdir}/install_fio.log; disabling this container run"
    CONTAINER_ENABLED[$i]=0
    docker cp "${cname}:/out/install_fio.log" "${outdir}/" >/dev/null 2>&1 || true
    docker rm -f "$cname" >/dev/null 2>&1 || true
    # leave loop to continue preparing other containers
  fi
done

# Arm waiters: for each enabled container we exec a wait+fio command that uses that container's FIO_TARGET
for i in $(seq 1 6); do
  if [[ "${CONTAINER_ENABLED[$i]}" != "1" ]]; then
    echo "[SKIP] container ${CONTAINER_PREFIX}${i} disabled, skipping arm"
    continue
  fi
  wl="${CONTAINER_WORKLOAD[$i]}"
  cname="${CONTAINER_PREFIX}${i}"
  rw="${RW[$wl]}"; bs="${BS[$wl]}"; iodepth="${IODEPTH[$wl]}"; extra="${EXTRA[$wl]}"
  target="${CONTAINER_FIO_TARGET[$i]}"
  fio_cmd="fio --name='${wl}' --filename='${target}' --size=${TEST_FILE_SIZE} --rw='${rw}' ${extra} --bs='${bs}' --iodepth=${iodepth} --ioengine=libaio --direct=1 --invalidate=1 --time_based --runtime=${RUNTIME} --group_reporting --output-format=json >/out/fio_${wl}.json 2>/out/fio_${wl}.log"
  cmd="while [ ! -f /out/_start ]; do sleep 0.05; done; ${fio_cmd}"
  echo "[ARM] ${cname} armed (target=${target})"
  docker exec -d "$cname" sh -lc "$cmd" || true
done

# prepare iostat and trigger
rm -f "${OUT_SHARED_DIR}/_start" >/dev/null 2>&1 || true
IOSTAT_LOG="${RESULT_ROOT}/multi_iostat_vdb.log"
if command -v iostat >/dev/null 2>&1; then
  echo "[IOSTAT] starting iostat for ${DEVICE} -> ${IOSTAT_LOG}"
  iostat -x -k 1 "${DEVICE}" > "${IOSTAT_LOG}" 2>&1 & echo $! > "${RESULT_ROOT}/iostat_pid"
else
  echo "[IOSTAT] iostat not found; host-level metrics not collected"
fi

sleep 1
echo "[TRIGGER] releasing barrier -> touch ${OUT_SHARED_DIR}/_start"
touch "${OUT_SHARED_DIR}/_start"

# wait for JSON outputs and collect (map workload -> container index to place file)
timeout=$((RUNTIME + 120))
for i in $(seq 1 6); do
  wl="${CONTAINER_WORKLOAD[$i]}"
  outdir="${RESULT_ROOT}/${CONTAINER_PREFIX}${i}"
  mkdir -p "${outdir}"
  if [[ "${CONTAINER_ENABLED[$i]}" != "1" ]]; then
    echo "[SKIP] c${i} disabled, no outputs expected"
    continue
  fi
  waitfile="${OUT_SHARED_DIR}/fio_${wl}.json"
  waited=0
  echo "[WAIT] waiting for ${waitfile} for container c${i}"
  while [[ ! -s "${waitfile}" && $waited -lt $timeout ]]; do
    sleep 1
    waited=$((waited+1))
  done
  if [[ -s "${waitfile}" ]]; then
    mv "${waitfile}" "${outdir}/fio_${CONTAINER_PREFIX}${i}_${wl}.json"
  else
    echo "[WARN] missing json for ${CONTAINER_PREFIX}${i} ${wl}"
  fi
  if [[ -f "${OUT_SHARED_DIR}/fio_${wl}.log" ]]; then mv "${OUT_SHARED_DIR}/fio_${wl}.log" "${outdir}/" || true; fi
done

# stop iostat
if [[ -f "${RESULT_ROOT}/iostat_pid" ]]; then
  kill "$(cat "${RESULT_ROOT}/iostat_pid")" 2>/dev/null || true
  rm -f "${RESULT_ROOT}/iostat_pid"
fi

# fetch install logs
for i in $(seq 1 6); do
  outdir="${RESULT_ROOT}/${CONTAINER_PREFIX}${i}"
  docker cp "${CONTAINER_PREFIX}${i}:/out/install_fio.log" "${outdir}/" >/dev/null 2>&1 || true
done

# run summarizer
if command -v python3 >/dev/null 2>&1 && [[ -f "${ROOT}/summarize.py" ]]; then
  echo "[SUMMARIZE] running summarize.py"
  python3 "${ROOT}/summarize.py"
else
  echo "[SUMMARIZE] skip (python3 or summarize.py missing)"
fi

echo "[CLEANUP] removing containers (best-effort)"
for i in $(seq 1 6); do docker rm -f "${CONTAINER_PREFIX}${i}" >/dev/null 2>&1 || true; done

echo "[DONE] concurrent run finished. Results in ${RESULT_ROOT}"
