# Codebase

Self-host LLM inference on rented GPUs using K3s, Envoy AI Gateway, KServe + llm-d + vLLM.
Control plane on Hetzner Cloud, GPU workers on Vast.ai.

**Tags**: `k3s` `kserve` `vllm` `llm-d` `envoy-ai-gateway` `hetzner` `vast-ai` `gpu-inference` `self-hosted-llm`

---

## Architecture (Case beta — current/active)

All inference components co-located on the GPU node — inference data plane stays local, no cross-node hops for vLLM responses. Cross-node control plane traffic (Flannel VXLAN) flows over a WireGuard tunnel when CP and GPU are on different networks (e.g., Hetzner + Vast.ai).

```
Browser ──https──→ envoy-llm.yacodata.com:30080
                     ↓
             Envoy Gateway proxy  (GPU node, NodePort 30080)
                     ↓
             Envoy AI Gateway     (token metering, routing)
                     ↓
             KServe LLMInferenceService "qwen-7b"
               ├── llm-d Router   (cache-aware endpoint picker)
               ├── EPP Scheduler  (prefix-cache w:2.0 + load-aware w:1.0)
               └── vLLM pod       (Qwen/Qwen2.5-7B-Instruct, RTX 3090)

Frontend (CP node):
Browser ──https──→ chat.yacodata.com
                     ↓
             NextChat (NodePort 30081, Hetzner CP)
```

**Two public DNS records**:
| Record | Target | Purpose |
|--------|--------|---------|
| `envoy-llm.yacodata.com` | Vast.ai public IP | TLS SNI for Envoy Gateway |
| `chat.yacodata.com` | Hetzner CP IP | NextChat frontend |

---

## Directory Structure

```
./
├── README.md                          # Project overview, all cases
├── CODEBASE.md                        # This file
├── Plan.md                            # Full architecture plan
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
│   │   ├── envoyproxy.yaml            # GPU node scheduling for proxy pods
│   │   ├── certificate.yaml           # ClusterIssuer + Certificate (envoy-llm.yacodata.com)
│   │   ├── aigatewayroute.yaml        # AIGatewayRoute: header match → InferencePool
│   │   ├── cors-policy.yaml           # SecurityPolicy: CORS for NextChat
│   │   ├── envoy-gateway-values.yaml  # Helm values: AI Gateway hooks, controller FQDN
│   │   └── envoy-gateway-values-addon.yaml  # Helm values: InferencePool backend resource
│   │
│   ├── kserve/                        # KServe resources
│   │   ├── qwen-model.yaml            # LLMInferenceServiceConfig: model uri + name
│   │   ├── qwen-workload.yaml         # LLMInferenceServiceConfig: image, GPU, scheduling
│   │   ├── qwen-router.yaml           # LLMInferenceServiceConfig: router/scheduler {}
│   │   ├── llm-inferenceservice.yaml  # LLMInferenceService: composes 3 configs via baseRefs
│   │   └── endpoint-picker-config.yaml# ConfigMap: EPP scorer weights (prefix-cache 2.0, load 1.0)
│   │
│   ├── wireguard-cp-setup.sh         # WireGuard server setup on Hetzner CP
│   ├── wireguard-setup.sh            # WireGuard client setup + UFW rules (run on GPU node)
│   └── epp-scheduler/                # EPP scheduler reference (placeholder)
│
├── case_alpha/                        # PREVIOUS — minimal FastAPI + WireGuard
├── case_gamma/                        # FUTURE — multi-model MIG binpacking
├── case_omega/                        # FUTURE — multi-model on RunPod
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
- **Gateway** (`ai-gateway`, `envoy-ai-gateway-system`): HTTPS listener on port 443, TLS termination with cert-manager certificate for `envoy-llm.yacodata.com`. Labeled `serving.kserve.io/gateway: kserve-ingress-gateway` for KServe discovery. Allows routes from all namespaces.
- **EnvoyProxy** (`gpu-node-proxy`): Schedules proxy pods on GPU node via `nodeSelector` + `tolerations`.
- **Service**: Auto-created by Envoy Gateway, patched to `NodePort` with `nodePort: 30080`. Found via label selector `gateway.envoyproxy.io/owning-gateway-namespace=envoy-ai-gateway-system,gateway.envoyproxy.io/owning-gateway-name=ai-gateway`.
- **Helm install sequence**: Stage 1 (base values with AI Gateway hooks), then after InferencePool CRDs exist, stage 2 (addon values + restart).
- **Deployment**: Single replica on GPU node alongside vLLM pod.
- **Cross-node networking**: The proxy pod connects to the envoy-gateway controller (CP node) via xDS. Flannel VXLAN carries this traffic; when CP and GPU are on different networks, VXLAN packets flow over a WireGuard tunnel (see [WireGuard setup](#prerequisites)).

### 3. Envoy AI Gateway (v1.0.0)
- **CRD chart** (`ai-gateway-crds-helm`): Installed in `envoy-ai-gateway-system`, provides `AIGatewayRoute`, `InferencePool`, `InferenceModel` CRDs.
- **Controller chart** (`ai-gateway-helm`): AI routing logic, token metering, rate limiting.
- **AIGatewayRoute** (`qwen-route`, `beta`): Matches header `x-ai-eg-model: qwen2.5-7b` (Exact). Backend refs to `InferencePool qwen-7b-inference-pool` from `inference.networking.k8s.io`. Includes `llmRequestCosts` for input/output/total token metering. Parent refs to Gateway `ai-gateway` in `envoy-ai-gateway-system`.

### 4. KServe (v0.18)
- Installed monolithically via `kubectl apply --server-side -f kserve.yaml` (not split Helm charts).
- Gateway API enabled — `kserveGateway=envoy-ai-gateway-system/ai-gateway`.
- Manages `LLMInferenceService` + automatically creates `InferencePool`/`InferenceModel` via `router.scheduler: {}`.

### 5. LLMInferenceService (qwen-7b)
Split into 3 composable configs (`serving.kserve.io/v1alpha1`):

| Config | Key Fields |
|--------|-----------|
| `qwen-model` | `uri: hf://Qwen/Qwen2.5-7B-Instruct`, `name: qwen2.5-7b` |
| `qwen-workload` | Image `docker-registry.yacodata.com/kserve-vllm-qwen:0.11`, GPU 1 (10Gi/6Gi), hostNetwork, nodeSelector+tolerations, imagePullSecrets |
| `qwen-router` | `router: {route: {}, gateway: {}, scheduler: {}}` |

`LLMInferenceService` composes them via `baseRefs`.

### 6. vLLM Model
- **Model**: Qwen/Qwen2.5-7B-Instruct (public, ~4 GB).
- **Image**: `docker-registry.yacodata.com/kserve-vllm-qwen:0.11` — vLLM base image + baked model weights.
- **Cold start**: ~10 seconds (weights baked in, no HF download at startup).
- **HF token**: Passed via BuildKit secret at build time (`--secret id=hf_token,env=HF_TOKEN`), not persisted in image layers.

### 7. EPP Scheduler
ConfigMap `custom-endpoint-picker-config` in namespace `beta`:
```yaml
schedulingProfiles:
  - name: default
    plugins:
      - pluginRef: prefix-cache-scorer; weight: 2.0
      - pluginRef: load-aware-scorer;    weight: 1.0
      - pluginRef: max-score-picker
```

### 8. TLS
- **Issuer**: cert-manager `ClusterIssuer` (Let's Encrypt, DNS-01 via Cloudflare).
- **Certificates**:
  - `envoy-tls-cert` in `envoy-ai-gateway-system` for `envoy-llm.yacodata.com`.
  - `frontend-tls-cert` in `frontend` for `chat.yacodata.com`.
- **Cloudflare secret**: `cloudflare-api-token` in `cert-manager` namespace.

### 9. CORS
SecurityPolicy `cors-policy` (namespace `beta`) targeting AIGatewayRoute `qwen-route`:
- Allowed origins: `https://chat.yacodata.com`, `https://*.yacodata.com`, `http://localhost:3000`, `http://localhost:8000`.
- Methods: POST, OPTIONS, GET.
- Headers: Content-Type, Authorization.

### 10. NextChat Frontend
- **Deployment**: `yidadaa/chatgpt-next-web:latest`, served from Hetzner CP.
- **Service**: NodePort `30081` (port 443 → container 3000).
- **TLS**: Self-served via `TLS_CERT`/`TLS_KEY` env vars from mounted `frontend-tls-cert` secret.
- **Endpoint**: `BASE_URL=https://envoy-llm.yacodata.com:30080/v1`, model `qwen2.5-7b`.

### 11. Monitoring
- Prometheus + Grafana (kube-prometheus-stack) + DCGM exporter for GPU metrics. All in `monitoring` namespace.

---

## Prerequisites

### WireGuard tunnel (cross-network clusters only)

When the CP and GPU nodes are on different networks (e.g., Hetzner CP + Vast.ai GPU), Flannel VXLAN cannot reach the GPU node's private IP. A host-native WireGuard tunnel bridges this gap. If all nodes share a flat network, skip this.

1. **Server (CP node):** Run `case_beta/wireguard-cp-setup.sh` to generate keys, create config, and start `wg-quick@wg0`.
2. **Client (GPU node):** Generate keys, create `wg0.conf` with the CP's public key, run `case_beta/wireguard-setup.sh`.
3. **Key exchange:** Share public keys between nodes; add GPU's public key to CP's `wg0.conf` `[Peer]` section.
4. **Route (CP node):** Add `ip route add <gpu-internal-ip>/32 via 10.8.0.2 dev wg0` to route VXLAN through the tunnel.

See [case_beta/README.md](./case_beta/README.md#wireguard-setup) for full instructions.

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
    ├── 8c. Envoy Gateway addon values + restart
    ├── 9. Re-apply Gateway (post-KServe)
    ├── 10. Monitoring (Prometheus + Grafana + DCGM)
    ├── 11. KServe configs (EPP + 3 model configs)
    ├── 12. LLMInferenceService
    ├── 13. AIGatewayRoute
    ├── 14. Patch proxy service → NodePort 30080
    ├── 15. CORS policy
    └── 16. NextChat frontend

Post-deploy:
    - Vast.ai port forwarding: instance port → 30080
    - DNS A records: envoy-llm → vast-ip, chat → hetzner-ip
```

## Request Flow (end-to-end)

```
Browser POST https://envoy-llm.yacodata.com:30080/v1/chat/completions
  Header: x-ai-eg-model: qwen2.5-7b
  ↓ (public internet)
Vast.ai instance port → GPU node 30080
  ↓
Envoy Gateway proxy (NodePort 30080, HTTPS terminated)
  ↓
Envoy AI Gateway matches AIGatewayRoute "qwen-route"
  ├── Matches header x-ai-eg-model: qwen2.5-7b
  ├── Applies token metering (input/output/total)
  └── Routes to InferencePool "qwen-7b-inference-pool"
      ↓
KServe llm-d router → EPP scheduler
  ├── prefix-cache scorer (w:2.0)
  └── load-aware scorer (w:1.0)
      ↓
vLLM pod (Qwen/Qwen2.5-7B-Instruct, RTX 3090)
  ↓
Response back through chain
```
