# Case α (alpha) — Minimal Single Model

FastAPI reverse proxy → vLLM → GPU (single Vast.ai instance, no separate CP). No KServe, no llm-d.

## Architecture

```
Client → kubectl port-forward → FastAPI Gateway → vLLM → GPU
```

Everything runs on one Vast.ai instance — K3s server (control plane + workloads) on the same machine as the GPU.

## Requirements

### Instance (Vast.ai)

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| vCPU | 4 | 8 |
| RAM | 8 GB | 16 GB |
| Disk | 40 GB | 80 GB |
| GPU | RTX 4090 (24 GB) | For larger models |

### Vast.ai template ports

| Port | Purpose |
|------|---------|
| (none required) | Use `kubectl port-forward` — no open inbound ports needed |

### Software (pre-installed on image)

| Component | Notes |
|-----------|-------|
| Docker | For building the gateway image |
| CUDA + nvidia-smi | GPU drivers |
| curl, bash | Bootstrap prerequisites |

---

## Contents

| File / Dir | Purpose |
|------------|---------|
| `fastapi-gateway/` | FastAPI reverse proxy (Dockerfile + app code) |
| `fastapi-deployment.yaml` | K8s Deployment + Service for the gateway |
| `vllm-deployment.yaml` | K8s Deployment + Service + Namespace for vLLM |
| `gpu_providers/vast-ai-single.sh` | Single-node K3s server bootstrap for Vast.ai |

---

## Model Weight Strategy

By default, vLLM downloads the model weights from Hugging Face at pod startup. This is simple but adds ~5-15 min cold start on first launch.

| Strategy | Cold Start | Image Size | When to use |
|----------|-----------|------------|-------------|
| **HF download** (default) | 5–15 min | ~1 GB (python + vLLM) | First deployment, prototyping |
| **Baked in Docker image** | ~10 s | ~20 GB (includes ~19 GB weights) | Hot start, frequent pod restarts |

### Option A: Hugging Face download (default)

The `vllm-deployment.yaml` references the model by name — vLLM downloads it from HF at startup:

```
deepseek-ai/DeepSeek-Coder-33B-Instruct-AWQ
```

A `HUGGING_FACE_HUB_TOKEN` secret is needed for gated models. The weights are cached in an `emptyDir` volume under `/root/.cache/huggingface/`.

### Option B: Bake weights into a custom vLLM image (hot start)

Pre-download the model and build a custom image:

```bash
bash model-image/build.sh \
  --base vllm/vllm-openai:latest \
  --model deepseek-ai/DeepSeek-Coder-33B-Instruct-AWQ \
  --tag vllm-with-weights:latest
```

Then update `vllm-deployment.yaml` to use `vllm-with-weights:latest` instead of `vllm/vllm-openai:latest`.

---

## Deployment

### 1. Bootstrap K3s on Vast.ai

SSH into your Vast.ai instance and run:

```bash
# Copy the script to the instance or curl it from a raw URL
bash gpu_providers/vast-ai-single.sh
```

This installs K3s server, configures the NVIDIA container runtime, and deploys the NVIDIA device plugin.

### 2. Create the Hugging Face token secret

```bash
kubectl create namespace alpha
kubectl -n alpha create secret generic hf-token --from-literal=token=<your-hf-token>
```

If the model is public (like Qwen/Qwen2.5-0.5B-Instruct), you can skip this step.

### 3. Build the gateway image (local, no registry needed)

```bash
docker build -t llm-gateway:latest case_alpha/fastapi-gateway
```

`imagePullPolicy: IfNotPresent` picks up the locally built image.

### 4. Deploy vLLM

```bash
kubectl apply -f case_alpha/vllm-deployment.yaml

# Watch the pod — model download can take a few minutes
kubectl -n alpha get pods -w
```

### 5. Deploy FastAPI gateway

```bash
kubectl apply -f case_alpha/fastapi-deployment.yaml
```

### 6. Test via port-forward

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

---

## What alpha does NOT include

- KServe (no CRDs, no InferenceService)
- llm-d (no router, no EPP scheduler, no prefix-cache routing)
- Envoy AI Gateway (no token metering, no rate limiting)
- Scale-to-zero (pod runs 24/7)
- MIG or GPU sharing
- Multi-model serving

## When to use alpha

- First deployment: learn the K3s + Vast.ai bootstrap workflow
- Single model, low traffic, no advanced routing needed
- Budget-conscious proof of concept
- Baseline to compare against beta (llm-d improvements)
