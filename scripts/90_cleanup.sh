#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
K8S_DIR="${here}/../k8s"
WIPE_OSD="${WIPE_OSD:-no}"
DISKS=(${DISKS_OVERRIDE:-/dev/vdb /dev/vdc /dev/vdd /dev/vde /dev/vdf /dev/vdg /dev/vdh})
kubectl -n fio-lab delete -f "${K8S_DIR}/victim2x.yaml" --ignore-not-found
kubectl -n fio-lab delete -f "${K8S_DIR}/noisy.yaml" --ignore-not-found
kubectl -n fio-lab delete -f "${K8S_DIR}/victim.yaml" --ignore-not-found
kubectl -n fio-lab delete pvc --all --ignore-not-found || true
kubectl -n rook-ceph delete -f https://raw.githubusercontent.com/rook/rook/master/deploy/examples/toolbox.yaml --ignore-not-found
kubectl delete -f "${K8S_DIR}/pool-sc-s1.yaml" --ignore-not-found
if [ "${UNINSTALL_ROOK:-no}" = "yes" ]; then
  helm uninstall rook-ceph-cluster -n rook-ceph || true
  helm uninstall rook-ceph -n rook-ceph || true
  kubectl delete ns rook-ceph --ignore-not-found || true
fi
if [ "${WIPE_OSD}" = "yes" ]; then
  for d in "${DISKS[@]}"; do
    [ -b "$d" ] || { echo "[WARN] $d missing"; continue; }
    umount -f ${d}?* 2>/dev/null || true
    sgdisk --zap-all "$d" || true
    wipefs -a "$d" || true
    blkdiscard "$d" 2>/dev/null || true
  done
fi
echo "[OK] Cleanup done."
