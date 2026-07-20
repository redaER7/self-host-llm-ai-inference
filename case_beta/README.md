# Case β (beta) — Single Model, All on GPU Node

Envoy AI Gateway → KServe + llm-d + EPP → vLLM → Vast.ai RTX 3090. All inference components co-located on the GPU node — inference traffic stays local, no cross-node hops for the data plane.

**Note on cross-node networking:** If your K3s cluster runs entirely on a single flat network (e.g., all nodes on the same LAN or cloud VPC), Flannel VXLAN works natively and you can skip the WireGuard setup below. The setup described here assumes Hetzner CP + Vast.ai GPU, which are on different networks — Flannel VXLAN from the CP node cannot reach the GPU node's private Vast.ai IP. A WireGuard tunnel bridges this gap. See [WireGuard setup](#wireguard-setup) for details.

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

All inference traffic stays within the GPU node. Envoy Gateway proxy pods are scheduled on the GPU node via `nodeSelector` + `tolerations`, alongside the KServe vLLM workload. Cross-node traffic (Flannel VXLAN between CP and GPU) flows over a WireGuard tunnel so the CP can reach GPU node pods.

TLS termination is handled by Envoy Gateway at the Gateway level. Certificates are provisioned automatically by cert-manager via Let's Encrypt DNS-01 challenge through Cloudflare.

## Benefits Over Alpha

| Benefit | Why |
|---------|-----|
| **Low latency** | Inference path stays within GPU node (no cross-node hop for vLLM responses) |
| **Production routing** | Token metering, rate limiting, cache-aware EPP scheduling |
| **Single entry point** | Envoy Gateway NodePort on `envoy-llm.yacodata.com` |
| **Faster cold start** | Model weights baked into Docker image (~10 s vs 5-15 min HF download) |
| **Standard networking** | No hostNetwork workarounds; pods use regular Flannel overlay |

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
| cert-manager | 1.18+ | Webhook certificates + Let's Encrypt (DNS-01 Cloudflare) |
| AI Gateway CRDs (Helm) | v1.0.0 | InferencePool, InferenceModel |
| Envoy Gateway | v1.8+ | Gateway API provider; proxy pods scheduled on GPU node |
| AI Gateway Controller (Helm) | v1.0.0 | AI routing, token metering, rate limiting |
| LWS Operator | v0.6.2+ | LeaderWorkerSet (KServe dependency) |
| KServe | v0.18+ | LLMInferenceService CRD (llm-d mode) |

---

## Install Order

1. **K3s** — Hetzner CP + Vast.ai GPU agent (see [k3s-install.sh](../k8s_control_plane/k3s-install.sh) and [vast-ai-bootstrap.sh](../gpu_providers/vast-ai-bootstrap.sh))
2. **WireGuard tunnel** — Bridge CP and GPU networks (skip if same network). See [WireGuard setup](#wireguard-setup)
3. **cert-manager** — webhook certificates
4. **AI Gateway CRDs (Helm)** — InferencePool, InferenceModel
5. **Envoy Gateway (Helm)** — installs Gateway API + Envoy CRDs, controller; then apply GatewayClass + EnvoyProxy + Gateway
6. **AI Gateway Controller (Helm)** — AI routing, token metering, rate limiting
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

## WireGuard Setup

Required when CP and GPU nodes are on different networks (e.g. Hetzner + Vast.ai). Skip if all nodes are on the same LAN — Flannel VXLAN works natively.

### How it works

Flannel uses VXLAN (`UDP 8472`) for pod-to-pod networking across nodes. The CP needs to reach the GPU node's internal IP (`10.0.2.15` on Vast.ai), but that IP is private and not routable from the internet. A WireGuard tunnel makes it reachable.

```
CP node (Hetzner)                GPU node (Vast.ai)
┌────────────────────┐          ┌────────────────────┐
│ wg0 (10.8.0.1) ────┼─ tunnel ─┼─→ wg0 (10.8.0.2)  │
│                    │ UDP 51820│                    │
│ route 10.0.2.15    │          │ UFW open: 8472,   │
│   via 10.8.0.2     │          │  10250, 6443       │
└────────────────────┘          └────────────────────┘
```

### Step 1 — CP node (run as root)

```bash
bash case_beta/wireguard-cp-setup.sh
```

This creates your server key, starts WireGuard, and prints the **server public key**. Save it — you'll need it for the GPU node.

Then open **port 51820/udp** in the Hetzner firewall.

### Step 2 — GPU node (run as root)

```bash
export CP_NODE_IP=89.167.109.193
bash case_beta/wireguard-setup.sh
```

The script will:
1. Generate a client key pair
2. **Prompt you for the CP server's public key** (from `/etc/wireguard/server.pub`)
3. Create `/etc/wireguard/wg0.conf`, start the tunnel, and configure UFW
4. Print your **GPU client public key**

If `CP_NODE_IP` is not set, the script prompts for it interactively.

Copy the GPU public key from the output. Then on the **CP node**, add it to the WireGuard config:

```bash
sudo sed -i '/^# \[Peer\]/a PublicKey = <paste-GPU-public-key>\nAllowedIPs = 10.8.0.2/32' /etc/wireguard/wg0.conf
sudo systemctl restart wg-quick@wg0
```

### Step 3 — Verify the tunnel

From the GPU node:

```bash
ping -c 3 10.8.0.1
```

You should see replies (~100-120ms for Hetzner↔Vast.ai).

### Step 4 — Add VXLAN route on CP node

```bash
sudo ip route add 10.0.2.15/32 via 10.8.0.2 dev wg0
```

To make this persistent across reboots, add `PostUp` to the `[Interface]` section of `/etc/wireguard/wg0.conf`:

```ini
PostUp = ip route add 10.0.2.15/32 via 10.8.0.2 dev wg0
```

### Step 5 — Test cross-node pod networking

From the CP node, once the GPU node has joined the K3s cluster:

```bash
kubectl run test --image=busybox:1.36 --rm -it --restart=Never \
  -- nc -zv -w3 <any-pod-ip-on-gpu-node> <port>
```

### Firewall reference (GPU node)

The setup script opens these ports automatically:

| Port | Protocol | Purpose |
|------|----------|---------|
| 8472 | UDP | Flannel VXLAN (from CP only) |
| 10250 | TCP | Kubelet |
| 6443 | TCP | K3s API |

---

## Contents

| File / Dir | Purpose |
|------------|---------|
| `k8s_secrets.sh` | Create all secrets + TLS certificate (run first) |
| `k8s_deploy.sh` | Deploy all infrastructure + workloads (run after secrets) |
| `docker_build.sh` | Build and push model image to registry (run on GPU node) |
| `envoy-ai-gateway/gatewayclass.yaml` | GatewayClass (references Envoy Gateway controller) |
| `envoy-ai-gateway/gateway.yaml` | Gateway resource (HTTPS listener, TLS termination, KServe label) |
| `envoy-ai-gateway/certificate.yaml` | ClusterIssuer + Certificate (Let's Encrypt DNS-01 via Cloudflare) |
| `envoy-ai-gateway/envoyproxy.yaml` | EnvoyProxy (GPU node scheduling for Envoy proxy pods) |
| `envoy-ai-gateway/inferencepool.yaml` | InferencePool + InferenceModel |
| `envoy-ai-gateway/aigatewayroute.yaml` | HTTPRoute (route `/v1/` → KServe backend) |
| `envoy-ai-gateway/cors-policy.yaml` | SecurityPolicy (CORS for NextChat origin) |
| `kserve/` | KServe LLMInferenceServiceConfig + LLMInferenceService |
| `epp-scheduler/` | EPP scorer weights reference |
| `wireguard-cp-setup.sh` | WireGuard server setup on Hetzner CP (run first) |
| `wireguard-setup.sh` | WireGuard client setup + UFW rules (run on GPU node) |

---

## Quick Start

```bash
# 1. Set secrets as environment variables
export CLOUDFLARE_API_TOKEN="your-cloudflare-token"
export REGISTRY_USERNAME="your-registry-user"
export REGISTRY_PASSWORD="your-registry-password"
export REGISTRY_USER="your-registry-user"
export REGISTRY_PASS="your-registry-password"
export HF_TOKEN="your-hf-token"

# 2. Create all secrets
bash k8s_secrets.sh

# 3. Build and push model image (on GPU node)
bash docker_build.sh

# 4. Deploy everything
bash k8s_deploy.sh
```

Then configure Vast.ai port forwarding and DNS (see [Manual Deployment](#manual-deployment) for details).

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

### 5. Install Envoy Gateway with GPU node scheduling

Envoy Gateway v1.8 ships with Gateway API CRDs and Envoy Gateway CRDs bundled. A single command installs everything:

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.8.2 \
  -n envoy-gateway-system --create-namespace

kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available
```

Create the GatewayClass, an `EnvoyProxy` resource to schedule proxy pods on the GPU node, then apply the Gateway (which references both):

```bash
kubectl apply -f envoy-ai-gateway/gatewayclass.yaml
kubectl apply -f envoy-ai-gateway/envoyproxy.yaml
kubectl apply -f envoy-ai-gateway/gateway.yaml
```

This ensures:
- A `GatewayClass` named `envoy` references the Envoy Gateway controller
- Envoy proxy pods land on the GPU node (via `EnvoyProxy` nodeSelector + tolerations)
- The Gateway is discoverable by KServe via the `serving.kserve.io/gateway` label
- Cross-namespace HTTPRoutes are allowed (`allowedRoutes.namespaces.from: All`)

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
helm install lws oci://registry.k8s.io/lws/charts/lws --version v0.6.2 \
  --namespace lws-system --create-namespace
```

### 8. Install KServe (llm-d mode) — monolithic

```bash
kubectl apply --server-side -f https://github.com/kserve/kserve/releases/download/v0.18.0/kserve.yaml
```

### 9. Create Cloudflare DNS-01 secret, ClusterIssuer, and Certificate

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

### 10. Create the Gateway resource

The Gateway was already applied in step 5 (alongside the EnvoyProxy). This step is a no-op if you already ran both commands there.

```bash
kubectl apply -f envoy-ai-gateway/gateway.yaml
```

This creates an HTTPS listener on port 443, terminating TLS with the cert-manager-issued certificate for `envoy-llm.yacodata.com`. The Gateway references the `gpu-node-proxy` EnvoyProxy via `spec.infrastructure.parametersRef` for GPU node scheduling, and is labeled `serving.kserve.io/gateway: kserve-ingress-gateway` for KServe discovery.

### 11. Install monitoring stack

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

### 12. Build the model image

Model weights are baked into the serving image for fast cold start (~10 s).

```bash
bash model-image/build.sh \
  --base vllm/vllm-openai:latest \
  --model Qwen/Qwen2.5-7B-Instruct \
  --tag docker-registry.yacodata.com/kserve-vllm-qwen:0.1
```

Push to the registry so the GPU node can pull it:

```bash
docker push docker-registry.yacodata.com/kserve-vllm-qwen:0.1
```

### 13. Create registry and HF secrets

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

### 14. Create LLMInferenceServiceConfig template

```bash
kubectl apply -f kserve/llm-inferenceservice-config.yaml
```

### 15. Deploy LLMInferenceService

```bash
kubectl apply -f kserve/llm-inferenceservice.yaml
```

### 16. Apply InferencePool + InferenceModel

```bash
kubectl apply -f envoy-ai-gateway/inferencepool.yaml
```

### 17. Apply HTTPRoute

The HTTPRoute attaches to the `ai-gateway` Gateway in `envoy-ai-gateway-system` and routes `/v1/` traffic to the KServe service.

```bash
kubectl apply -f envoy-ai-gateway/aigatewayroute.yaml
```

### 18. Expose Envoy Gateway via NodePort

Envoy Gateway auto-creates a port for each Gateway listener. The HTTPS listener on port 443 appears as the first port in the service.

```bash
kubectl patch service envoy-gateway-proxy -n envoy-gateway-system \
  --type=json \
  -p='[{"op":"replace","path":"/spec/type","value":"NodePort"},{"op":"add","path":"/spec/ports/-","value":{"name":"https","port":443,"targetPort":443,"nodePort":30080,"protocol":"TCP"}}]'
```

### 19. Apply CORS policy

Allows NextChat (served from `chat.yacodata.com` or localhost) to make browser API calls to Envoy Gateway:

```bash
kubectl apply -f envoy-ai-gateway/cors-policy.yaml
```

### 20. Configure Vast.ai port forwarding

In the Vast.ai instance page, add a port mapping:
- **Port**: `30080`
- **Protocol**: TCP

This maps `https://<vast-public-ip>:<mapped-port>` → Envoy Gateway HTTPS on the GPU node.

### 21. Set DNS A records

| Record | Type | Value | Purpose |
|--------|------|-------|---------|
| `envoy-llm.yacodata.com` | A | `<vast-public-ip>` | TLS SNI for Envoy Gateway (proxy: DNS only) |
| `chat.yacodata.com` | A | `<hetzner-cp-ip>` | NextChat frontend (proxy: DNS only or proxied) |

The Let's Encrypt DNS-01 challenge uses Cloudflare API tokens, so the A record is only needed for TLS SNI at request time, not for certificate issuance.

### 22. Deploy NextChat frontend

NextChat is a static SPA served from the CP node. See [frontend/nextchat/README.md](../frontend/nextchat/README.md) for deployment.

```bash
kubectl create namespace frontend
kubectl apply -f ../frontend/nextchat/
```

Access at `http://<hetzner-cp-ip>:3080` and configure:
- **Endpoint**: `https://envoy-llm.yacodata.com:30080/v1`
- **Model**: `qwen2.5-7b`

### 23. Test

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
| Data plane | hostNetwork + direct WireGuard IP | Flannel VXLAN over WireGuard |
| Inference latency | Cross-node hop over WireGuard | Local to GPU node (no hop) |
| Control plane | WireGuard for data only | WireGuard for Flannel VXLAN |
| Setup complexity | WireGuard + UFW + hostNetwork | WireGuard + UFW + route (no hostNetwork) |
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

- Production single-model deployment with inference staying on the GPU node (no cross-node hop for the data plane)
- Multi-turn conversations where prefix caching matters
- When token metering and rate limiting are required
- When you want Envoy Gateway as the single routing layer (no FastAPI, no NGINX)
- When all nodes are on the same network (skip WireGuard — Flannel VXLAN works natively)
