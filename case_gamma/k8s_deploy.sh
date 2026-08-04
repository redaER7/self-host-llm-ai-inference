#!/usr/bin/env bash
set -euo pipefail

# Deploy gamma-specific resources (multi-model MIG setup on A100 40GB).
# Assumes cluster infrastructure (Envoy Gateway, KServe, etc.) is already
# installed via case_beta/k8s_deploy.sh.
# Run AFTER k8s_secrets.sh from case_beta (or create secrets manually).

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

echo "=== 2. MIG device plugin config ==="
kubectl apply -f "${SCRIPT_DIR}/mig/device-plugin-config.yaml"

echo "=== 3. KServe Model Configs ==="
kubectl apply -f "${SCRIPT_DIR}/kserve/llm-inference-service-config-model-qwen14b.yaml"
kubectl apply -f "${SCRIPT_DIR}/kserve/llm-inference-service-config-workload-qwen14b.yaml"
kubectl apply -f "${SCRIPT_DIR}/kserve/llm-inference-service-config-model-qwen7b.yaml"
kubectl apply -f "${SCRIPT_DIR}/kserve/llm-inference-service-config-workload-qwen7b.yaml"

echo "=== 4. KServe LLMInferenceServices ==="
kubectl apply -f "${SCRIPT_DIR}/kserve/llm-inferenceservice-qwen14b.yaml"
kubectl apply -f "${SCRIPT_DIR}/kserve/llm-inferenceservice-qwen7b.yaml"

echo "=== 5. Envoy AI Gateway Backends ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/backend-qwen14b.yaml"
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/backend-qwen7b.yaml"

echo "=== 6. AIGatewayRoute ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/aigatewayroute.yaml"

echo "=== 7. Rate Limiting ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/rate-limit.yaml"

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
