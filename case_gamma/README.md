# Case γ (gamma) — Multi-Model Binpacking (with llm-d)

Two models (Qwen 2.5 7B + Llama 3 70B) on a single A100 80GB via MIG partitioning. Each model gets its own KServe LLMInferenceService + llm-d + EPP stack, pinned to a dedicated MIG partition.

## Architecture

```
Client → Envoy AI Gateway
           ├── /v1/ + model: qwen2.5-7b   → KServe "qwen-llm"  → vLLM (MIG 1g.10gb)
           └── /v1/ + model: llama3-70b    → KServe "llama-llm" → vLLM (MIG 3g.40gb)
                                                  │
                                           Vast.ai A100 80GB (MIG partitioned)
```

### MIG Layout

```
A100 80GB
┌──────────────────────────────────────────────────┐
│ ┌─────────────────┐  ┌──────────────────────────┐ │
│ │ MIG 1g.10gb     │  │ MIG 3g.40gb             │ │
│ │ Qwen 2.5 7B AWQ │  │ Llama 3 70B AWQ         │ │
│ │ ~4 GB used      │  │ ~40 GB used             │ │
│ │ 6 GB KV cache   │  │ 24 GB KV cache          │ │
│ └─────────────────┘  └──────────────────────────┘ │
│ Remaining: ~30 GB (system, NCCL, buffers)         │
└──────────────────────────────────────────────────┘
```

## Requirements

### Kubernetes Cluster

Same as beta — see [case_beta/README.md](../case_beta/README.md#requirements).

### GPU (Vast.ai)

| GPU | VRAM | Why |
|-----|------|-----|
| **A100 80GB** | 80 GB | Required for MIG partitioning; supports 1g.10gb + 3g.40gb simultaneously |

### MIG Partitions

| Model | Partition | VRAM Allocated | VRAM Used | KV Cache Headroom |
|-------|-----------|---------------|-----------|-------------------|
| Qwen 2.5 7B | `1g.10gb` | 10 GB | ~4 GB | ~6 GB |
| Llama 3 70B | `3g.40gb` | 40 GB | ~40 GB | Shared system |
| System / NCA | — | ~30 GB | — | GPU context, scheduler |

### Model Images

Both models are baked into separate Docker images (hot start). See [model-image/README.md](./model-image/README.md) for build commands.

### Software

Same as beta — see [case_beta/README.md](../case_beta/README.md#software-additional-components-over-alpha).

---

## Install Order

1. **K3s** — single-node on Hetzner
2. **cert-manager** + **Gateway API CRDs** + **GIE CRDs** + **Envoy Gateway** + **Envoy AI Gateway** + **LWS** + **KServe** — same as beta (steps 2–8)
3. **Monitoring** — Prometheus + Grafana + DCGM (shared stack, see [monitoring/](../monitoring/))
4. **Rent A100 on Vast.ai** — join as K3s agent with `MIG_PROFILES=1g.10gb,3g.40gb`
5. **Apply MIG device plugin config** — `migStrategy: mixed`
6. **Build both model images** — Qwen + Llama baked Docker images
7. **Deploy LLMInferenceServiceConfig** + **both LLMInferenceServices**
8. **Apply Envoy AI Gateway config** — 2 InferencePools + 2 InferenceModels + HTTPRoute

---

## Contents

| File / Dir | Purpose |
|------------|---------|
| `mig/configure-mig.sh` | Creates MIG partitions on A100 via `nvidia-smi mig` |
| `mig/device-plugin-config.yaml` | ConfigMap for `migStrategy: mixed` |
| `envoy-ai-gateway/` | 2 InferencePools + 2 InferenceModels + HTTPRoute |
| `kserve/` | LLMInferenceServiceConfig + 2 LLMInferenceServices |
| `model-image/` | Build instructions for both model images |

---

## Deployment

### 1. Prerequisites

- K3s cluster running (see [k8s_control_plane](../k8s_control_plane/))
- KServe + Envoy AI Gateway installed (same as beta)
- Monitoring stack installed (see [monitoring/README.md](../monitoring/README.md))

### 2. Install monitoring stack (if not already installed)

Installed once per cluster — shared by alpha and beta cases.

```bash
kubectl create namespace monitoring
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  -f ../monitoring/kube-prometheus-stack-values.yaml
kubectl apply -f ../monitoring/dcgm-exporter.yaml
```

See [monitoring/README.md](../monitoring/README.md) for dashboard setup and Grafana access.

### 3. Rent an A100 on Vast.ai

Find an A100 80GB instance with MIG-capable drivers.

```bash
export K3S_URL=https://<control-plane-ip>:6443
export K3S_TOKEN=<node-token>
export MIG_PROFILES=1g.10gb,3g.40gb
bash gpu_providers/vast-ai-bootstrap.sh
```

The bootstrap script now creates MIG partitions automatically when `MIG_PROFILES` is set.

### 4. Apply MIG device plugin config

```bash
kubectl apply -f mig/device-plugin-config.yaml
```

The device plugin detects MIG partitions and exposes them as `nvidia.com/mig-1g.10gb` and `nvidia.com/mig-3g.40gb` resources.

### 5. Build model images

```bash
# Qwen 2.5 7B
bash ../model-image/build.sh \
  --base quay.io/kserve/vllm:latest \
  --model Qwen/Qwen2.5-7B-Instruct-AWQ \
  --tag qwen-with-weights:latest

# Llama 3 70B (requires HF token for gated model)
bash ../model-image/build.sh \
  --base quay.io/kserve/vllm:latest \
  --model meta-llama/Llama-3-70B-Instruct-AWQ \
  --tag llama-with-weights:latest
```

### 6. Create namespace and deploy KServe config

```bash
kubectl create namespace gamma
kubectl apply -f kserve/llm-inferenceservice-config.yaml
```

### 7. Deploy both models

```bash
kubectl apply -f kserve/llm-inferenceservice-qwen.yaml
kubectl apply -f kserve/llm-inferenceservice-llama.yaml
```

### 8. Apply Envoy AI Gateway config

```bash
kubectl apply -f envoy-ai-gateway/
```

### 9. Test

```bash
GATEWAY_IP=<control-plane-ip>

# Qwen
curl -X POST http://$GATEWAY_IP/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen2.5-7b", "messages": [{"role": "user", "content": "Hello"}]}'

# Llama
curl -X POST http://$GATEWAY_IP/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "llama3-70b", "messages": [{"role": "user", "content": "Hello"}]}'
```

---

## MIG Caveats

- Partition sizes are **static** — requires node reboot + re-creation to change
- Only A100/H100 GPUs support MIG (not RTX)
- Some Vast.ai providers may not expose MIG-capable drivers — look for "verified" hosts with CUDA 12.x
- Each MIG partition runs its own vLLM + llm-d EPP process
- Memory limits in the pod spec should match the MIG partition to avoid OOM

## What gamma does NOT include

- RunPod provider (see omega)
- More than 2 models on one GPU (theoretically possible with more MIG profiles)

## When to use gamma

- Two models need to share one expensive GPU
- MIG hardware isolation is preferred over time-slicing
- Cost efficiency is a priority (2 models, 1 GPU)
