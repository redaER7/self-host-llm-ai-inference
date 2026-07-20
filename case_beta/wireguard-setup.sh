#!/usr/bin/env bash
set -euo pipefail

# WireGuard client setup for Vast.ai GPU node.
# Run after the CP node setup is done.
#
# Usage:
#   export CP_NODE_IP=89.167.109.193
#   bash case_beta/wireguard-setup.sh
#
# If CP_NODE_IP is not set, the script prompts for it.

: "${CP_NODE_IP:=}"

echo "[1/5] Installing wireguard-tools"
sudo apt-get update -y && sudo apt-get install -y wireguard-tools
sudo modprobe wireguard

echo "[2/5] Generating client keys"
wg genkey | sudo tee /etc/wireguard/client.key | wg pubkey | sudo tee /etc/wireguard/client.pub
sudo chmod 600 /etc/wireguard/client.key

echo ""
echo "Your GPU node public key is:"
echo ""
sudo cat /etc/wireguard/client.pub
echo ""
echo "Copy this key and add it to the CP node's /etc/wireguard/wg0.conf [Peer] section."
echo "Then restart WireGuard on the CP node: sudo systemctl restart wg-quick@wg0"
echo ""

read -rp "Paste the CP server's public key (from /etc/wireguard/server.pub): " CP_PUB
if [ -z "$CP_NODE_IP" ]; then
  read -rp "CP node public IP (e.g. 89.167.109.193): " CP_NODE_IP
fi

KEY=$(sudo cat /etc/wireguard/client.key)

sudo tee /etc/wireguard/wg0.conf > /dev/null <<EOF
[Interface]
Address = 10.8.0.2/24
PrivateKey = $KEY
MTU = 1420

[Peer]
PublicKey = $CP_PUB
Endpoint = $CP_NODE_IP:51820
AllowedIPs = 10.8.0.0/24
PersistentKeepalive = 25
EOF

echo "[3/5] Starting WireGuard"
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0

echo "[4/5] Opening UFW firewall"
sudo ufw --force enable
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow from $CP_NODE_IP to any port 8472 proto udp
sudo ufw allow from 10.8.0.0/24 to any port 10250 proto tcp
sudo ufw allow from 10.8.0.0/24 to any port 6443 proto tcp

echo "[5/5] Verifying tunnel"
echo ""
echo "================================================"
sudo wg show
echo "================================================"
echo ""
echo "Check connectivity to the CP node:"
echo ""
echo "   ping -c 3 10.8.0.1"
echo ""
echo "Once the CP has added your public key and restarted wg-quick,"
echo "ping 10.8.0.1 should work."
echo ""
echo "Then on the CP node, add the VXLAN route:"
echo "   sudo ip route add 10.0.2.15/32 via 10.8.0.2 dev wg0"
echo ""
