# Case Gamma — Multi-Model MIG on A100 40GB

## Overview

Single NVIDIA A100 40GB GPU split via MIG (Multi-Instance GPU) into two slices:

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
│  Rate Limits: 7B=50/min, 14B=30/min         │
│  Token Limits: 7B=10K/min, 14B=5K/min       │
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

- K3s cluster with NVIDIA GPU operator (MIG-enabled)
- KServe installed (via `case_beta/k8s_deploy.sh`)
- Envoy AI Gateway installed (via `case_beta/k8s_deploy.sh`)
- Monitoring stack installed (kube-prometheus-stack, DCGM, ServiceMonitors)

## Setup

### 1. Configure MIG on GPU node

SSH into the GPU node and run:

```bash
# First time: install mig-parted + create systemd service
bash case_gamma/mig/configure-mig.sh --profiles 2g.10gb,3g.20gb --install

# Subsequent (after reboot): MIG auto-restores via systemd
# Manual re-apply only if needed:
bash case_gamma/mig/configure-mig.sh --profiles 2g.10gb,3g.20gb
```

The `--install` flag:
- Creates a systemd service (`nvidia-mig-config.service`) that restores MIG partitions on boot
- Partitions are recreated using `nvidia-smi mig -cgi` after `nvidia-persistenced` starts

### 2. Deploy gamma resources

```bash
bash case_gamma/k8s_deploy.sh
```

This applies:
- MIG device plugin config
- KServe LLMInferenceServices (model + workload configs)
- Envoy AI Gateway backends + AIGatewayRoute
- Rate limit policies

### 3. Verify

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

## Files

```
case_gamma/
├── README.md                              # This file
├── k8s_deploy.sh                          # Deploy script
├── envoy-ai-gateway/
│   ├── aigatewayroute.yaml                # Set B AIGatewayRoute (model routing)
│   ├── backend-qwen7b.yaml                # Backend + AIServiceBackend for 7B
│   ├── backend-qwen14b.yaml               # Backend + AIServiceBackend for 14B
│   └── rate-limit.yaml                    # Per-model rate/token limits
├── kserve/
│   ├── llm-inference-service-config-model-qwen7b.yaml     # Model config for 7B
│   ├── llm-inference-service-config-model-qwen14b.yaml    # Model config for 14B
│   ├── llm-inference-service-config-workload-qwen7b.yaml  # Workload config for 7B
│   ├── llm-inference-service-config-workload-qwen14b.yaml # Workload config for 14B
│   ├── llm-inferenceservice-qwen7b.yaml                   # LLMInferenceService for 7B
│   └── llm-inferenceservice-qwen14b.yaml                  # LLMInferenceService for 14B
└── mig/
    ├── configure-mig.sh                   # MIG setup script + systemd installer
    └── device-plugin-config.yaml          # NVIDIA MIG device plugin configmap
```

### On GPU node (after --install)

```
/etc/systemd/system/nvidia-mig-config.service  # Boot-time MIG restore
```
