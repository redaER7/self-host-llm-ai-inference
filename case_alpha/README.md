# Case α (alpha) — Minimal Single Model

Envoy Gateway → vLLM on a Trooper AI GPU, with a WireGuard tunnel connecting the Hetzner control plane to the GPU node. Public HTTPS via cert-manager. Security code–protected NextChat frontend.

## Architecture

```
Browser ──https──→ llm.yacodata.com / chat.yacodata.com (443)
                      │
                 socat (CP host, 443 → 30080)
                      │
                 Envoy Gateway proxy (CP, NodePort 30080)
                    ├── /v1/*  → vLLM (GPU, vllm-service:8100 via WireGuard)
                    └── /*     → NextChat (CP, nextchat:3000)
```

| Component | Where | Detail |
|-----------|-------|--------|
| K3s CP | Hetzner CX33 (4 vCPU, 8 GB) | K3s server, `node-role.kubernetes.io/control-plane` |
| GPU worker | Trooper AI | K3s agent, `gpu-node` label + taint |
| Envoy Gateway | Hetzner CP | Helm install (no AI Gateway), proxy pod on CP node |
| vLLM | GPU node | `hostNetwork: true`, HF download at startup |
| NextChat | Hetzner CP | ClusterIP:3000, password protected via `CODE` env var |
| TLS | cert-manager | Let's Encrypt DNS-01 via Cloudflare, SAN cert for both domains |
| WireGuard | Hetzner ↔ GPU (native) | Data-plane tunnel, subnet 10.10.0.0/24 |
| Port 443 | socat systemd service | `TCP-LISTEN:443 → TCP:127.0.0.1:30080` |

## Requirements

### GPU (Trooper AI)

| GPU | VRAM | Why |
|-----|------|-----|
| RTX 3090 / RTX 6000 Ada | 24–48 GB | Fits Qwen 2.5-3B (~2 GB) with lots of headroom |

### Hetzner Firewall

| Port | Source | Purpose |
|------|--------|---------|
| 6443 | $GPU_NODE_IP | K3s API — GPU node joins via public IP |
| 51820/udp | 10.10.0.0/24 | WireGuard |
| 22 | ${PERSONAL_IP} | SSH |

### Software

| Component | Notes |
|-----------|-------|
| K3s v1.33+ | Lightweight Kubernetes |
| NVIDIA device plugin | GPU scheduling (`k8s_control_plane/manifests/nvidia-device-plugin.yaml`) |
| Helm | cert-manager, Envoy Gateway installation |

## Contents

| File / Dir | Purpose |
|------------|---------|
| `k8s_secrets.sh` | Namespaces + secrets (run first) |
| `k8s_deploy.sh` | Full 12-step deployment (run second) |
| `envoy-gateway/` | Envoy Gateway resources (no AI Gateway extensions) |
| `envoy-gateway/gatewayclass.yaml` | GatewayClass `envoy` |
| `envoy-gateway/envoyproxy.yaml` | CP node scheduling, NodePort type |
| `envoy-gateway/gateway.yaml` | Single HTTPS listener, SAN cert for both domains |
| `envoy-gateway/certificate.yaml` | ClusterIssuer + Certificate (Let's Encrypt DNS-01) |
| `envoy-gateway/httproute-vllm.yaml` | Route `/v1/*` → `vllm-service:8100` |
| `envoy-gateway/httproute-nextchat.yaml` | Route `chat.yacodata.com` → `nextchat:3000` |
| `envoy-gateway/cors-policy.yaml` | CORS for NextChat origin |
| `frontend/nextchat/deployment.yaml` | Alpha-specific NextChat (CODE + correct model) |
| `vllm-deployment.yaml` | vLLM Deployment + Service (Qwen2.5-3B-Instruct) |

## Quick Start

### 1. Set environment variables

```bash
export CLOUDFLARE_API_TOKEN="your-cloudflare-token"
export REGISTRY_USERNAME="your-registry-user"
export REGISTRY_PASSWORD="your-registry-password"
export HF_TOKEN="your-hf-token"
export NEXTCHAT_CODE="your-chat-password"
```

### 2. Create secrets and namespaces

```bash
bash case_alpha/k8s_secrets.sh
```

### 3. Deploy everything

```bash
bash case_alpha/k8s_deploy.sh
```

### 4. Port 443 forwarder (run once)

```bash
bash hetzner-cp-node-socat.sh
```

## Deployment Details

The `k8s_deploy.sh` script runs 12 steps:

```
 1. Namespaces (alpha, frontend, cert-manager, envoy-*)
 2. cert-manager (Helm v1.18.0)
 3. NVIDIA device plugin (local manifest with GPU node tolerations)
 4. Envoy Gateway (Helm, minimal values — no AI Gateway)
 5. GatewayClass + EnvoyProxy + Gateway
 6. TLS Certificate (wait for Ready)
 7. Patch proxy service → NodePort 30080
 8. vLLM deployment (Qwen2.5-3B, GPU node)
 9. NextChat (deployment + service, HTTP only)
10. HTTPRoutes (vLLM + NextChat)
11. CORS policy
12. socat forwarder (443 → 30080)
```

## Testing

```bash
# Inference via public domain
curl -X POST https://llm.yacodata.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen2.5-3B-Instruct","messages":[{"role":"user","content":"hello"}],"max_tokens":100}'

# NextChat (open in browser)
# https://chat.yacodata.com/

# Local test via Envoy NodePort (bypasses socat)
curl -k -X POST https://localhost:30080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Host: llm.yacodata.com" \
  -d '{"model":"Qwen/Qwen2.5-3B-Instruct","messages":[{"role":"user","content":"hello"}],"max_tokens":100}'
```

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Envoy Gateway | Same pattern as beta, no custom code to maintain |
| No AI Gateway | Plain HTTPRoute instead of AIGatewayRoute — no router needed |
| SAN cert (both domains) | Single cert, one Let's Encrypt rate limit, simpler than two certs |
| socat (not iptables) | Reliable, systemd-managed, no conflict with kube-proxy iptables |
| Path-based routing (not SNI) | Single listener, routes by path prefix |
| NextChat password | `CODE` env var from Kubernetes Secret |
| No baked model image | HF download at startup (3B is small, ~1-2 min) |

## What alpha does NOT include

- KServe (no CRDs, no InferenceService)
- llm-d (no router, no EPP scheduler)
- Envoy AI Gateway (no token metering, no rate limiting)
- Scale-to-zero (pod runs 24/7)
- MIG or GPU sharing
- Multi-model serving
- Baked model image

## When to use alpha

- First deployment: learn the K3s + Trooper AI bootstrap workflow
- Minimal stack: Envoy Gateway + vLLM + NextChat
- Test public HTTPS inference before adding complexity
- Baseline to compare against beta (KServe + llm-d improvements)
