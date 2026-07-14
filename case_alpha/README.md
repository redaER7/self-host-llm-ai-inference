# Case α (alpha) — Minimal Single Model

FastAPI reverse proxy → vLLM on a Vast.ai GPU, with a WireGuard tunnel connecting the Hetzner control plane to the GPU node. No KServe, no llm-d.

## Architecture

```
                              ┌─────────────────────┐
                              │   Hetzner CX33       │
                              │   K3s control-plane  │
                              │                      │
 Client ──port-forward──→ FastAPI Gateway (hostNetwork)
                              │       │
                              │ 10.8.0.1 (wg-easy)
                              │       │
                          WireGuard   │
                              │       │
                              │ 10.8.0.2 (client)
                              │       │
                              │  vLLM (hostNetwork)
                              │       │
                              │   GPU (RTX 4090)
                              └───────┴─────────────┘
```

| Component | Where | Detail |
|-----------|-------|--------|
| K3s CP | Hetzner CX33 (4 vCPU, 8 GB) | K3s server, `node-role.kubernetes.io/control-plane` |
| GPU worker | Vast.ai instance | K3s agent, `gpu-node` label + taint |
| FastAPI gateway | Hetzner CP | `hostNetwork: true`, reaches vLLM via WireGuard |
| vLLM | Vast.ai GPU | `hostNetwork: true`, listens on host's WireGuard IP |
| WireGuard | Hetzner (wg-easy) ↔ Vast.ai (client) | Data-plane tunnel, subnet 10.8.0.0/24 |
| Client access | Local machine | `kubectl port-forward svc/llm-gateway 8080:8000` |

Both pods use `hostNetwork: true` — the gateway connects to vLLM directly at the GPU node's WireGuard IP (`10.8.0.2:8000`), bypassing ClusterIP routing and avoiding cross-node VXLAN issues.

### WireGuard Notes

- The K3s API uses the **public IP** (`K3S_URL=https://<hetzner-public>:6443`) because wg-easy runs in Docker and owns `10.8.0.1` — the host K3s server is not directly reachable on that IP.
- The WireGuard tunnel only carries **data-plane** traffic (gateway → vLLM at `10.8.0.2:8000`), which is the latency-sensitive path.
- `dnsPolicy: ClusterFirstWithHostNet` on both pods ensures CoreDNS still resolves service names despite host networking.

## Requirements

### Vast.ai Template Ports

| Port | Purpose |
|------|---------|
| 8472 | Flannel VXLAN (required for pod networking) |
| 10250 | Kubelet (required for kubectl exec, logs, port-forward) |
| 8000 | vLLM HTTP API (when using NodePort; not needed with hostNetwork + WireGuard) |

### Hetzner Firewall

| Port | Source | Purpose |
|------|--------|---------|
| 6443 | 0.0.0.0/0 | K3s API — GPU node joins via public IP |
| 51820/udp | 10.8.0.0/24 | WireGuard (wg-easy container) |
| 22 | 0.0.0.0/0 | SSH |

### Software

| Component | Notes |
|-----------|-------|
| K3s v1.33+ | Lightweight Kubernetes |
| NVIDIA device plugin | GPU scheduling on Vast.ai node |
| Docker | For building the gateway image |
| CUDA 12.x | Pre-installed on Vast.ai GPU images |
| WireGuard tools | On Vast.ai, for tunnel client |

## Contents

| File / Dir | Purpose |
|------------|---------|
| `fastapi-gateway/` | FastAPI reverse proxy (Dockerfile + app code) |
| `fastapi-deployment.yaml` | K8s Deployment + Service for the gateway (ClusterIP) |
| `vllm-deployment.yaml` | K8s Deployment + Service + Namespace for vLLM |
| `gpu_providers/vast-ai-bootstrap.sh` | K3s agent bootstrap for Vast.ai GPU instances |

## Model Weight Strategy

By default, vLLM downloads the model weights from Hugging Face at pod startup.

| Strategy | Cold Start | Image Size | When to use |
|----------|-----------|------------|-------------|
| **HF download** (default) | 5–15 min | ~1 GB (python + vLLM) | First deployment, prototyping |
| **Baked in Docker image** | ~10 s | ~20 GB (includes weights) | Hot start, frequent restarts |

### Hugging Face download (default)

The `vllm-deployment.yaml` references the model by name — vLLM downloads it at startup. A `HF_TOKEN` secret is needed for gated models. Weights are cached in an `emptyDir` volume under `/root/.cache/huggingface/`.

### Bake weights into a custom vLLM image

```bash
bash model-image/build.sh \
  --base vllm/vllm-openai:latest \
  --model deepseek-ai/DeepSeek-Coder-33B-Instruct-AWQ \
  --tag vllm-with-weights:latest
```

Then update `vllm-deployment.yaml` to use the custom image.

## Deployment

### 1. Bootstrap the Hetzner control plane

```bash
ssh root@<hetzner-ip>
bash k8s_control_plane/k3s-install.sh
```

Note the `K3S_URL` and `K3S_TOKEN` output.

### 2. Create a Vast.ai instance

- Image: Ubuntu 22.04 with CUDA 12.x
- Open ports: **8472**, **10250**
- SSH in after provisioning

### 3. Bootstrap the GPU node

```bash
export K3S_URL=https://<hetzner-public-ip>:6443
export K3S_TOKEN=<node-token>
bash gpu_providers/vast-ai-bootstrap.sh
```

Verify the node joins:

```bash
kubectl get nodes
```

Expected: `albab-server-0` (control-plane) and `vast-*` (gpu-node), both Ready.

### 4. Apply NVIDIA device plugin

```bash
bash k8s_control_plane/apply-gpu-manifests.sh
```

### 5. Set up WireGuard tunnel

On the **Vast.ai** instance, install and configure the WireGuard client:

```bash
sudo apt update
sudo apt install -y wireguard-tools resolvconf
sudo modprobe wireguard
sudo systemctl enable resolvconf
sudo systemctl start resolvconf
```

Create `/etc/wireguard/wg0.conf` with the client config from the wg-easy admin UI:

```ini
[Interface]
PrivateKey = <client-private-key>
Address = 10.8.0.2/24
DNS = 10.8.0.1

[Peer]
PublicKey = <server-public-key>
PresharedKey = <preshared-key>
Endpoint = <hetzner-public-ip>:51820
AllowedIPs = 10.8.0.0/24
PersistentKeepalive = 25
```

Start the tunnel:

```bash
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0
```

Allow traffic from the tunnel to reach vLLM on port 8000:

```bash
sudo ufw allow from 10.8.0.0/24 to any port 8000 proto tcp
```

### 6. Create the Hugging Face token secret

```bash
kubectl create namespace alpha
kubectl -n alpha create secret generic hf-token --from-literal=token=<your-hf-token>
```

Skip this step if the model is public (e.g., Qwen/Qwen2.5-0.5B-Instruct).

### 7. Build and deploy the gateway image

```bash
docker build -t llm-gateway:latest case_alpha/fastapi-gateway

# If using a registry (multi-node):
# docker tag llm-gateway:latest <registry>/llm-gateway:latest
# docker push <registry>/llm-gateway:latest
```

### 8. Deploy vLLM

```bash
kubectl apply -f case_alpha/vllm-deployment.yaml
kubectl -n alpha get pods -w
```

Wait for the vLLM pod to reach `Running`. Model download may take a few minutes.

### 9. Deploy FastAPI gateway

```bash
kubectl apply -f case_alpha/fastapi-deployment.yaml
```

### 10. Test via port-forward

```bash
kubectl -n alpha port-forward svc/llm-gateway 8080:8000 &

curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-0.5B-Instruct",
    "messages": [{"role": "user", "content": "Say hello in Python"}],
    "max_tokens": 50
  }'
```

## When to use alpha

- First deployment: learn the K3s + Vast.ai bootstrap workflow
- Single model, low traffic, no advanced routing needed
- Budget-conscious proof of concept
- Baseline to compare against beta (llm-d improvements)
