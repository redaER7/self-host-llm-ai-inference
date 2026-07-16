#!/usr/bin/env bash
set -euo pipefail

# Create all Kubernetes secrets and TLS certificates for case_beta.
# Run this BEFORE k8s_deploy.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Secrets ==="

# create namespaces if not already created

if ! kubectl get ns cert-manager &> /dev/null; then
  kubectl create ns cert-manager
fi

if ! kubectl get ns beta &> /dev/null; then
  kubectl create ns beta
fi
if kubectl get ns envoy-ai-gateway-system &> /dev/null; then
  kubectl create ns envoy-ai-gateway-system
fi
if kubectl get ns envoy-gateway-system &> /dev/null; then
  kubectl create ns envoy-gateway-system
fi

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

echo ""
echo "All secrets created."
