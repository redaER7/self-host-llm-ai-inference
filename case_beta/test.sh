
kubectl port-forward -n envoy-gateway-system \
  svc/envoy-envoy-ai-gateway-system-ai-gateway-e09f2496 \
  8443:443

# Terminal 2: Frontend (HTTPS on 443)
kubectl port-forward -n frontend svc/nextchat 3443:443
Test commands
# Test API (will use self-signed cert, so -k)
curl -k -X POST https://localhost:8443/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-ai-eg-model: qwen2.5-7b" \
  -d '{
    "model": "qwen2.5-7b",
    "messages": [{"role": "user", "content": "Say hello"}],
    "max_tokens": 50
  }'





kubectl get pods --all-namespaces --field-selector=status.phase=Failed -o json | \
  jq -r '.items[] | select(.status.reason == "Evicted") | .metadata.namespace + " " + .metadata.name' | \
  while read -r namespace name; do
    kubectl delete pod "$name" -n "$namespace"
  done
