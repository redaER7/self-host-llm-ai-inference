# WireGuard Setup

Shared WireGuard setup scripts for connecting a Hetzner CP node to one or more Vast.ai GPU nodes.

## How it works

Flannel VXLAN (UDP 8472) is used for pod-to-pod networking across nodes. The CP needs to reach each GPU node's Vast.ai internal IP (e.g. `10.0.2.15`), which is private and not routable from the public internet. A WireGuard tunnel makes each GPU reachable.

Additionally, when using `hostNetwork: true` on pods, they communicate directly via the WireGuard IPs (e.g. the FastAPI gateway at `10.8.0.1` reaches vLLM at `10.8.0.2:8100`).

```
CP node (Hetzner)                GPU node (Vast.ai)
┌────────────────────┐          ┌──────────────────────┐
│ wg0 (10.8.0.1) ────┼─ tunnel ─┼─→ wg0 (10.8.0.2)    │
│                    │ UDP 51820│   (or 10.8.0.3, etc) │
│ route <gpu-ip>     │          │                      │
│   via 10.8.0.X     │          │ UFW open: 8472,     │
└────────────────────┘          │  10250, 6443         │
                                └──────────────────────┘
```

## Setup

### 1. CP node (run once)

```bash
bash wireguard/cp-setup.sh
```

- Generates server keys at `/etc/wireguard/server.{key,pub}`
- Creates `/etc/wireguard/wg0.conf` with NAT for tunnel traffic
- Starts `wg-quick@wg0`
- Prints the **server public key** — share with each GPU node
- Open port **51820/udp** in the Hetzner firewall

### 2. Each GPU node

```bash
export CP_NODE_IP=89.167.109.193
export WG_ADDRESS=10.8.0.2/24   # unique per GPU: .2, .3, .4, ...
bash wireguard/gpu-setup.sh
```

The script:
- Generates client keys
- Prompts for the CP server's public key (reads `CP_NODE_IP` from env var or prompts)
- Creates `/etc/wireguard/wg0.conf` with the **return route** (`PostUp`)
- Starts `wg-quick@wg0`
- Configures UFW (Flannel VXLAN + control plane ports)
- Prints the **GPU client public key**

### 3. Add GPU peer to CP config

On the CP, add each GPU's public key to `/etc/wireguard/wg0.conf`:

```ini
[Peer]
PublicKey = <gpu-public-key>
AllowedIPs = 10.8.0.2/32
```

Then restart: `sudo systemctl restart wg-quick@wg0`

### 4. Verify

```bash
# From GPU node
ping -c 3 10.8.0.1

# From CP node
ping -c 3 10.8.0.2
```

### 5. VXLAN route on CP (if using VXLAN)

```bash
sudo ip route add <gpu-vast-ip>/32 via 10.8.0.2 dev wg0
```

## Multi-GPU example

CP config with two GPU peers:

```ini
[Interface]
Address = 10.8.0.1/24
ListenPort = 51820
PrivateKey = <cp-private-key>
MTU = 1420
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
# case_beta GPU
PublicKey = <beta-pub-key>
AllowedIPs = 10.8.0.2/32

[Peer]
# case_alpha GPU
PublicKey = <alpha-pub-key>
AllowedIPs = 10.8.0.3/32
```

## Firewall reference (GPU node)

| Port | Protocol | Purpose |
|------|----------|---------|
| 8472 | UDP | Flannel VXLAN (from CP only) |
| 10250 | TCP | Kubelet |
| 6443 | TCP | K3s API |
| 22 | TCP | SSH |

## Files

| File | Purpose |
|------|---------|
| `cp-setup.sh` | WireGuard server setup (run on Hetzner CP) |
| `gpu-setup.sh` | WireGuard client setup (run on each GPU node) |
