# NextChat — ChatGPT-Next-Web

Frontend UI for self-hosted LLM inference. Served from the Hetzner CP node and calls the Envoy Gateway via the browser.

## Deploy

```bash
# Create the frontend secret first (password for chat UI)
kubectl create secret generic nextchat-secret \
  -n frontend \
  --from-literal=code="your-chat-password"

# Apply deployment + service
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
```

## Deployment variants

Each case has its own deployment file with case-specific settings:

| Case | File | Model | CODE source |
|------|------|-------|-------------|
| α | `case_alpha/frontend/nextchat/deployment.yaml` | Qwen/Qwen2.5-3B-Instruct | `nextchat-secret` |
| β | `frontend/nextchat/deployment.yaml` | qwen2.5-7b | `nextchat-secret` |

## Env vars

| Variable | Purpose |
|----------|---------|
| `BASE_URL` | LLM API endpoint (Envoy Gateway URL, no `/v1` suffix) |
| `CUSTOM_MODELS` | Comma-separated model names to show in dropdown |
| `CODE` | Password to access the chat UI (from Secret `nextchat-secret`) |

## Access

```
https://chat.yacodata.com
```

TLS is terminated at Envoy Gateway (cert-manager). NextChat serves plain HTTP internally on port 3000.

## Security

- The `CODE` env var protects the chat UI with a password
- API calls from the browser use the configured BASE_URL (CORS must allow the frontend origin)
- The Envoy Gateway terminates TLS before proxying to NextChat
