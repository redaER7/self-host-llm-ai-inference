# Codebase

Self-host LLM inference on rented GPUs using K3s, Envoy Gateway, vLLM.
Control plane on Hetzner Cloud, GPU workers on Trooper AI / Vast.ai.

**Tags**: `k3s` `vllm` `envoy-gateway` `hetzner` `trooper-ai` `vast-ai` `wireguard` `gpu-inference` `self-hosted-llm`

---

## Architecture (Case alpha — current/active)

Minimal path: Envoy Gateway (no AI Gateway) → vLLM on a Trooper AI GPU over WireGuard. Public HTTPS via cert-manager. Security code–protected NextChat frontend.

```
Browser ──https──→ llm.yacodata.com / chat.yacodata.com (443)
                      │
                 socat (CP host, 443 → 30080)
                      │
                 Envoy Gateway proxy (CP, NodePort 30080)
                    ├── /v1/*  → vLLM (GPU, vllm-service:8100 via WireGuard)
                    └── /*     → NextChat (CP, nextchat:3000)
```

**Two public DNS records:**
| Record | Target | Purpose |
|--------|--------|---------|
| `llm.yacodata.com` | Hetzner CP IP | TLS SNI for Envoy Gateway |
| `chat.yacodata.com` | Hetzner CP IP | NextChat frontend |

**Key properties:**
- No AI Gateway, no KServe, no llm-d, no EPP — plain HTTPRoute to vLLM
- Single SAN cert for both domains (`llm.yacodata.com`, `chat.yacodata.com`)
- Path-based routing: `/v1/*` → vLLM, `/*` → NextChat
- socat systemd service for port 443 → 30080 (replaces iptables REDIRECT)
- NextChat password-protected via `CODE` env var from Kubernetes Secret
- Model: Qwen/Qwen2.5-3B-Instruct (HF download at startup, ~1-2 min cold start)
- 3-script deploy: `k8s_secrets.sh` → `k8s_deploy.sh` → `hetzner-cp-node-socat.sh`

---

## Architecture (Case beta — alternative)

All inference components co-located on the GPU node — inference data plane stays local, no cross-node hops for vLLM responses. Cross-node control plane traffic (Flannel VXLAN) flows over a WireGuard tunnel when CP and GPU are on different networks (e.g., Hetzner + Vast.ai).

```
Browser ──https──→ llm.yacodata.com (443)
                     ↓
             Envoy Gateway proxy  (CP node, NodePort 30080)
                     ↓
             Envoy AI Gateway     (token metering, routing)
                     ↓
             InferencePool "qwen-7b-inference-pool"
                     ↓
             KServe LLMInferenceService "qwen-7b"
               └── vLLM pod       (Qwen/Qwen2.5-7B-Instruct, GPU)

Frontend (CP node):
Browser ──https──→ chat.yacodata.com
                     ↓
             NextChat (NodePort 30081, Hetzner CP)
```

**Two public DNS records**:
| Record | Target | Purpose |
|--------|--------|---------|
| `llm.yacodata.com` | GPU node public IP | TLS SNI for Envoy Gateway |
| `chat.yacodata.com` | Hetzner CP IP | NextChat frontend |

---

## Directory Structure

```
./
├── README.md                          # Project overview, all cases
├── CODEBASE.md                        # This file
├── Plan.md                            # Full architecture plan
├── hetzner-cp-node-socat.sh           # socat forwarder 443→30080 (shared α β)
├── .env                               # Environment variables (gitignored)
│
├── case_beta/                         # ACTIVE — single-model, Envoy AI Gateway
│   ├── k8s_secrets.sh                 # [1] Namespaces + secrets
│   ├── docker_build.sh                # [2] Build + push model image (GPU node)
│   ├── k8s_deploy.sh                  # [3] Full deployment (CP node)
│   ├── README.md
│   │
│   ├── envoy-ai-gateway/              # Envoy Gateway + AI Gateway resources
│   │   ├── gatewayclass.yaml          # GatewayClass "envoy"
│   │   ├── gateway.yaml               # Gateway "ai-gateway" (HTTPS, TLS, KServe label)
│   │   ├── envoyproxy.yaml            # CP node scheduling for proxy pods, container-level resources
│   │   ├── certificate.yaml           # ClusterIssuer + Certificate (llm.yacodata.com)
│   │   ├── aigatewayroute.yaml        # AIGatewayRoute: header match → InferencePool
│   │   ├── backend.yaml               # Backend + AIServiceBackend to InferencePool
│   │   ├── rate-limit.yaml            # BackendTrafficPolicy targeting HTTPRoute
│   │   ├── cors-policy.yaml           # SecurityPolicy: CORS for NextChat
│   │   ├── envoy-gateway-values.yaml  # Helm values: AI Gateway hooks, controller FQDN
│   │   └── envoy-gateway-values-addon.yaml  # Helm values: InferencePool backend resource
│   │
│   ├── kserve/                        # KServe resources
│   │   ├── qwen-model.yaml            # LLMInferenceServiceConfig: model uri + name
│   │   ├── qwen-workload.yaml         # LLMInferenceServiceConfig: image, GPU, scheduling
│   │   ├── qwen-router.yaml           # LLMInferenceServiceConfig: router (no scheduler override)
│   │   ├── llm-inferenceservice.yaml  # LLMInferenceService: composes 3 configs via baseRefs
│   │   └── endpoint-picker-config.yaml# ConfigMap: EPP scorer weights (prefix-cache 2.0, load 1.0)
│   │
│   ├── wireguard-cp-setup.sh         # WireGuard server setup on Hetzner CP
│   ├── wireguard-setup.sh            # WireGuard client setup + UFW rules (run on GPU node)
│   └── epp-scheduler/                # EPP scheduler reference (placeholder)
│
├── case_alpha/                        # ACTIVE — minimal single model, Envoy Gateway
│   ├── k8s_secrets.sh                 # [1] Namespaces + secrets
│   ├── k8s_deploy.sh                  # [2] Full 12-step deployment
│   ├── README.md
│   │
│   ├── envoy-gateway/                 # Envoy Gateway resources (no AI Gateway)
│   │   ├── gatewayclass.yaml          # GatewayClass "envoy"
│   │   ├── gateway.yaml               # Gateway "alpha-gateway" (HTTPS, SAN cert)
│   │   ├── envoyproxy.yaml            # CP node scheduling, NodePort type
│   │   ├── certificate.yaml           # ClusterIssuer + Certificate (llm + chat SAN)
│   │   ├── envoy-gateway-values.yaml  # Helm values — no extensions, no hooks
│   │   ├── httproute-vllm.yaml        # Route /v1/* → vllm-service:8100
│   │   ├── httproute-nextchat.yaml    # Route chat.yacodata.com → nextchat:3000
│   │   └── cors-policy.yaml           # SecurityPolicy: CORS for NextChat
│   │
│   ├── frontend/nextchat/             # Alpha-specific NextChat deployment
│   │   └── deployment.yaml            # CODE from secret, CUSTOM_MODELS for 3B
│   │
│   └── vllm-deployment.yaml           # vLLM (Qwen2.5-3B, GPU node, hostNetwork)
├── case_gamma/                        # FUTURE — multi-model MIG binpacking
├── case_omega/                        # FUTURE — multi-model on RunPod
│
├── wireguard/                           # Shared WireGuard scripts
│   ├── README.md                        # Documentation
│   ├── cp-setup.sh                      # Server setup (run on CP)
│   └── gpu-setup.sh                     # Client setup (run on each GPU node)
│
├── frontend/
│   └── nextchat/                      # NextChat SPA deployment
│       ├── deployment.yaml            # Env: BASE_URL, CUSTOM_MODELS, TLS_CERT/KEY
│       ├── service.yaml               # NodePort 30081, 443 → targetPort 3000
│       ├── certificate.yaml           # Certificate for chat.yacodata.com
│       └── README.md
│
├── model-image/                       # Model image with baked weights
│   ├── Dockerfile                     # vLLM base + HF snapshot download (BuildKit secret)
│   └── build.sh                       # Build helper script
│
├── monitoring/
│   ├── kube-prometheus-stack-values.yaml  # Prometheus + Grafana
│   ├── dcgm-exporter.yaml                # NVIDIA GPU metrics
│   └── README.md
│
└── gpu_providers/
    └── vast-ai-bootstrap.sh           # Vast.ai instance bootstrap (k3s agent join)
```

---

## Component Details

### 1. K3s Cluster
- **Control plane**: Hetzner CX33, runs K3s server + controllers (cert-manager, KServe, Envoy Gateway controller, AI Gateway controller).
- **GPU worker**: Vast.ai instance, K3s agent joined with label `node-role.kubernetes.io/gpu-node: "true"` and taint `gpu-node=true:NoSchedule`.
- **Networking**: Flannel (default K3s CNI). Cross-node traffic via WireGuard tunnel between Hetzner and Vast.ai.

### 2. Envoy Gateway (v1.8.2)
- **Controller**: Installed via Helm in `envoy-gateway-system` namespace.
- **GatewayClass** (`envoy`): References `gateway.envoyproxy.io/gatewayclass-controller`.
- **Gateway** (`ai-gateway`, `envoy-ai-gateway-system`): HTTPS listener on port 443, TLS termination with cert-manager certificate for `llm.yacodata.com`. Labeled `serving.kserve.io/gateway: kserve-ingress-gateway` for KServe discovery. Allows routes from all namespaces.
- **EnvoyProxy** (`ai-gateway-proxy`): Schedules proxy pods on CP node in `envoy-ai-gateway-system` namespace. Resources set via `spec.provider.kubernetes.envoyDeployment.container.resources`.
- **Service**: Auto-created by Envoy Gateway, patched to `NodePort` with `nodePort: 30080`. Found via label selector `gateway.envoyproxy.io/owning-gateway-namespace=envoy-ai-gateway-system,gateway.envoyproxy.io/owning-gateway-name=ai-gateway`.
- **Helm install sequence**: Stage 1 (base values with AI Gateway hooks), then after InferencePool CRDs exist, stage 2 (addon values + restart).
- **Deployment**: Single replica on CP node.
- **Cross-node networking**: The proxy pod connects to the envoy-gateway controller (CP node) via xDS. Flannel VXLAN carries this traffic; when CP and GPU are on different networks, VXLAN packets flow over a WireGuard tunnel (see [WireGuard setup](#prerequisites)).

### 3. Envoy AI Gateway (v1.0.0)
- **CRD chart** (`ai-gateway-crds-helm`): Installed in `envoy-ai-gateway-system`, provides `AIGatewayRoute`, `InferencePool`, `InferenceModel` CRDs.
- **Controller chart** (`ai-gateway-helm`): AI routing logic, token metering, rate limiting.
- **AIGatewayRoute** (`qwen-route`, `beta`): Matches header `x-ai-eg-model: qwen2.5-7b` (Exact). Backend refs to `InferencePool qwen-7b-inference-pool` from `inference.networking.k8s.io`. Includes `llmRequestCosts` for input/output/total token metering. Parent refs to Gateway `ai-gateway` in `envoy-ai-gateway-system`.
- **Backend routing**: Uses `gateway.envoyproxy.io/v1alpha1` Backend with FQDN pointing to the InferencePool, plus `aigateway.envoyproxy.io/v1beta1` AIServiceBackend. Switched from FQDN-based service to InferencePool-based routing.

### 4. KServe (v0.18)
- Installed monolithically via `kubectl apply --server-side -f kserve.yaml` (not split Helm charts).
- Gateway API enabled — `kserveGateway=envoy-ai-gateway-system/ai-gateway`.
- Manages `LLMInferenceService` + automatically creates `InferencePool` via `router.scheduler: {}`. InferencePool enables AI Gateway to route directly without EPP.
- Two Gateways: `kserve-ingress-gateway` (kserve namespace, HTTP:80, ClusterIP internal) for KServe internal routing; `ai-gateway` (envoy-ai-gateway-system, HTTPS:443, NodePort:30080) for external traffic.

### 5. LLMInferenceService (qwen-7b)
Split into 3 composable configs (`serving.kserve.io/v1alpha1`):

| Config | Key Fields |
|--------|-----------|
| `qwen-model` | `uri: hf://Qwen/Qwen2.5-7B-Instruct`, `name: qwen2.5-7b` |
| `qwen-workload` | Image `vllm/vllm-openai:latest`, GPU 1 (16Gi/14Gi), hostNetwork, nodeSelector+tolerations, imagePullSecrets. Args: `--tensor-parallel-size 1 --max-num-seqs 4 --gpu-memory-utilization 0.85`. model-cache: emptyDir (not hostPath). |
| `qwen-router` | `router: {route: {}, gateway: {}}` — scheduler template override removed (caused container spec to be wiped). |

`LLMInferenceService` composes them via `baseRefs`.

### 6. vLLM Model
- **Model**: Qwen/Qwen2.5-7B-Instruct (public, ~15 GB).
- **Image**: `vllm/vllm-openai:latest` — upstream vLLM image (no baked model weights).
- **Cold start**: ~5-10 minutes (model downloaded via storage-initializer init container from HuggingFace, then loaded by vLLM).
- **Download cache**: `model-cache` emptyDir mounted at `/mnt/huggingface/models`; model re-downloaded on each new pod.
- **HF token**: Passed via env var from `hf-token` secret.

### 7. EPP Scheduler (not deployed)
- KServe's EPP (router/scheduler) deployment is **not created** when the router config has no scheduler template override.
- With a single-worker InferencePool, routing is handled directly by the InferencePool and AI Gateway — the EPP layer is not required.
- ConfigMap `custom-endpoint-picker-config` in namespace `beta` defines scoring weights (prefix-cache w:2.0, load-aware w:1.0) but is unused without EPP.
- Scheduler template override (`qwen-router.yaml`) was removed because partial `scheduler.template` overrides replace the entire built-in PodTemplateSpec, wiping containers.

### 8. TLS
- **Issuer**: cert-manager `ClusterIssuer` (Let's Encrypt, DNS-01 via Cloudflare).
- **Certificates**:
  - `envoy-tls-cert` in `envoy-ai-gateway-system` for `llm.yacodata.com` (changed from `envoy-llm.yacodata.com`).
  - `frontend-tls-cert` in `frontend` for `chat.yacodata.com`.
- **Cloudflare secret**: `cloudflare-api-token` in `cert-manager` namespace.

### 9. CORS
SecurityPolicy `cors-policy` (namespace `beta`) targeting HTTPRoute `qwen-7b-kserve-route` (changed from AIServiceBackend):
- Allowed origins: `https://chat.yacodata.com`, `https://*.yacodata.com`, `http://localhost:3000`, `http://localhost:8000`.
- Methods: POST, OPTIONS, GET.
- Headers: Content-Type, Authorization.

### 10. NextChat Frontend
- **Deployment**: `yidadaa/chatgpt-next-web:latest`, served from Hetzner CP.
- **Service**: NodePort `30081` (port 443 → container 3000).
- **TLS**: Self-served via `TLS_CERT`/`TLS_KEY` env vars from mounted `frontend-tls-cert` secret.
- **Endpoint**: `BASE_URL=https://llm.yacodata.com/v1` (standard HTTPS port 443, not 30080). Model `qwen2.5-7b`.

### 11. Monitoring
- Prometheus + Grafana (kube-prometheus-stack) + DCGM exporter for GPU metrics. All in `monitoring` namespace.

---

## Prerequisites

### WireGuard tunnel (cross-network clusters only)

When the CP and GPU nodes are on different networks (e.g., Hetzner CP + Vast.ai GPU), Flannel VXLAN cannot reach the GPU node's private IP. A host-native WireGuard tunnel bridges this gap. If all nodes share a flat network, skip this.

See [wireguard/README.md](./wireguard/README.md) for full setup instructions.

**Quick start:**
1. **Server (CP node):** Run `bash wireguard/cp-wireguard-setup.sh` — generates keys, creates config, sets K3s `node-ip` + `flannel-iface=wg0`, starts `wg-quick@wg0`.
2. **Client (GPU node):** Run `bash wireguard/gpu-wireguard-setup.sh` — generates keys, prompts for CP pubkey/IP, starts tunnel, verifies ping to `10.10.0.1`.
3. **Key exchange:** Add GPU's public key to CP's `wg0.conf` `[Peer]` section, restart wg-quick on CP.
4. **K3s agent:** Install with `--node-ip=10.10.0.2 --flannel-iface=wg0` so Flannel VXLAN binds to the WG interface.
5. **UFW:** Allow UDP 8472 from the peer's WG IP on both nodes — `sudo ufw allow from 10.10.0.0/24 to any port 8472 proto udp`
6. **All cases use WG subnet `10.10.0.0/24`:** CP = `.1`, GPU = `.2`, etc.

## Deployment Flow

3 scripts, run in order (after WireGuard tunnel is up):

```
[1] k8s_secrets.sh (run once, any node with kubectl)
    ├── Namespaces: cert-manager, beta, envoy-ai-gateway-system,
    │               envoy-gateway-system, lws-system, kserve, frontend
    ├── cloudflare-api-token secret (cert-manager)
    ├── registry-credentials secret (beta, for image pull)
    └── hf-token secret (beta, for model download)

[2] docker_build.sh (run on GPU node with Docker + registry push access)
    ├── docker login → docker-registry.yacodata.com
    ├── docker build --secret id=hf_token,env=HF_TOKEN
    └── docker push kserve-vllm-qwen:0.11

[3] k8s_deploy.sh (run on CP node with kubectl + helm)
    ├── 1. Namespace "beta"
    ├── 2. cert-manager (Helm v1.18.0)
    ├── 3. AI Gateway CRDs (Helm)
    ├── 4. Envoy Gateway base install + wait
    ├── 5. GatewayClass + EnvoyProxy + Gateway
    ├── 6. AI Gateway Controller + wait
    ├── 7. LWS Operator
    ├── 8. KServe monolithic + InfExt CRDs
    ├── 9. Re-apply Gateway (post-KServe) + Certificate
    ├── 10. KServe configs (qwen-model, qwen-workload, qwen-router)
    ├── 11. LLMInferenceService
    ├── 12. AIGatewayRoute + Backend + AIServiceBackend
    ├── 13. Rate limit policy + CORS policy
    └── 14. NextChat frontend

Post-deploy:
    - GPU node port forwarding: instance port → 30080
    - DNS A records: llm → gpu-ip, chat → hetzner-ip
```

## Request Flow (end-to-end)

```
Browser POST https://llm.yacodata.com/v1/chat/completions
  Header: x-ai-eg-model: qwen2.5-7b
  ↓ (public internet, DNS → GPU node public IP)
Envoy Gateway proxy (CP node, NodePort 30080, HTTPS terminated)
  ↓ (Flannel VXLAN over WireGuard if cross-network)
Envoy AI Gateway matches AIGatewayRoute "qwen-route"
  ├── Matches header x-ai-eg-model: qwen2.5-7b
  ├── Applies token metering (input/output/total)
  └── Routes to InferencePool "qwen-7b-inference-pool"
      ↓
KServe HTTPRoute "qwen-7b-kserve-route" → InferencePool
      ↓ (via Backend + AIServiceBackend to InferencePool FQDN)
vLLM pod (Qwen/Qwen2.5-7B-Instruct, GPU)
  ↓
Response back through chain
```
