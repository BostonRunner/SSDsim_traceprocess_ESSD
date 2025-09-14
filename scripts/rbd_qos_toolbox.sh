#!/usr/bin/env bash
set -euo pipefail
NS="${NS:-fio-lab}"
POOL="${POOL:-lab-s1}"
SEL="${SEL:-app=noisy}"
IOPS_LIMIT="${IOPS_LIMIT:-6000}"
IOPS_BURST="${IOPS_BURST:-12000}"
BURST_SEC="${BURST_SEC:-10}"
BPS_LIMIT_MB="${BPS_LIMIT_MB:-32}"
BPS_BURST_MB="${BPS_BURST_MB:-64}"
mapfile -t ROWS < <(kubectl -n "${NS}" get pvc -l "${SEL}" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.volumeName}{"\n"}{end}')
for row in "${ROWS[@]}"; do
  [ -n "${row}" ] || continue
  pvc="${row%%|*}"; pv="${row##*|}"
  [ -n "$pv" ] || { echo "[WARN] PVC ${pvc} has no PV yet"; continue; }
  handle="$(kubectl get pv "${pv}" -o jsonpath='{.spec.csi.volumeHandle}')"
  [ -n "$handle" ] || { echo "[WARN] PV ${pv} no handle"; continue; }
  img="${POOL}/${handle}"
  echo "[APPLY] ${img}"
  kubectl -n rook-ceph exec deploy/rook-ceph-tools -- rbd qos set "${img}"     --iops-limit "${IOPS_LIMIT}" --iops-burst "${IOPS_BURST}" --iops-burst-duration "${BURST_SEC}"     --bps-limit "$((BPS_LIMIT_MB*1024*1024))" --bps-burst "$((BPS_BURST_MB*1024*1024))"
done
