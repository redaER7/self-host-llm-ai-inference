# Case β (beta) — Single Model with Envoy AI Gateway + KServe + llm-d + EPP

Envoy AI Gateway → KServe LLMInferenceService → llm-d (EPP scheduler) → vLLM (Qwen 2.5 32B Instruct AWQ). Control plane on Hetzner CX33, GPU worker on Trooper AI (RTX 3090). Cross-node pod networking via Flannel VXLAN over WireGuard.

## Architecture

```
Client → https://llm.yacodata.com:443
           │
           ▼
         Envoy Gateway proxy (CP node, NodePort 30080)
           ├── TLS termination (cert-manager + Let's Encrypt)
           ├── CORS (SecurityPolicy for NextChat origin)
           │
           ▼
         AI Gateway Controller — ext-proc (model-based routing)
           ├── x-ai-eg-model header → AIServiceBackend
           ├── Token metering (InputToken / OutputToken / TotalToken)
           │
           ▼
          AIServiceBackend "llm-server-backend"
           │
           ▼
          Backend → InferencePool "llm-server-inference-pool"
           │         (gateway-api-inference-extension)
           ▼
         KServe internal gateway (kserve namespace, ClusterIP :80)
           │
           ▼
         llm-d router (EPP scheduler)
           ├── prefix-cache-scorer (weight 2.0)
           ├── load-aware-scorer (weight 1.0, threshold 50)
           └── max-score-picker
           │
           ▼
          vLLM pod (GPU node, hostNetwork, 10.10.0.2:8000)
            ├── model: Qwen/Qwen2.5-32B-Instruct-AWQ
            ├── quantization: awq
            ├── max-model-len: 8192
            ├── max-num-seqs: 8
            └── gpu-memory-utilization: 0.90
```

The AI Gateway proxy (Envoy), KServe controller, and llm-d (EPP scheduler) run on the **control-plane node** (Hetzner). The vLLM pod runs on the **GPU node** (Trooper AI) with `hostNetwork: true`, binding directly to `10.10.0.2:8000`. Cross-node traffic flows over Flannel VXLAN (`UDP 8472`) through a WireGuard tunnel (`10.10.0.0/24`).

TLS termination happens at the Envoy Gateway proxy (cert-manager + Let's Encrypt DNS-01 via Cloudflare).

## Key Features

| Feature | Implementation |
|---------|---------------|
| **Model-based routing** | AI Gateway Controller via `x-ai-eg-model` header |
| **Token metering** | AIGatewayRoute `llmRequestCosts` (input/output/total) |
| **Rate limiting** | BackendTrafficPolicy (30 req/min + 5000 tok/min) |
| **EPP scheduling** | KServe endpoint picker (prefix-cache + load-aware) |
| **InferencePool** | Gateway API Inference Extension CRD |
| **CORS** | SecurityPolicy for NextChat origins |
| **TLS** | cert-manager + Let's Encrypt DNS-01 via Cloudflare |

## Benefits Over Plain Deployment

| Benefit | Why |
|---------|-----|
| **Production routing** | Envoy AI Gateway with token metering, rate limiting, model-based routing |
| **KServe lifecycle** | LLMInferenceService manages deployment, service, InferencePool, HTTPRoute automatically |
| **Cache-aware routing** | EPP scheduler routes to pods with warm KV cache (prefix-cache-scorer) |
| **Load-aware routing** | EPP distributes across healthy pods (load-aware-scorer) |
| **Simple model updates** | Change model in config, redeploy — weights download at startup |
| **Single entry point** | Envoy Gateway NodePort on `llm.yacodata.com` |

## Requirements

### Kubernetes Cluster

Same K3s setup as alpha — see [case_alpha/README.md](../case_alpha/README.md#requirements). Control plane on Hetzner CX33 (4 vCPU / 8 GB RAM), GPU worker joined as K3s agent with label `node-role.kubernetes.io/gpu-node`.

### GPU (Trooper AI)
  
| GPU | VRAM | Why |
|-----|------|-----|
| **RTX 3090** | 24 GB | Fits Qwen 2.5 32B AWQ (~16 GiB weights) tight on KV cache — reduce max_model_len if needed |

### Model Weights

Weights download from HuggingFace on first pod startup. The model-cache volume persists across restarts, avoiding re-download.

| Property | Value |
|----------|-------|
| Model | Qwen/Qwen2.5-32B-Instruct-AWQ |
| Quantization | AWQ (INT4) |
| Strategy | HF download at startup |
| Cold start | ~5-6 min (first time), ~10 s (cached) |
| Download size | ~20 GB |
| VRAM usage | ~16 GiB weights + ~6 GiB KV cache (at 8192 ctx, batch=8) |

### Software Stack

| Component | Version | Notes |
|-----------|---------|-------|
| K3s | v1.33+ | Lightweight K8s; Flannel VXLAN over WireGuard |
| cert-manager | 1.18+ | Webhook certificates + Let's Encrypt (DNS-01 Cloudflare) |
| Envoy Gateway | v1.8+ | Gateway API provider; proxy pods on CP node |
| AI Gateway Controller (Helm) | v1.0.0 | AI routing, token metering, rate limiting |
| LWS Operator | v0.9+ | LeaderWorkerSet (KServe dependency) |
| KServe | v0.18+ | LLMInferenceService CRD |
| vLLM | latest | OpenAI-compatible LLM serving |

---

## Install Order

1. **K3s** — Hetzner CP + Trooper AI GPU agent (see [k3s-install.sh](../k8s_control_plane/k3s-install.sh))
2. **WireGuard tunnel** — Bridge CP and GPU networks. See [WireGuard setup](#wireguard-setup)
3. **cert-manager** — webhook certificates
4. **AI Gateway CRDs (Helm)** — InferencePool, AIGatewayRoute CRDs
5. **Envoy Gateway (Helm)** — installs Gateway API + Envoy CRDs, controller
6. **AI Gateway Controller (Helm)** — AI routing, token metering, rate limiting
7. **LWS Operator** — LeaderWorkerSet (needed by KServe)
8. **KServe** — LLMInferenceService CRD
9. **Cloudflare DNS-01 secret + ClusterIssuer + Certificate** — Let's Encrypt TLS for llm.yacodata.com
10. **Create Gateway + GatewayClass** — HTTPS listener referencing the cert-manager certificate
11. **Apply EnvoyProxy** — schedule proxy pods on CP node, service type NodePort
12. **Create secrets** — registry credentials and HF token
13. **Deploy LLMInferenceServiceConfig + LLMInferenceService** — model + workload configs
14. **Deploy Backend + AIServiceBackend** — Backend points to InferencePool created by LLMInferenceService
15. **Apply AIGatewayRoute** — route with header match `x-ai-eg-model: Qwen/Qwen2.5-32B-Instruct-AWQ`
16. **Apply CORS policy** — allow NextChat origin to call Envoy Gateway
17. **Set DNS A record** — llm.yacodata.com → Hetzner CP public IP
18. **Deploy NextChat** — frontend UI on CP node (see [frontend/nextchat](../frontend/nextchat))

---

## WireGuard Setup

Required when CP and GPU nodes are on different networks (e.g. Hetzner + Trooper AI). Skip if all nodes are on the same LAN — Flannel VXLAN works natively.

### How it works

Flannel uses VXLAN (`UDP 8472`) for pod-to-pod networking across nodes. The CP reaches the GPU node's WireGuard IP (`10.10.0.2`) via a tunnel.

```
CP node (Hetzner)                GPU node (Trooper AI)
┌────────────────────┐          ┌────────────────────┐
│ wg0 (10.10.0.1) ────┼─ tunnel ─┼─→ wg0 (10.10.0.2) │
│                    │ UDP 51820│                    │
│ Flannel iface: wg0 │          │ Flannel iface: wg0 │
└────────────────────┘          └────────────────────┘
```

### Step 1 — Set up WireGuard

On the CP node (Hetzner), run:
```bash
bash wireguard/cp-setup.sh
```

This creates the server key, starts WireGuard, and prints the **server public key**.

Open **port 51820/udp** in the Hetzner firewall.

### Step 2 — GPU node

On the GPU node (Trooper AI), run:
```bash
export CP_NODE_IP=89.167.109.193
bash wireguard/gpu-setup.sh
```

The script will:
1. Generate a client key pair
2. Prompt for the CP server's public key
3. Create `/etc/wireguard/wg0.conf`, start the tunnel
4. Print the GPU client public key

Copy the GPU public key. On the **CP node**, add it:
```bash
sudo sed -i '/^# \[Peer\]/a PublicKey = <paste-GPU-public-key>\nAllowedIPs = 10.10.0.2/32' /etc/wireguard/wg0.conf
sudo systemctl restart wg-quick@wg0
```

### Step 3 — Configure Flannel to use wg0

On the GPU node, configure K3s to bind Flannel to the WireGuard interface:
```bash
echo "flannel-iface: wg0" >> /etc/rancher/k3s/config.yaml
echo "node-ip: 10.10.0.2" >> /etc/rancher/k3s/config.yaml
sudo systemctl restart k3s-agent
```

No VXLAN route is needed — both nodes are on the `10.10.0.0/24` WireGuard subnet and route to each other natively.

### Step 4 — Verify

From the CP node:
```bash
ping -c 3 10.10.0.2
```

You should see replies (~31ms for Hetzner ↔ Trooper AI).

### Firewall reference (GPU node)

| Port | Protocol | Purpose |
|------|----------|---------|
| 8472 | UDP | Flannel VXLAN |
| 10250 | TCP | Kubelet |

---

## Contents

| File / Dir | Purpose |
|------------|---------|
| `k8s_secrets.sh` | Create all secrets + TLS certificate (run first) |
| `k8s_deploy.sh` | Deploy all infrastructure + workloads (run after secrets) |
| `envoy-ai-gateway/gatewayclass.yaml` | GatewayClass (references Envoy Gateway controller) |
| `envoy-ai-gateway/gateway.yaml` | Gateway resource (HTTPS listener, TLS termination, KServe label) |
| `envoy-ai-gateway/kserve-gateway.yaml` | KServe internal Gateway + EnvoyProxy (CP node, ClusterIP) |
| `envoy-ai-gateway/certificate.yaml` | ClusterIssuer + Certificate (Let's Encrypt DNS-01 via Cloudflare) |
| `envoy-ai-gateway/envoyproxy.yaml` | EnvoyProxy (CP node scheduling, NodePort service) |
| `envoy-ai-gateway/aigatewayroute.yaml` | AIGatewayRoute (header match → AIServiceBackend) |
| `envoy-ai-gateway/backend.yaml` | Backend + AIServiceBackend (Backend points to InferencePool) |
| `envoy-ai-gateway/cors-policy.yaml` | SecurityPolicy (CORS for NextChat origin) |
| `envoy-ai-gateway/rate-limit.yaml` | BackendTrafficPolicy (30 req/min + 5000 tok/min) |
| `kserve/llm-inference-service-config-model.yaml` | Model source (HF repo + model name) |
| `kserve/llm-inference-service-config-workload.yaml` | Workload config (vLLM image, args, resources, GPU scheduling) |
| `kserve/llm-inferenceservice.yaml` | LLMInferenceService (combines model + workload) |
| `kserve/endpoint-picker-config.yaml` | EPP scheduler scorer weights |
| `epp-scheduler/` | EPP scorer weights reference |

---

## Quick Start

```bash
# 1. Set secrets as environment variables
export CLOUDFLARE_API_TOKEN="your-cloudflare-token"
export REGISTRY_USERNAME="your-registry-user"
export REGISTRY_PASSWORD="your-registry-password"
export HF_TOKEN="your-hf-token"

# 2. Create all secrets
bash k8s_secrets.sh

# 3. Deploy everything
bash k8s_deploy.sh
```

---

## Deployment

### 1. Prerequisites

- K3s cluster running with Hetzner CP and Trooper AI GPU agent joined and labeled `gpu-node`
- GPU node has NVIDIA drivers and device plugin installed
- WireGuard tunnel established between CP (`10.10.0.1`) and GPU (`10.10.0.2`)
- Flannel configured to use `wg0` interface on the GPU node

### 2. Create the beta namespace

```bash
kubectl create namespace beta
```

### 3. Install cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io --force-update
helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace \
  --version v1.18.0 \
  --set crds.enabled=true
```

### 4. Install AI Gateway CRDs

```bash
helm upgrade -i aieg-crd oci://docker.io/envoyproxy/ai-gateway-crds-helm \
  --version v1.0.0 \
  --namespace envoy-ai-gateway-system \
  --create-namespace
```

### 5. Install Envoy Gateway

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.8.2 \
  -n envoy-gateway-system --create-namespace

kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available
```

### 6. Install AI Gateway Controller

```bash
helm upgrade -i aieg oci://docker.io/envoyproxy/ai-gateway-helm \
  --version v1.0.0 \
  --namespace envoy-ai-gateway-system \
  --create-namespace

kubectl wait --timeout=2m -n envoy-ai-gateway-system deployment/ai-gateway-controller --for=condition=Available
```

### 7. Install LWS Operator

```bash
helm install lws oci://registry.k8s.io/lws/charts/lws --version v0.9.0 \
  --namespace lws-system --create-namespace
```

### 8. Install KServe

```bash
kubectl apply --server-side -f https://github.com/kserve/kserve/releases/download/v0.18.0/kserve.yaml
```

### 9. Create Cloudflare DNS-01 secret, ClusterIssuer, and Certificate

```bash
kubectl create secret generic cloudflare-api-token \
  --namespace cert-manager \
  --from-literal=api-token=<cloudflare-api-token>

kubectl apply -f envoy-ai-gateway/certificate.yaml
```

Wait for the certificate to be ready:
```bash
kubectl get certificate envoy-tls-cert -n envoy-ai-gateway-system -w
```

### 10. Create Gateway + GatewayClass

```bash
kubectl apply -f envoy-ai-gateway/gatewayclass.yaml
kubectl apply -f envoy-ai-gateway/kserve-gateway.yaml
kubectl apply -f envoy-ai-gateway/envoyproxy.yaml
kubectl apply -f envoy-ai-gateway/gateway.yaml
```

This creates:
- A `GatewayClass` named `envoy` referencing the Envoy Gateway controller
- A `Gateway` `ai-gateway` with HTTPS listener on port 443 (TLS via cert-manager)
- A `Gateway` `kserve-ingress-gateway` with HTTP on port 80 (internal, ClusterIP)
- Envoy proxy pods scheduled on the CP node via `nodeSelector`

### 11. Create registry and HF secrets

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

### 12. Deploy LLMInferenceService

```bash
kubectl apply -f kserve/llm-inference-service-config-model.yaml
kubectl apply -f kserve/llm-inference-service-config-workload.yaml
kubectl apply -f kserve/llm-inferenceservice.yaml
```

Wait for the vLLM pod to be ready (first start downloads ~8.8 GB weights):
```bash
kubectl wait --timeout=10m -n beta pod -l serving.kserve.io/inferenceservice=llm-server --for=condition=Ready
```

### 13. Deploy Backend + AIServiceBackend

```bash
kubectl apply -f envoy-ai-gateway/backend.yaml
```

### 14. Apply AIGatewayRoute

Routes requests with header `x-ai-eg-model: Qwen/Qwen2.5-32B-Instruct-AWQ` to the AIServiceBackend:

```bash
kubectl apply -f envoy-ai-gateway/aigatewayroute.yaml
```

### 15. Apply rate limiting

```bash
kubectl apply -f envoy-ai-gateway/rate-limit.yaml
```

### 16. Apply CORS policy

```bash
kubectl apply -f envoy-ai-gateway/cors-policy.yaml
```

### 17. Expose Envoy Gateway via NodePort

Envoy Gateway auto-creates a service for each Gateway. Patch it to NodePort:

```bash
kubectl patch service envoy-envoy-ai-gateway-system-ai-gateway-e09f2496 -n envoy-gateway-system \
  --type=json \
  -p='[{"op":"replace","path":"/spec/type","value":"NodePort"}]'
```

### 18. Set DNS A records

| Record | Type | Value | Purpose |
|--------|------|-------|---------|
| `llm.yacodata.com` | A | `89.167.109.193` | TLS SNI for Envoy Gateway (CP public IP) |
| `chat.yacodata.com` | A | `89.167.109.193` | NextChat frontend |

### 19. Open firewall port

Open TCP port **30080** on the Hetzner firewall to allow external traffic to the NodePort.

### 20. Deploy NextChat frontend

```bash
kubectl create namespace frontend
kubectl apply -f ../frontend/nextchat/
```

Access at `https://chat.yacodata.com` and configure:
- **Endpoint**: `https://llm.yacodata.com/v1`
- **Model**: `Qwen/Qwen2.5-32B-Instruct-AWQ`

### 21. Test

```bash
curl -X POST https://llm.yacodata.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-ai-eg-model: Qwen/Qwen2.5-32B-Instruct-AWQ" \
  -d '{
    "model": "Qwen/Qwen2.5-32B-Instruct-AWQ",
    "messages": [{"role": "user", "content": "Write a hello world in Python"}],
    "max_tokens": 100
  }'
```

---

## Key Differences from Plain Deployment

| Aspect | Plain Deployment (alpha+envoy-AI) | KServe + llm-d (beta) |
|--------|----------------|----------------------|
| Model lifecycle | Manual Deployment | LLMInferenceService CRD |
| Routing | Manual Service/HTTPRoute | InferencePool + EPP scheduler |
| Cache-aware routing | None | EPP prefix-cache-scorer (weight 2.0) |
| Load-aware routing | None | EPP load-aware-scorer (weight 1.0, threshold 50) |
| Token metering | Enabled | Enabled |
| Rate limiting | None | 30 req/min + 5000 tok/min |
| Model updates | Edit Deployment YAML | Edit LLMInferenceServiceConfig |

---

## What beta does NOT include

- Multi-model serving (see gamma)
- MIG or GPU sharing (see gamma)
- RunPod provider (see omega)
- Baked model image (downloads from HF at startup — use [model-image builder](../model-image/) to bake)

## When to use beta

- Single-model deployment with KServe lifecycle management
- When token metering, rate limiting, and cache-aware routing are required
- When you want a single public HTTPS endpoint with TLS termination
- When all nodes are on the same network (skip WireGuard — Flannel VXLAN works natively)
