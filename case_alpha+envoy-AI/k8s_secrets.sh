#!/usr/bin/env bash
set -euo pipefail

echo "=== Namespaces ==="
for ns in alpha cert-manager envoy-gateway-system envoy-ai-gateway-system frontend monitoring; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

echo "[1/4] Cloudflare API token (cert-manager DNS-01)"
kubectl create secret generic cloudflare-api-token \
  --namespace cert-manager \
  --from-literal=api-token="${CLOUDFLARE_API_TOKEN:?Set CLOUDFLARE_API_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[2/4] Registry credentials (image pull)"
kubectl create secret docker-registry registry-credentials \
  --namespace alpha \
  --docker-server=docker-registry.yacodata.com \
  --docker-username="${REGISTRY_USERNAME:?Set REGISTRY_USERNAME}" \
  --docker-password="${REGISTRY_PASSWORD:?Set REGISTRY_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[3/4] HuggingFace token (model download)"
kubectl create secret generic hf-token \
  --namespace alpha \
  --from-literal=token="${HF_TOKEN:?Set HF_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[4/4] NextChat secret (password protection)"
kubectl create secret generic nextchat-secret \
  --namespace frontend \
  --from-literal=code="${NEXTCHAT_CODE:?Set NEXTCHAT_CODE}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "All secrets created."
