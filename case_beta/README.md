# Case β (beta) — Single Model, All on GPU Node

Envoy AI Gateway → KServe + llm-d + EPP → vLLM → Vast.ai RTX 3090. All components co-located on the GPU node — no cross-node networking, no WireGuard latency, no tunnel complexity.

## Architecture

```
Client → envoy-llm.yacodata.com:30080
           ↓
         Envoy Gateway proxy (GPU node, NodePort 30080 → HTTPS)
           ↓
         Envoy AI Gateway (InferencePool)
           ├── Token metering + rate limiting
           ├── Cache-aware routing
           │
           └── KServe LLMInferenceService "qwen-7b"
                ├── llm-d Router (cache-aware endpoint picker)
                ├── EPP Scheduler
                │   ├── prefix-cache scorer (w:2.0)
                │   └── load-aware scorer (w:1.0)
                └── vLLM pod (Qwen/Qwen2.5-7B-Instruct)
                      │
               Vast.ai RTX 3090 (single node, all local)
```

All inference traffic stays within the GPU node — no WireGuard tunnel, no cross-node ClusterIP routing, no external gateway component. Envoy Gateway proxy pods are scheduled on the GPU node via `nodeSelector` + `tolerations`, alongside the KServe vLLM workload.

TLS termination is handled by Envoy Gateway at the Gateway level. Certificates are provisioned automatically by cert-manager via Let's Encrypt DNS-01 challenge through Cloudflare.

## Benefits Over Alpha

| Benefit | Why |
|---------|-----|
| **No WireGuard latency** | Data plane is single-hop inside the GPU node |
| **Simpler networking** | No tunnel setup, no UFW rules, no hostNetwork workarounds |
| **Single entry point** | Envoy Gateway NodePort on `envoy-llm.yacodata.com` |
| **Production routing** | Token metering, rate limiting, cache-aware EPP scheduling |
| **Faster cold start** | Model weights baked into Docker image (~10 s vs 5-15 min HF download) |

## Requirements

### Kubernetes Cluster

Same K3s setup as alpha — see [case_alpha/README.md](../case_alpha/README.md#requirements). The control plane (Hetzner CX33) runs the K3s server and controllers; the data plane runs entirely on the GPU node.

### GPU (Vast.ai)

| GPU | VRAM | Why |
|-----|------|-----|
| **RTX 3090** | 24 GB | Fits Qwen 2.5-7B-Instruct (~4 GB) with room for KV cache and batch processing |

### Model Weights

Weights are baked into the Docker image at build time — no download at pod startup.

| Property | Value |
|----------|-------|
| Model | Qwen/Qwen2.5-7B-Instruct |
| Strategy | Baked in image |
| Cold start | ~10 s |
| Image size | ~6 GB (model + vLLM runtime) |

### Software Stack

| Component | Version | Notes |
|-----------|---------|-------|
| cert-manager | 1.17+ | Webhook certificates + Let's Encrypt (DNS-01 Cloudflare) |
| Gateway API CRDs | v1.3.0+ | Standard K8s gateway resources |
| GIE CRDs | v0.3.0+ | InferencePool, InferenceModel |
| Envoy Gateway | v1.5+ | Gateway API provider; proxy pods scheduled on GPU node |
| Envoy AI Gateway | latest | AI routing, token metering, rate limiting |
| LWS Operator | v0.6.2+ | LeaderWorkerSet (KServe dependency) |
| KServe | v0.18+ | LLMInferenceService CRD (llm-d mode) |

---

## Install Order

1. **K3s** — Hetzner CP + Vast.ai GPU agent (see [k3s-install.sh](../k8s_control_plane/k3s-install.sh) and [vast-ai-bootstrap.sh](../gpu_providers/vast-ai-bootstrap.sh))
2. **cert-manager** — webhook certificates
3. **Gateway API CRDs** — standard K8s gateway resources
4. **GIE CRDs** — InferencePool, InferenceModel (must precede Envoy Gateway)
5. **Envoy Gateway** — with custom config to schedule proxy pods on GPU node
6. **Envoy AI Gateway** — AI routing, token metering, rate limiting
7. **LWS Operator** — LeaderWorkerSet (needed by KServe)
8. **KServe** — LLMInferenceService CRD (llm-d mode)
9. **Monitoring** — Prometheus + Grafana + DCGM (shared stack, see [monitoring/](../monitoring/))
10. **Cloudflare DNS-01 secret + ClusterIssuer + Certificate** — Let's Encrypt TLS for envoy-llm.yacodata.com
11. **Create Gateway resource** — HTTPS listener referencing the cert-manager certificate
12. **Build model image** — bake Qwen weights into serving image
13. **Create secrets** — registry credentials and HF token
14. **Deploy LLMInferenceServiceConfig + LLMInferenceService**
15. **Apply InferencePool + InferenceModel** — Envoy AI Gateway pool config
16. **Apply HTTPRoute** — attach route to Gateway
17. **Expose Envoy Gateway** — patch service to NodePort
18. **Configure Vast.ai port forwarding** — map instance port → NodePort
19. **Apply CORS policy** — allow NextChat origin to call Envoy Gateway
20. **Set DNS A record** — envoy-llm.yacodata.com → Vast.ai public IP
21. **Deploy NextChat** — frontend UI on CP node (see [frontend/nextchat](../frontend/nextchat))

---

## Contents

| File / Dir | Purpose |
|------------|---------|
| `envoy-ai-gateway/gateway.yaml` | Gateway resource (HTTPS listener, TLS termination) |
| `envoy-ai-gateway/certificate.yaml` | ClusterIssuer + Certificate (Let's Encrypt DNS-01 via Cloudflare) |
| `envoy-ai-gateway/inferencepool.yaml` | InferencePool + InferenceModel |
| `envoy-ai-gateway/aigatewayroute.yaml` | HTTPRoute (route `/v1/` → KServe backend) |
| `envoy-ai-gateway/cors-policy.yaml` | SecurityPolicy (CORS for NextChat origin) |
| `kserve/` | KServe LLMInferenceServiceConfig + LLMInferenceService |
| `epp-scheduler/` | EPP scorer weights reference |

---

## Deployment

### 1. Prerequisites

- K3s cluster running with Hetzner CP and Vast.ai GPU agent joined and labeled `gpu-node`
- GPU node has NVIDIA drivers and device plugin installed

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

### 6. Install Envoy Gateway with GPU node scheduling

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.5.0 \
  -n envoy-gateway-system --create-namespace
```

Create an `EnvoyGateway` resource to schedule proxy pods on the GPU node:

```bash
kubectl apply -f - <<EOF
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyGateway
metadata:
  name: envoy-gateway-config
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyDeployment:
        replicas: 1
        pod:
          nodeSelector:
            node-role.kubernetes.io/gpu-node: "true"
          tolerations:
            - key: "gpu-node"
              operator: "Equal"
              value: "true"
              effect: "NoSchedule"
EOF
```

This ensures Envoy proxy pods land on the same node as the KServe vLLM workload — no cross-node networking needed.

### 7. Install Envoy AI Gateway

```bash
helm install aig oci://docker.io/envoyproxy/ai-gateway-helm --version latest \
  -n envoy-ai-gateway-system --create-namespace
```

### 8. Install LWS Operator

```bash
helm install lws oci://registry.k8s.io/lws/charts/lws --version v0.6.2 \
  --namespace lws-system --create-namespace
```

### 9. Install KServe (llm-d mode)

```bash
helm install kserve oci://ghcr.io/kserve/charts/kserve --version v0.18.0 \
  -n kserve --create-namespace \
  --set llm-d.enabled=true
```

### 10. Create Cloudflare DNS-01 secret, ClusterIssuer, and Certificate

Create the Cloudflare API token secret (requires DNS:Edit permission for yacodata.com):

```bash
kubectl create secret generic cloudflare-api-token \
  --namespace cert-manager \
  --from-literal=api-token=<cloudflare-api-token>
```

Apply the ClusterIssuer and Certificate:

```bash
kubectl apply -f envoy-ai-gateway/certificate.yaml
```

Wait for the certificate to be ready:

```bash
kubectl get certificate envoy-tls-cert -n envoy-ai-gateway-system -w
```

The DNS-01 challenge creates a TXT record in Cloudflare automatically. Once the certificate is Ready, proceed.

### 11. Create the Gateway resource

```bash
kubectl apply -f envoy-ai-gateway/gateway.yaml
```

This creates an HTTPS listener on port 443, terminating TLS with the cert-manager-issued certificate for `envoy-llm.yacodata.com`.

### 12. Install monitoring stack

Prometheus + Grafana + DCGM exporter for GPU metrics.

```bash
kubectl create namespace monitoring
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  -f ../monitoring/kube-prometheus-stack-values.yaml
kubectl apply -f ../monitoring/dcgm-exporter.yaml
```

See [monitoring/README.md](../monitoring/README.md) for dashboard setup and Grafana access.

### 13. Build the model image

Model weights are baked into the serving image for fast cold start (~10 s).

```bash
bash model-image/build.sh \
  --base quay.io/kserve/vllm:latest \
  --model Qwen/Qwen2.5-7B-Instruct \
  --tag docker-registry.yacodata.com/kserve-vllm-qwen:0.1
```

Push to the registry so the GPU node can pull it:

```bash
docker push docker-registry.yacodata.com/kserve-vllm-qwen:0.1
```

### 14. Create registry and HF secrets

```bash
kubectl create secret docker-registry registry-credentials \
  --namespace beta \
  --docker-server=docker-registry.yacodata.com \
  --docker-username=<username> \
  --docker-password=<password>

kubectl create secret generic hf-token \
  --namespace beta \
  --from-literal=token=<hf-token>
```

### 15. Create LLMInferenceServiceConfig template

```bash
kubectl apply -f kserve/llm-inferenceservice-config.yaml
```

### 16. Deploy LLMInferenceService

```bash
kubectl apply -f kserve/llm-inferenceservice.yaml
```

### 17. Apply InferencePool + InferenceModel

```bash
kubectl apply -f envoy-ai-gateway/inferencepool.yaml
```

### 18. Apply HTTPRoute

The HTTPRoute attaches to the `ai-gateway` Gateway in `envoy-ai-gateway-system` and routes `/v1/` traffic to the KServe service.

```bash
kubectl apply -f envoy-ai-gateway/aigatewayroute.yaml
```

### 19. Expose Envoy Gateway via NodePort

Envoy Gateway auto-creates a port for each Gateway listener. The HTTPS listener on port 443 appears as the first port in the service.

```bash
kubectl patch service envoy-gateway-proxy -n envoy-gateway-system \
  --type=json \
  -p='[{"op":"replace","path":"/spec/type","value":"NodePort"},{"op":"add","path":"/spec/ports/-","value":{"name":"https","port":443,"targetPort":443,"nodePort":30080,"protocol":"TCP"}}]'
```

### 20. Apply CORS policy

Allows NextChat (served from `chat.yacodata.com` or localhost) to make browser API calls to Envoy Gateway:

```bash
kubectl apply -f envoy-ai-gateway/cors-policy.yaml
```

### 21. Configure Vast.ai port forwarding

In the Vast.ai instance page, add a port mapping:
- **Port**: `30080`
- **Protocol**: TCP

This maps `https://<vast-public-ip>:<mapped-port>` → Envoy Gateway HTTPS on the GPU node.

### 22. Set DNS A records

| Record | Type | Value | Purpose |
|--------|------|-------|---------|
| `envoy-llm.yacodata.com` | A | `<vast-public-ip>` | TLS SNI for Envoy Gateway (proxy: DNS only) |
| `chat.yacodata.com` | A | `<hetzner-cp-ip>` | NextChat frontend (proxy: DNS only or proxied) |

The Let's Encrypt DNS-01 challenge uses Cloudflare API tokens, so the A record is only needed for TLS SNI at request time, not for certificate issuance.

### 23. Deploy NextChat frontend

NextChat is a static SPA served from the CP node. See [frontend/nextchat/README.md](../frontend/nextchat/README.md) for deployment.

```bash
kubectl create namespace frontend
kubectl apply -f ../frontend/nextchat/
```

Access at `http://<hetzner-cp-ip>:3080` and configure:
- **Endpoint**: `https://envoy-llm.yacodata.com:30080/v1`
- **Model**: `qwen2.5-7b`

### 24. Test

Using the domain (requires DNS A record):

```bash
curl -X POST https://envoy-llm.yacodata.com:30080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <api-key>" \
  -d '{
    "model": "qwen2.5-7b",
    "messages": [{"role": "user", "content": "Write a hello world in Python"}],
    "max_tokens": 100
  }'
```

Without DNS, use `--resolve` to override DNS resolution (cert still validates for the domain name):

```bash
VAST_IP=<vast-instance-public-ip>

curl -X POST https://envoy-llm.yacodata.com:30080/v1/chat/completions \
  --resolve envoy-llm.yacodata.com:30080:$VAST_IP \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <api-key>" \
  -d '{
    "model": "qwen2.5-7b",
    "messages": [{"role": "user", "content": "Write a hello world in Python"}],
    "max_tokens": 100
  }'
```

---

## Key Differences from alpha

| Aspect | alpha | beta |
|--------|-------|------|
| Gateway | FastAPI (custom, CP node) | Envoy AI Gateway (GPU node) |
| Networking | WireGuard tunnel (CP ↔ GPU) | All local (single node) |
| Latency | Cross-node hop | Zero additional hop |
| Setup complexity | WireGuard, UFW, hostNetwork | NodeSelector only |
| Model deployment | plain Deployment | KServe LLMInferenceService |
| Model weights | HF download at startup | Baked in Docker image |
| Router | None (kube-proxy) | llm-d (cache-aware) |
| Scheduler | None | EPP (prefix-cache + load-aware) |
| Token metering | ❌ | ✅ |
| Rate limiting | ❌ (manual) | ✅ (per-user, per-model) |
| Scale-to-zero | ❌ | ✅ (WVA) |

---

## What beta does NOT include

- Multi-model serving (see gamma)
- MIG or GPU sharing (see gamma)
- RunPod provider (see omega)

## When to use beta

- Production single-model deployment without cross-node networking overhead
- Multi-turn conversations where prefix caching matters
- When token metering and rate limiting are required
- When you want Envoy Gateway as the single routing layer (no FastAPI, no NGINX)
