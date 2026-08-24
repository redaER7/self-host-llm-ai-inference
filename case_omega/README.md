# Case Ω (omega) — Multi-Model on Blackwell (2 GPUs, no MIG)

KServe + vLLM + llm-d + Envoy AI Gateway → 2 separate GPUs, no MIG partitioning.

## What omega does

| Model | GPU | VRAM | Quant | Context |
|-------|-----|------|-------|---------|
| Llama 3.1 70B Instruct | RTX Pro 5000 Blackwell (48GB) | ~35GB | AWQ INT4 | 16384 |
| Mistral 7B Instruct | RTX Pro 4000 Blackwell (24GB) | ~14GB | BF16 | 8192 |

- **2 LLMInferenceServices** (one per model)
- **llm-d EPP** wired (prefix-cache + load-aware scorers)
- **Envoy AI Gateway** routes via `x-ai-eg-model` header
- **Per-model rate limiting** via Envoy BackendTrafficPolicy
- **TLS** via Let's Encrypt (Cloudflare DNS01)
- **Monitoring**: kube-prometheus-stack + Grafana + vLLM dashboards + DCGM exporter

## Architecture

```
Internet
  │
  └── Envoy AI Gateway (NodePort 30080)
        ├── x-ai-eg-model: meta-llama/Llama-3.1-70B-Instruct
        │     └── LLMInferenceService "llama70b"
        │           └── vLLM (Llama 70B AWQ INT4) on Blackwell 48GB
        │
        └── x-ai-eg-model: mistralai/Mistral-7B-Instruct-v0.3
              └── LLMInferenceService "mistral7b"
                    └── vLLM (Mistral 7B BF16) on Blackwell 24GB
```

## Prerequisites

1. GPU nodes bootstrapped with labels:
   - `node-role.kubernetes.io/gpu-node=true`
   - `gpu-type=rtx-pro-5000-blackwell` (or appropriate label for each GPU)
   - Taint: `gpu-node=true:NoSchedule`
2. NVIDIA container runtime + device plugin installed on each GPU node
3. K3s agent connected to the cluster
4. Environment variables set:
   - `HF_TOKEN` — HuggingFace token (model download)
   - `REGISTRY_USERNAME` / `REGISTRY_PASSWORD` — Docker registry credentials
   - `CLOUDFLARE_API_TOKEN` — Cloudflare API token (TLS certificates)

## Deployment

```bash
# 1. Create secrets (run once)
export HF_TOKEN=hf_...
export REGISTRY_USERNAME=...
export REGISTRY_PASSWORD=...
export CLOUDFLARE_API_TOKEN=...
bash k8s_secrets.sh

# 2. Deploy all resources
bash k8s_deploy.sh
```

Notes:
- AIGatewayRoute rules set `timeouts.request: 300s` (long decode responses exceed Envoy's 60 s default)
- Step 9b patches the storage-initializer init-container resources (cpu=4, mem=24Gi) via `kserve/inferenceservice-config-patch.yaml` and restarts the KServe controller

## Verification

```bash
# Check pods
kubectl get pods -n omega -w

# Check LLMInferenceServices
kubectl get llminferenceservices -n omega

# Test Llama 70B
curl -X POST https://llm.yacodata.com/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'x-ai-eg-model: meta-llama/Llama-3.1-70B-Instruct' \
  -d '{"model":"meta-llama/Llama-3.1-70B-Instruct","messages":[{"role":"user","content":"hello"}],"max_tokens":50}'

# Test Mistral 7B
curl -X POST https://llm.yacodata.com/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'x-ai-eg-model: mistralai/Mistral-7B-Instruct-v0.3' \
  -d '{"model":"mistralai/Mistral-7B-Instruct-v0.3","messages":[{"role":"user","content":"hello"}],"max_tokens":50}'
```

## What omega does NOT include

- **No MIG** — each model gets a full GPU (no partitioning)
- **No auto-scaling** — fixed 1 replica per model (add HPA/WVA later if needed)
- **No scale-to-zero** — pods stay running (add Knative or similar later)
- **No WireGuard** — RunPod-style networking not used; direct GPU node connectivity

## Differences from gamma

| Aspect | Gamma | Omega |
|--------|-------|-------|
| GPU | A100 40GB (MIG) | 2× Blackwell (48GB + 24GB, no MIG) |
| Models | 2 (Qwen 7B + Qwen 14B) | 2 (Llama 70B + Mistral 7B) |
| MIG | ✅ | ❌ |
| MIG directory | ✅ | ❌ |
| Workload resources | `nvidia.com/mig-*` | `nvidia.com/gpu: "1"` |
| Quantization | AWQ | AWQ (Llama) + BF16 (Mistral) |
