# Case β (beta) — Single Model, Improved (with llm-d)

Envoy AI Gateway → KServe + llm-d + EPP → vLLM → Vast.ai RTX 4090. Adds cache-aware routing, token metering, and rate limiting over alpha.

## Architecture

```
Client → Envoy AI Gateway (port 80)
           ├── Token metering + rate limiting
           ├── InferencePool routing
           │
           └── KServe LLMInferenceService "deepseek-33b"
                ├── llm-d Router (cache-aware endpoint)
                ├── EPP Scheduler
                │   ├── prefix-cache scorer (w:2.0)
                │   └── load-aware scorer (w:1.0)
                └── InferencePool → vLLM pod (DeepSeek-Coder-33B-Instruct-AWQ)
                                      │
                               Vast.ai RTX 4090 (K3s agent)
```

## Requirements

### Kubernetes Cluster

Same as alpha — see [case_alpha/README.md](../case_alpha/README.md#requirements).

### GPU (Vast.ai)

| GPU | VRAM | Why |
|-----|------|-----|
| **RTX 4090** | 24 GB | Fits DeepSeek 33B AWQ (~19 GB) with room for KV cache |

### Model Weights

Weights are baked into the Docker image at build time — no download at pod startup. The build uses the shared [model-image/build.sh](../model-image/build.sh) script.

| Property | Value |
|----------|-------|
| Strategy | Baked in image |
| Cold start | ~10 s |
| Image size | ~20 GB (includes ~19 GB weights) |

### Software (additional components over alpha)

| Component | Version | Source |
|-----------|---------|--------|
| cert-manager | 1.17+ | Helm |
| Gateway API CRDs | v1.3.0+ | Raw manifests |
| GIE CRDs | v0.3.0+ | envoy/ai-gateway |
| Envoy Gateway | v1.5+ | Helm |
| Envoy AI Gateway | latest | Helm |
| LWS Operator | v0.6.2+ | Helm |
| KServe | v0.18+ | Helm (llm-d mode) |

---

## Install Order

1. **K3s** — single-node on Hetzner (see [k3s-install.sh](../k8s_control_plane/k3s-install.sh))
2. **cert-manager** — webhook certificates
3. **Gateway API CRDs** — standard K8s gateway resources
4. **GIE CRDs** — InferencePool, InferenceModel (must precede Envoy Gateway)
5. **Envoy Gateway** — Gateway API provider
6. **Envoy AI Gateway** — AI routing, token metering, rate limiting
7. **LWS Operator** — LeaderWorkerSet (needed by KServe)
8. **KServe** — LLMInferenceService CRD (llm-d mode)
9. **Monitoring** — Prometheus + Grafana + DCGM (shared stack, see [monitoring/](../monitoring/))
10. **Build model image** — bake weights into serving image
11. **Deploy LLMInferenceServiceConfig + LLMInferenceService**
12. **Apply Envoy AI Gateway config** — InferencePool, InferenceModel, HTTPRoute

---

## Contents

| File / Dir | Purpose |
|------------|---------|
| `envoy-ai-gateway/` | Envoy AI Gateway CRDs (InferencePool, InferenceModel, HTTPRoute) |
| `kserve/` | KServe LLMInferenceServiceConfig + LLMInferenceService |
| `epp-scheduler/` | EPP scorer weights reference |

---

## Deployment

### 1. Prerequisites

- K3s cluster running (see [k8s_control_plane](../k8s_control_plane/))
- Vast.ai instance joined as K3s agent, labeled `cloud=vast`, NVIDIA device plugin installed

### 2. Create the beta namespace

```bash
kubectl create namespace beta
```

### 3. Install cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io --force-update
helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace \
  --version v1.17.1 \
  --set crds.enabled=true
```

### 4. Install Gateway API CRDs

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml
```

### 5. Install GIE CRDs

```bash
kubectl apply -f https://github.com/envoyproxy/ai-gateway/releases/download/latest/crds.yaml
```

### 6. Install Envoy Gateway

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.5.0 -n envoy-gateway-system --create-namespace
```

### 7. Install Envoy AI Gateway

```bash
helm install aig oci://docker.io/envoyproxy/ai-gateway-helm --version latest -n envoy-ai-gateway-system --create-namespace
```

### 8. Install LWS Operator

```bash
helm install lws oci://registry.k8s.io/lws/charts/lws --version v0.6.2 \
  --namespace lws-system --create-namespace
```

### 9. Install KServe (llm-d mode)

```bash
helm install kserve oci://ghcr.io/kserve/charts/kserve --version v0.18.0 -n kserve --create-namespace \
  --set llm-d.enabled=true
```

### 10. Install monitoring stack

Prometheus + Grafana + DCGM exporter for GPU metrics. Installed once per cluster — shared by all cases.

```bash
kubectl create namespace monitoring
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  -f ../monitoring/kube-prometheus-stack-values.yaml
kubectl apply -f ../monitoring/dcgm-exporter.yaml
```

See [monitoring/README.md](../monitoring/README.md) for dashboard setup and Grafana access.

### 11. Build the model image

Model weights are baked into the serving image for hot start (~10 s cold start vs 5–15 min with HF download).

```bash
bash model-image/build.sh \
  --base quay.io/kserve/vllm:latest \
  --model deepseek-ai/DeepSeek-Coder-33B-Instruct-AWQ \
  --tag kserve-vllm-with-weights:latest
```

For a single-node cluster the image stays local (`imagePullPolicy: IfNotPresent`). For multi-node, push to a registry and update the image in `kserve/llm-inferenceservice-config.yaml`.

### 12. Create LLMInferenceServiceConfig template

```bash
kubectl apply -f kserve/llm-inferenceservice-config.yaml
```

### 13. Deploy LLMInferenceService

```bash
kubectl apply -f kserve/llm-inferenceservice.yaml
```

### 14. Apply Envoy AI Gateway config

```bash
kubectl apply -f envoy-ai-gateway/
```

### 15. Test

```bash
GATEWAY_IP=<control-plane-ip>

curl -X POST http://$GATEWAY_IP/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <api-key>" \
  -d '{
    "model": "deepseek-coder-33b",
    "messages": [{"role": "user", "content": "Write a hello world in Python"}],
    "max_tokens": 100
  }'
```

---

## Key Differences from alpha

| Aspect | alpha | beta |
|--------|-------|------|
| Gateway | FastAPI (custom) | Envoy AI Gateway |
| Model deployment | plain Deployment | KServe LLMInferenceService |
| Model weights | HF download at startup | Baked in Docker image |
| Router | None (kube-proxy) | llm-d (cache-aware) |
| Scheduler | None | EPP (prefix-cache + load-aware) |
| Token metering | ❌ | ✅ |
| Rate limiting | ❌ (manual) | ✅ (per-user, per-model) |
| Scale-to-zero | ❌ | ✅ (WVA) |
| Install complexity | Low | Medium |

---

## What beta does NOT include

- Multi-model serving (see gamma)
- MIG or GPU sharing (see gamma)
- RunPod provider (see omega)

## When to use beta

- Production single-model deployment
- Multi-turn conversations where prefix caching matters
- When token metering and rate limiting are required
- Baseline to test llm-d improvements over alpha
