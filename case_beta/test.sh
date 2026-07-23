
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


curl -s -X POST http://localhost:8200/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct",
    "messages": [{"role": "user", "content": "Write python class which outputs sum and product"}],
    "max_tokens": 1000
  }' | jq -r '.choices[0].message.content' | sed 's/Ġ/ /g; s/Ċ/\n/g' > response.txt



curl -s -X POST http://localhost:8200/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct",
    "messages": [{"role": "user", "content": "Outline major diffrences between Django API and FastAPI"}],
    "max_tokens": 1200
  }' | jq -r '.choices[0].message.content' | sed 's/Ġ/ /g; s/Ċ/\n/g' > response.txt



docker run -it \
    -e HF_TOKEN="${HF_TOKEN}" \
    -e VLLM_LOGGING_LEVEL=DEBUG \
    --gpus all \
    --shm-size=8g \
    -p 8000:8000 \
    vllm/vllm-openai:latest \
    --model ${MODEL_NAME} \
    --max-model-len 8192



curl -s -X POST 127.0.0.1:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-3B-Instruct",
    "messages": [{"role": "user", "content": "Write simple sum production class in Python"}],
    "max_tokens": 1200
  }' | jq -r '.choices[0].message.content' | sed 's/Ġ/ /g; s/Ċ/\n/g' > response.txt