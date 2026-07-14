# GPU Providers

Shared scripts and configs for provisioning GPU workers.

## Contents

- `vast-ai-bootstrap.sh` — K3s agent bootstrap for Vast.ai instances (used by alpha/beta/gamma)
- `runpod-kubelet/` — k8s-runpod-kubelet Helm config (used by omega)

## Vast.ai Bootstrap

```bash
export K3S_URL=https://<hetzner-public-ip>:6443
export K3S_TOKEN=<node-token>
bash vast-ai-bootstrap.sh
```

The bootstrap installs the K3s agent, configures the NVIDIA container runtime, and applies the device plugin. After bootstrap, the GPU node appears in the cluster with labels `node-role.kubernetes.io/gpu-node=true` and taint `gpu-node=true:NoSchedule`.

## WireGuard Setup (post-bootstrap)

For data-plane traffic (gateway → vLLM), a WireGuard tunnel connects the Hetzner CP to the Vast.ai GPU worker. This is configured manually after bootstrap — see case alpha README for detailed steps.
