#!/usr/bin/env bash
set -euo pipefail

# WireGuard CP Node Setup for Case Beta
# Run this on the Hetzner CP node BEFORE setting up the GPU node client.
#
# This script:
#   - Installs wireguard-tools
#   - Generates server key pair
#   - Creates /etc/wireguard/wg0.conf (you must add the GPU peer's public key)
#   - Enables/starts wg-quick@wg0
#
# After running:
#   1. Share /etc/wireguard/server.pub with the GPU node
#   2. Add the GPU node's public key to the [Peer] section in /etc/wireguard/wg0.conf
#   3. Restart: sudo systemctl restart wg-quick@wg0
#   4. Add VXLAN route: sudo ip route add <gpu-internal-ip>/32 via 10.8.0.2 dev wg0

echo "[1/4] Installing wireguard-tools"
sudo apt-get update -y
sudo apt-get install -y wireguard-tools

echo "[2/4] Generating server key pair"
wg genkey | sudo tee /etc/wireguard/server.key | wg pubkey | sudo tee /etc/wireguard/server.pub
sudo chmod 600 /etc/wireguard/server.key

echo "[3/4] Creating /etc/wireguard/wg0.conf"
SERVER_PRIV=$(sudo cat /etc/wireguard/server.key)

sudo tee /etc/wireguard/wg0.conf > /dev/null <<EOF
[Interface]
Address = 10.8.0.1/24
ListenPort = 51820
PrivateKey = $SERVER_PRIV
MTU = 1420

# NAT for VXLAN traffic
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

# [Peer]
# GPU node (Vast.ai) — ADD AFTER GENERATING GPU CLIENT KEY:
# PublicKey = <gpu-client-public-key>
# AllowedIPs = 10.8.0.2/32
EOF

echo "[4/4] Starting WireGuard"
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0

echo ""
echo "=== WireGuard CP setup complete ==="
echo ""
echo "Server public key (share with GPU node):"
sudo cat /etc/wireguard/server.pub
echo ""
echo "Next steps:"
echo "  1. On the GPU node, run: bash case_beta/wireguard-setup.sh"
echo "  2. Get the GPU node's public key and add it to /etc/wireguard/wg0.conf:"
echo "     [Peer]"
echo "     PublicKey = <gpu-client-public-key>"
echo "     AllowedIPs = 10.8.0.2/32"
echo "  3. Restart WireGuard: sudo systemctl restart wg-quick@wg0"
echo "  4. Verify: ping -c 3 10.8.0.2"
echo "  5. Add VXLAN route: sudo ip route add <gpu-internal-ip>/32 via 10.8.0.2 dev wg0"
echo ""
echo "Don't forget to open port 51820/udp in the Hetzner firewall."
