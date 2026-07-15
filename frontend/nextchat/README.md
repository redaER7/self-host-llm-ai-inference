# NextChat — ChatGPT-Next-Web

Frontend UI for self-hosted LLM inference. Served from the Hetzner CP node and calls Envoy AI Gateway on the GPU node via the browser.

## Deploy

```bash
kubectl create namespace frontend
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
```

## Access

```
http://<hetzner-cp-ip>:3080
```

Configure the API endpoint in NextChat settings:
- **Endpoint**: `https://envoy-llm.yacodata.com:30080/v1`
- **API Key**: (as configured in Envoy AI Gateway)
- **Model**: `qwen2.5-7b`

Or set defaults via the deployment environment variables (`BASE_URL`, `OPENAI_API_KEY`).

## TLS (optional)

Add Cloudflare proxy on `chat.yacodata.com` → Hetzner CP IP:3080, or add cert-manager + nginx ingress on the CP node.
