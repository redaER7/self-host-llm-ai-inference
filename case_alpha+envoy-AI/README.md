# Case α+envoy-AI — Minimal Single Model with Envoy AI Gateway

Envoy AI Gateway → vLLM on a Trooper AI GPU, with a WireGuard tunnel connecting the Hetzner control plane to the GPU node. Public HTTPS via cert-manager. Token metering and CORS-enabled NextChat frontend.

Same as case_alpha but replaces plain Envoy Gateway HTTPRoute routing with Envoy AI Gateway (token metering).

## Architecture

```
Browser ──https──→ llm.yacodata.com / chat.yacodata.com (443)
                       │
                  socat (CP host, 443 → 30080)
                       │
                  Envoy Gateway proxy (CP, NodePort 30080)
                       │
              AI Gateway Controller — ext-proc
                       │
              AIGatewayRoute "qwen-route" (token metering)
                       │
              Backend → vllm-service.alpha.svc.cluster.local:8100
                       │
                   vLLM (GPU node)
```

| Component | Where | Detail |
|-----------|-------|--------|
| K3s CP | Hetzner CX33 (4 vCPU, 8 GB) | K3s server, `node-role.kubernetes.io/control-plane` |
| GPU worker | Trooper AI | K3s agent, `gpu-node` label + taint |
| Envoy Gateway | Hetzner CP | Helm install with AI Gateway extensionManager |
| AI Gateway Controller | Hetzner CP | Token metering, AIGatewayRoute routing |
| vLLM | GPU node | `hostNetwork: true`, HF download at startup (3B ~2 GB) |
| NextChat | Hetzner CP | ClusterIP:3000, password protected via `CODE` env var |
| TLS | cert-manager | Let's Encrypt DNS-01 via Cloudflare, SAN cert for both domains |
| WireGuard | Hetzner ↔ GPU (native) | Data-plane tunnel, subnet 10.10.0.0/24 |
| Port 443 | socat systemd service | `TCP-LISTEN:443 → TCP:127.0.0.1:30080` |

## Requirements

### GPU

| GPU | VRAM | Why |
|-----|------|-----|
| Any NVIDIA GPU | 4+ GB | Qwen 2.5-3B (~2 GB) fits even low-end GPUs |

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
| Helm | cert-manager, Envoy Gateway, AI Gateway installation |

## Contents

| File / Dir | Purpose |
|------------|---------|
| `k8s_secrets.sh` | Namespaces + secrets (run first) |
| `k8s_deploy.sh` | Full 16-step deployment (run second) |
| `envoy-ai-gateway/envoy-gateway-values.yaml` | Helm values with extensionManager → AI Gateway controller |
| `envoy-ai-gateway/gatewayclass.yaml` | GatewayClass `envoy` |
| `envoy-ai-gateway/envoyproxy.yaml` | CP node scheduling, NodePort type |
| `envoy-ai-gateway/gateway.yaml` | Two HTTPS listeners: `llm.yacodata.com` + `chat.yacodata.com` |
| `envoy-ai-gateway/certificate.yaml` | ClusterIssuer + Certificate (Let's Encrypt DNS-01) |
| `envoy-ai-gateway/backend.yaml` | Backend → `vllm-service.alpha.svc.cluster.local:8100` + AIServiceBackend |
| `envoy-ai-gateway/aigatewayroute.yaml` | AIGatewayRoute with token metering (no header match) |
| `envoy-ai-gateway/cors-policy.yaml` | SecurityPolicy (CORS for NextChat origin) |
| `envoy-ai-gateway/httproute-nextchat.yaml` | HTTPRoute for `chat.yacodata.com` → NextChat |
| `frontend/nextchat/deployment.yaml` | NextChat with `CUSTOM_MODELS: Qwen/Qwen2.5-3B-Instruct` |
| `frontend/nextchat/service.yaml` | NextChat ClusterIP:3000 |
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
bash case_alpha+envoy-AI/k8s_secrets.sh
```

### 3. Deploy everything

```bash
bash case_alpha+envoy-AI/k8s_deploy.sh
```

### 4. Port 443 forwarder (run once)

```bash
bash hetzner-cp-node-socat.sh
```

## Deployment Details

The `k8s_deploy.sh` script runs 18 steps:

```
 1. Namespaces (alpha, frontend, monitoring, cert-manager, envoy-*)
 2. cert-manager (Helm v1.18.0)
 3. AI Gateway CRDs (Helm v1.0.0)
 4. NVIDIA device plugin (local manifest with GPU node tolerations)
 5. Envoy Gateway (Helm, with extensionManager → AI Gateway controller)
 6. AI Gateway Controller (Helm v1.0.0)
 7. GatewayClass + EnvoyProxy + Gateway
 8. TLS Certificate (wait for Ready)
 9. Patch proxy service → NodePort 30080
10. vLLM deployment (Qwen2.5-3B, GPU node)
11. Backend + AIServiceBackend
12. AIGatewayRoute (token metering)
13. CORS policy (SecurityPolicy on Gateway)
14. NextChat (deployment + service + HTTPRoute)
15. socat forwarder (443 → 30080)
16. kube-prometheus-stack (Prometheus + Grafana + node_exporter + kube-state-metrics)
17. ServiceMonitors (vLLM + Envoy proxy metrics scrape)
18. DCGM Exporter (GPU metrics DaemonSet)
```

## Testing

```bash
# Inference via public domain
curl -X POST https://llm.yacodata.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen2.5-3B-Instruct","messages":[{"role":"user","content":"hello"}],"max_tokens":100}'

# NextChat (open in browser)
open https://chat.yacodata.com/

# Local test via Envoy NodePort (bypasses socat)
curl -k -X POST https://localhost:30080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Host: llm.yacodata.com" \
  -d '{"model":"Qwen/Qwen2.5-3B-Instruct","messages":[{"role":"user","content":"hello"}],"max_tokens":100}'
```

## Differences from case_alpha

| Aspect | case_alpha | case_alpha+envoy-AI |
|--------|------------|---------------------|
| Model | Qwen 2.5 3B | **Qwen 2.5 3B** (same) |
| Envoy Gateway values | Minimal (no extensions) | **extensionManager** → AI Gateway |
| AI Gateway CRDs | ❌ | ✅ |
| AI Gateway Controller | ❌ | ✅ |
| Routing | HTTPRoute `/v1/` → vLLM | **AIGatewayRoute** (with token metering) |
| Token metering | ❌ | ✅ (input/output/total) |

| Gateway listeners | Single HTTPS (both domains) | **Two listeners** (llm + chat) |

## Differences from case_beta

| Aspect | case_beta | case_alpha+envoy-AI |
|--------|-----------|---------------------|
| KServe | ✅ LLMInferenceService | **❌** plain Deployment |
| Backend target | InferencePool | **vLLM Service** (`vllm-service:8100`) |
| InferencePool | ✅ | ❌ |
| LWS Operator | ✅ | ❌ |
| Monitoring | ✅ Prometheus/DCGM | ✅ Prometheus/DCGM |
| Complexity | High | **Medium** |

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| AIGatewayRoute without header match | Single-model deployment — no need for `x-ai-eg-model` header; all requests routed to the only backend |
| Two Gateway listeners (llm + chat) | AIGatewayRoute attaches to `llm-https`, HTTPRoute attaches to `chat-https` — no route conflicts |
| Backend → Service FQDN (not InferencePool) | No KServe — vLLM is a plain Deployment with a ClusterIP Service |
| SAN cert (both domains) | Single cert, one Let's Encrypt rate limit, simpler than two certs |
| socat (not iptables) | Reliable, systemd-managed, no conflict with kube-proxy iptables |

## What this case does NOT include

- KServe (no CRDs, no InferenceService)
- InferencePool / InferenceModel (no EPP scheduler)
- Multi-model serving
- Envoy AI Gateway metrics (not yet configured)
- Scale-to-zero (pod runs 24/7)
- MIG or GPU sharing
- Baked model image (HF download at startup)
