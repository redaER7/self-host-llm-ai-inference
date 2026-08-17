# Case β (beta) — Single Model with Envoy AI Gateway + KServe

Envoy AI Gateway → KServe LLMInferenceService → vLLM (Qwen3.8-27B, BF16, TP2). Control plane on Hetzner CX33, GPU worker on Trooper AI (2× A100 40GB). Cross-node pod networking via Flannel VXLAN over WireGuard.

llm-d is installed by KServe as the router image (via built-in LLMInferenceServiceConfigs) and routes requests to the vLLM worker. With a single replica the EPP scheduler is a pass-through — custom scorer weights (prefix-cache + load-aware) are defined in `kserve/endpoint-picker-config.yaml` but not wired into the LLMInferenceService. Uncomment the `router.scheduler.endpointPickerConfig` block in `kserve/llm-inferenceservice.yaml` when scaling to 2+ replicas.

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
          KServe workload service
            │
            ▼
           vLLM pod (GPU node, hostNetwork, 10.10.0.2:8000)
            ├── model: Qwen/Qwen3.8-27B
            ├── precision: bf16 (no quantization)
            ├── tensor-parallel-size: 2 (2× A100 40GB)
            ├── max-model-len: 262144
            ├── max-num-seqs: 8
            └── gpu-memory-utilization: 0.90
```

The AI Gateway proxy (Envoy) and KServe controller run on the **control-plane node** (Hetzner). The vLLM pod runs on the **GPU node** (Trooper AI) with `hostNetwork: true`, binding directly to `10.10.0.2:8000`. Cross-node traffic flows over Flannel VXLAN (`UDP 8472`) through a WireGuard tunnel (`10.10.0.0/24`).

TLS termination happens at the Envoy Gateway proxy (cert-manager + Let's Encrypt DNS-01 via Cloudflare).

## Key Features

| Feature | Implementation |
|---------|---------------|
| **Model-based routing** | AI Gateway Controller via `x-ai-eg-model` header |
| **Token metering** | AIGatewayRoute `llmRequestCosts` (input/output/total) |
| **Rate limiting** | BackendTrafficPolicy (30 req/min) |
| **EPP scheduling** | KServe endpoint picker — default config (custom scorer weights available, see `endpoint-picker-config.yaml`) |
| **InferencePool** | Gateway API Inference Extension CRD |
| **CORS** | SecurityPolicy for NextChat origins |
| **TLS** | cert-manager + Let's Encrypt DNS-01 via Cloudflare |

## Benefits Over Plain Deployment

| Benefit | Why |
|---------|-----|
| **Production routing** | Envoy AI Gateway with token metering, rate limiting, model-based routing |
| **KServe lifecycle** | LLMInferenceService manages deployment, service, InferencePool, HTTPRoute automatically |
| **Prefetch-cache-aware routing** | EPP scorer config available (`endpoint-picker-config.yaml`); wire via `router.scheduler` in LLMInferenceService to activate when scaling to 2+ replicas |
| **Load-aware routing** | EPP scorer config available (same ConfigMap); activate when scaling to 2+ replicas |
| **Simple model updates** | Change model in config, redeploy — weights download at startup |
| **Single entry point** | Envoy Gateway NodePort on `llm.yacodata.com` |

## Requirements

### Kubernetes Cluster

Same K3s setup as alpha — see [case_alpha/README.md](../case_alpha/README.md#requirements). Control plane on Hetzner CX33 (4 vCPU / 8 GB RAM), GPU worker joined as K3s agent with label `node-role.kubernetes.io/gpu-node`.

### GPU (Trooper AI)
  
| GPU | VRAM | Why |
|-----|------|-----|
| **2× A100 40GB** | 80 GB total | BF16 Qwen3.8-27B (~52 GiB weights) via TP2 → ~26 GiB weights/GPU, ~14 GiB/GPU left for KV cache + activations. Hybrid attention (48/64 linear layers) keeps KV small even at 262k context |

### Model Weights

Weights download from HuggingFace on first pod startup. The model-cache volume persists across restarts, avoiding re-download.

| Property | Value |
|----------|-------|
| Model | Qwen/Qwen3.8-27B |
| Precision | BF16 (native, no quantization) |
| Strategy | HF download at startup |
| Cold start | ~10-15 min (first time, 55.6 GB), ~10 s (cached) |
| Download size | ~55.6 GB (51.7 GiB) |
| VRAM usage | ~26 GiB weights/GPU (TP2) + KV cache (at 262k ctx, batch=8) |
| Context window | 262144 native (extensible to 1M) |
| Hybrid attention | 48 Gated DeltaNet (linear) layers + 16 full-attention layers |
| Extras | Multimodal (vision tower), built-in MTP draft head (opt-in), reasoning + tool calling |

### Software Stack

| Component | Version | Notes |
|-----------|---------|-------|
| K3s | v1.33+ | Lightweight K8s; Flannel VXLAN over WireGuard |
| cert-manager | 1.18+ | Webhook certificates + Let's Encrypt (DNS-01 Cloudflare) |
| Envoy Gateway | v1.8+ | Gateway API provider; proxy pods on CP node |
| AI Gateway Controller (Helm) | v1.0.0 | AI routing, token metering, rate limiting |
| LWS Operator | v0.9+ | LeaderWorkerSet (KServe dependency) |
| KServe | v0.18+ | LLMInferenceService CRD |
| vLLM | latest (v0.17+; see [Qwen3.8-27B recipe](https://recipes.vllm.ai/Qwen/Qwen3.8-27B)) | OpenAI-compatible LLM serving; hybrid-attention support requires vLLM ≥ 0.17.0 (recipe pins `vllm/vllm-openai:qwen38`) |

---

## Install Order

Deployment is fully automated by [k8s_deploy.sh](k8s_deploy.sh) (run after [k8s_secrets.sh](k8s_secrets.sh)). The steps below mirror the script so you know what runs and in what order:

1. **K3s** — Hetzner CP + Trooper AI GPU agent (see [k3s-install.sh](../k8s_control_plane/k3s-install.sh))
2. **WireGuard tunnel** — Bridge CP and GPU networks. See [WireGuard setup](#wireguard-setup)
3. **cert-manager** — webhook certificates; creates `envoy-tls-cert` + `chat-tls-cert` (Let's Encrypt DNS-01 via Cloudflare)
4. **AI Gateway CRDs (Helm)** — AIGatewayRoute CRDs
5. **Envoy Gateway (Helm)** — Gateway API provider; proxy pods on CP node
6. **AI Gateway Controller (Helm)** — AI routing, token metering, rate limiting
7. **GatewayClass + EnvoyProxy + Gateway** — HTTPS listener referencing the cert-manager certificate
8. **LWS Operator + KServe (monolithic)** — LeaderWorkerSet + LLMInferenceService CRD
9. **8a — Built-in LLMInferenceServiceConfigs** — EPP scheduler, router, worker templates
10. **8b — Gateway API Inference Extension CRDs** — `InferencePool` CRD
11. **8c — Enable InferencePool in Envoy Gateway** — apply addon values + restart EG
12. **Re-apply Gateways + KServe ingress gateway** — after KServe/IEP CRDs are present
13. **Patch Envoy proxy service → NodePort 30080** — expose `ai-gateway` externally
14. **kube-prometheus-stack** — Prometheus + Grafana + node_exporter (monitoring namespace)
15. **ServiceMonitors** — scrape vLLM + Envoy proxy metrics
16. **DCGM Exporter** — GPU metrics on GPU node (with ServiceMonitor)
17. **Grafana dashboards** — vLLM, Envoy Gateway, DCGM ConfigMaps (auto-imported)
18. **KServe configs** — endpoint-picker + model + workload LLMInferenceServiceConfigs
19. **LLMInferenceService** — model + workload combined
20. **Backend + AIServiceBackend** — Backend points to the InferencePool created by LLMInferenceService
21. **AIGatewayRoute** — header match `x-ai-eg-model: Qwen/Qwen3.8-27B`
22. **Rate limiting** — BackendTrafficPolicy (30 req/min)
23. **CORS policy** — allow NextChat origin to call Envoy Gateway
24. **NextChat frontend + HTTPRoute** — UI on CP node + route through `ai-gateway`
25. **Set DNS A records** — `llm.yacodata.com` + `chat.yacodata.com` → Hetzner CP public IP

---

## WireGuard Setup

Required when CP and GPU nodes are on different networks (e.g. Hetzner + Trooper AI). Skip if all nodes are on the same LAN — Flannel VXLAN works natively.

> Full reference — setup scripts, multi-GPU ports, firewall rules and troubleshooting: [`wireguard/README.md`](../wireguard/README.md).

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
bash wireguard/cp-wireguard-setup.sh
```

This creates the server key, starts WireGuard, and prints the **server public key**.

Open **port 51820/udp** in the Hetzner firewall.

> **New GPU node (2× A100)**: the A100 node is a **new** node and needs its own WireGuard peer + Flannel config. Follow the same steps below with a new IP in `10.10.0.0/24` (e.g. `10.10.0.3`), then add its peer on the CP and set `node-ip`/`flannel-iface: wg0` in its K3s config before joining the cluster.

### Step 2 — GPU node

On the GPU node (Trooper AI), run:
```bash
export CP_NODE_IP=<CP_PUBLIC_IP>
bash wireguard/gpu-wireguard-setup.sh
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
| 29817–29836 | UDP | WireGuard inbound from CP (must be allowed in the Trooper AI external firewall) |
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
| `envoy-ai-gateway/envoy-gateway-values.yaml` | EG Helm values (proxy config) |
| `envoy-ai-gateway/envoy-gateway-values-addon.yaml` | EG addon values (enable InferencePool) |
| `envoy-ai-gateway/aigatewayroute.yaml` | AIGatewayRoute (header match → AIServiceBackend) |
| `envoy-ai-gateway/backend.yaml` | Backend + AIServiceBackend (Backend points to InferencePool) |
| `envoy-ai-gateway/cors-policy.yaml` | SecurityPolicy (CORS for NextChat origin) |
| `envoy-ai-gateway/rate-limit.yaml` | BackendTrafficPolicy (30 req/min) |
| `envoy-ai-gateway/httproute-nextchat.yaml` | HTTPRoute routing `chat.yacodata.com` → NextChat |
| `kserve/llm-inference-service-config-model.yaml` | Model source (HF repo + model name) |
| `kserve/llm-inference-service-config-workload.yaml` | Workload config (vLLM image, args, resources, GPU scheduling) |
| `kserve/llm-inferenceservice.yaml` | LLMInferenceService (combines model + workload) |
| `kserve/endpoint-picker-config.yaml` | EPP scheduler scorer weights (available but not wired; see `llm-inferenceservice.yaml` commented block) |
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

## Key Differences from Plain Deployment

| Aspect | Plain Deployment (alpha+envoy-AI) | KServe (beta) |
|--------|----------------|----------------------|
| Model lifecycle | Manual Deployment | LLMInferenceService CRD |
| Routing | Manual Service/HTTPRoute | InferencePool (via Gateway API Inference Extension) |
| Cache-aware routing | None | Available (EPP config created, wire in LLMInferenceService to activate) |
| Load-aware routing | None | Available (same as above) |
| Token metering | Enabled | Enabled |
| Rate limiting | None | 30 req/min |
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
