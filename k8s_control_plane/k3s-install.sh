#!/usr/bin/env bash
set -euo pipefail

# K3s Control Plane Installer
# Run this on your Hetzner server to set up a single-node K3s control plane.
#
# Usage:
#   ssh root@<hetzner-ip>
#   bash k3s-install.sh

INSTALL_K3S_VERSION="v1.33.2+k3s1"

echo "[1/4] Installing K3s v1.33"
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="$INSTALL_K3S_VERSION" \
  sh -s - \
    --disable=traefik \
    --disable=servicelb \
    --write-kubeconfig-mode=644

echo "[2/4] Waiting for node to be ready"
for i in $(seq 1 30); do
  if k3s kubectl get node "$(hostname)" 2>/dev/null | grep -q Ready; then
    echo "   Node ready"
    break
  fi
  sleep 3
done

echo "[3/4] Labeling control plane node"
k3s kubectl label node "$(hostname)" \
  node-role.kubernetes.io/control-plane="true" \
  --overwrite 2>/dev/null || true

echo "[4/4] K3s control plane ready"
NODE_IP=$(k3s kubectl get node "$(hostname)" -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null || curl -s ifconfig.me)
TOKEN=$(sudo cat /var/lib/rancher/k3s/server/node-token 2>/dev/null)

echo ""
echo "=========================================="
echo " K3s Control Plane Ready"
echo "=========================================="
echo " K3S_URL=https://${NODE_IP}:6443"
echo " K3S_TOKEN=${TOKEN}"
echo "=========================================="
echo ""
echo "Copy the values above and use them in:"
echo "  gpu_providers/vast-ai-bootstrap.sh"
echo ""
