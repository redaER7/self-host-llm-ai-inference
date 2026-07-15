#!/bin/bash

sudo apt update -y
sudo apt install -y wireguard-tools

# Check if WireGuard module is available
sudo modprobe wireguard
lsmod | grep wireguard

sudo apt update
sudo apt install -y resolvconf

# Enable and start it
sudo systemctl enable resolvconf
sudo systemctl start resolvconf

# Copy wg0.conf to /etc/wireguard/wg0.conf (exported from wireguard)
# Should be similar to:
# [Interface]
# PrivateKey = yPXXXXX=
# Address = 10.8.0.4/24
# DNS = 1.1.1.1,8.8.8.8
# MTU = 1420
#
# [Peer]
# PublicKey = KpYXXXX=
# PresharedKey = 40ZXXXXX=
# AllowedIPs = 10.8.0.0/24
# PersistentKeepalive = 25
# Endpoint = XXXX:51820

sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0
sudo wg show
# test with ping -c 3 10.8.0.1

sudo ufw enable

# Set default policies
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Allow SSH (CRITICAL)
sudo ufw allow 22/tcp

# Allow WireGuard
sudo ufw allow 51820/udp

# Allow vLLM API (only from VPN subnet)
sudo ufw allow from 10.8.0.0/24 to any port 8100 proto tcp

# Allow Gateway (only from VPN subnet)
sudo ufw allow from 10.8.0.0/24 to any port 8200 proto tcp

# Allow Kubernetes API (only from VPN subnet)
sudo ufw allow from 10.8.0.0/24 to any port 6443 proto tcp

# Allow Flannel (only from VPN subnet)
sudo ufw allow from 10.8.0.0/24 to any port 8472 proto udp

# Allow Kubelet (only from VPN subnet)
sudo ufw allow from 10.8.0.0/24 to any port 10250 proto tcp

# Allow Docker Registry (only from VPN subnet)
sudo ufw allow from 10.8.0.0/24 to any port 5000 proto tcp

# Allow outbound WireGuard (for the client)
sudo ufw allow out 51820/udp
