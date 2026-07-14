#!/usr/bin/env bash
set -euo pipefail

# Vast.ai K3s Agent Bootstrap
# Run this script on a fresh Vast.ai GPU instance to join your K3s cluster.
#
# Usage:
#   export K3S_URL=https://<control-plane-ip>:6443
#   export K3S_TOKEN=<node-token>
#   bash vast-ai-bootstrap.sh
#
# Optional env vars:
#   NODE_NAME      — explicit node name (default: vast-<hostname>-<random>)
#   LABELS         — extra node labels, comma-separated (default: node-role.kubernetes.io/gpu-node=true,role=gpu)
#   INSTALL_NVIDIA — install NVIDIA container toolkit (default: true)
#   MIG_PROFILES   — if set, creates MIG partitions (e.g. "1g.10gb,3g.40gb") and labels node

: "${K3S_URL:?K3S_URL is required}"
: "${K3S_TOKEN:?K3S_TOKEN is required}"
: "${NODE_NAME:=vast-$(hostname)-$(head -c6 /dev/urandom | base64 | tr -dc a-z0-9 | head -c6)}"
: "${LABELS:=node-role.kubernetes.io/gpu-node=true,role=gpu}"
: "${INSTALL_NVIDIA:=true}"

echo "[1/7] Installing K3s agent (v1.33.2+k3s1)"
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="v1.33.2+k3s1" \
  K3S_URL="$K3S_URL" \
  K3S_TOKEN="$K3S_TOKEN" \
  K3S_NODE_NAME="$NODE_NAME" \
  INSTALL_K3S_EXEC="agent --disable-apiserver-lb --with-node-id" \
  sh -

echo "[2/7] Waiting for node to register"
for i in $(seq 1 30); do
  if k3s kubectl get node "$NODE_NAME" &>/dev/null 2>&1; then
    break
  fi
  sleep 3
done

echo "[3/7] Labeling and tainting node"
IFS=',' read -ra KV <<< "$LABELS"
for pair in "${KV[@]}"; do
  [[ -n "$pair" ]] && k3s kubectl label node "$NODE_NAME" "$pair" --overwrite 2>/dev/null || true
done

# Taint so only GPU workloads schedule here
k3s kubectl taint node "$NODE_NAME" gpu-node=true:NoSchedule --overwrite 2>/dev/null || true

# Symlink K3s bundled CNI plugins to /opt/cni/bin (needed for pod sandbox networking)
CNI_SRC=/var/lib/rancher/k3s/data/current/bin
CNI_DST=/opt/cni/bin
if [ -d "$CNI_SRC" ]; then
  mkdir -p "$CNI_DST"
  for plugin in "$CNI_SRC"/*; do
    name=$(basename "$plugin")
    if [ -f "$plugin" ] && [ ! -e "$CNI_DST/$name" ]; then
      ln -sf "$plugin" "$CNI_DST/$name"
    fi
  done
fi

# Auto-detect GPU model
if command -v nvidia-smi &>/dev/null; then
  GPU_MODEL=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)
  GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
  k3s kubectl label node "$NODE_NAME" "gpu-model=$GPU_MODEL" --overwrite 2>/dev/null || true
  k3s kubectl label node "$NODE_NAME" "gpu-count=$GPU_COUNT" --overwrite 2>/dev/null || true
  echo "   Detected: $GPU_COUNT x $GPU_MODEL"
fi

if [[ "$INSTALL_NVIDIA" == "true" ]]; then
  echo "[4/7] Installing NVIDIA container toolkit"
  if ! command -v nvidia-ctk &>/dev/null; then
    distribution=$(. /etc/os-release;echo "$ID$VERSION_ID")
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -sL "https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list" | \
      sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
      tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update -qq && apt-get install -y -qq nvidia-container-toolkit
  fi

  echo "[4b/7] Writing containerd config with NVIDIA runtime"
  CONFIG_FILE=/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl
  cp "$CONFIG_FILE" "${CONFIG_FILE}.bak" 2>/dev/null || true
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

  echo "[4c/7] Restarting k3s-agent"
  systemctl restart k3s-agent
fi

if [[ -n "${MIG_PROFILES:-}" ]]; then
  echo "[5/7] Configuring MIG partitions: $MIG_PROFILES"
  IFS=',' read -ra PROFILES <<< "$MIG_PROFILES"
  nvidia-smi mig -cgi "${PROFILES[*]}" -C
  k3s kubectl label node "$NODE_NAME" "mig=true" --overwrite 2>/dev/null || true
  k3s kubectl label node "$NODE_NAME" "mig-profiles=$MIG_PROFILES" --overwrite 2>/dev/null || true
  echo "   MIG ready: $MIG_PROFILES"
fi

echo "[6/7] Creating kubeconfig for kubectl"
mkdir -p /root/.kube
k3s kubectl config view --raw > /root/.kube/config 2>/dev/null || true

echo "[7/7] Node ready"
k3s kubectl get node "$NODE_NAME" -o wide
