# Self-Host LLM AI Inference

Self-host large language model inference on rented GPUs using Kubernetes, KServe, vLLM, and llm-d. Control plane on Hetzner Cloud, GPU workers on Trooper AI and dedicated Blackwell GPUs.

**Tags**: `k3s` `vllm` `envoy-gateway` `hetzner` `trooper-ai` `wireguard` `gpu-inference` `self-hosted-llm`

We use **Trooper AI** on-demand GPU instances for GPU workers — they allow quick deploy and delete cycles, fitting our need for ephemeral GPU capacity. For a comparison of GPU rental options across providers, see [How to Rent Affordable GPU for AI Inference](https://yacodata.com/en/blog/how-to-rent-affordable-gpu-for-ai-inference).

---

## Table of Contents

- [Deployment](#deployment)
- [Cases Overview](#cases-overview)
- [Case α (alpha) — Minimal Single Model](#case-α-alpha--minimal-single-model)
- [Case α+AI (alpha+envoy-AI) — Minimal + AI Gateway](#case-αai-alphaenvoy-ai--minimal--ai-gateway)
- [Case β (beta) — Single Model (with KServe)](#case-β-beta--single-model-with-kserve)
- [Case γ (gamma) — Multi-Model MIG Binpacking](#case-γ-gamma--multi-model-mig-binpacking)
- [Case Ω (omega) — Multi-Model on Blackwell (2 GPUs, no MIG)](#case-ω-omega--multi-model-on-blackwell-2-gpus-no-mig)

---

## Deployment

Cluster setup is shared across all cases. Run these steps once before deploying any case:

### 1. Create the K3s control plane

```bash
bash k8s_control_plane/k3s-install.sh
```

Installs K3s on the Hetzner control-plane node. See [k8s_control_plane/](./k8s_control_plane/).

### 2. Activate the WireGuard tunnel

```bash
# On the control-plane node
bash wireguard/cp-wireguard-setup.sh

# On the GPU node
bash wireguard/gpu-wireguard-setup.sh
```

Bridges the Hetzner CP and the GPU provider network (subnet `10.10.0.0/24`). See [wireguard/](./wireguard/).

### 3. Join the GPU node

```bash
export K3S_URL=https://<cp-public-ip>:6443
export K3S_TOKEN=<node-token>
bash gpu_providers/gpu-node-bootstrap.sh
```

Installs the K3s agent, NVIDIA container runtime, and device plugin on the GPU worker. See [gpu_providers/](./gpu_providers/).

After these steps, pick a case below and follow its Quick Start.

---

## Cases Overview

| Case | Name | Gateway | LLM Stack | GPU Provider | Models |
|------|------|---------|-----------|-------------|--------|
| **α** | alpha | Envoy Gateway (plain) | vLLM (direct) | Trooper AI | Qwen 2.5-3B |
| **α+AI** | alpha+envoy-AI | Envoy AI Gateway | vLLM (direct) | Trooper AI | DeepSeek-R1-Distill-Qwen-14B |
| **β** | beta | Envoy AI Gateway | KServe + vLLM | Trooper AI (2× RTX 4080 Super 32GB) | Qwen3.8-27B (FP8) |
| **γ** | gamma | Envoy AI Gateway | KServe + vLLM + llm-d | Trooper AI (A100 40GB, MIG) | Qwen 2.5-7B + Qwen 2.5-14B |
| **Ω** | omega | Envoy AI Gateway | KServe + vLLM + llm-d | Blackwell (2 GPUs) | Llama 3.1 70B + Mistral 7B |

See [Plan.md](./Plan.md) for full architecture details.

---

## Case α (alpha) — Minimal Single Model

Envoy Gateway (no AI Gateway) → vLLM on a Trooper AI GPU, with a WireGuard tunnel connecting the Hetzner control plane to the GPU node. Public HTTPS via cert-manager (Let's Encrypt DNS-01 Cloudflare) with `llm.yacodata.com` + `chat.yacodata.com` on a single SAN cert.

```
Browser ──https──→ llm.yacodata.com / chat.yacodata.com (443)
                      │
                 socat (CP host, 443 → 30080)
                      │
                 Envoy Gateway proxy (CP, NodePort 30080)
                    ├── /v1/*  → vLLM (GPU, vllm-service:8100 via WireGuard)
                    └── /*     → NextChat (CP, nextchat:3000)
```

| Component | Where | Detail |
|-----------|-------|--------|
| K3s control plane | Hetzner CX33 | K3s server, `node-role.kubernetes.io/control-plane` |
| GPU worker | Trooper AI | K3s agent, `node-role.kubernetes.io/gpu-node`, taint `gpu-node=true:NoSchedule` |
| Envoy Gateway | Hetzner CP | Helm install (no AI Gateway, no extensions), proxy pod on CP node |
| vLLM | GPU node | `hostNetwork: true`, `vllm/vllm-openai:latest`, HF download at startup |
| NextChat | Hetzner CP | ClusterIP:3000, HTTP only (TLS at Envoy), password protected via `CODE` env var |
| TLS | cert-manager | Let's Encrypt DNS-01 via Cloudflare, SAN cert for both domains |
| WireGuard | Hetzner ↔ Trooper AI | Native WG, subnet 10.10.0.0/24 |
| Port 443 | socat systemd service | `TCP-LISTEN:443 → TCP:127.0.0.1:30080` |

### When to use alpha

- First deployment: learn the K3s + Trooper AI bootstrap workflow
- Minimal stack: Envoy Gateway + vLLM + NextChat
- Test public HTTPS inference before adding complexity
- Baseline to compare against beta (KServe lifecycle management)

### Quick Start

```bash
# 1. Set secrets
export CLOUDFLARE_API_TOKEN=... REGISTRY_USERNAME=... REGISTRY_PASSWORD=... HF_TOKEN=... NEXTCHAT_CODE=...

# 2. Create secrets
bash case_alpha/k8s_secrets.sh

# 3. Deploy everything
bash case_alpha/k8s_deploy.sh

# 4. Run once after deploy: socat port 443 forwarder
bash hetzner-cp-node-socat.sh
```

See [case_alpha/README.md](./case_alpha/README.md) for full details.

---

## Case α+AI (alpha+envoy-AI) — Minimal + AI Gateway

Same as case_alpha but replaces plain Envoy Gateway HTTPRoute routing with Envoy AI Gateway, adding token metering (input/output/total) and CORS for the NextChat frontend. Runs DeepSeek-R1-Distill-Qwen-14B on the GPU node.

```
Browser ──https──→ llm.yacodata.com / chat.yacodata.com (443)
                       │
                  socat (CP host, 443 → 30080)
                       │
                  Envoy Gateway proxy (CP, NodePort 30080)
                       │
              AI Gateway Controller — ext-proc
                       │
              AIGatewayRoute (token metering)
                       │
                   vLLM (GPU node)
```

See [case_alpha+envoy-AI/README.md](./case_alpha+envoy-AI/README.md) for full deployment.

---

## Case β (beta) — Single Model (with KServe)

Envoy AI Gateway → KServe → vLLM on Trooper AI 2× RTX 4080 Super 32GB (FP8, TP2). Dense BF16 (~52 GiB) needs ~80 GB VRAM; the FP8 checkpoint halves it to ~31 GB. Control plane on Hetzner CX33, GPU worker on Trooper AI. Cross-node pod networking via Flannel VXLAN over a WireGuard tunnel. Includes TLS (Let's Encrypt via Cloudflare), CORS for NextChat frontend, token metering, and rate limiting.

```
Client → llm.yacodata.com:443 (HTTPS)
           ↓
         Envoy Gateway proxy (CP node)
           ↓
         Envoy AI Gateway (InferencePool, token metering, rate limiting)
           ↓
         KServe LLMInferenceService "qwen-27b"
           └── vLLM (Qwen/Qwen3.8-27B-FP8, GPU node, TP2)
```

**Frontend**: [NextChat](https://github.com/chatgptnextweb/nextchat) served from CP node at `chat.yacodata.com`, calls Envoy Gateway directly from the browser (CORS configured via SecurityPolicy).

See [case_beta/README.md](./case_beta/README.md) for full deployment.

---

## Case γ (gamma) — Multi-Model MIG Binpacking

Two models (Qwen 2.5 7B + Qwen 2.5 14B) on a single A100 40GB via MIG partitioning. Each model gets its own KServe LLMInferenceService pinned to a dedicated MIG partition.

See [case_gamma/README.md](./case_gamma/README.md) for details.

---

## Shared Infrastructure

| Component | Directory | Used By |
|-----------|-----------|---------|
| K3s control plane | [k8s_control_plane/](./k8s_control_plane/) | α β γ Ω |
| GPU provider bootstrap | [gpu_providers/](./gpu_providers/) | α β γ Ω |
| Model image builder | [model-image/](./model-image/) | optional — all cases download weights from HF at startup |
| Monitoring (Prometheus + Grafana + DCGM) | [monitoring/](./monitoring/) | α+AI β γ Ω |
| NextChat frontend | [frontend/nextchat/](./frontend/nextchat/) | α α+AI β |
| socat forwarder (443→30080) | root: `hetzner-cp-node-socat.sh` | α α+AI β |

### Trooper AI firewall

Trooper AI has an external firewall in front of GPU nodes. For WireGuard to connect, you must open **outbound UDP 51820** to the CP node's public IP in the Trooper AI dashboard. See [wireguard/README.md](./wireguard/README.md#external-firewall-trooper-ai-gpu-node) for details.

---

## Case Ω (omega) — Multi-Model on Blackwell (2 GPUs, no MIG)

KServe + vLLM + llm-d + Envoy AI Gateway serving two models on two dedicated GPUs (no MIG partitioning):

| Model | GPU | VRAM | Quant |
|-------|-----|------|-------|
| Llama 3.1 70B Instruct | RTX Pro 5000 Blackwell | 48 GB | AWQ INT4 |
| Mistral 7B Instruct | RTX Pro 4000 Blackwell | 24 GB | BF16 |

Includes llm-d EPP (prefix-cache + load-aware scorers), per-model rate limiting, token metering, TLS via Let's Encrypt, and full monitoring.

See [case_omega/README.md](./case_omega/README.md) for details.
