#!/usr/bin/env bash
set -euo pipefail

# Vast.ai Single-Node Bootstrap (no Hetzner CP)
# Runs K3s server + GPU workloads on one Vast.ai instance.
#
# Usage:
#   bash vast-ai-single.sh

echo "[1/6] Installing K3s server (v1.33.2+k3s1, skip start)"
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="v1.33.2+k3s1" \
  INSTALL_K3S_SKIP_START=true \
  INSTALL_K3S_SKIP_ENABLE=true \
  INSTALL_K3S_EXEC="server \
    --disable=traefik \
    --disable=servicelb \
    --write-kubeconfig-mode=644" \
  sh -

echo "[2/6] Installing NVIDIA container toolkit"
if ! command -v nvidia-ctk &>/dev/null; then
  distribution=$(. /etc/os-release;echo "$ID$VERSION_ID")
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -sL "https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list" | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -qq && apt-get install -y -qq nvidia-container-toolkit
fi

echo "[3/6] Writing containerd config with NVIDIA runtime"
CONFIG_FILE=/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl
mkdir -p "$(dirname "$CONFIG_FILE")"
cat > "$CONFIG_FILE" << 'CONFIGEOF'
imports = ["/etc/containerd/conf.d/*.toml"]
version = 2

[plugins]

  [plugins."io.containerd.internal.v1.opt"]
    path = "/var/lib/rancher/k3s/agent/containerd"

  [plugins."io.containerd.cri.v1.images"]
    disable_snapshot_annotations = true
    snapshotter = "overlayfs"

    [plugins."io.containerd.cri.v1.images".pinned_images]
      sandbox = "rancher/mirrored-pause:3.6"

    [plugins."io.containerd.cri.v1.images".registry]
      config_path = "/var/lib/rancher/k3s/agent/etc/containerd/certs.d"

  [plugins."io.containerd.cri.v1.runtime"]
    device_ownership_from_security_context = false
    enable_selinux = false
    enable_unprivileged_icmp = true
    enable_unprivileged_ports = true

    [plugins."io.containerd.cri.v1.runtime".cni]
      bin_dir = "/var/lib/rancher/k3s/data/cni"
      conf_dir = "/var/lib/rancher/k3s/agent/etc/cni/net.d"

    [plugins."io.containerd.cri.v1.runtime".containerd]
      default_runtime_name = "nvidia"

      [plugins."io.containerd.cri.v1.runtime".containerd.runtimes]

        [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.nvidia]
          runtime_type = "io.containerd.runc.v2"

          [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.nvidia.options]
            BinaryName = "/usr/bin/nvidia-container-runtime"
            SystemdCgroup = true

        [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v2"

          [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc.options]
            SystemdCgroup = true

  [plugins."io.containerd.grpc.v1.cri"]
    stream_server_address = "127.0.0.1"
    stream_server_port = "10010"
CONFIGEOF

echo "[4/6] Starting K3s server"
systemctl enable k3s
systemctl start k3s

echo "[5/6] Waiting for node to register"
NODE_NAME=$(hostname)
for i in $(seq 1 60); do
  if k3s kubectl get node "$NODE_NAME" 2>/dev/null | grep -q Ready; then
    break
  fi
  sleep 3
done

echo "[6/6] Labeling node and applying device plugin"
k3s kubectl label node "$NODE_NAME" \
  node-role.kubernetes.io/gpu-node="true" \
  role="gpu" \
  --overwrite 2>/dev/null || true
k3s kubectl taint node "$NODE_NAME" gpu-node=true:NoSchedule --overwrite 2>/dev/null || true

# Auto-detect GPU model
if command -v nvidia-smi &>/dev/null; then
  GPU_MODEL=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)
  GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
  k3s kubectl label node "$NODE_NAME" "gpu-model=$GPU_MODEL" --overwrite 2>/dev/null || true
  k3s kubectl label node "$NODE_NAME" "gpu-count=$GPU_COUNT" --overwrite 2>/dev/null || true
  echo "   Detected: $GPU_COUNT x $GPU_MODEL"
fi


echo ""
echo "=========================================="
echo " K3s Single-Node Ready"
echo "=========================================="
echo " Export these for kubectl from your local:"
echo "   k3s kubectl config view --raw > ~/vast-kubeconfig"
echo " Then use the server IP + port 6443"
echo "=========================================="
k3s kubectl get node