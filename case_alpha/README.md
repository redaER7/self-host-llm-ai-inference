# Case α (alpha) — Minimal Single Model

FastAPI reverse proxy → vLLM → Vast.ai RTX 4090. No KServe, no llm-d.

## Architecture

```
Client → FastAPI Gateway (port 80) → vLLM (port 8001) → GPU (RTX 4090)
```

## Requirements

### Kubernetes Cluster

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| Kubernetes version | v1.25+ | v1.32+ |
| K3s version | v1.25+ | v1.32+ |
| Control plane nodes | 1 | 3 (HA) |
| vCPU per node | 4 | 8 |
| RAM per node | 8 GB | 16 GB |
| Disk per node | 40 GB | 80 GB |

> **Reference**: We use Hetzner Cloud (e.g. CX33, 4 vCPU / 8 GB RAM, ~€10.70/mo). Any K8s-ready provider works.

### GPU (Vast.ai)

| GPU | VRAM | Why |
|-----|------|-----|
| **RTX 4090** | 24 GB | Fits DeepSeek 33B AWQ (~19 GB) with room for KV cache |
| RTX 6000 Ada | 48 GB | Overkill but works |

### Storage

| Type | Size | Purpose |
|------|------|---------|
| Control plane disk | 20–40 GB | K3s + OS + kubelet images |
| Model weights (downloaded) | ~40 GB | DeepSeek-Coder-33B-Instruct-AWQ |

### Networking

| Component | Requirement |
|-----------|-------------|
| Vast.ai → Control plane | Direct public IP (K3s agent joins via K3S_URL) |
| Client → FastAPI | NodePort or Ingress on control plane |
| Ports | 6443 (K3s API), 80/443 (FastAPI) |

### Software

| Component | Version | Notes |
|-----------|---------|-------|
| K3s | v1.32+ | Lightweight Kubernetes |
| NVIDIA device plugin | latest | GPU scheduling on Vast.ai node |
| Docker | 24+ | For building the gateway image |
| Python | 3.11+ | For local dev/testing (optional) |

---

## Contents

| File / Dir | Purpose |
|------------|---------|
| `fastapi-gateway/` | FastAPI reverse proxy (Dockerfile + app code) |
| `fastapi-deployment.yaml` | K8s Deployment + Service for the gateway |
| `vllm-deployment.yaml` | K8s Deployment + Service + Namespace for vLLM |
| `gpu_providers/vast-ai-bootstrap.sh` | K3s agent bootstrap for Vast.ai GPU instances |

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

### 1. Prerequisites

- K3s cluster running (see [k8s_control_plane](../k8s_control_plane/))
- Vast.ai instance joined as K3s agent (see [gpu_providers/vast-ai-bootstrap.sh](../gpu_providers/vast-ai-bootstrap.sh))
- NVIDIA device plugin installed on the Vast.ai node

### 2. Create the Hugging Face token secret

```bash
kubectl create namespace alpha
kubectl -n alpha create secret generic hf-token --from-literal=token=<your-hf-token>
```

If the model is not gated (public), you can skip this step — the vLLM pod references it as optional.

### 3. Build and push the gateway image

```bash
# Build
docker build -t llm-gateway:latest ./fastapi-gateway

# If using a multi-node cluster, push to a registry
docker tag llm-gateway:latest <your-registry>/llm-gateway:latest
docker push <your-registry>/llm-gateway:latest
```

> **Note**: For a single-node cluster you can skip the registry — `imagePullPolicy: IfNotPresent` uses the locally built image.

### 4. Deploy vLLM

```bash
kubectl apply -f vllm-deployment.yaml

# Watch the pod — model download can take 5-15 min
kubectl -n alpha get pods -w
```

### 5. Deploy FastAPI gateway

```bash
kubectl apply -f fastapi-deployment.yaml
```

### 6. Test

```bash
# Get the gateway NodePort
GATEWAY_PORT=$(kubectl -n alpha get svc llm-gateway -o jsonpath='{.spec.ports[0].nodePort}')
GATEWAY_IP=<any-control-plane-node-ip>

curl -X POST http://$GATEWAY_IP:$GATEWAY_PORT/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-ai/DeepSeek-Coder-33B-Instruct-AWQ",
    "messages": [{"role": "user", "content": "Write a hello world in Python"}],
    "max_tokens": 100
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
