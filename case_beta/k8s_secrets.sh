#!/usr/bin/env bash
set -euo pipefail

# Create all Kubernetes secrets and TLS certificates for case_beta.
# Run this BEFORE k8s_deploy.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Secrets ==="

echo "[1/4] Cloudflare API token (cert-manager DNS-01)"
kubectl create secret generic cloudflare-api-token \
  --namespace cert-manager \
  --from-literal=api-token="${CLOUDFLARE_API_TOKEN:?Set CLOUDFLARE_API_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[2/4] Registry credentials (model image pull)"
kubectl create namespace beta --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret docker-registry registry-credentials \
  --namespace beta \
  --docker-server=docker-registry.yacodata.com \
  --docker-username="${REGISTRY_USERNAME:?Set REGISTRY_USERNAME}" \
  --docker-password="${REGISTRY_PASSWORD:?Set REGISTRY_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[3/4] HuggingFace token (model download)"
kubectl create secret generic hf-token \
  --namespace beta \
  --from-literal=token="${HF_TOKEN:?Set HF_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[4/4] TLS certificate (envoy-llm.yacodata.com)"
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/certificate.yaml"

echo ""
echo "Waiting for certificate to be ready..."
kubectl wait --timeout=5m -n envoy-ai-gateway-system certificate/envoy-tls-cert --for=condition=Ready

echo ""
echo "All secrets created."
