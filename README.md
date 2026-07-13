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
| **β** | beta | Envoy AI Gateway | KServe + vLLM + llm-d | Vast.ai | DeepSeek 33B (single) |
| **γ** | gamma | Envoy AI Gateway | KServe + vLLM + llm-d | Vast.ai (MIG) | Qwen 7B + Llama 3 70B |
| **Ω** | omega | Envoy AI Gateway | KServe + vLLM + llm-d | RunPod | Qwen 7B + DeepSeek 33B + Llama 3 70B |

See [Plan.md](./Plan.md) for full architecture details.

---

## Case α (alpha) — Minimal Single Model

Simplest possible path: a FastAPI reverse proxy in front of a single vLLM pod running on a rented Vast.ai GPU.

### Architecture

```
K8s Control Plane (Hetzner) → FastAPI → vLLM (Deployment)
                                           │
                              Vast.ai RTX 4090 (K3s agent joined via bootstrap)
```

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

#### Storage

| Type | Size | Purpose |
|------|------|---------|
| Control plane disk | 20–40 GB | K3s + OS + kubelet images |
| Model weights | ~40 GB | DeepSeek-Coder-33B-Instruct-AWQ (downloaded at runtime by vLLM) |

No persistent volume needed — model is downloaded on pod startup from Hugging Face. For repeat deployments, cache weights on a PVC to avoid re-downloads.

#### GPU (Vast.ai)

| GPU | VRAM | Why |
|-----|------|-----|
| **RTX 4090** | 24 GB | Fits DeepSeek 33B AWQ (~19 GB) with room for KV cache |
| RTX 6000 Ada | 48 GB | Overkill but works |

**Provisioning**: Rent a Vast.ai instance, SSH in, and run a bootstrap script that installs the K3s agent and joins the cluster via public IP:

```bash
export K3S_URL=https://<control-plane-public-ip>:6443
export K3S_TOKEN=<node-token>
curl -sfL https://get.k3s.io | K3S_URL=$K3S_URL K3S_TOKEN=$K3S_TOKEN sh -
```

The node appears in the cluster with `cloud=vast` and `gpu-type=rtx4090` labels. Pods are scheduled to it via `nodeSelector`.

#### Networking

| Component | Requirement |
|-----------|-------------|
| Vast.ai → Control plane | Direct public IP connection (K3S_URL) |
| Client → FastAPI | Ingress or NodePort on control plane |
| Ports | 6443 (K3s API), 80/443 (FastAPI) |

#### Software Stack

| Component | Version | Notes |
|-----------|---------|-------|
| K3s | v1.32+ | Lightweight Kubernetes |
| NVIDIA device plugin | latest | GPU scheduling on Vast.ai node |
| FastAPI | latest | Custom reverse proxy to vLLM |
| vLLM | latest | Inference engine |
| Python | 3.11+ | FastAPI runtime |
| CUDA | 12.x | On Vast.ai GPU image |

#### Domain / DNS

Optional — a hostname pointing to the control plane IP for accessing the FastAPI gateway.

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

## Case β (beta) — Single Model, Improved (with llm-d)

Envoy AI Gateway → KServe + llm-d + EPP → vLLM on Vast.ai RTX 4090. Adds cache-aware routing, token metering, and rate limiting.

See [case_beta/README.md](./case_beta/README.md) for details.

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

---

## Case Ω (omega) — Multi-Model on RunPod (with llm-d)

*Coming soon.*
