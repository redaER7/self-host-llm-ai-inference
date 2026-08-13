#!/usr/bin/env bash
set -euo pipefail

# Create all Kubernetes secrets for case_gamma.
# Run this BEFORE k8s_deploy.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Secrets ==="

echo "Ensuring namespaces exist..."
for ns in gamma cert-manager envoy-ai-gateway-system envoy-gateway-system kserve; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

echo "[1/2] HuggingFace token (model download)"
kubectl create secret generic hf-token \
  --namespace gamma \
  --from-literal=token="${HF_TOKEN:?Set HF_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[2/3] Registry credentials (image pull)"
kubectl create secret docker-registry registry-credentials \
  --namespace gamma \
  --docker-server="${REGISTRY_SERVER:-docker-registry.yacodata.com}" \
  --docker-username="${REGISTRY_USERNAME:?Set REGISTRY_USERNAME}" \
  --docker-password="${REGISTRY_PASSWORD:?Set REGISTRY_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[3/3] Cloudflare API token (TLS certificate DNS01 challenge)"
kubectl create secret generic cloudflare-api-token \
  --namespace cert-manager \
  --from-literal=api-token="${CLOUDFLARE_API_TOKEN:?Set CLOUDFLARE_API_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "All secrets created."
