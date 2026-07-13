# K8s Control Plane (Hetzner Cloud)

Single-node K3s control plane for all cases.

## Setup

### 1. Provision a Hetzner server

We use a CX33 (4 vCPU, 8 GB RAM). Any provider works.

### 2. SSH and install K3s

```bash
ssh root@<hetzner-ip>
bash k3s-install.sh
```

This outputs `K3S_URL` and `K3S_TOKEN` — use those to bootstrap Vast.ai GPU workers.

### 3. Apply GPU manifests

Once a Vast.ai node has joined:

```bash
bash apply-gpu-manifests.sh
```

## Contents

| File | Purpose |
|------|---------|
| `k3s-install.sh` | Installs K3s v1.33 on the Hetzner node (disables Traefik, ServiceLB) |
| `apply-gpu-manifests.sh` | Applies NVIDIA device plugin DaemonSet |
| `manifests/nvidia-device-plugin.yaml` | DaemonSet that registers GPUs on Vast.ai nodes |
