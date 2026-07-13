# GPU Providers

Shared scripts and configs for provisioning GPU workers.

## Contents

- `vast-ai-bootstrap.sh` — K3s agent bootstrap for Vast.ai instances (used by alpha/beta/gamma)
- `runpod-kubelet/` — k8s-runpod-kubelet Helm config (used by omega)

## Vast.ai Bootstrap

```bash
export K3S_URL=https://<control-plane-public-ip>:6443
export K3S_TOKEN=<node-token>
bash vast-ai-bootstrap.sh
```
