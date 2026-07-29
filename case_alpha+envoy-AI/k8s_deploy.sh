#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== 1. Namespaces ==="
kubectl create namespace alpha --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace frontend --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

echo "=== 2. cert-manager ==="
helm repo add jetstack https://charts.jetstack.io --force-update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.18.0 \
  --set crds.enabled=true

echo "=== 3. AI Gateway CRDs ==="
helm upgrade -i aieg-crd oci://docker.io/envoyproxy/ai-gateway-crds-helm \
  --version v1.0.0 \
  --namespace envoy-ai-gateway-system \
  --create-namespace

echo "=== 4. NVIDIA device plugin (GPU node) ==="
kubectl apply -f "${SCRIPT_DIR}/../k8s_control_plane/manifests/nvidia-device-plugin.yaml"
echo "Waiting for device plugin DaemonSet..."
kubectl wait --timeout=2m -n kube-system pod -l name=nvidia-device-plugin-ds --for=condition=Ready 2>/dev/null || true

echo "=== 5. Envoy Gateway (with AI Gateway extensionManager) ==="
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version v1.8.2 \
  -n envoy-gateway-system --create-namespace \
  -f "${SCRIPT_DIR}/envoy-ai-gateway/envoy-gateway-values.yaml"
kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available

echo "=== 6. AI Gateway Controller ==="
helm upgrade -i aieg oci://docker.io/envoyproxy/ai-gateway-helm \
  --version v1.0.0 \
  --namespace envoy-ai-gateway-system \
  --create-namespace
kubectl wait --timeout=2m -n envoy-ai-gateway-system deployment/ai-gateway-controller --for=condition=Available

echo "=== 7. GatewayClass + EnvoyProxy + Gateway ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/gatewayclass.yaml"
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/envoyproxy.yaml"
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/gateway.yaml"

echo "=== 8. TLS Certificate (llm.yacodata.com + chat.yacodata.com) ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/certificate.yaml"
kubectl wait --timeout=5m -n alpha certificate/alpha-tls-cert --for=condition=Ready

echo "=== 9. Patch proxy service → NodePort 30080 ==="
ENVOY_SVC=$(kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-namespace=alpha,gateway.envoyproxy.io/owning-gateway-name=alpha-gateway \
  -o jsonpath='{.items[0].metadata.name}')
kubectl patch service "$ENVOY_SVC" -n envoy-gateway-system \
  --type=json \
  -p='[{"op":"replace","path":"/spec/ports/0/nodePort","value":30080}]'

echo "=== 10. Deploy vLLM (DeepSeek-R1-Distill-Qwen-14B AWQ) on GPU ==="
kubectl apply -f "${SCRIPT_DIR}/vllm-deployment.yaml"
echo "Waiting for vLLM pod to be Running..."
kubectl wait --timeout=15m -n alpha pod -l app=vllm --for=condition=Ready 2>/dev/null || true

echo "=== 11. Backend + AIServiceBackend ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/backend.yaml"

echo "=== 12. AIGatewayRoute (token metering) ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/aigatewayroute.yaml"

echo "=== 13. CORS policy ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/cors-policy.yaml"

echo "=== 14. Deploy NextChat (HTTP only, TLS at Envoy) ==="
kubectl apply -f "${SCRIPT_DIR}/frontend/nextchat/deployment.yaml"
kubectl apply -f "${SCRIPT_DIR}/frontend/nextchat/service.yaml"
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/httproute-nextchat.yaml"

echo "=== 15. socat forwarder 443 → 30080 (run once) ==="
bash "${SCRIPT_DIR}/../hetzner-cp-node-socat.sh"

echo "=== 16. kube-prometheus-stack (Prometheus + Grafana + node_exporter) ==="
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  -f "${SCRIPT_DIR}/../monitoring/kube-prometheus-stack-values.yaml"
kubectl wait --timeout=3m -n monitoring pod -l app.kubernetes.io/instance=kube-prometheus-stack --for=condition=Ready 2>/dev/null || true

echo "=== 17. ServiceMonitors (Prometheus scrape configs) ==="
kubectl apply -f "${SCRIPT_DIR}/../monitoring/vllm-service-monitor.yaml"
kubectl apply -f "${SCRIPT_DIR}/../monitoring/envoy-proxy-service-monitor.yaml"

echo "=== 18. DCGM Exporter (GPU metrics on GPU node) ==="
helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts --force-update
helm upgrade dcgm-exporter gpu-helm-charts/dcgm-exporter \
  --namespace monitoring \
  --set-string nodeSelector."node-role\.kubernetes\.io/gpu-node"=true \
  --set tolerations[0].key=gpu-node \
  --set tolerations[0].operator=Equal \
  --set-string tolerations[0].value=true \
  --set tolerations[0].effect=NoSchedule \
  --set serviceMonitor.enabled=true \
  --set serviceMonitor.namespace=monitoring \
  --set serviceMonitor.labels.release=kube-prometheus-stack
kubectl wait --timeout=2m -n monitoring pod -l app.kubernetes.io/name=dcgm-exporter --for=condition=Ready 2>/dev/null || true

echo ""
echo "=== All resources deployed ==="
echo ""
echo "Test inference:"
echo "  curl -X POST https://llm.yacodata.com/v1/chat/completions \\"
echo "    -H \"Content-Type: application/json\" \\"
echo "    -d '{\"model\":\"casperhansen/deepseek-r1-distill-qwen-14b-awq\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":100}'"
echo ""
echo "Test NextChat:"
echo "  open https://chat.yacodata.com/"
echo ""
echo "Grafana (NodePort):"
echo "  GRAFANA_PORT=\$(kubectl -n monitoring get svc kube-prometheus-stack-grafana -o jsonpath='{.spec.ports[0].nodePort}')"
echo "  echo \"http://<cp-ip>:\$GRAFANA_PORT\"  # admin / admin"
echo ""
echo "Monitor AI Gateway logs:"
echo "  kubectl logs -n envoy-ai-gateway-system deployment/ai-gateway-controller -f"
