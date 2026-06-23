# Backtest bridge — EA ⇄ Hermes (async→sync)

Ponte que transforma o webhook **assíncrono** do Hermes (responde `202 Accepted`)
numa chamada **síncrona** para o EA do Strategy Tester, com cache e timeout.

## Fluxo

```
EA (tester, DLL rest-mql, SÍNCRONO)
  └─ POST /decide (contexto) ─▶ FastAPI bridge
                                  ├─ cache hit? → devolve na hora
                                  └─ gera correlation_id, monta prompt compacto
                                     ├─ POST /webhooks/smc ─▶ Hermes (202) → skill smc-backtest
                                     │                                         decide → curl
                                     └─ aguarda /callback (timeout) ◀── POST /callback (decisão)
  ◀─ 200 {decisão}  (ou NO_DECISION em timeout)
  executa OU invalida conforme InpOnTimeout do EA
```

## Componentes

| Peça | Onde | Papel |
|---|---|---|
| `bridge.py` | esta pasta | FastAPI: `/decide` (EA), `/callback` (skill), `/health`. Cache + correlação + timeout |
| skill `smc-backtest` | `../claude-skill/smc-backtest/` | decisor puro: contexto→decisão, callback via `curl`. Sem MCP, sem memória |
| rota `smc` | `config.yaml` do Hermes | `prompt: "{prompt_text}"` + `skills: ["smc-backtest"]` |

## Rodar

```bash
pip install fastapi uvicorn httpx
uvicorn bridge:app --host 0.0.0.0 --port 8000
```

Config por env:

| Var | Default | Descrição |
|---|---|---|
| `HERMES_URL` | `http://192.168.100.56:8644` | base do Hermes |
| `HERMES_ROUTE` | `smc` | rota do webhook |
| `CALLBACK_BASE_URL` | `http://192.168.100.56:8000` | onde a ponte escuta (acessível pelo Hermes p/ o callback) |
| `DECIDE_TIMEOUT` | `45` | s; **deve ser menor** que o timeout do EA |
| `HERMES_WEBHOOK_SECRET` | — | se a rota exigir HMAC-SHA256 |
| `CACHE_FILE` | `backtest_cache.json` | cache de decisões (replay) |

## Contratos

**EA → `/decide`:**
```json
{"symbol":"WINQ26","instrument":"WIN","server_time":"2025-03-14T11:35:00","tf_signal":"M5",
 "snapshot":{ /* JSON do SMC_Suite: price, trend, premium_discount, indicators, zones */ },
 "htf_bias":"bearish","account":{...},"position":{"dir":"none","volume":0,"sl":0,"tp":0,"id":0},
 "trigger":"ADX_CROSS"}
```

**`/decide` → EA:**
```json
{"action":"BUY|SELL|HOLD|CLOSE|NO_DECISION","volume":1,"sl":0,"tp":0,"close_id":0,
 "reason":"...","source":"llm|cache|timeout|error","correlation_id":"..."}
```

**skill → `/callback` (via curl):**
```json
{"correlation_id":"...","decision":{"action":"...","volume":1,"sl":0,"tp":0,"close_id":0,"reason":"..."}}
```

## Pendências

- **EA:** montar o `snapshot` rico (hoje o EA só lê buffers 3..8 do indicador). Caminho mais barato: o `SMC_Suite` grava o JSON no tester (`InpExportJSON=true`) e o EA lê do `Common\Files` + anexa `account`/`position`. **A confirmar:** o Strategy Tester grava/lê `Common\Files`.
- **EA:** `InpOnTimeout` = `TRIGGER` (executa pelo sinal mecânico) | `INVALIDATE` (descarta) | `HOLD`.
- **Memória:** OFF no backtest (baseline). Corte temporal fica para uma 2ª fase.
- A assinatura HMAC depende de como a rota `smc` for configurada no Hermes (secret ou aberta na LAN).
