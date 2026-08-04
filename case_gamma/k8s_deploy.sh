#!/usr/bin/env bash
set -euo pipefail

# Deploy all resources for case_gamma (multi-model MIG setup on A100 40GB).
# Includes full cluster infrastructure + gamma-specific LLM resources.
# Run AFTER k8s_secrets.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== 0. MIG pre-check ==="
if ! kubectl get configmap -n kube-system nvidia-device-plugin-config &>/dev/null; then
  echo "WARNING: MIG device plugin not configured."
  echo "Run on GPU node first:"
  echo "  bash ${SCRIPT_DIR}/mig/configure-mig.sh --profiles 2g.10gb,3g.20gb"
  echo ""
  read -p "Continue anyway? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
else
  echo "MIG device plugin config found."
fi

echo "=== 1. Namespace ==="
kubectl create namespace gamma --dry-run=client -o yaml | kubectl apply -f -

echo "=== 2. cert-manager ==="
helm repo add jetstack https://charts.jetstack.io --force-update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.18.0 \
  --set crds.enabled=true

echo "Creating TLS certificates (llm.yacodata.com, chat.yacodata.com)"
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/certificate.yaml"
kubectl wait --timeout=5m -n envoy-ai-gateway-system certificate/envoy-tls-cert --for=condition=Ready

echo "=== 3. AI Gateway CRDs ==="
helm upgrade -i aieg-crd oci://docker.io/envoyproxy/ai-gateway-crds-helm \
  --version v1.0.0 \
  --namespace envoy-ai-gateway-system \
  --create-namespace

echo "=== 4. AI Gateway Controller ==="
helm upgrade -i aieg oci://docker.io/envoyproxy/ai-gateway-helm \
  --version v1.0.0 \
  --namespace envoy-ai-gateway-system \
  --create-namespace
kubectl wait --timeout=2m -n envoy-ai-gateway-system deployment/ai-gateway-controller --for=condition=Available

echo "=== 5. Envoy Gateway ==="
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version v1.8.2 \
  -n envoy-gateway-system --create-namespace \
  -f "${SCRIPT_DIR}/envoy-ai-gateway/envoy-gateway-values.yaml"
kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available

echo "=== 6. GatewayClass + EnvoyProxy + Gateway ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/gatewayclass.yaml"
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/envoyproxy.yaml"
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/gateway.yaml"

echo "=== 7. Enable InferencePool support + restart ==="
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version v1.8.2 \
  -n envoy-gateway-system \
  -f "${SCRIPT_DIR}/envoy-ai-gateway/envoy-gateway-values.yaml" \
  -f "${SCRIPT_DIR}/envoy-ai-gateway/envoy-gateway-values-addon.yaml"
kubectl rollout restart -n envoy-gateway-system deployment/envoy-gateway
kubectl wait --timeout=2m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available

echo "=== 8. Re-apply Gateways (after KServe CRDs) ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/gateway.yaml"
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/kserve-gateway.yaml"

echo "=== 9. MIG device plugin config ==="
kubectl apply -f "${SCRIPT_DIR}/mig/device-plugin-config.yaml"

echo "=== 10. KServe Model Configs ==="
kubectl apply -f "${SCRIPT_DIR}/kserve/llm-inference-service-config-model-qwen14b.yaml"
kubectl apply -f "${SCRIPT_DIR}/kserve/llm-inference-service-config-workload-qwen14b.yaml"
kubectl apply -f "${SCRIPT_DIR}/kserve/llm-inference-service-config-model-qwen7b.yaml"
kubectl apply -f "${SCRIPT_DIR}/kserve/llm-inference-service-config-workload-qwen7b.yaml"

echo "=== 11. KServe LLMInferenceServices ==="
kubectl apply -f "${SCRIPT_DIR}/kserve/llm-inferenceservice-qwen14b.yaml"
kubectl apply -f "${SCRIPT_DIR}/kserve/llm-inferenceservice-qwen7b.yaml"

echo "=== 12. Envoy AI Gateway Backends ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/backend-qwen14b.yaml"
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/backend-qwen7b.yaml"

echo "=== 13. AIGatewayRoute ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/aigatewayroute.yaml"

echo "=== 14. Rate Limiting ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/rate-limit.yaml"

echo "=== 15. CORS policy ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/cors-policy.yaml"

echo ""
echo "Gamma resources deployed."
echo ""
echo "Verify with:"
echo "  kubectl get pods -n gamma -w"
echo "  kubectl get llminferenceservices -n gamma"
echo ""
echo "Test with:"
echo "  curl -X POST https://llm.yacodata.com/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -H 'x-ai-eg-model: Qwen/Qwen2.5-14B-Instruct-AWQ' \\"
echo "    -d '{\"model\":\"Qwen/Qwen2.5-14B-Instruct-AWQ\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":50}'"
