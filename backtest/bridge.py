#!/usr/bin/env python3
"""
Ponte de backtest EA <-> Hermes (async webhook -> sync).

Fluxo:
  EA (Strategy Tester, DLL rest-mql, SINCRONO)
    --> POST /decide  (contexto de mercado)
        - gera correlation_id
        - cache hit? devolve na hora
        - senao: monta prompt compacto e dispara o webhook do Hermes (202),
          registra um Future e ESPERA o callback (com timeout).
  Hermes roda a skill `smc-backtest` -> decide -> curl POST /callback
    --> /callback casa o correlation_id e libera o Future.
  /decide responde a decisao ao EA (ou NO_DECISION em timeout).

Rodar:  uvicorn bridge:app --host 0.0.0.0 --port 8000
Requer: fastapi, uvicorn, httpx
"""
import os
import json
import time
import uuid
import hmac
import asyncio
import hashlib
from pathlib import Path

import httpx
from fastapi import FastAPI, Request

# ─── Config (env) ────────────────────────────────────────────────────────────
HERMES_URL      = os.getenv("HERMES_URL",      "http://192.168.100.56:8644")
HERMES_ROUTE    = os.getenv("HERMES_ROUTE",    "smc")
CALLBACK_BASE   = os.getenv("CALLBACK_BASE_URL", "http://192.168.100.56:8000")  # onde ESTA ponte escuta (acessivel pelo Hermes)
DECIDE_TIMEOUT  = float(os.getenv("DECIDE_TIMEOUT", "45"))   # deve ser < timeout do EA
DISPATCH_TIMEOUT= float(os.getenv("DISPATCH_TIMEOUT", "10")) # timeout do POST ao webhook
WEBHOOK_SECRET  = os.getenv("HERMES_WEBHOOK_SECRET", "")     # se a rota exigir HMAC-SHA256
CACHE_FILE      = Path(os.getenv("CACHE_FILE", "backtest_cache.json"))

app = FastAPI(title="SMC Backtest Bridge")

# ─── Cache persistente (replay barato e deterministico) ──────────────────────
_cache: dict = {}
if CACHE_FILE.exists():
    try:
        _cache = json.loads(CACHE_FILE.read_text(encoding="utf-8"))
    except Exception:
        _cache = {}

def _save_cache() -> None:
    try:
        CACHE_FILE.write_text(json.dumps(_cache, ensure_ascii=False), encoding="utf-8")
    except Exception:
        pass

def _cache_key(ctx: dict) -> str:
    """Chave deterministica: so os campos que mudam a decisao."""
    relevant = {
        "symbol": ctx.get("symbol"),
        "tf":     ctx.get("tf_signal"),
        "t":      ctx.get("server_time"),
        "snap":   ctx.get("snapshot"),
        "htf":    ctx.get("htf_bias"),
        "pos":    ctx.get("position"),
    }
    blob = json.dumps(relevant, sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()

# ─── Correlacao async ────────────────────────────────────────────────────────
_pending: dict[str, asyncio.Future] = {}

def _build_prompt(ctx: dict, correlation_id: str) -> str:
    s   = ctx.get("snapshot", {}) or {}
    ind = s.get("indicators", {}) or {}
    pd  = s.get("premium_discount", {}) or {}
    tr  = s.get("trend", {}) or {}
    px  = s.get("price", {}) or {}
    pos = ctx.get("position", {}) or {}
    zones = s.get("zones", []) or []
    cb = f"{CALLBACK_BASE.rstrip('/')}/callback"
    return "\n".join([
        "MODO BACKTEST. Decida SO com este contexto (sem MCP, sem memoria).",
        f"correlation_id={correlation_id}",
        f"callback_url={cb}",
        f"symbol={ctx.get('symbol')} tf={ctx.get('tf_signal')} server_time={ctx.get('server_time')}",
        f"preco_last={px.get('last_close')} bid={px.get('bid')} ask={px.get('ask')}",
        f"trend_major={tr.get('major')} trend_minor={tr.get('minor')} htf_bias={ctx.get('htf_bias')}",
        f"zona={pd.get('current_zone')} equilibrio={pd.get('equilibrium')} range=[{pd.get('range_low')},{pd.get('range_high')}]",
        f"ADX={ind.get('adx')} ADX_prev={ind.get('adx_prev')} DI+={ind.get('di_plus')} DI-={ind.get('di_minus')} %R={ind.get('wpr')} ATR={ind.get('atr')}",
        f"posicao dir={pos.get('dir')} vol={pos.get('volume')} open={pos.get('open')} sl={pos.get('sl')} tp={pos.get('tp')} id={pos.get('id')}",
        "zonas_fvg=" + json.dumps(zones, ensure_ascii=False),
        "Aplique a skill smc-backtest e devolva a decisao via curl no callback_url.",
    ])

def _sign(body: bytes) -> dict:
    if not WEBHOOK_SECRET:
        return {}
    mac = hmac.new(WEBHOOK_SECRET.encode(), body, hashlib.sha256).hexdigest()
    return {"X-Hub-Signature-256": f"sha256={mac}"}

# ─── Endpoints ───────────────────────────────────────────────────────────────
@app.post("/decide")
async def decide(req: Request):
    ctx = await req.json()

    key = _cache_key(ctx)
    if key in _cache:
        out = dict(_cache[key]); out["source"] = "cache"
        return out

    correlation_id = uuid.uuid4().hex
    payload = {
        "prompt_text": _build_prompt(ctx, correlation_id),
        "correlation_id": correlation_id,
        "event_type": "smc_decide",
    }
    body = json.dumps(payload).encode("utf-8")
    headers = {"Content-Type": "application/json", **_sign(body)}

    loop = asyncio.get_event_loop()
    fut: asyncio.Future = loop.create_future()
    _pending[correlation_id] = fut

    url = f"{HERMES_URL.rstrip('/')}/webhooks/{HERMES_ROUTE}"
    try:
        async with httpx.AsyncClient(timeout=DISPATCH_TIMEOUT) as client:
            await client.post(url, content=body, headers=headers)  # espera-se 202 Accepted
    except Exception as e:
        _pending.pop(correlation_id, None)
        return {"action": "NO_DECISION", "source": "error",
                "reason": f"falha ao disparar Hermes: {e}", "correlation_id": correlation_id}

    try:
        decision = await asyncio.wait_for(fut, timeout=DECIDE_TIMEOUT)
    except asyncio.TimeoutError:
        _pending.pop(correlation_id, None)
        return {"action": "NO_DECISION", "source": "timeout",
                "reason": f"sem callback em {DECIDE_TIMEOUT}s", "correlation_id": correlation_id}

    decision["correlation_id"] = correlation_id
    _cache[key] = {k: v for k, v in decision.items() if k != "source"}
    _save_cache()
    decision["source"] = "llm"
    return decision

@app.post("/callback")
async def callback(req: Request):
    body = await req.json()
    cid = body.get("correlation_id")
    decision = body.get("decision", {k: v for k, v in body.items() if k != "correlation_id"})
    fut = _pending.pop(cid, None)
    if fut and not fut.done():
        fut.set_result(decision)
        return {"status": "ok"}
    return {"status": "unknown_or_late", "correlation_id": cid}

@app.get("/health")
async def health():
    return {"status": "ok", "pending": len(_pending), "cache_entries": len(_cache),
            "hermes": f"{HERMES_URL}/webhooks/{HERMES_ROUTE}", "timeout": DECIDE_TIMEOUT}
