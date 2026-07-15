# Self-Host LLM AI Inference

Self-host large language model inference on rented GPUs using Kubernetes, KServe, vLLM, and llm-d. Control plane on Hetzner Cloud, GPU workers on Vast.ai and RunPod.

**Tags**: `k3s` `kserve` `vllm` `llm-d` `envoy-ai-gateway` `fastapi` `hetzner` `vast-ai` `runpod` `mig` `gpu-inference` `self-hosted-llm`

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
| **α** | alpha | FastAPI | vLLM (plain) | Vast.ai | DeepSeek 33B (single) |
| **β** | beta | Envoy AI Gateway | KServe + vLLM + llm-d | Vast.ai | Qwen 2.5-7B (all on GPU node) |
| **γ** | gamma | Envoy AI Gateway | KServe + vLLM + llm-d | Vast.ai (MIG) | Qwen 7B + Llama 3 70B |
| **Ω** | omega | Envoy AI Gateway | KServe + vLLM + llm-d | RunPod | Qwen 7B + DeepSeek 33B + Llama 3 70B |

See [Plan.md](./Plan.md) for full architecture details.

---

## Case α (alpha) — Minimal Single Model

Simplest possible path: a FastAPI reverse proxy in front of a single vLLM pod running on a Vast.ai GPU worker, with a WireGuard tunnel connecting the Hetzner control plane to the GPU node.

```
Client ──kubectl port-forward──→ FastAPI Gateway (Hetzner CP, hostNetwork)
                                       │
                                 WireGuard tunnel (10.8.0.0/24)
                                       │
                                 vLLM (Vast.ai GPU, hostNetwork)
```

| Component | Where | Detail |
|-----------|-------|--------|
| K3s control plane | Hetzner CX33 | K3s server, `node-role.kubernetes.io/control-plane` |
| GPU worker | Vast.ai | K3s agent, `node-role.kubernetes.io/gpu-node`, taint `gpu-node=true:NoSchedule` |
| FastAPI gateway | Hetzner CP | `hostNetwork: true`, nodeSelector for control-plane |
| vLLM | Vast.ai GPU | `hostNetwork: true`, nodeSelector + toleration for gpu-node |
| WireGuard tunnel | Hetzner CP ↔ Vast.ai | wg-easy on Hetzner, client on Vast.ai |
| Client access | Local machine | `kubectl port-forward svc/llm-gateway 8080:8000` |

Both pods use `hostNetwork: true` — the gateway reaches vLLM directly at the GPU node's WireGuard IP (`10.8.0.2:8000`), bypassing ClusterIP routing and avoiding cross-node VXLAN issues.

### Requirements

#### Kubernetes Cluster

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| Kubernetes version | v1.25+ | v1.32+ |
| K3s version | v1.25+ | v1.32+ |
| Control plane nodes | 1 | 3 (HA) |
| vCPU per node | 4 | 8 |
| RAM per node | 8 GB | 16 GB |
| Disk per node | 40 GB | 80 GB |

> **Reference**: We use Hetzner Cloud (e.g. CX33, 4 vCPU / 8 GB RAM, ~€10.70/mo). Any K8s-ready provider works.

#### GPU (Vast.ai)

| GPU | VRAM | Why |
|-----|------|-----|
| **RTX 4090** | 24 GB | Fits DeepSeek 33B AWQ (~19 GB) with room for KV cache |
| RTX 6000 Ada | 48 GB | Overkill but works |

#### Vast.ai template ports

| Port | Purpose |
|------|---------|
| 8472 | Flannel VXLAN (cross-node pod networking) |
| 10250 | Kubelet (kubectl exec, logs, port-forward) |

#### Networking

| Component | Requirement |
|-----------|-------------|
| K3s API (data plane) | Vast.ai → Hetzner via public IP, port 6443 open on Hetzner firewall |
| Gateway → vLLM (data plane) | WireGuard tunnel (10.8.0.0/24), vLLM at 10.8.0.2:8000 |
| Client → Gateway | `kubectl port-forward` via Hetzner CP |

### What alpha does NOT include

- KServe (no CRDs, no InferenceService)
- llm-d (no router, no EPP scheduler, no prefix-cache routing)
- Envoy AI Gateway (no token metering, no rate limiting)
- Scale-to-zero (pod runs 24/7)
- MIG or GPU sharing
- Multi-model serving

### When to use alpha

- First deployment: learn the K3s + Vast.ai bootstrap workflow
- Single model, low traffic, no advanced routing needed
- Budget-conscious proof of concept
- Baseline to compare against beta (llm-d improvements)

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
| NextChat frontend | [frontend/nextchat/](./frontend/nextchat/) | β |

---

## Case Ω (omega) — Multi-Model on RunPod (with llm-d)

*Coming soon.*
