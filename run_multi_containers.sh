#!/usr/bin/env bash
# run_multi_containers.sh
# 并发 6 容器测试：upper/lower 分盘（upper->/mnt/docker/upper/c*，lower->/mnt/docker/lower/c*）
# 使用 nerdctl --rootfs，把手动挂载的 overlay 当作根；用 _start 屏障同步开跑。

set -euo pipefail

UPPER_ROOT="${UPPER_ROOT:-/mnt/docker/upper}"
LOWER_ROOT="${LOWER_ROOT:-/mnt/docker/lower}"
MERGED_ROOT="${MERGED_ROOT:-/mnt/docker/merged}"
RESULT_ROOT="${RESULT_ROOT:-./results_split}"
ROUND_TAG="${ROUND_TAG:-multi}"
OUT_DIR="${RESULT_ROOT}/${ROUND_TAG}"

RUNTIME="${RUNTIME:-90}"
TEST_FILE_SIZE="${TEST_FILE_SIZE:-8G}"
IOENGINE="${IOENGINE:-libaio}"
DIRECT="${DIRECT:-1}"
DEVICE="${DEVICE:-/dev/vdb}"   # 可选：iostat 观察 upper 盘

WORKLOADS=(seqrw seqwrite randwrite hotrw hotwrite randrw)

declare -A RW BS IODEPTH EXTRA
RW[seqrw]="readwrite";   BS[seqrw]="128k"; IODEPTH[seqrw]=1;  EXTRA[seqrw]="--rwmixread=50"
RW[seqwrite]="write";    BS[seqwrite]="128k"; IODEPTH[seqwrite]=1; EXTRA[seqwrite]=""
RW[randwrite]="randwrite"; BS[randwrite]="4k"; IODEPTH[randwrite]=32; EXTRA[randwrite]=""
RW[hotrw]="randrw";      BS[hotrw]="4k"; IODEPTH[hotrw]=32; EXTRA[hotrw]="--rwmixread=70 --random_distribution=zipf:1.2 --randrepeat=0"
RW[hotwrite]="randwrite"; BS[hotwrite]="4k"; IODEPTH[hotwrite]=32; EXTRA[hotwrite]="--random_distribution=zipf:1.2 --randrepeat=0"
RW[randrw]="randrw";     BS[randrw]="4k"; IODEPTH[randrw]=32; EXTRA[randrw]="--rwmixread=50"

need() { command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] 需要命令：$1"; exit 1; }; }
need nerdctl
need mount
need umount

mkdir -p "${OUT_DIR}" "${MERGED_ROOT}"

# 安装 fio
install_fio() {
  local cname="$1"
  if nerdctl exec "$cname" sh -lc 'command -v fio >/dev/null 2>&1'; then return 0; fi
  local log="/out/install_fio.log"
  nerdctl exec "$cname" sh -lc "mkdir -p /out" || true
  set +e
  nerdctl exec "$cname" sh -lc "command -v apt-get >/dev/null 2>&1 && (apt-get -o Acquire::Retries=3 update >>${log} 2>&1 || true; DEBIAN_FRONTEND=noninteractive apt-get install -y fio libaio1 >>${log} 2>&1 || true)" >/dev/null 2>&1
  nerdctl exec "$cname" sh -lc "command -v apk >/dev/null 2>&1 && (apk update >>${log} 2>&1 || true; apk add --no-cache fio libaio >>${log} 2>&1 || true)" >/dev/null 2>&1
  nerdctl exec "$cname" sh -lc "command -v dnf >/dev/null 2>&1 && (dnf -y install fio libaio >>${log} 2>&1 || (dnf -y install epel-release >>${log} 2>&1 && dnf -y install fio libaio >>${log} 2>&1) || true)" >/dev/null 2>&1
  nerdctl exec "$cname" sh -lc "command -v microdnf >/dev/null 2>&1 && (microdnf -y install fio >>${log} 2>&1 || true)" >/dev/null 2>&1
  nerdctl exec "$cname" sh -lc "command -v yum >/dev/null 2>&1 && (yum -y install fio libaio >>${log} 2>&1 || (yum -y install epel-release >>${log} 2>&1 && yum -y install fio libaio >>${log} 2>&1) || true)" >/dev/null 2>&1
  nerdctl exec "$cname" sh -lc "command -v zypper >/dev/null 2>&1 && (zypper --non-interactive refresh >>${log} 2>&1 || true; zypper --non-interactive install -y fio libaio >>${log} 2>&1 || true)" >/dev/null 2>&1
  set -e
  nerdctl exec "$cname" sh -lc 'command -v fio >/dev/null 2>&1'
}

# 挂载 overlay 并启动容器
for i in $(seq 1 6); do
  cname="ovsplit_c${i}"
  upper="${UPPER_ROOT}/c${i}/upper"
  work="${UPPER_ROOT}/c${i}/work"
  lower="${LOWER_ROOT}/c${i}"
  merged="${MERGED_ROOT}/c${i}"

  [ -d "${lower}" ] || { echo "[ERROR] 缺少 lower: ${lower}"; exit 2; }
  sudo mkdir -p "${upper}" "${work}" "${merged}/out"

  sudo umount "${merged}" >/dev/null 2>&1 || true
  sudo mount -t overlay overlay -o "lowerdir=${lower},upperdir=${upper},workdir=${work}" "${merged}"

  nerdctl rm -f "${cname}" >/dev/null 2>&1 || true
  nerdctl run -d --name "${cname}" --rootfs "${merged}" sh -c 'tail -f /dev/null'
done

# 安装 fio
for i in $(seq 1 6); do install_fio "ovsplit_c${i}" || true; done

# iostat（可选）
if command -v iostat >/dev/null 2>&1; then
  iostat -x -k 1 "${DEVICE}" > "${OUT_DIR}/iostat_${DEVICE##*/}.log" 2>&1 & echo $! > "${OUT_DIR}/iostat.pid"
fi

# 预置命令等待触发
for i in $(seq 1 6); do
  cname="ovsplit_c${i}"
  wl="${WORKLOADS[$((i-1))]}"
  rw="${RW[$wl]}"; bs="${BS[$wl]}"; iodepth="${IODEPTH[$wl]}"; extra="${EXTRA[$wl]}"
  nerdctl exec -d "${cname}" sh -lc "while [ ! -f /out/_start ]; do sleep 0.05; done; mkdir -p /opt; fio --name='${wl}' --filename=/opt/testfile --size=${TEST_FILE_SIZE} --rw='${rw}' ${extra} --bs='${bs}' --iodepth=${iodepth} --ioengine=${IOENGINE} --direct=${DIRECT} --time_based --runtime=${RUNTIME} --group_reporting --output-format=json >/out/fio_${wl}.json 2>/out/fio_${wl}.log" || true
done

# 触发开始
echo "[TRIGGER] start all"
for i in $(seq 1 6); do sudo touch "${MERGED_ROOT}/c${i}/out/_start"; done

# 等待结果并汇总
echo "round,container,workload,bw_MBps,iops,lat_ms,json_path,timestamp" > "${OUT_DIR}/summary.csv"
timeout=$((RUNTIME + 120))
for i in $(seq 1 6); do
  cname="ovsplit_c${i}"; wl="${WORKLOADS[$((i-1))]}"
  merged="${MERGED_ROOT}/c${i}"; host_out="${OUT_DIR}/c${i}"; mkdir -p "${host_out}"
  waited=0
  while [ ! -s "${merged}/out/fio_${wl}.json" ] && [ $waited -lt $timeout ]; do sleep 1; waited=$((waited+1)); done
  [ -s "${merged}/out/fio_${wl}.json" ] && sudo cp -f "${merged}/out/fio_${wl}.json" "${host_out}/"
  [ -f "${merged}/out/fio_${wl}.log" ]  && sudo cp -f "${merged}/out/fio_${wl}.log"  "${host_out}/" || true

  # 解析 JSON 追加 CSV
  python3 - "$i" "$i" "${host_out}/fio_${wl}.json" "${OUT_DIR}/summary.csv" <<'PY'
import json,sys,os,datetime
round_,cid,jpath,csv=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
if not os.path.exists(jpath): 
    print("WARN missing", jpath); raise SystemExit(0)
def load_any(text):
    for i,ch in enumerate(text):
        if ch=='{':
            for j in range(len(text)-1,i,-1):
                if text[j]=='}':
                    try: return json.loads(text[i:j+1])
                    except: pass
    return None
t=open(jpath,'rb').read().decode('utf-8','ignore')
try: data=json.loads(t)
except: data=load_any(t)
job=(data.get('jobs') or [{}])[0] if data else {}
rd=job.get('read') or {}; wr=job.get('write') or {}
def f(x):
    try: return float(x)
    except: return 0.0
bw=(rd.get('bw_bytes') or 0)+(wr.get('bw_bytes') or 0)
if not bw: bw=(f(rd.get('bw',0))+f(wr.get('bw',0)))*1024
iops=f(rd.get('iops',0))+f(wr.get('iops',0))
lat_src=wr.get('clat_ns') or wr.get('lat_ns') or job.get('clat_ns') or job.get('lat_ns')
lat= (float(lat_src.get('mean',0))/1e6) if isinstance(lat_src,dict) else 0.0
wl=os.path.basename(jpath).split('_')[-1].split('.')[0]
ts=datetime.datetime.now().isoformat(timespec='seconds')
with open(csv,'a') as f:
    f.write(f"{round_},{cid},{wl},{bw/(1024*1024):.3f},{iops:.3f},{lat:.3f},{jpath},{ts}\n")
print("OK", round_, cid, wl)
PY
done

# 关闭 iostat
if [ -f "${OUT_DIR}/iostat.pid" ]; then
  kill "$(cat "${OUT_DIR}/iostat.pid}")" 2>/dev/null || true
  rm -f "${OUT_DIR}/iostat.pid"
fi

# 收尾：停容器/卸载
for i in $(seq 1 6); do nerdctl rm -f "ovsplit_c${i}" >/dev/null 2>&1 || true; done
for i in $(seq 1 6); do sudo umount "${MERGED_ROOT}/c${i}" >/dev/null 2>&1 || true; done

echo "[DONE] 并发测试完成：${OUT_DIR}/summary.csv"
