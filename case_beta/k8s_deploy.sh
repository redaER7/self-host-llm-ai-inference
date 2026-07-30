#!/usr/bin/env bash
set -euo pipefail

# Deploy all Kubernetes resources for case_beta.
# Run AFTER k8s_secrets.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== 1. Namespace ==="
kubectl create namespace beta --dry-run=client -o yaml | kubectl apply -f -

echo "=== 2. cert-manager ==="
helm repo add jetstack https://charts.jetstack.io --force-update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.18.0 \
  --set crds.enabled=true

echo "Creating TLS certificate (llm.yacodata.com)"
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/certificate.yaml"
kubectl wait --timeout=5m -n envoy-ai-gateway-system certificate/envoy-tls-cert --for=condition=Ready

# Note: chat-tls-cert is also created by certificate.yaml above (same file)

echo "=== 3. AI Gateway CRDs ==="
helm upgrade -i aieg-crd oci://docker.io/envoyproxy/ai-gateway-crds-helm \
  --version v1.0.0 \
  --namespace envoy-ai-gateway-system \
  --create-namespace

echo "=== 4. Envoy Gateway ==="
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version v1.8.2 \
  -n envoy-gateway-system --create-namespace \
  -f "${SCRIPT_DIR}/envoy-ai-gateway/envoy-gateway-values.yaml"
kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available

echo "=== 5. AI Gateway Controller ==="
helm upgrade -i aieg oci://docker.io/envoyproxy/ai-gateway-helm \
  --version v1.0.0 \
  --namespace envoy-ai-gateway-system \
  --create-namespace
kubectl wait --timeout=2m -n envoy-ai-gateway-system deployment/ai-gateway-controller --for=condition=Available

echo "=== 6. GatewayClass + EnvoyProxy + Gateway ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/gatewayclass.yaml"
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/envoyproxy.yaml"
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/gateway.yaml"

echo "=== 7. LWS Operator ==="
helm upgrade --install lws oci://registry.k8s.io/lws/charts/lws \
  --namespace lws-system --create-namespace

echo "=== 8. KServe (monolithic) ==="
curl -sL https://github.com/kserve/kserve/releases/download/v0.18.0/kserve.yaml -o /tmp/kserve.yaml
kubectl apply --server-side --force-conflicts -f /tmp/kserve.yaml || {
  echo "First apply failed (CRD race), waiting 15s for CRD establishment..."
  sleep 15
  kubectl wait --for=condition=Established crd/clusterstoragecontainers.serving.kserve.io --timeout=60s
  kubectl apply --server-side -f /tmp/kserve.yaml
}

echo "=== 8a. Built-in LLMInferenceServiceConfigs ==="
for f in config-llm-scheduler config-llm-template config-llm-router-route \
  config-llm-worker-data-parallel config-llm-decode-template \
  config-llm-decode-worker-data-parallel config-llm-prefill-template \
  config-llm-prefill-worker-data-parallel; do                    # ← removed tokenizer, tracing, scheduler-latency-predictor
  kubectl apply -n kserve -f "https://raw.githubusercontent.com/kserve/kserve/v0.18.0/config/llmisvcconfig/${f}.yaml"
done

echo "=== 8b. Gateway API Inference Extension CRDs ==="
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/latest/download/manifests.yaml

echo "=== 8c. Enable InferencePool support in Envoy Gateway + restart ==="
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version v1.8.2 \
  -n envoy-gateway-system \
  -f "${SCRIPT_DIR}/envoy-ai-gateway/envoy-gateway-values.yaml" \
  -f "${SCRIPT_DIR}/envoy-ai-gateway/envoy-gateway-values-addon.yaml"
kubectl rollout restart -n envoy-gateway-system deployment/envoy-gateway
kubectl wait --timeout=2m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available

echo "=== 9. Re-apply Gateways (after KServe CRDs) ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/gateway.yaml"
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/kserve-gateway.yaml"

echo "=== 9a. Patch ai-gateway proxy service → NodePort 30080 ==="
ENVOY_SVC=$(kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-namespace=envoy-ai-gateway-system,gateway.envoyproxy.io/owning-gateway-name=ai-gateway \
  -o jsonpath='{.items[0].metadata.name}')
kubectl patch service "$ENVOY_SVC" -n envoy-gateway-system \
  --type=json \
  -p='[{"op":"replace","path":"/spec/ports/0/nodePort","value":30080}]'

echo "=== 10. ServiceMonitors (Prometheus scrape configs) ==="
kubectl apply -f "${SCRIPT_DIR}/../monitoring/vllm-service-monitor.yaml"
kubectl apply -f "${SCRIPT_DIR}/../monitoring/envoy-proxy-service-monitor.yaml"

echo "=== 11. Grafana dashboards (ConfigMaps with grafana_dashboard label) ==="
kubectl apply -f "${SCRIPT_DIR}/../monitoring/vllm-dashboard-configmap.yaml"
kubectl apply -f "${SCRIPT_DIR}/../monitoring/envoy-gateway-dashboard-configmap.yaml"
kubectl apply -f "${SCRIPT_DIR}/../monitoring/dcgm-nvidia-dashboard-configmap.yaml"

echo "=== 12. KServe Configs ==="
kubectl apply -f "${SCRIPT_DIR}/kserve/endpoint-picker-config.yaml"
kubectl apply -f "${SCRIPT_DIR}/kserve/llm-inference-service-config-model.yaml"
kubectl apply -f "${SCRIPT_DIR}/kserve/llm-inference-service-config-workload.yaml"

echo "=== 13. KServe LLMInferenceService ==="
kubectl apply -f "${SCRIPT_DIR}/kserve/llm-inferenceservice.yaml"

echo "=== 14. Envoy AI Gateway Backend + AIServiceBackend ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/backend.yaml"

echo "=== 15. AIGatewayRoute ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/aigatewayroute.yaml"

echo "=== 16. Rate Limiting ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/rate-limit.yaml"

echo "=== 17. CORS policy ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/cors-policy.yaml"

echo "=== 18. NextChat frontend ==="
kubectl create namespace frontend --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${SCRIPT_DIR}/../frontend/nextchat/"

echo "=== 19. NextChat HTTPRoute (pointing to ai-gateway) ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/httproute-nextchat.yaml"

echo ""
echo "All resources deployed."
echo "Next steps (run once after initial deploy):"
echo "  bash hetzner-cp-node-socat.sh"
