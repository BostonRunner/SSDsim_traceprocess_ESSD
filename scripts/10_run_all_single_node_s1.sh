#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
K8S_DIR="${here}/../k8s"
OUT_DIR="${here}/../results"
command -v kubectl >/dev/null || { echo "[FATAL] kubectl not found"; exit 1; }
if ! kubectl get ns kube-flannel >/dev/null 2>&1; then
  kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
fi
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
kubectl taint nodes --all node-role.kubernetes.io/master- || true
DISKS=(${DISKS_OVERRIDE:-/dev/vdb /dev/vdc /dev/vdd /dev/vde /dev/vdf /dev/vdg /dev/vdh})
echo "== wiping OSD disks ==" "${DISKS[@]}"
for d in "${DISKS[@]}"; do [ -b "$d" ] || { echo "[FATAL] $d missing"; exit 2; }; done
for d in "${DISKS[@]}"; do umount -f ${d}?* 2>/dev/null || true; sgdisk --zap-all "$d" || true; wipefs -a "$d" || true; blkdiscard "$d" 2>/dev/null || true; done
if ! command -v helm >/dev/null 2>&1; then curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash; fi
helm repo add rook-release https://charts.rook.io/release >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1 || true
helm upgrade --install rook-ceph rook-release/rook-ceph -n rook-ceph --create-namespace
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
cat > "${here}/rook-single-node-values.yaml" <<EOF
cephClusterSpec:
  cephVersion: { image: quay.io/ceph/ceph:reef }
  dataDirHostPath: /var/lib/rook
  mon: { count: 1, allowMultiplePerNode: true }
  mgr: { count: 1 }
  crashCollector: { disable: true }
  storage:
    useAllNodes: false
    useAllDevices: false
    nodes:
    - name: ${NODE}
      devices:
$(for d in "${DISKS[@]}"; do echo "      - {name: ${d}}"; done)
EOF
helm upgrade --install rook-ceph-cluster rook-release/rook-ceph-cluster -n rook-ceph -f "${here}/rook-single-node-values.yaml"
for i in $(seq 1 60); do
  not_ready=$(kubectl -n rook-ceph get pods --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed"{c++} END{print c+0}')
  [ "$not_ready" = "0" ] && break || true
  echo "waiting ceph pods... (${i}/60)"; sleep 10
done
kubectl -n rook-ceph get pods | egrep 'mon|mgr|osd|csi' || true
kubectl apply -f "${K8S_DIR}/namespace.yaml"
kubectl apply -f "${K8S_DIR}/pool-sc-s1.yaml"
kubectl -n rook-ceph apply -f https://raw.githubusercontent.com/rook/rook/master/deploy/examples/toolbox.yaml
for i in $(seq 1 60); do
  st=$(kubectl -n rook-ceph get deploy/rook-ceph-tools -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)
  [ "$st" = "1" ] && break || true
  echo "waiting toolbox... (${i}/60)"; sleep 5
done
collect_stage(){ local stage="$1"; NS="fio-lab" OUT="${OUT_DIR}" STAGE="${stage}" "${here}/collect_results.sh" || true; echo "[OK] ${stage} -> ${OUT_DIR}/${stage}.csv"; }
kubectl -n fio-lab apply -f "${K8S_DIR}/victim.yaml"
kubectl -n fio-lab rollout status sts/victim --timeout=5m
sleep 150; collect_stage baseline
kubectl -n fio-lab apply -f "${K8S_DIR}/noisy.yaml"
kubectl -n fio-lab rollout status sts/noisy --timeout=5m
sleep 150; collect_stage with_noisy
SEL="app=noisy" POOL="lab-s1" NS="fio-lab" "${here}/rbd_qos_toolbox.sh"
sleep 150; collect_stage with_qos
kubectl -n fio-lab apply -f "${K8S_DIR}/victim2x.yaml"
kubectl -n fio-lab rollout status sts/victim2x --timeout=5m
SEL="app=victim"  POOL="lab-s1" NS="fio-lab" IOPS_LIMIT=4000 IOPS_BURST=8000  BPS_LIMIT_MB=16 BPS_BURST_MB=32 "${here}/rbd_qos_toolbox.sh"
SEL="app=victim2x" POOL="lab-s1" NS="fio-lab" IOPS_LIMIT=8000 IOPS_BURST=16000 BPS_LIMIT_MB=32 BPS_BURST_MB=64 "${here}/rbd_qos_toolbox.sh"
sleep 150; collect_stage portion_2x
echo "[DONE] CSVs in ${OUT_DIR}/"
