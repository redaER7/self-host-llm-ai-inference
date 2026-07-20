#!/usr/bin/env bash
set -euo pipefail

# WireGuard server setup for Hetzner CP node.
# Run this first, then set up the GPU client.

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
# PublicKey = <paste-GPU-public-key-here>
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
echo "1. Save this public key — you'll need it on the GPU node:"
echo ""
echo "   $(sudo cat /etc/wireguard/server.pub)"
echo ""
echo "2. Open port 51820/udp in the Hetzner firewall."
echo ""
echo "3. After setting up the GPU node, add its public key:"
echo ""
echo "   sudo sed -i '/^# \\[Peer\\]/a PublicKey = <GPU-public-key>\\nAllowedIPs = 10.8.0.2/32' /etc/wireguard/wg0.conf"
echo "   sudo systemctl restart wg-quick@wg0"
echo "   ping -c 3 10.8.0.2"
echo ""
echo "4. Add VXLAN route:"
echo ""
echo "   sudo ip route add 10.0.2.15/32 via 10.8.0.2 dev wg0"
echo ""

