

curl -s -X POST 127.0.0.1:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct",
    "messages": [{"role": "user", "content": "Write Python Class for sum and product of two numbers"}],
    "max_tokens": 500
  }' | jq -r '.choices[0].message.content' | sed 's/Ġ/ /g; s/Ċ/\n/g' > response.txt




# Test AI Gateway endpoint
curl -s -X POST https://llm.yacodata.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-ai-eg-model: qwen2.5-7b" \
  -d '{
    "model": "qwen2.5-7b",
    "messages": [{"role": "user", "content": "Say hello in one word"}],
    "max_tokens": 50
  }' | jq .


# Test vLLM directly (via KServe workload service, from within cluster)
# kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never -- \
#   -s http://qwen-7b-kserve-workload-svc.beta.svc.cluster.local:8000/v1/chat/completions \
#   -H "Content-Type: application/json" \
#   -d '{"model":"Qwen/Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"hi"}],"max_tokens":10}'


# Clean up evicted pods
kubectl get pods --all-namespaces --field-selector=status.phase=Failed -o json | \
  jq -r '.items[] | select(.status.reason == "Completed") | .metadata.namespace + " " + .metadata.name' | \
  while read -r namespace name; do
    kubectl delete pod "$name" -n "$namespace"
  done
