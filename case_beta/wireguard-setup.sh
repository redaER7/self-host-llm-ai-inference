#!/usr/bin/env bash
set -euo pipefail

# WireGuard GPU Node Setup for Case Beta
# Run this on the Vast.ai GPU node AFTER creating /etc/wireguard/wg0.conf:
#
#   1. Generate key pair:  wg genkey | tee /etc/wireguard/client.key | wg pubkey > /etc/wireguard/client.pub
#   2. Create /etc/wireguard/wg0.conf with the generated private key
#   3. Share client.pub with the CP node (add to CP's Peer section)
#   4. Add CP's public key to this node's Peer section in wg0.conf
#
# This script:
#   - Installs wireguard-tools
#   - Loads the WireGuard kernel module
#   - Enables/starts wg-quick@wg0
#   - Configures UFW to allow Flannel VXLAN + control plane over WireGuard
#
# Prerequisites:
#   - /etc/wireguard/wg0.conf exists (created manually with keys)
#   - sudo access

echo "[1/5] Installing wireguard-tools"
sudo apt-get update -y
sudo apt-get install -y wireguard-tools resolvconf

echo "[2/5] Loading WireGuard kernel module"
sudo modprobe wireguard
lsmod | grep wireguard

echo "[3/5] Enabling resolvconf"
sudo systemctl enable resolvconf
sudo systemctl start resolvconf

echo "[4/5] Starting WireGuard tunnel"
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0
sudo wg show

echo "  → Verify with: ping -c 3 10.8.0.1"

echo "[5/5] Configuring UFW"
sudo ufw --force enable

# Default policies
sudo ufw default deny incoming
sudo ufw default allow outgoing

# SSH (keep access)
sudo ufw allow 22/tcp

# Allow Flannel VXLAN from WireGuard subnet (cross-node pod networking)
sudo ufw allow from 10.8.0.0/24 to any port 8472 proto udp

# Allow Kubelet from WireGuard subnet
sudo ufw allow from 10.8.0.0/24 to any port 10250 proto tcp

# Allow K3s API from WireGuard subnet (optional — GPU reaches CP via public IP)
sudo ufw allow from 10.8.0.0/24 to any port 6443 proto tcp

echo ""
echo "=== WireGuard setup complete ==="
echo "Tunnel status:"
sudo wg show
echo ""
echo "Next step: On the CP node, add a route for the GPU VXLAN endpoint:"
echo "  sudo ip route add <gpu-internal-ip>/32 via 10.8.0.2 dev wg0"
echo "  (e.g., sudo ip route add 10.0.2.15/32 via 10.8.0.2 dev wg0)"
