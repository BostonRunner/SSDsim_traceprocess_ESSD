#!/usr/bin/env bash
set -euo pipefail
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
if ! command -v apt >/dev/null 2>&1; then echo "[FATAL] need Ubuntu/Debian (apt)"; exit 1; fi
sudo apt update
sudo apt install -y curl gnupg2 ca-certificates lsb-release apt-transport-https   chrony conntrack socat ebtables ethtool iptables arptables ipset   gdisk parted util-linux nvme-cli jq
sudo swapoff -a || true
sudo sed -ri '/\sswap\s/s/^/#/' /etc/fstab || true
if ! dpkg -s containerd >/dev/null 2>&1; then sudo apt install -y containerd; fi
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -ri 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
cat <<'EOF' | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF
cat <<'EOF' | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
sudo modprobe overlay br_netfilter || true
sudo sysctl --system
sudo systemctl enable --now containerd
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /"  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt update
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
if [ ! -f /etc/kubernetes/admin.conf ]; then
  sudo kubeadm init --pod-network-cidr="${POD_CIDR}"
fi
if [ "$(id -u)" -eq 0 ]; then
  export KUBECONFIG=/etc/kubernetes/admin.conf
else
  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config
fi
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
kubectl taint nodes --all node-role.kubernetes.io/master- || true
for i in $(seq 1 60); do
  ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{c++} END{print c+0}')
  [ "${ready}" -ge 1 ] && break || true
  echo "waiting nodes Ready... (${i}/60)"; sleep 5
done
kubectl get nodes -o wide
kubectl get pods -A
echo "[OK] Bootstrap finished."
