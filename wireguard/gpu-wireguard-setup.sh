#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------
# GPU node WireGuard + K3s agent join
# ------------------------------------------------------------

WG_IFACE="wg0"
WG_NET="10.10.0.2/24"
CP_ENDPOINT="<CONTROL_PLANE_PUBLIC_IP>:51820"   # will prompt
CP_PUBLIC_KEY="<CONTROL_PLANE_PUBLIC_KEY>"      # will prompt
K3S_CONFIG="/etc/rancher/k3s/config.yaml"

# 1. Install WireGuard
echo "📦 Installing WireGuard..."
apt update && apt install -y wireguard

# 2. Generate keys (if not present)
cd /etc/wireguard
if [[ ! -f privatekey ]]; then
    umask 077
    wg genkey | tee privatekey | wg pubkey > publickey
    echo "✅ Keys generated."
else
    echo "ℹ️  Keys already exist, using them."
fi
PRIV=$(cat privatekey)
PUB=$(cat publickey)

echo "🔑 Your public key (give this to the control‑plane node):"
echo "   $PUB"
echo ""

# 3. Gather control‑plane details
read -p "Enter the control‑plane public key: " CP_PUBLIC_KEY
read -p "Enter the control‑plane public IP address (e.g. 89.167.109.193): " CP_IP
CP_ENDPOINT="${CP_IP}:51820"

# 4. Create wg0.conf (GPU as client)
cat > wg0.conf <<EOF
[Interface]
Address = $WG_NET
PrivateKey = $PRIV

[Peer]
PublicKey = $CP_PUBLIC_KEY
Endpoint = $CP_ENDPOINT
AllowedIPs = 10.10.0.0/24
PersistentKeepalive = 25
EOF

echo "✅ WireGuard config created."

# 5. Enable and start WireGuard
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0
echo "✅ WireGuard started."

# 6. Test connectivity
echo "⏳ Testing ping to control‑plane (10.10.0.1)..."
if ping -c 2 10.10.0.1 >/dev/null; then
    echo "✅ WireGuard tunnel is UP."
else
    echo "❌ Cannot reach 10.10.0.1. Please check firewall and config."
    exit 1
fi

# 7. Create K3s agent config
mkdir -p $(dirname $K3S_CONFIG)
cat > $K3S_CONFIG <<EOF
node-ip: 10.10.0.2
EOF
echo "✅ K3s agent config written."

# 8. Get join token and URL
read -p "Enter the K3S_TOKEN (from control‑plane): " K3S_TOKEN
K3S_URL="https://10.10.0.1:6443"

# 9. Join the cluster
echo "🚀 Joining K3s cluster..."
export K3S_URL K3S_TOKEN
curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="v1.33.2+k3s1" \
    K3S_URL="$K3S_URL" \
    K3S_TOKEN="$K3S_TOKEN" \
    K3S_NODE_NAME="gpu-node-$(hostname)" \
    INSTALL_K3S_EXEC="agent --disable-apiserver-lb --with-node-id" \
    sh -

echo "✅ Installation complete. Waiting for node to be Ready..."
sleep 10

# test
timeout 5 curl -v -k https://10.10.0.1:6443