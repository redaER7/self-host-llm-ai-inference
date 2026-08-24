# Case β (beta) — Dense Model Benchmark Suite

Dedicated environment for testing dense models on 1× RTX 4090 Pro (48 GB). Envoy AI Gateway → KServe → vLLM. Control plane on Hetzner CX33, GPU worker with RTX 4090 Pro 48 GB.

Models tested:

| Model | Params | Quant | Weights | Native ctx | Context ladder |
|---|---|---|---|---|---|
| **Qwen/Qwen3.6-27B** | 27B | FP8 | ~27 GB | 128K | 8192 / 32768 / 65536 / 131072 |
| **google/gemma-4-31b** | 31B | QAT INT4 | ~20 GB | 256K | 8192 / 32768 / 131072 / 262144 |
| **deepseek-ai/DeepSeek-R1-Distill-Qwen-32B** | 32B | AWQ INT4 | ~19 GB | 128K | 8192 / 32768 / 65536 |

Benchmark script: `Tests/bench_matrix.py` — run per model per context via interactive sweep.

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
           vLLM pod (GPU node, hostNetwork)
            ├── model: casperhansen/deepseek-r1-distill-qwen-32b-awq (current)
            ├── quantization: awq
            ├── reasoning-parser: deepseek_r1
            ├── max-model-len: 8192 (varied per sweep)
            ├── max-num-seqs: 8
            └── gpu-memory-utilization: 0.90
```

## Key Features

| Feature | Implementation |
|---------|---------------|
| **Model-based routing** | AI Gateway Controller via `x-ai-eg-model` header |
| **Token metering** | AIGatewayRoute `llmRequestCosts` (input/output/total) |
| **Rate limiting** | BackendTrafficPolicy (30 req/min) |
| **EPP scheduling** | KServe endpoint picker (custom scorer weights in `endpoint-picker-config.yaml`) |
| **InferencePool** | Gateway API Inference Extension CRD |
| **CORS** | SecurityPolicy for NextChat origins |
| **TLS** | cert-manager + Let's Encrypt DNS-01 via Cloudflare |

## Requirements

### GPU

| GPU | VRAM | Models |
|-----|------|--------|
| **RTX 4090 Pro** | 48 GB | Qwen3.6-27B (FP8), Gemma 4 31B (QAT INT4), R1-Distill-32B (AWQ) |

All three fit on a single card with TP=1. Context ladders per model above.

### Model Weights

Weights download from HuggingFace on first pod startup. The model-cache volume persists across restarts, avoiding re-download.

| Model | Quant | Weights | KV headroom* | Cold start |
|---|---|---|---|---|
| Qwen/Qwen3.6-27B | FP8 | ~27 GB | ~16 GB | ~5 min (first), ~10 s (cached) |
| google/gemma-4-31b | QAT INT4 | ~20 GB | ~23 GB | ~5 min (first), ~10 s (cached) |
| deepseek-ai/DeepSeek-R1-Distill-Qwen-32B | AWQ INT4 | ~19 GB | ~24 GB | ~5 min (first), ~10 s (cached) |

*\*at `--gpu-memory-utilization 0.90` (~43 GB usable)*

### vLLM Notes

- **Qwen3.6-27B**: Uses `--tool-call-parser hermes` for tool calling.
- **Gemma 4 31B**: Requires vLLM nightly for hybrid attention support (5:1 SWA:Global). Use `--tool-call-parser hermes`.
- **DeepSeek-R1-Distill-32B**: Always emits `<think>…</think>` reasoning blocks. Use `--reasoning-parser deepseek_r1`. No way to disable reasoning mode — decode numbers include thinking tokens.

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

Deployment is fully automated by [k8s_deploy.sh](k8s_deploy.sh) (run after [k8s_secrets.sh](k8s_secrets.sh)). The steps below mirror the script so you know what runs and in what order:

1. **K3s** — Hetzner CP + Trooper AI GPU agent (see [k3s-install.sh](../k8s_control_plane/k3s-install.sh))
2. **WireGuard tunnel** — Bridge CP and GPU networks. See [WireGuard setup](#wireguard-setup)
3. **cert-manager** — webhook certificates; creates `envoy-tls-cert` + `chat-tls-cert` (Let's Encrypt DNS-01 via Cloudflare)
4. **AI Gateway CRDs (Helm)** — AIGatewayRoute CRDs
5. **Envoy Gateway (Helm)** — Gateway API provider; proxy pods on CP node
6. **AI Gateway Controller (Helm)** — AI routing, token metering, rate limiting
7. **GatewayClass + EnvoyProxy + Gateway** — HTTPS listener referencing the cert-manager certificate
8. **LWS Operator + KServe (monolithic)** — LeaderWorkerSet + LLMInferenceService CRD
9. **8a — Patch storage-initializer resources** — apply `inferenceservice-config-patch.yaml`, restart controller
10. **8b — Built-in LLMInferenceServiceConfigs** — EPP scheduler, router, worker templates
11. **8c — Gateway API Inference Extension CRDs** — `InferencePool` CRD
12. **8d — Enable InferencePool in Envoy Gateway** — apply addon values + restart EG
13. **Re-apply Gateways + KServe ingress gateway** — after KServe/IEP CRDs are present
14. **Patch Envoy proxy service → NodePort 30080** — expose `ai-gateway` externally
15. **kube-prometheus-stack** — Prometheus + Grafana + node_exporter (monitoring namespace)
16. **ServiceMonitors** — scrape vLLM + Envoy proxy metrics
17. **DCGM Exporter** — GPU metrics on GPU node (with ServiceMonitor)
18. **Grafana dashboards** — vLLM, Envoy Gateway, DCGM ConfigMaps (auto-imported)
19. **KServe configs** — endpoint-picker + model + workload LLMInferenceServiceConfigs
20. **LLMInferenceService** — model + workload combined
21. **Backend + AIServiceBackend** — Backend points to the InferencePool created by LLMInferenceService
22. **AIGatewayRoute** — header match `x-ai-eg-model: casperhansen/deepseek-r1-distill-qwen-32b-awq`
23. **Rate limiting** — BackendTrafficPolicy (30 req/min)
24. **CORS policy** — allow NextChat origin to call Envoy Gateway
25. **NextChat frontend + HTTPRoute** — UI on CP node + route through `ai-gateway`
26. **Set DNS A records** — `llm.yacodata.com` + `chat.yacodata.com` → Hetzner CP public IP

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
bash wireguard/cp-wireguard-setup.sh
```

This creates the server key, starts WireGuard, and prints the **server public key**.

Open **port 51820/udp** in the Hetzner firewall.

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
| `kserve/inferenceservice-config-patch.yaml` | Patch storage-initializer init container resources (cpu=4, mem=24Gi) |
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

- Dense model benchmarking on a single RTX 4090 Pro (48 GB)
- When token metering, rate limiting, and cache-aware routing are required
- When you want a single public HTTPS endpoint with TLS termination
- When all nodes are on the same network (skip WireGuard — Flannel VXLAN works natively)
