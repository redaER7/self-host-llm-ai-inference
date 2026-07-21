# Case α (alpha) — Minimal Single Model

FastAPI reverse proxy → vLLM on a Vast.ai GPU, with a WireGuard tunnel connecting the Hetzner control plane to the GPU node. No KServe, no llm-d.

## Architecture

```
                              ┌─────────────────────┐
                              │   Hetzner CX33       │
                              │   K3s control-plane  │
                              │                      │
 Client ──port-forward──→ FastAPI Gateway (ClusterIP)
                              │       │
                              │ 10.10.0.1 (wg0)
                              │       │
                          WireGuard   │
                              │       │
                              │ 10.10.0.2 (wg0)
                              │       │
                              │  vLLM (ClusterIP)
                              │       │
                               │   GPU (RTX 3090/4090)
                              └───────┴─────────────┘
```

| Component | Where | Detail |
|-----------|-------|--------|
| K3s CP | Hetzner CX33 (4 vCPU, 8 GB) | K3s server, `node-role.kubernetes.io/control-plane` |
| GPU worker | Vast.ai / Trooper AI | K3s agent, `gpu-node` label + taint |
| FastAPI gateway | Hetzner CP | Standard pod via `llm-gateway:8200` ClusterIP |
| vLLM | GPU node | Standard pod via `vllm-service:8100` ClusterIP |
| WireGuard | Hetzner ↔ GPU (native) | Data-plane tunnel, subnet 10.10.0.0/24 |
| Client access | Local machine | `kubectl port-forward svc/llm-gateway 8080:8200` |

Pods use standard Flannel overlay networking. VXLAN traffic flows through the WireGuard tunnel, so cross-node pod-to-pod communication (e.g. FastAPI → vLLM) works via ClusterIP DNS names without `hostNetwork`.

### WireGuard Notes

- The K3s API uses the **WG IP** (`K3S_URL=https://10.10.0.1:6443`) since nodes are on overlapping private networks.
- The WireGuard tunnel carries both **control-plane** (kubelet, VXLAN) and **data-plane** traffic between the nodes.
- `dnsPolicy: ClusterFirstWithHostNet` on both pods ensures CoreDNS still resolves service names despite host networking.

## Requirements

### Vast.ai Template Ports

| Port | Purpose |
|------|---------|
| 8472 | Flannel VXLAN (required for pod networking) |
| 10250 | Kubelet (required for kubectl exec, logs, port-forward) |

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
| Docker | For building and pushing the gateway image |
| CUDA 12.x | Pre-installed on Vast.ai GPU images |
| WireGuard tools | On Vast.ai, for tunnel client |

## Contents

| File / Dir | Purpose |
|------------|---------|
| `fastapi-gateway/` | FastAPI reverse proxy (Dockerfile + app code) |
| `fastapi-deployment.yaml` | K8s Deployment + Service for the gateway (ClusterIP) |
| `vllm-deployment.yaml` | K8s Deployment + Service + Namespace for vLLM |
| `wireguard-setup.sh` | WireGuard client setup (delegates to `../wireguard/gpu-setup.sh`, address `10.8.0.3/24`) |
| `gpu_providers/vast-ai-bootstrap.sh` | K3s agent bootstrap for Vast.ai GPU instances |

## Model Weight Strategy

By default, vLLM downloads the model weights from Hugging Face at pod startup.

| Strategy | Cold Start | Image Size | When to use |
|----------|-----------|------------|-------------|
| **HF download** (default) | 1-2 min | ~1 GB (python + vLLM) | First deployment, prototyping |
| **Baked in Docker image** | ~10 s | ~6 GB (includes weights) | Hot start, frequent restarts |

### Hugging Face download (default)

The `vllm-deployment.yaml` references `Qwen/Qwen2.5-7B-Instruct` — vLLM downloads it at startup (~4 GB). A `HF_TOKEN` secret is included in the deployment for higher Hugging Face API rate limits (not required for this public model). Weights are cached in an `emptyDir` volume under `/root/.cache/huggingface/`.

### Bake weights into a custom vLLM image

```bash
bash model-image/build.sh \
  --base vllm/vllm-openai:latest \
  --model Qwen/Qwen2.5-7B-Instruct \
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

The script installs the K3s agent, NVIDIA container toolkit, and configures containerd.

### 4. Label and taint the GPU node

On the **control plane**, run:

```bash
NODE_NAME=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name | sed 's|node/||')
kubectl label node "$NODE_NAME" \
  node-role.kubernetes.io/gpu-node=true \
  role=gpu
kubectl taint node "$NODE_NAME" gpu-node=true:NoSchedule
```

### 5. Apply NVIDIA device plugin

```bash
bash k8s_control_plane/apply-gpu-manifests.sh
```

### 6. Set up WireGuard tunnel

Run the shared CP setup script first (if not already done):

```bash
bash wireguard/cp-setup.sh
```

Then on the **GPU node**, run the shared GPU setup with the alpha-specific address:

```bash
export CP_NODE_IP=89.167.109.193
export WG_ADDRESS=10.8.0.3/24
bash wireguard/gpu-setup.sh
```

On the **CP node**, add the GPU's public key as a second peer in `/etc/wireguard/wg0.conf`:

```ini
[Peer]
# case_alpha GPU
PublicKey = <alpha-gpu-public-key>
AllowedIPs = 10.8.0.3/32
```

Then restart: `sudo systemctl restart wg-quick@wg0`

Verify the tunnel is up:

```bash
# From GPU
ping -c 3 10.8.0.1

# From CP
ping -c 3 10.8.0.3
```

### 7. Create registry credentials secret

```bash
kubectl create namespace alpha
kubectl -n alpha create secret docker-registry registry-credentials \
  --docker-server=docker-registry.yacodata.com \
  --docker-username="${REGISTRY_USER}" \
  --docker-password="${REGISTRY_PASS}"
```

### 8. Build and push the gateway image

```bash
docker build -t docker-registry.yacodata.com/llm-gateway:0.1 \
  case_alpha/fastapi-gateway/
docker tag docker-registry.yacodata.com/llm-gateway:0.1 \
  docker-registry.yacodata.com/llm-gateway:latest
docker push docker-registry.yacodata.com/llm-gateway:0.1
docker push docker-registry.yacodata.com/llm-gateway:latest
```

### 9. Deploy vLLM

```bash
kubectl apply -f case_alpha/vllm-deployment.yaml
kubectl -n alpha get pods -w
```

Wait for the vLLM pod to reach `Running`. Model download (~4 GB) may take 1-2 minutes.

### 10. Deploy FastAPI gateway

```bash
kubectl apply -f case_alpha/fastapi-deployment.yaml
```

### 11. Test via port-forward

The API is kept local — accessed via `kubectl port-forward`. Envoy AI Gateway will be added in case beta for external exposure.

```bash
kubectl -n alpha port-forward svc/llm-gateway 8080:8200 &

curl -s -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct",
    "messages": [{"role": "user", "content": "Write hello world in Python"}],
    "max_tokens": 50
  }' | jq -r '.choices[0].message.content' | sed 's/Ġ/ /g; s/Ċ/\n/g'
```

## When to use alpha

- First deployment: learn the K3s + Vast.ai bootstrap workflow
- Single model, low traffic, no advanced routing needed
- Budget-conscious proof of concept
- Baseline to compare against beta (llm-d improvements)
