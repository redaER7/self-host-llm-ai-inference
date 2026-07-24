#!/usr/bin/env bash
set -euo pipefail

# Deploy all Kubernetes resources for case_alpha.
# Run AFTER k8s_secrets.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== 1. Namespaces ==="
kubectl create namespace alpha --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace frontend --dry-run=client -o yaml | kubectl apply -f -

echo "=== 2. cert-manager ==="
helm repo add jetstack https://charts.jetstack.io --force-update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.18.0 \
  --set crds.enabled=true

echo "=== 3. Envoy Gateway (no AI Gateway) ==="
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version v1.8.2 \
  -n envoy-gateway-system --create-namespace \
  -f "${SCRIPT_DIR}/envoy-gateway/envoy-gateway-values.yaml"
kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available

echo "=== 4. GatewayClass + EnvoyProxy + Gateway ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-gateway/gatewayclass.yaml"
kubectl apply -f "${SCRIPT_DIR}/envoy-gateway/envoyproxy.yaml"
kubectl apply -f "${SCRIPT_DIR}/envoy-gateway/gateway.yaml"

echo "=== 5. TLS Certificate (llm.yacodata.com + chat.yacodata.com) ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-gateway/certificate.yaml"
kubectl wait --timeout=5m -n alpha certificate/alpha-tls-cert --for=condition=Ready

echo "=== 6. Patch proxy service → NodePort 30080 ==="
ENVOY_SVC=$(kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-namespace=alpha,gateway.envoyproxy.io/owning-gateway-name=alpha-gateway \
  -o jsonpath='{.items[0].metadata.name}')
kubectl patch service "$ENVOY_SVC" -n envoy-gateway-system \
  --type=json \
  -p='[{"op":"replace","path":"/spec/ports/0/nodePort","value":30080}]'

echo "=== 7. Deploy vLLM (Qwen2.5-3B) on GPU ==="
kubectl apply -f "${SCRIPT_DIR}/vllm-deployment.yaml"
echo "Waiting for vLLM pod to be Running..."
kubectl wait --timeout=10m -n alpha pod -l app=vllm --for=condition=Ready 2>/dev/null || true

echo "=== 8. Deploy NextChat (HTTP only, TLS at Envoy) ==="
kubectl apply -f "${SCRIPT_DIR}/../frontend/nextchat/deployment.yaml"
kubectl apply -f "${SCRIPT_DIR}/../frontend/nextchat/service.yaml"

echo "=== 9. Apply HTTPRoutes ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-gateway/httproute-vllm.yaml"
kubectl apply -f "${SCRIPT_DIR}/envoy-gateway/httproute-nextchat.yaml"

echo "=== 10. CORS policy ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-gateway/cors-policy.yaml"

echo "=== 11. iptables REDIRECT 443 → 30080 ==="
sudo iptables -t nat -I PREROUTING 1 -p tcp --dport 443 -j REDIRECT --to-port 30080 2>/dev/null || true
sudo iptables -t nat -I OUTPUT 1 -p tcp --dport 443 -j REDIRECT --to-port 30080 2>/dev/null || true
sudo netfilter-persistent save 2>/dev/null || true

echo ""
echo "=== All resources deployed ==="
echo "Test inference:"
echo "  curl -X POST https://llm.yacodata.com/v1/chat/completions \\"
echo "    -H \"Content-Type: application/json\" \\"
echo "    -d '{\"model\":\"Qwen/Qwen2.5-3B-Instruct\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":100}'"
echo ""
echo "Test NextChat:"
echo "  curl -k https://chat.yacodata.com/"
