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
import uuid
import hmac
import asyncio
import logging
import hashlib
from pathlib import Path

import httpx
from fastapi import FastAPI, Request

# ─── Config (env) ────────────────────────────────────────────────────────────
HERMES_URL      = os.getenv("HERMES_URL",      "http://192.168.100.56:8644")
HERMES_ROUTE    = os.getenv("HERMES_ROUTE",    "backtest")
CALLBACK_BASE   = os.getenv("CALLBACK_BASE_URL", "http://127.0.0.1:8000")  # onde ESTA ponte escuta (acessivel pelo Hermes)
DECIDE_TIMEOUT  = float(os.getenv("DECIDE_TIMEOUT", "45"))   # deve ser < timeout do EA
DISPATCH_TIMEOUT= float(os.getenv("DISPATCH_TIMEOUT", "10")) # timeout do POST ao webhook
WEBHOOK_SECRET  = os.getenv("HERMES_WEBHOOK_SECRET", "")     # rota com HMAC-SHA256 (X-Hub-Signature-256)
WEBHOOK_TOKEN   = os.getenv("HERMES_WEBHOOK_TOKEN", "")      # rota com token simples (X-Gitlab-Token)
CACHE_FILE      = Path(os.getenv("CACHE_FILE", "backtest_cache.json"))
LOG_FILE        = os.getenv("LOG_FILE", "logs/bridge.log")

# ─── Logging (arquivo + console) ─────────────────────────────────────────────
Path(LOG_FILE).parent.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    handlers=[logging.FileHandler(LOG_FILE, encoding="utf-8"), logging.StreamHandler()],
)
log = logging.getLogger("bridge")

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

def _auth_headers(body: bytes) -> dict:
    h: dict = {}
    if WEBHOOK_TOKEN:                       # GitLab-style: comparacao de string simples
        h["X-Gitlab-Token"] = WEBHOOK_TOKEN
    if WEBHOOK_SECRET:                      # GitHub-style: HMAC-SHA256 do corpo
        mac = hmac.new(WEBHOOK_SECRET.encode(), body, hashlib.sha256).hexdigest()
        h["X-Hub-Signature-256"] = f"sha256={mac}"
    return h

# ─── Endpoints ───────────────────────────────────────────────────────────────
@app.post("/decide")
async def decide(req: Request):
    ctx = await req.json()
    sym, t = ctx.get("symbol"), ctx.get("server_time")

    key = _cache_key(ctx)
    if key in _cache:
        out = dict(_cache[key]); out["source"] = "cache"
        log.info("DECIDE cache-hit symbol=%s t=%s -> %s", sym, t, out.get("action"))
        return out

    correlation_id = uuid.uuid4().hex
    payload = {
        "prompt_text": _build_prompt(ctx, correlation_id),
        "correlation_id": correlation_id,
        "event_type": "smc_decide",
    }
    body = json.dumps(payload).encode("utf-8")
    headers = {"Content-Type": "application/json", **_auth_headers(body)}

    loop = asyncio.get_event_loop()
    fut: asyncio.Future = loop.create_future()
    _pending[correlation_id] = fut

    url = f"{HERMES_URL.rstrip('/')}/webhooks/{HERMES_ROUTE}"
    log.info("DECIDE miss symbol=%s t=%s cid=%s -> dispatch %s", sym, t, correlation_id, url)
    try:
        async with httpx.AsyncClient(timeout=DISPATCH_TIMEOUT) as client:
            r = await client.post(url, content=body, headers=headers)  # espera-se 202 Accepted
        log.info("DISPATCH cid=%s hermes_status=%s", correlation_id, r.status_code)
    except Exception as e:
        _pending.pop(correlation_id, None)
        log.error("DISPATCH-FAIL cid=%s err=%s", correlation_id, e)
        return {"action": "NO_DECISION", "source": "error",
                "reason": f"falha ao disparar Hermes: {e}", "correlation_id": correlation_id}

    try:
        decision = await asyncio.wait_for(fut, timeout=DECIDE_TIMEOUT)
    except asyncio.TimeoutError:
        _pending.pop(correlation_id, None)
        log.warning("TIMEOUT cid=%s sem callback em %ss", correlation_id, DECIDE_TIMEOUT)
        return {"action": "NO_DECISION", "source": "timeout",
                "reason": f"sem callback em {DECIDE_TIMEOUT}s", "correlation_id": correlation_id}

    decision["correlation_id"] = correlation_id
    _cache[key] = {k: v for k, v in decision.items() if k != "source"}
    _save_cache()
    decision["source"] = "llm"
    log.info("DECIDE done cid=%s -> %s sl=%s tp=%s", correlation_id,
             decision.get("action"), decision.get("sl"), decision.get("tp"))
    return decision

@app.post("/callback")
async def callback(req: Request):
    body = await req.json()
    cid = body.get("correlation_id")
    decision = body.get("decision", {k: v for k, v in body.items() if k != "correlation_id"})
    fut = _pending.pop(cid, None)
    if fut and not fut.done():
        fut.set_result(decision)
        log.info("CALLBACK ok cid=%s action=%s", cid, decision.get("action"))
        return {"status": "ok"}
    log.warning("CALLBACK late/unknown cid=%s", cid)
    return {"status": "unknown_or_late", "correlation_id": cid}

@app.get("/health")
async def health():
    return {"status": "ok", "pending": len(_pending), "cache_entries": len(_cache),
            "hermes": f"{HERMES_URL}/webhooks/{HERMES_ROUTE}",
            "callback_base": CALLBACK_BASE, "timeout": DECIDE_TIMEOUT}

log.info("bridge configurada | hermes=%s/webhooks/%s | callback_base=%s | timeout=%ss | log=%s",
         HERMES_URL, HERMES_ROUTE, CALLBACK_BASE, DECIDE_TIMEOUT, LOG_FILE)
