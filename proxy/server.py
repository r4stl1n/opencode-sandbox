import os

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse
from starlette.background import BackgroundTask

ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY", "")
OPENAI_COMPAT_API_KEY = os.environ.get("OPENAI_COMPAT_API_KEY", "")

ANTHROPIC_UPSTREAM = os.environ.get("ANTHROPIC_UPSTREAM", "https://api.anthropic.com")
OPENAI_UPSTREAM = os.environ.get("OPENAI_UPSTREAM", "https://api.openai.com")
# Generic OpenAI-compatible upstream (LM Studio, Ollama, OpenRouter, vLLM, etc.).
# No default — the /compat route returns 503 unless this is set.
OPENAI_COMPAT_UPSTREAM = os.environ.get("OPENAI_COMPAT_UPSTREAM", "")

TIMEOUT = httpx.Timeout(connect=10.0, read=600.0, write=30.0, pool=30.0)

HOP_BY_HOP = {
    "connection", "keep-alive", "transfer-encoding", "te", "trailer",
    "proxy-authorization", "proxy-authenticate", "upgrade",
    "host", "content-length",
}

app = FastAPI(title="opencode-sandbox-llm-proxy")
client = httpx.AsyncClient(timeout=TIMEOUT)


def _scrub(headers):
    return {k: v for k, v in headers.items() if k.lower() not in HOP_BY_HOP}


async def _forward(request, upstream_base, upstream_path, auth_header_name, auth_header_value):
    if not request.headers.get(auth_header_name):
        raise HTTPException(401, detail=f"missing {auth_header_name}")

    headers = _scrub(request.headers)
    headers[auth_header_name] = auth_header_value
    body = await request.body()
    upstream_url = f"{upstream_base.rstrip('/')}/{upstream_path.lstrip('/')}"

    upstream_req = client.build_request(
        method=request.method,
        url=upstream_url,
        params=request.query_params,
        content=body,
        headers=headers,
    )
    try:
        upstream_resp = await client.send(upstream_req, stream=True)
    except httpx.RequestError as exc:
        raise HTTPException(502, detail=f"upstream error: {exc}") from exc

    return StreamingResponse(
        upstream_resp.aiter_raw(),
        status_code=upstream_resp.status_code,
        headers=_scrub(upstream_resp.headers),
        background=BackgroundTask(upstream_resp.aclose),
    )


def _ensure_v1(path):
    # Different clients append paths differently to a configured baseURL:
    # the claude SDK sends `v1/messages`, opencode's anthropic provider sends
    # bare `messages`. Both need to land at `<upstream>/v1/messages`.
    p = path.lstrip("/")
    if p.startswith("v1/"):
        p = p[3:]
    return f"v1/{p}"


@app.api_route("/anthropic/{path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE"])
async def anthropic(path, request: Request):
    if not ANTHROPIC_API_KEY:
        raise HTTPException(503, detail="proxy: ANTHROPIC_API_KEY not configured")
    return await _forward(request, ANTHROPIC_UPSTREAM, _ensure_v1(path), "x-api-key", ANTHROPIC_API_KEY)


@app.api_route("/v1/{path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE"])
async def openai(path, request: Request):
    if not OPENAI_API_KEY:
        raise HTTPException(503, detail="proxy: OPENAI_API_KEY not configured")
    return await _forward(request, OPENAI_UPSTREAM, _ensure_v1(path), "authorization", f"Bearer {OPENAI_API_KEY}")


@app.api_route("/compat/{path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE"])
async def openai_compat(path, request: Request):
    # Generic OpenAI-compatible passthrough. Upstream URL is configurable so
    # users can point this at LM Studio, Ollama, OpenRouter, vLLM, etc.
    if not OPENAI_COMPAT_UPSTREAM:
        raise HTTPException(503, detail="proxy: OPENAI_COMPAT_UPSTREAM not configured")
    # If no compat key is configured (typical for local ollama / llama.cpp
    # which ignore auth), pass through the client's Authorization header
    # rather than overriding with an empty "Bearer " (httpx rejects that).
    auth = (
        f"Bearer {OPENAI_COMPAT_API_KEY}"
        if OPENAI_COMPAT_API_KEY
        else request.headers.get("authorization", "Bearer sandbox")
    )
    return await _forward(request, OPENAI_COMPAT_UPSTREAM, _ensure_v1(path), "authorization", auth)


@app.get("/healthz")
async def healthz():
    return {"ok": True}
