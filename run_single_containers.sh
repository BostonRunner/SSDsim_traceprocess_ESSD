#!/usr/bin/env bash
# run_single_containers.sh
# 单容器顺序测试：upper/lower 已按你指定的目录准备好：
#   upper 基于 /mnt/docker/upper/c1..c6 （写入盘 /dev/vdb）
#   lower 基于 /mnt/docker/lower/c1..c6 （只读盘 /dev/vdc）
# 每个容器以我们手动挂载的 overlay 作为根（nerdctl --rootfs），确保“镜像层读”和“容器层写”分盘生效。

set -euo pipefail

# 固定目录（你已准备好）
UPPER_ROOT="${UPPER_ROOT:-/mnt/docker/upper}"
LOWER_ROOT="${LOWER_ROOT:-/mnt/docker/lower}"
MERGED_ROOT="${MERGED_ROOT:-/mnt/docker/merged}"   # 临时挂载点（会自动创建）

# 结果输出
RESULT_ROOT="${RESULT_ROOT:-./results_split}"
ROUND_TAG="${ROUND_TAG:-single}"                    # 可按需修改
OUT_DIR="${RESULT_ROOT}/${ROUND_TAG}"

# FIO 配置
RUNTIME="${RUNTIME:-90}"                            # 秒
TEST_FILE_SIZE="${TEST_FILE_SIZE:-8G}"
FIO_LOCAL_BIN="${FIO_LOCAL_BIN:-}"                  # 可选：指定宿主机 fio 可执行文件以注入容器
IOENGINE="${IOENGINE:-libaio}"                      # 可选：io_uring/libaio
DIRECT="${DIRECT:-1}"

# 负载映射（6 容器固定分别跑一种）
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

# 安装 fio（在 rootfs 内，按包管理器自动尝试；失败则尝试从宿主注入 FIO_LOCAL_BIN）
install_fio() {
  local cname="$1"
  echo "[INSTALL] 确保 ${cname} 内有 fio"
  if nerdctl exec "$cname" sh -lc 'command -v fio >/dev/null 2>&1'; then
    echo "  -> 已存在"; return 0
  fi
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

  if nerdctl exec "$cname" sh -lc 'command -v fio >/dev/null 2>&1'; then
    echo "  -> 安装成功"; return 0
  fi

  if [[ -n "${FIO_LOCAL_BIN}" && -x "${FIO_LOCAL_BIN}" ]]; then
    echo "  -> 包管理安装失败，尝试注入本机 fio：${FIO_LOCAL_BIN}"
    nerdctl cp "${FIO_LOCAL_BIN}" "${cname}:/usr/local/bin/fio" || true
    nerdctl exec "$cname" sh -lc "chmod +x /usr/local/bin/fio" || true
    nerdctl exec "$cname" sh -lc 'command -v fio >/dev/null 2>&1' && { echo "  -> 注入成功"; return 0; }
  fi

  echo "[WARN] ${cname} 内无 fio，后续该容器会跳过压测"
  return 1
}

append_metrics() {
  local round="$1" cid="$2" json="$3"
  local csv="${OUT_DIR}/summary.csv"
  python3 - "$round" "$cid" "$json" "$csv" <<'PY'
import json,sys,os,datetime
round_,cid,jpath,csv=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
if not os.path.exists(csv):
    open(csv,'w').write("round,container,workload,bw_MBps,iops,lat_ms,json_path,timestamp\n")
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
if not data: raise SystemExit(0)
job=(data.get('jobs') or [{}])[0]
rd=job.get('read') or {}; wr=job.get('write') or {}
def f(x): 
    try: return float(x)
    except: return 0.0
bw=(rd.get('bw_bytes') or 0)+(wr.get('bw_bytes') or 0)
if not bw: bw=(f(rd.get('bw',0))+f(wr.get('bw',0)))*1024
iops=f(rd.get('iops',0))+f(wr.get('iops',0))
lat_src=wr.get('clat_ns') or wr.get('lat_ns') or job.get('clat_ns') or job.get('lat_ns')
lat= (float(lat_src.get('mean',0))/1e6) if isinstance(lat_src,dict) else 0.0
ts=datetime.datetime.now().isoformat(timespec='seconds')
wl=os.path.basename(jpath).split('_')[-1].split('.')[0]
with open(csv,'a') as f:
    f.write(f"{round_},{cid},{wl},{bw/(1024*1024):.3f},{iops:.3f},{lat:.3f},{jpath},{ts}\n")
print("OK", round_, cid, wl)
PY
}

for i in $(seq 1 6); do
  cname="ovsplit_c${i}"
  upper="${UPPER_ROOT}/c${i}/upper"
  work="${UPPER_ROOT}/c${i}/work"
  lower="${LOWER_ROOT}/c${i}"
  merged="${MERGED_ROOT}/c${i}"
  host_out="${OUT_DIR}/c${i}"
  wl="${WORKLOADS[$((i-1))]}"
  rw="${RW[$wl]}"; bs="${BS[$wl]}"; iodepth="${IODEPTH[$wl]}"; extra="${EXTRA[$wl]}"

  mkdir -p "${host_out}" "${merged}"

  # 基本校验
  if [ ! -d "${lower}" ]; then echo "[ERROR] 缺少 lower: ${lower}"; exit 2; fi
  sudo mkdir -p "${upper}" "${work}" "${merged}/out"

  echo "===== [${i}/6] overlay -> merged=${merged} ====="
  sudo umount "${merged}" >/dev/null 2>&1 || true
  sudo mount -t overlay overlay -o "lowerdir=${lower},upperdir=${upper},workdir=${work}" "${merged}"

  # 以 overlay 根启动容器
  nerdctl rm -f "${cname}" >/dev/null 2>&1 || true
  nerdctl run -d --name "${cname}" --rootfs "${merged}" sh -c 'tail -f /dev/null'

  # 安装 fio
  install_fio "${cname}" || { echo "[SKIP] ${cname} 无 fio"; nerdctl rm -f "${cname}" >/dev/null 2>&1 || true; sudo umount "${merged}" || true; continue; }

  echo "[FIO] ${cname} wl=${wl} runtime=${RUNTIME}s size=${TEST_FILE_SIZE}"
  nerdctl exec "${cname}" sh -lc "mkdir -p /opt; fio --name='${wl}' --filename=/opt/testfile --size=${TEST_FILE_SIZE} --rw='${rw}' ${extra} --bs='${bs}' --iodepth=${iodepth} --ioengine=${IOENGINE} --direct=${DIRECT} --time_based --runtime=${RUNTIME} --group_reporting --output-format=json >/out/fio_${wl}.json 2>/out/fio_${wl}.log"

  # 收集结果并追加汇总
  sudo cp -f "${merged}/out/fio_${wl}.json" "${host_out}/" 2>/dev/null || true
  sudo cp -f "${merged}/out/fio_${wl}.log"  "${host_out}/" 2>/dev/null || true
  [ -s "${host_out}/fio_${wl}.json" ] && append_metrics "$i" "$i" "${host_out}/fio_${wl}.json"

  # 清理本轮
  nerdctl rm -f "${cname}" >/dev/null 2>&1 || true
  sudo umount "${merged}" || true
done

echo "[DONE] 顺序测试完成：${OUT_DIR}/summary.csv"
