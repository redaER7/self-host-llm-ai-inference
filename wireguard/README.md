# WireGuard Setup

Shared WireGuard setup scripts for connecting a Hetzner CP node to one or more remote GPU nodes (e.g. Trooper AI).

## How it works

Flannel VXLAN (UDP 8472) is used for pod-to-pod networking across nodes. Both K3s server and agent must set `--flannel-iface=wg0` so VXLAN packets are sent through the WireGuard tunnel.

```
CP node (Hetzner)                GPU node (Trooper AI)
┌────────────────────┐          ┌──────────────────────────┐
│ wg0 (10.10.0.1) ───┼─ tunnel ─┼──→ wg0 (10.10.0.2)      │
│ K3s server         │ UDP 51820│   K3s agent              │
│ flannel-iface=wg0  │          │   flannel-iface=wg0      │
│ node-ip: 10.10.0.1 │          │   node-ip: 10.10.0.2     │
└────────────────────┘          └──────────────────────────┘
```

Both nodes need UFW rules allowing UDP 8472 from the peer's WG subnet:
```bash
sudo ufw allow from 10.10.0.0/24 to any port 8472 proto udp
```

## K3s requirements

**On the CP node** — K3s config at `/etc/rancher/k3s/config.yaml`:
```yaml
node-ip: 10.10.0.1
advertise-address: 10.10.0.1
node-external-ip: <public-ip>
flannel-iface: wg0
```

**On each GPU node** — K3s agent install:
```bash
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="v1.33.2+k3s1" \
  K3S_URL="https://10.10.0.1:6443" \
  K3S_TOKEN="<node-token>" \
  K3S_NODE_NAME="gpu-node-$(hostname)" \
  INSTALL_K3S_EXEC="agent --node-ip=10.10.0.2 --flannel-iface=wg0" sh -
```

## Setup

### 1. CP node (run first)

```bash
bash wireguard/cp-wireguard-setup.sh
```

- Generates server keys, creates `/etc/wireguard/wg0.conf`
- Configures K3s with `node-ip: 10.10.0.1`, `flannel-iface: wg0`
- Starts `wg-quick@wg0`
- Prints the **server public key** and **K3s join token**

### 2. Each GPU node

```bash
bash wireguard/gpu-wireguard-setup.sh
```

The script:
- Generates client keys
- Prompts for CP's public key and public IP
- Creates `/etc/wireguard/wg0.conf`, starts WireGuard
- Verifies tunnel with `ping 10.10.0.1`

Install K3s agent separately (see above).

### 3. Add GPU peer to CP config

On the CP, add each GPU's public key to `/etc/wireguard/wg0.conf`:

```ini
[Peer]
PublicKey = <gpu-public-key>
AllowedIPs = 10.10.0.2/32
```

Then restart: `sudo systemctl restart wg-quick@wg0`

### 4. Verify

```bash
# From GPU node
ping -c 3 10.10.0.1

# From CP node
ping -c 3 10.10.0.2

# Cross-node Flannel pod connectivity
kubectl run -it --rm debug --image=busybox --restart=Never -- ping -c 3 10.10.0.2
```

## Multi-GPU example

CP config with two GPU peers:

```ini
[Interface]
Address = 10.10.0.1/24
ListenPort = 51820
PrivateKey = <cp-private-key>
MTU = 1420

[Peer]
# GPU 1
PublicKey = <gpu1-pub-key>
AllowedIPs = 10.10.0.2/32

[Peer]
# GPU 2
PublicKey = <gpu2-pub-key>
AllowedIPs = 10.10.0.3/32
```

## Firewall reference (both nodes)

### CP node (Hetzner) — UFW

| Port | Protocol | From | Purpose |
|------|----------|------|---------|
| 51820 | UDP | Anywhere | WireGuard tunnel |
| 8472 | UDP | 10.10.0.0/24 | Flannel VXLAN |
| 6443 | TCP | 10.10.0.0/24 | K3s API |
| 10250 | TCP | 10.10.0.0/24 | Kubelet |
| 22 | TCP | Anywhere | SSH |

### GPU node (Trooper AI) — UFW

| Port | Protocol | From | Purpose |
|------|----------|------|---------|
| 8472 | UDP | 10.10.0.0/24 | Flannel VXLAN |
| 22 | TCP | Anywhere | SSH |

### External firewall (Trooper AI GPU node)

Trooper AI has an external firewall in front of the GPU node. These rules must be configured in the Trooper AI dashboard **before** WireGuard can connect:

| Port | Protocol | Destination | Direction | Purpose |
|------|----------|-------------|-----------|---------|
| 51820 | UDP | <GPU_NODE_IP> | Outbound | WireGuard handshake/keepalive to CP |


## Files

| File | Purpose |
|------|---------|
| `cp-wireguard-setup.sh` | WireGuard + K3s config on CP node |
| `gpu-wireguard-setup.sh` | WireGuard setup on GPU node |
| `trooper-gpu-port-forward.sh` | Optional: kubelet port forwarding for Trooper AI |
