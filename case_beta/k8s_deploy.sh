#!/usr/bin/env bash
set -euo pipefail

# Deploy all Kubernetes resources for case_beta.
# Run AFTER k8s_secrets.sh.

# install helm
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
chmod 700 get_helm.sh
./get_helm.sh

#set up cluster access on gpu node
#sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
#sudo chown $USER:$USER ~/.kube/config
#chmod 600 ~/.kube/config

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== 1. Namespace ==="
kubectl create namespace beta --dry-run=client -o yaml | kubectl apply -f -

echo "=== 2. cert-manager ==="
helm repo add jetstack https://charts.jetstack.io --force-update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.18.0 \
  --set crds.enabled=true

echo " Creating TLS certificate (envoy-llm.yacodata.com)"
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/certificate.yaml"

echo ""
echo "Waiting for certificate to be ready..."
kubectl wait --timeout=5m -n envoy-ai-gateway-system certificate/envoy-tls-cert --for=condition=Ready

echo "Creating TLS certificate (chat.yacodata.com)"
kubectl apply -f "${SCRIPT_DIR}/../frontend/nextchat/certificate.yaml"
kubectl wait --timeout=5m -n frontend certificate/frontend-tls-cert --for=condition=Ready

echo "=== 3. AI Gateway CRDs ==="
helm upgrade -i aieg-crd oci://docker.io/envoyproxy/ai-gateway-crds-helm \
  --version v1.0.0 \
  --namespace envoy-ai-gateway-system \
  --create-namespace

echo "=== 4. Envoy Gateway ==="
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version v1.8.2 \
  -n envoy-gateway-system --create-namespace
kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available

echo "=== 5. GatewayClass + EnvoyProxy + Gateway ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/gatewayclass.yaml"
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/envoyproxy.yaml"
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/gateway.yaml"

echo "=== 6. AI Gateway Controller ==="
helm upgrade -i aieg oci://docker.io/envoyproxy/ai-gateway-helm \
  --version v1.0.0 \
  --namespace envoy-ai-gateway-system \
  --create-namespace
kubectl wait --timeout=2m -n envoy-ai-gateway-system deployment/ai-gateway-controller --for=condition=Available

echo "=== 7. LWS Operator ==="
helm upgrade --install lws oci://registry.k8s.io/lws/charts/lws --version v0.6.2 \
  --namespace lws-system --create-namespace

echo "=== 8. KServe (monolithic) ==="
kubectl apply --server-side -f https://github.com/kserve/kserve/releases/download/v0.18.0/kserve.yaml

echo "=== 9. Re-apply Gateway (after KServe CRDs) ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/gateway.yaml"

echo "=== 10. Monitoring ==="
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  -f "${SCRIPT_DIR}/../monitoring/kube-prometheus-stack-values.yaml"
kubectl apply -f "${SCRIPT_DIR}/../monitoring/dcgm-exporter.yaml"

echo "=== 11. KServe LLMInferenceServiceConfig ==="
kubectl apply -f "${SCRIPT_DIR}/kserve/llm-inferenceservice-config.yaml"

echo "=== 12. KServe LLMInferenceService ==="
kubectl apply -f "${SCRIPT_DIR}/kserve/llm-inferenceservice.yaml"

echo "=== 13. Envoy AI Gateway InferencePool + Model ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/inferencepool.yaml"

echo "=== 14. Envoy AI Gateway HTTPRoute ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/aigatewayroute.yaml"

echo "=== 15. Expose Envoy Gateway via NodePort ==="
kubectl patch service envoy-gateway-proxy -n envoy-gateway-system \
  --type=json \
  -p='[{"op":"replace","path":"/spec/type","value":"NodePort"},{"op":"add","path":"/spec/ports/-","value":{"name":"https","port":443,"targetPort":443,"nodePort":30080,"protocol":"TCP"}}]'

echo "=== 16. CORS policy ==="
kubectl apply -f "${SCRIPT_DIR}/envoy-ai-gateway/cors-policy.yaml"

echo "=== 17. NextChat frontend ==="
kubectl create namespace frontend --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${SCRIPT_DIR}/../frontend/nextchat/"

echo ""
echo "All resources deployed."
echo "Next steps:"
echo "  1. Configure Vast.ai port forwarding: instance port -> 30080"
echo "  2. Set DNS A records:"
echo "     - envoy-llm.yacodata.com -> <vast-public-ip>"
echo "     - chat.yacodata.com      -> <hetzner-cp-ip>"
echo "  3. Access NextChat at https://<hetzner-cp-ip>:3080"
