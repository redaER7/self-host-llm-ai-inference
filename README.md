# Self-Host LLM AI Inference

Self-host large language model inference on rented GPUs using Kubernetes, KServe, vLLM, and llm-d. Control plane on Hetzner Cloud, GPU workers on Vast.ai and RunPod.

**Tags**: `k3s` `vllm` `envoy-gateway` `hetzner` `trooper-ai` `vast-ai` `wireguard` `gpu-inference` `self-hosted-llm`

We use **Vast.ai** on-demand instances for GPU workers — they allow quick deploy and delete cycles, fitting our need for ephemeral GPU capacity. For a comparison of GPU rental options across providers, see [How to Rent Affordable GPU for AI Inference](https://yacodata.com/en/blog/how-to-rent-affordable-gpu-for-ai-inference).

---

## Table of Contents

- [Cases Overview](#cases-overview)
- [Case α (alpha) — Minimal Single Model](#case-α-alpha--minimal-single-model)
- [Case β (beta) — Single Model, Improved (with llm-d)](#case-β-beta--single-model-improved-with-llm-d)
- [Case γ (gamma) — Multi-Model Binpacking (with llm-d)](#case-γ-gamma--multi-model-binpacking-with-llm-d)
- [Case Ω (omega) — Multi-Model on RunPod (with llm-d)](#case-ω-omega--multi-model-on-runpod-with-llm-d)

---

## Cases Overview

| Case | Name | Gateway | LLM Stack | GPU Provider | Models |
|------|------|---------|-----------|-------------|--------|
| **α** | alpha | Envoy Gateway (plain) | vLLM (direct) | Trooper AI | Qwen 2.5-3B |
| **β** | beta | Envoy AI Gateway | KServe + vLLM + llm-d | Vast.ai | Qwen 2.5-7B |
| **γ** | gamma | Envoy AI Gateway | KServe + vLLM + llm-d | Vast.ai (MIG) | Qwen 7B + Llama 3 70B |
| **Ω** | omega | Envoy AI Gateway | KServe + vLLM + llm-d | RunPod | Qwen 7B + DeepSeek 33B + Llama 3 70B |

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

### What alpha does NOT include

- KServe (no CRDs, no InferenceService)
- llm-d (no router, no EPP scheduler)
- Envoy AI Gateway (no token metering, no rate limiting)
- Scale-to-zero (pod runs 24/7)
- MIG or GPU sharing
- Multi-model serving
- Baked model image (downloads from HF at startup)

### When to use alpha

- First deployment: learn the K3s + Trooper AI bootstrap workflow
- Minimal stack: Envoy Gateway + vLLM + NextChat
- Test public HTTPS inference before adding complexity
- Baseline to compare against beta (KServe + llm-d improvements)

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

## Case β (beta) — Single Model, All on GPU Node

Envoy AI Gateway → KServe + llm-d + EPP → vLLM on Vast.ai RTX 3090. All components co-located on the GPU node — no cross-node networking, no WireGuard tunnel. Includes TLS (Let's Encrypt via Cloudflare), CORS for NextChat frontend, and Envoy Gateway as the single routing layer.

```
Client → envoy-llm.yacodata.com:30080 (HTTPS)
           ↓
         Envoy Gateway proxy (GPU node, hostNetwork)
           ↓
         Envoy AI Gateway (InferencePool, token metering, rate limiting)
           ↓
         KServe LLMInferenceService "qwen-7b"
           ├── llm-d Router (cache-aware)
           ├── EPP Scheduler (prefix-cache + load-aware)
           └── vLLM (Qwen/Qwen2.5-7B-Instruct, same node)
```

**Frontend**: [NextChat](https://github.com/chatgptnextweb/nextchat) served from CP node at `chat.yacodata.com`, calls Envoy Gateway directly from the browser (CORS configured via SecurityPolicy).

See [case_beta/README.md](./case_beta/README.md) for full deployment.

---

## Case γ (gamma) — Multi-Model Binpacking (with llm-d)

Two models (Qwen 2.5 7B + Llama 3 70B) on a single A100 80GB via MIG partitioning. Each model gets its own KServe + llm-d + EPP stack pinned to a dedicated MIG partition.

See [case_gamma/README.md](./case_gamma/README.md) for details.

---

## Shared Infrastructure

| Component | Directory | Used By |
|-----------|-----------|---------|
| K3s control plane | [k8s_control_plane/](./k8s_control_plane/) | α β γ Ω |
| GPU provider bootstrap | [gpu_providers/](./gpu_providers/) | α β γ Ω |
| Model image builder | [model-image/](./model-image/) | α β γ Ω |
| Monitoring (Prometheus + Grafana + DCGM) | [monitoring/](./monitoring/) | β γ Ω |
| NextChat frontend | [frontend/nextchat/](./frontend/nextchat/) | α β |
| socat forwarder (443→30080) | root: `hetzner-cp-node-socat.sh` | α β |

### Trooper AI firewall

Trooper AI has an external firewall in front of GPU nodes. For WireGuard to connect, you must open **outbound UDP 51820** to the CP node's public IP in the Trooper AI dashboard. See [wireguard/README.md](./wireguard/README.md#external-firewall-trooper-ai-gpu-node) for details.

---

## Case Ω (omega) — Multi-Model on RunPod (with llm-d)

*Coming soon.*
