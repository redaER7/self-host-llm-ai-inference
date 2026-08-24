# Case Gamma — Multi-Model MIG on A100 40GB (Trooper AI)

## Overview

Single NVIDIA A100 40GB GPU (Trooper AI) split via MIG (Multi-Instance GPU) into two slices:

| MIG Profile | VRAM | Model | Quantization |
|-------------|------|-------|--------------|
| `2g.10gb` | ~10 GB | Qwen 2.5 7B Instruct | AWQ |
| `3g.20gb` | ~20 GB | Qwen 2.5 14B Instruct | AWQ |

Models are downloaded at runtime from HuggingFace — no baked images required.

## Architecture

```
Client
  │
  ▼
┌──────────────────────────────────────────────┐
│  Envoy AI Gateway (llm.yacodata.com)        │
│  Header: x-ai-eg-model                      │
│  Rate Limits: 7B=60/min, 14B=40/min         │
└──────────┬──────────────────┬────────────────┘
           │                  │
    ┌──────▼──────┐    ┌──────▼──────┐
    │ AISvcBacknd │    │ AISvcBacknd │
    │ qwen7b      │    │ qwen14b     │
    └──────┬──────┘    └──────┬──────┘
           │                  │
    ┌──────▼──────┐    ┌──────▼──────┐
    │ KServe CR   │    │ KServe CR   │
    │ qwen-7b     │    │ qwen-14b    │
    └──────┬──────┘    └──────┬──────┘
           │                  │
    ┌──────▼──────┐    ┌──────▼──────┐
    │ vLLM Pod    │    │ vLLM Pod    │
    │ (2g.10gb)   │    │ (3g.20gb)   │
    │ 8080        │    │ 8081        │
    └─────────────┘    └─────────────┘
           │                  │
    ┌──────▼──────────────────▼──────┐
    │  A100 40GB (MIG-enabled)      │
    │  ├─ 2g.10gb instance          │
    │  └─ 3g.20gb instance          │
    └────────────────────────────────┘
```

## Prerequisites

- K3s cluster with a MIG-capable GPU node (single A100 40GB on Trooper AI)
- KServe installed on the cluster (shared cluster component)
- NVIDIA GPU operator / device plugin configured for MIG
- [k8s_secrets.sh](k8s_secrets.sh) run first (registry credentials, HF token, Cloudflare API token)

Everything else — cert-manager, Envoy AI Gateway, KServe model config, monitoring, dashboards — is installed by [k8s_deploy.sh](k8s_deploy.sh) itself.

## Quick Start

```bash
# 1. Set secrets as environment variables
export CLOUDFLARE_API_TOKEN="your-cloudflare-token"
export REGISTRY_USERNAME="your-registry-user"
export REGISTRY_PASSWORD="your-registry-password"
export HF_TOKEN="your-hf-token"

# 2. Create all secrets
bash k8s_secrets.sh

# 3. Deploy everything (run from the repo root)
bash case_gamma/k8s_deploy.sh
```

## MIG Setup

Configure MIG on the GPU node before deploying:

```bash
# First time: install mig config and systemd service
bash case_gamma/mig/configure-mig.sh --profiles 2g.10gb,3g.20gb --install

# Subsequent (after reboot): MIG auto-restores via systemd
# Manual re-apply only if needed:
bash case_gamma/mig/configure-mig.sh --profiles 2g.10gb,3g.20gb
```

The `--install` flag:
- Creates a systemd service (`nvidia-mig-config.service`) that restores MIG partitions on boot
- Partitions are recreated using `nvidia-smi mig -cgi` after `nvidia-persistenced` starts

## Install Order

Deployment is fully automated by [k8s_deploy.sh](k8s_deploy.sh) (run after [k8s_secrets.sh](k8s_secrets.sh)). The steps below mirror the script so you know what runs and in what order:

0. **MIG pre-check** — verifies the MIG device plugin config exists
1. **Namespace** — creates `gamma`
2. **cert-manager + TLS certs** — webhook certificates + `envoy-tls-cert` / `chat-tls-cert` (Let's Encrypt DNS-01 via Cloudflare)
3. **AI Gateway CRDs (Helm)** — AIGatewayRoute CRDs
4. **AI Gateway Controller (Helm)** — AI routing, token metering
5. **Envoy Gateway (Helm)** — Gateway API provider
6. **GatewayClass + EnvoyProxy + Gateway** — HTTPS listeners referencing the cert-manager certificates
7. **Enable InferencePool + restart** — apply EG addon values + rollout restart
8. **Re-apply Gateways + KServe ingress gateway** — after KServe CRDs are present
9. **MIG device plugin config** — NVIDIA device plugin ConfigMap
10. **Patch Envoy proxy service → NodePort 30080** — expose `ai-gateway` externally
11. **KServe model configs** — model + workload LLMInferenceServiceConfigs for 7B and 14B
12. **KServe LLMInferenceServices** — 7B and 14B
13. **Envoy AI Gateway backends** — Backend + AIServiceBackend for 7B and 14B
14. **AIGatewayRoute** — header match routes models via `x-ai-eg-model`
15. **Rate limiting** — BackendTrafficPolicy (7B=60 req/min, 14B=40 req/min)
16. **CORS policy** — allow NextChat origin to call Envoy Gateway
17. **kube-prometheus-stack** — Prometheus + Grafana + node_exporter (monitoring namespace)
18. **ServiceMonitors** — scrape vLLM, Envoy proxy, AI Gateway metrics
19. **DCGM Exporter** — GPU metrics on GPU node (with ServiceMonitor)
20. **Grafana dashboards** — vLLM, Envoy Gateway, DCGM, AI Gateway ConfigMaps (auto-imported)

## Verify

```bash
# Check pods
kubectl get pods -n gamma -w

# Check LLMInferenceServices
kubectl get llminferenceservices -n gamma

# Check backends
kubectl get backends -n gamma

# Check route
kubectl get aigatewayroute -n gamma
```

## Testing

### Qwen 2.5 7B

```bash
curl -X POST https://llm.yacodata.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-ai-eg-model: Qwen/Qwen2.5-7B-Instruct-AWQ" \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct-AWQ",
    "messages": [{"role": "user", "content": "hello"}],
    "max_tokens": 50
  }'
```

### Qwen 2.5 14B

```bash
curl -X POST https://llm.yacodata.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-ai-eg-model: Qwen/Qwen2.5-14B-Instruct-AWQ" \
  -d '{
    "model": "Qwen/Qwen2.5-14B-Instruct-AWQ",
    "messages": [{"role": "user", "content": "hello"}],
    "max_tokens": 50
  }'
```

### Tool calling (Qwen 14B)

```bash
curl -X POST https://llm.yacodata.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-ai-eg-model: Qwen/Qwen2.5-14B-Instruct-AWQ" \
  -d '{
    "model": "Qwen/Qwen2.5-14B-Instruct-AWQ",
    "messages": [{"role": "user", "content": "What is the weather in Paris?"}],
    "tools": [{"type": "function", "function": {"name": "get_weather", "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}],
    "max_tokens": 100
  }'
```

## Troubleshooting

### Pod stuck in Pending

```bash
kubectl describe llminferenceservice qwen-7b -n gamma
```

Check if MIG profiles are active:
```bash
nvidia-smi --query-gpu=gpu_bus_id,mig.mode.current --format=csv
```

### 502 Bad Gateway

Check if the backend is reachable:
```bash
kubectl get svc -n gamma
kubectl get endpoints -n gamma
```

### Model download slow on first request

vLLM downloads the full model from HuggingFace on cold start. Expect 2-5 min for 7B, 5-10 min for 14B depending on network.

## MIG Persistence Across Reboots

On A100 (Ampere), MIG mode itself persists across reboots (stored in GPU InfoROM), but the individual MIG partitions (instances) do NOT. After each reboot, the partitions must be recreated.

This setup uses a systemd service to handle this automatically:

| Component | Path | Purpose |
|-----------|------|---------|
| Systemd service | `/etc/systemd/system/nvidia-mig-config.service` | Restores partitions at boot |
| Script | `case_gamma/mig/configure-mig.sh` | Installs and configures everything |

### How it works

1. On boot, systemd starts `nvidia-mig-config.service` (after `nvidia-persistenced`)
2. The service runs `nvidia-smi mig -cgi` to recreate the partitions
3. MIG partitions are restored before K3s agent starts registering resources

### Manual operations

```bash
# Check current MIG status
nvidia-smi -L

# Re-apply MIG config (e.g., after driver update)
sudo nvidia-smi mig -dci 2>/dev/null; sudo nvidia-smi mig -dgi 2>/dev/null
sudo nvidia-smi mig -cgi 2g.10gb,3g.20gb -C

# Disable the systemd service
sudo systemctl disable nvidia-mig-config.service
```

## What gamma does NOT include

- Multi-node GPU deployment (single A100, partitioned via MIG)
- Baked model images (downloads from HF at startup)
- Scale-to-zero (pods run 24/7)
- RunPod provider (see omega)
- Multi-replica scaling (each model runs 1 replica; EPP configured via `endpoint-picker-config.yaml` for future scaling)

## When to use gamma

- Multi-model serving on a single partitioned GPU (MIG) — two models on one A100 40GB
- When models should be reachable through one public HTTPS endpoint with header-based routing
- When per-model rate limiting is required at the gateway
- When you want model-specific metrics and dashboards (vLLM, Envoy Gateway, DCGM, AI Gateway)

## Benchmarking

Run concurrent load tests against both models via the AI Gateway header-based routing:

```bash
python Tests/case_gamma_concurrent.py --concurrency 10 --min-tokens 100 --max-tokens 1200
```

See `Tests/case_gamma_concurrent.py` for full options (TTFT probes, streaming vs non-streaming, per-model latency/token throughput summaries).

## Files

```
case_gamma/
├── README.md                              # This file
├── k8s_secrets.sh                         # Create all secrets + TLS certificates (run first)
├── k8s_deploy.sh                          # Deploy everything (run after secrets)
├── envoy-ai-gateway/
│   ├── aigatewayroute.yaml                # AIGatewayRoute (model routing via x-ai-eg-model, request timeout 300s)
│   ├── backend-qwen7b.yaml                # Backend + AIServiceBackend for 7B
│   ├── backend-qwen14b.yaml               # Backend + AIServiceBackend for 14B
│   ├── rate-limit.yaml                    # Per-model request rate limits
│   ├── cors-policy.yaml                   # SecurityPolicy (CORS for NextChat origin)
│   ├── gatewayclass.yaml                  # GatewayClass (references Envoy Gateway controller)
│   ├── gateway.yaml                       # Gateway resource (HTTPS listener, TLS termination)
│   ├── envoyproxy.yaml                    # EnvoyProxy (CP node scheduling, NodePort service)
│   ├── kserve-gateway.yaml                # KServe internal Gateway (ClusterIP)
│   ├── certificate.yaml                   # ClusterIssuer + Certificate (Let's Encrypt DNS-01)
│   ├── envoy-gateway-values.yaml          # EG Helm values (proxy config)
│   └── envoy-gateway-values-addon.yaml    # EG addon values (enable InferencePool)
├── kserve/
│   ├── llm-inference-service-config-model-qwen7b.yaml     # Model config for 7B
│   ├── llm-inference-service-config-model-qwen14b.yaml    # Model config for 14B
│   ├── llm-inference-service-config-workload-qwen7b.yaml  # Workload config for 7B
│   ├── llm-inference-service-config-workload-qwen14b.yaml # Workload config for 14B
│   ├── llm-inferenceservice-qwen7b.yaml                   # LLMInferenceService for 7B
│   ├── inferenceservice-config-patch.yaml                 # storage-initializer resources (cpu=4, mem=24Gi)
│   └── llm-inferenceservice-qwen14b.yaml                  # LLMInferenceService for 14B
└── mig/
    ├── configure-mig.sh                   # MIG setup script + systemd installer
    └── device-plugin-config.yaml          # NVIDIA MIG device plugin configmap
```

### On GPU node (after --install)

```
/etc/systemd/system/nvidia-mig-config.service  # Boot-time MIG restore
```
