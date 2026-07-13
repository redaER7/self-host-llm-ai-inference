import os
import logging

from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
import httpx

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("llm-gateway")

VLLM_URL = os.environ.get("VLLM_URL", "http://vllm-service:8001")
VLLM_TIMEOUT = int(os.environ.get("VLLM_TIMEOUT", "300"))

app = FastAPI(title="LLM Gateway", version="0.1.0")

client = httpx.AsyncClient(timeout=httpx.Timeout(VLLM_TIMEOUT))


@app.on_event("shutdown")
async def shutdown():
    await client.aclose()


async def proxy_request(path: str, request: Request) -> Response:
    url = f"{VLLM_URL}{path}"
    body = await request.body()
    headers = {
        k: v for k, v in request.headers.items()
        if k.lower() not in ("host", "content-length")
    }

    logger.info("proxying %s to %s", request.method, url)

    try:
        resp = await client.request(
            method=request.method,
            url=url,
            content=body,
            headers=headers,
        )
        return Response(
            content=resp.content,
            status_code=resp.status_code,
            headers=dict(resp.headers),
        )
    except httpx.TimeoutException:
        logger.error("timeout proxying %s", url)
        return JSONResponse(
            status_code=504,
            content={"error": "upstream timeout", "path": path},
        )
    except Exception as e:
        logger.error("error proxying %s: %s", url, str(e))
        return JSONResponse(
            status_code=502,
            content={"error": "bad gateway", "detail": str(e)},
        )


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/v1/models")
async def list_models():
    url = f"{VLLM_URL}/v1/models"
    try:
        resp = await client.get(url)
        return Response(content=resp.content, status_code=resp.status_code, headers=dict(resp.headers))
    except Exception as e:
        logger.error("error listing models: %s", str(e))
        return JSONResponse(status_code=502, content={"error": str(e)})


@app.post("/v1/completions")
async def completions(request: Request):
    return await proxy_request("/v1/completions", request)


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    return await proxy_request("/v1/chat/completions", request)


@app.post("/v1/embeddings")
async def embeddings(request: Request):
    return await proxy_request("/v1/embeddings", request)


@app.post("/v1/tokenize")
async def tokenize(request: Request):
    return await proxy_request("/v1/tokenize", request)


@app.post("/v1/detokenize")
async def detokenize(request: Request):
    return await proxy_request("/v1/detokenize", request)


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
async def catch_all(path: str, request: Request):
    return await proxy_request(f"/{path}", request)
