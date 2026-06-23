#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=1.2.0", "httpx>=0.27"]
# ///
"""Backtest callback MCP server.

Exposes a single narrow tool — ``submit_decision`` — for the ``smc-backtest``
skill running on the network-exposed ``webhook`` platform. Instead of granting
the webhook agent a full ``terminal`` toolset (a shell on a network surface)
just so it can ``curl`` a decision back to the MT5 backtest bridge, this server
performs the HTTP POST itself, giving the agent exactly one purpose-built tool.

Because the POST is made from this separate process, it is NOT subject to
Hermes' ``url_safety`` SSRF gate (which blocks private/internal addresses like
``192.168.100.55``) — which is what we want for a trusted LAN backtest bridge.

Wire format expected by the bridge (matches skills/trader/smc-backtest):

    POST <callback_url>
    {"correlation_id": "<id>",
     "decision": {"action": "BUY|SELL|HOLD|CLOSE",
                  "volume": 1, "sl": 0, "tp": 0, "close_id": 0,
                  "reason": "..."}}
"""

from __future__ import annotations

import httpx
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("backtest-callback")

# Generous but bounded — the bridge is on the LAN; a hung POST must not stall
# the whole agent turn forever.
_TIMEOUT_S = 10.0


@mcp.tool()
def submit_decision(
    callback_url: str,
    correlation_id: str,
    action: str,
    volume: int = 1,
    sl: float = 0,
    tp: float = 0,
    close_id: int = 0,
    reason: str = "",
) -> dict:
    """Send the backtest trade decision back to the MT5 bridge via HTTP POST.

    Call this exactly once per backtest request, after deciding the single
    action. Read ``callback_url`` and ``correlation_id`` from the incoming
    request context (they are provided in the prompt).

    Args:
        callback_url: The bridge endpoint to POST to (from the request).
        correlation_id: Echoes the request's correlation_id so the bridge can
            match the decision to its pending call.
        action: One of BUY, SELL, HOLD, CLOSE.
        volume: Contract volume (default 1). Used for BUY/SELL.
        sl: Absolute stop-loss price. Fill for BUY/SELL; 0 otherwise.
        tp: Absolute take-profit price. Fill for BUY/SELL; 0 otherwise.
        close_id: Position id to close. Fill for CLOSE; 0 otherwise.
        reason: Short human-readable rationale.

    Returns:
        A dict describing the outcome: ``ok``, the bridge HTTP ``status``, and
        the (truncated) response ``body`` — or ``ok=False`` with ``error``.
    """
    action_norm = (action or "").strip().upper()
    valid = {"BUY", "SELL", "HOLD", "CLOSE"}
    if action_norm not in valid:
        return {
            "ok": False,
            "error": f"invalid action {action!r}; must be one of {sorted(valid)}",
        }
    if not callback_url or not correlation_id:
        return {
            "ok": False,
            "error": "callback_url and correlation_id are both required",
        }

    payload = {
        "correlation_id": correlation_id,
        "decision": {
            "action": action_norm,
            "volume": int(volume),
            "sl": sl,
            "tp": tp,
            "close_id": int(close_id),
            "reason": reason or "",
        },
    }

    try:
        resp = httpx.post(callback_url, json=payload, timeout=_TIMEOUT_S)
    except Exception as exc:  # noqa: BLE001 — surface any transport failure to the agent
        return {
            "ok": False,
            "error": f"POST to {callback_url} failed: {exc!r}",
            "sent": payload,
        }

    return {
        "ok": 200 <= resp.status_code < 300,
        "status": resp.status_code,
        "body": resp.text[:500],
        "sent": payload,
    }


if __name__ == "__main__":
    mcp.run()
