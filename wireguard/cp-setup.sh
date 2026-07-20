#!/usr/bin/env bash
set -euo pipefail

# WireGuard server setup for the Hetzner CP node.
# Run this FIRST, before any GPU node clients.
#
# Usage:
#   bash wireguard/cp-setup.sh
#
# After running:
#   1. Share /etc/wireguard/server.pub with each GPU node
#   2. Add each GPU's public key as a [Peer] in /etc/wireguard/wg0.conf
#   3. Restart: sudo systemctl restart wg-quick@wg0
#   4. Add VXLAN route for each GPU: sudo ip route add <gpu-ip>/32 via <wg-gpu-ip> dev wg0

echo "[1/3] Installing wireguard-tools"
sudo apt-get update -y && sudo apt-get install -y wireguard-tools

echo "[2/3] Generating server keys"
wg genkey | sudo tee /etc/wireguard/server.key | wg pubkey | sudo tee /etc/wireguard/server.pub
sudo chmod 600 /etc/wireguard/server.key

KEY=$(sudo cat /etc/wireguard/server.key)

sudo tee /etc/wireguard/wg0.conf > /dev/null <<EOF
[Interface]
Address = 10.8.0.1/24
ListenPort = 51820
PrivateKey = $KEY
MTU = 1420

# NAT so VXLAN traffic can route through the tunnel
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

# [Peer]
# Add each GPU node below. Example:
# PublicKey = <gpu-public-key>
# AllowedIPs = 10.8.0.2/32
EOF

echo "[3/3] Starting WireGuard"
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0

echo ""
echo "================================================"
echo "  CP node setup complete"
echo "================================================"
echo ""
echo "Server public key (share with each GPU node):"
echo ""
echo "   $(sudo cat /etc/wireguard/server.pub)"
echo ""
echo "Next steps for each GPU node:"
echo ""
echo "  1. On GPU: bash wireguard/gpu-setup.sh"
echo "  2. Copy the GPU's public key, then on CP:"
echo "     sudo sed -i '/^# \\[Peer\\]/a PublicKey = <gpu-pub-key>\\nAllowedIPs = 10.8.0.2/32' /etc/wireguard/wg0.conf"
echo "     sudo systemctl restart wg-quick@wg0"
echo "     ping -c 3 10.8.0.2"
echo ""
echo "  3. Add VXLAN route on CP:"
echo "     sudo ip route add <gpu-vast-ip>/32 via 10.8.0.2 dev wg0"
echo ""
echo "  4. Add return route on GPU:"
echo "     sudo ip route add 89.167.109.193/32 via 10.8.0.1 dev wg0"
echo ""
echo "Hetzer firewall: open port 51820/udp"
echo ""
