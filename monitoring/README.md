# Monitoring

Shared monitoring stack for all cases: Prometheus + Grafana + node_exporter + DCGM + vLLM metrics.

## What's Monitored

| Source | Collector | Metrics |
|--------|-----------|---------|
| **Nodes** | node_exporter (DaemonSet) | CPU, RAM, disk, network |
| **GPU** | dcgm-exporter (DaemonSet) | GPU util, memory, temp, power, PCIe |
| **vLLM** | Built-in `/metrics` endpoint | TTFT, TPOT, tokens/sec, KV cache usage, queue depth |
| **Envoy AI Gateway** | Envoy stats endpoint | Request counts, token metering, HTTP status codes |
| **K8s cluster** | kube-state-metrics | Pods, deployments, nodes, services |

## Installation

### 1. Install kube-prometheus-stack

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  -f kube-prometheus-stack-values.yaml
```

### 2. Install DCGM Exporter (GPU metrics)

```bash
kubectl apply -f dcgm-exporter.yaml
```

### 3. Verify

```bash
kubectl -n monitoring get pods
kubectl -n kube-system get pods -l app=dcgm-exporter
```

### 4. Access Grafana

```bash
GRAFANA_PORT=$(kubectl -n monitoring get svc kube-prometheus-stack-grafana -o jsonpath='{.spec.ports[0].nodePort}')
echo "http://<control-plane-ip>:$GRAFANA_PORT"
# Default: admin / admin
```

### 5. Import Dashboards

| Dashboard | Grafana ID | Source |
|-----------|-----------|--------|
| NVIDIA DCGM Exporter | 12239 | grafana.com |
| vLLM Official | — | [vLLM repo](https://github.com/vllm-project/vllm/tree/main/examples/production-grafana-dashboards) |
| Kubernetes / Views / Global | 15757 | grafana.com |

Prometheus is configured to auto-discover vLLM pods via the `prometheus.io/scrape: "true"` annotation. vLLM pods expose metrics on port 8000 at `/metrics`.

## Prometheus Storage

- Retention: **7 days**
- Storage limit: **10 GB** (hostPath on the control plane node)
- Scrape interval: **30s**

This fits within the Hetzner CX33's 40 GB disk alongside K3s and container images.
