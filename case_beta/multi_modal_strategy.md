# Multi-Modal Binpacking Strategy (Strategy 2)

Run **two vLLM pods on one GPU** via NVIDIA time-slicing + MPS memory limits.

## Architecture

```
                          Envoy AI Gateway Proxy (CP)
                         /                           \
           x-ai-eg-model: Qwen/Qwen2.5-32B-Instruct-AWQ      x-ai-eg-model: Qwen-3B
                        /                               \
              InferencePool A                      InferencePool B
                    |                                    |
         ┌──────────▼──────────┐             ┌──────────▼──────────┐
          │  llm-server pod     │             │  qwen-3b pod        │
         │  CUDA_MPS_MEM_LIMIT │             │  CUDA_MPS_MEM_LIMIT │
         │  = 14 GiB          │             │  = 4 GiB            │
         └──────────┬──────────┘             └──────────┬──────────┘
                    │                                    │
                    └──────────┬─────────────────────────┘
                               │
                     ┌─────────▼─────────┐
                     │  RTX 4090 24 GiB  │
                     │  (time-sliced ×2) │
                     └───────────────────┘
```

## Memory Budget

| Component | DeepSeek 14B AWQ | Qwen 2.5-3B | Total |
|---|---|---|---|
| Weights | ~9.4 GiB | ~1.8 GiB (INT4) | ~11.2 GiB |
| KV Cache (4K ctx) | ~5 GiB | ~1 GiB | ~6 GiB |
| Overhead | ~1 GiB | ~0.5 GiB | ~1.5 GiB |
| **Total** | **~15.4 GiB** | **~3.3 GiB** | **~18.7 GiB** |

Fits in 24 GiB with ~5 GiB headroom.

## GPU Sharing Mechanism

### 1. NVIDIA Time-Slicing

Exposes 2 virtual GPUs from 1 physical GPU. Each pod gets one.

```yaml
# /var/lib/rancher/k3s/server/manifests/nvidia-device-plugin-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nvidia-device-plugin-config
  namespace: kube-system
data:
  config.yaml: |
    version: v1
    sharing:
      timeSlicing:
        resources:
          - name: nvidia.com/gpu
            replicas: 2
```

### 2. MPS Memory Limits

Each vLLM pod sets a hard GPU memory cap via CUDA MPS:

```yaml
env:
  - name: CUDA_MPS_PINNED_DEVICE_MEMORY_LIMIT
    value: "14000000000"  # 14 GiB for llm-server
```

```yaml
env:
  - name: CUDA_MPS_PINNED_DEVICE_MEMORY_LIMIT
    value: "4000000000"  # 4 GiB for Qwen
```

MPS daemon must run on the GPU node before pods start:

```bash
# On GPU node (init script or DaemonSet)
nvidia-cuda-mps-control -d
```

## New Files Required

### Model Config — Qwen 2.5-3B

**`case_beta/kserve/llm-inference-service-config-model-qwen.yaml`**

```yaml
apiVersion: serving.kserve.io/v1alpha1
kind: LLMInferenceServiceConfig
metadata:
  name: llm-inference-service-config-model-qwen
  namespace: beta
spec:
  model:
    uri: hf://Qwen/Qwen2.5-3B-Instruct
    name: Qwen/Qwen2.5-3B-Instruct
```

### Workload Config — Qwen 2.5-3B (GPU via time-slicing)

**`case_beta/kserve/llm-inference-service-config-workload-qwen.yaml`**

```yaml
apiVersion: serving.kserve.io/v1alpha1
kind: LLMInferenceServiceConfig
metadata:
  name: llm-inference-service-config-workload-qwen
  namespace: beta
spec:
  replicas: 1
  template:
    hostNetwork: true
    nodeSelector:
      node-role.kubernetes.io/gpu-node: "true"
    tolerations:
      - key: "gpu-node"
        operator: "Equal"
        value: "true"
        effect: "NoSchedule"
    imagePullSecrets:
      - name: registry-credentials
    containers:
      - name: main
        image: vllm/vllm-openai:latest
        command:
          - python3
          - -m
          - vllm.entrypoints.openai.api_server
        args:
          - --model
          - Qwen/Qwen2.5-3B-Instruct
          - --port
          - "8000"
          - --host
          - "0.0.0.0"
          - --dtype
          - auto
          - --quantization
          - awq
          - --tensor-parallel-size
          - "1"
          - --max-model-len
          - "4096"
          - --max-num-seqs
          - "4"
          - --gpu-memory-utilization
          - "0.20"
          - --download-dir
          - /mnt/huggingface/models
        env:
          - name: HF_TOKEN
            valueFrom:
              secretKeyRef:
                name: hf-token
                key: token
          - name: CUDA_MPS_PINNED_DEVICE_MEMORY_LIMIT
            value: "4000000000"
          - name: PYTHONUNBUFFERED
            value: "1"
        volumeMounts:
          - name: dshm
            mountPath: /dev/shm
          - name: model-cache
            mountPath: /mnt/huggingface/models
        resources:
          limits:
            nvidia.com/gpu: "1"
            memory: 8Gi
          requests:
            nvidia.com/gpu: "1"
            memory: 4Gi
        securityContext:
          runAsNonRoot: false
          capabilities:
            drop:
              - ALL
    volumes:
      - name: dshm
        emptyDir:
          medium: Memory
          sizeLimit: 2Gi
      - name: model-cache
        emptyDir: {}
```

### LLMInferenceService — Qwen 2.5-3B

**`case_beta/kserve/llm-inferenceservice-qwen.yaml`**

```yaml
apiVersion: serving.kserve.io/v1alpha1
kind: LLMInferenceService
metadata:
  name: qwen-3b
  namespace: beta
spec:
  baseRefs:
    - name: llm-inference-service-config-model-qwen
    - name: llm-inference-service-config-workload-qwen
```

### AI Gateway Backend — Qwen 2.5-3B

**`case_beta/envoy-ai-gateway/backend-qwen.yaml`**

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: Backend
metadata:
  name: qwen-inferencepool-backend
  namespace: beta
spec:
  endpoints:
    - fqdn:
        hostname: qwen-3b-kserve-workload-svc.beta.svc.cluster.local
        port: 8000
---
apiVersion: aigateway.envoyproxy.io/v1beta1
kind: AIServiceBackend
metadata:
  name: qwen-backend
  namespace: beta
spec:
  backendRef:
    group: gateway.envoyproxy.io
    kind: Backend
    name: qwen-inferencepool-backend
  schema:
    name: OpenAI
    version: v1
```

### Updated AIGatewayRoute

**`case_beta/envoy-ai-gateway/aigatewayroute.yaml`** (update existing)

```yaml
apiVersion: aigateway.envoyproxy.io/v1beta1
kind: AIGatewayRoute
metadata:
  name: llm-server-route
  namespace: beta
spec:
  hostnames:
    - llm.yacodata.com
  parentRefs:
    - name: ai-gateway
      namespace: envoy-ai-gateway-system
      kind: Gateway
      group: gateway.networking.k8s.io
  rules:
    - matches:
        - headers:
            - type: Exact
              name: x-ai-eg-model
              value: Qwen/Qwen2.5-32B-Instruct-AWQ
      backendRefs:
        - name: llm-server-backend
    - matches:
        - headers:
            - type: Exact
              name: x-ai-eg-model
              value: Qwen/Qwen2.5-3B-Instruct
      backendRefs:
        - name: qwen-backend
  llmRequestCosts:
    - metadataKey: llm_input_token
      type: InputToken
    - metadataKey: llm_output_token
      type: OutputToken
    - metadataKey: llm_total_token
      type: TotalToken
```

### Updated NextChat CUSTOM_MODELS

**`frontend/nextchat/deployment.yaml`** (update `CUSTOM_MODELS`)

```yaml
- name: CUSTOM_MODELS
  value: "Qwen/Qwen2.5-32B-Instruct-AWQ+max_tokens=8192,Qwen/Qwen2.5-3B-Instruct"
```

## Deploy Script Steps

Add to `case_beta/k8s_deploy.sh` after DeepSeek steps:

```bash
echo "=== 20. Qwen 2.5-3B KServe Configs ==="
kubectl apply -f "${SCRIPT_DIR}/kserve/llm-inference-service-config-model-qwen.yaml"
kubectl apply -f "${SCRIPT_DIR}/kserve/llm-inference-service-config-workload-qwen.yaml"

echo "=== 21. Qwen 2.5-3B LLMInferenceService ==="
kubectl apply -f "${SCRIPT_DIR}/kserve/llm-inferenceservice-qwen.yaml"

echo "=== 22. Qwen Backend + AIServiceBackend ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/backend-qwen.yaml"

echo "=== 23. Update AIGatewayRoute (add Qwen rule) ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/aigatewayroute.yaml"
```

## Verification

```bash
# Check both pods are running
kubectl get pods -n beta

# Test DeepSeek
curl -X POST https://llm.yacodata.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-ai-eg-model: Qwen/Qwen2.5-32B-Instruct-AWQ" \
  -d '{"model":"Qwen/Qwen2.5-32B-Instruct-AWQ","messages":[{"role":"user","content":"hello"}],"max_tokens":100}'

# Test Qwen
curl -X POST https://llm.yacodata.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-ai-eg-model: Qwen/Qwen2.5-3B-Instruct" \
  -d '{"model":"Qwen/Qwen2.5-3B-Instruct","messages":[{"role":"user","content":"hello"}],"max_tokens":100}'

# Check GPU memory split
kubectl exec -n beta deploy/llm-server -- nvidia-smi
kubectl exec -n beta deploy/qwen-3b -- nvidia-smi
```

## Prerequisites

1. **MPS Daemon** on GPU node: `nvidia-cuda-mps-control -d`
2. **NVIDIA device plugin** with time-slicing ConfigMap
3. Both pods must tolerate scheduling on the same GPU node
4. Total memory ≤ 24 GiB (verified: ~18.7 GiB)

## Risks

| Risk | Mitigation |
|---|---|
| OOM if DeepSeek peaks above 14 GiB | Set `--gpu-memory-utilization 0.60` on DeepSeek |
| Qwen cold start pre-empts DeepSeek's KV cache | Set `CUDA_MPS_ACTIVE_THREAD_PERCENTAGE=75` on DeepSeek, `25` on Qwen |
| MPS daemon not running | Deploy as DaemonSet with init container |
| Time-slicing adds context-switch latency | Acceptable for non-realtime workloads (<10ms overhead) |
