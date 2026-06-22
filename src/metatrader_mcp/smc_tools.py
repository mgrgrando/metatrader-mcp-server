"""
SMC tools para o MetaTrader MCP server (fork).

Le o estado SMC exportado pelo indicador SMC_Suite.mq5 (JSON gravado em
MT5 Common\\Files\\smc\\<SIMBOLO>_<TF>.json) e expoe a uma LLM via MCP.

Registrado em server.py via:  register_smc_tools(mcp)

Pasta do JSON: por padrao usa a pasta Common do MT5
    %APPDATA%\\MetaQuotes\\Terminal\\Common\\Files\\smc
Sobrescreva com a variavel de ambiente SMC_JSON_DIR.
"""

import os
import glob
import json


def _smc_dir() -> str:
    """Pasta onde o indicador grava os JSONs (Common\\Files\\smc por padrao)."""
    override = os.environ.get("SMC_JSON_DIR")
    if override:
        return override
    appdata = os.environ.get("APPDATA", "")
    return os.path.join(appdata, "MetaQuotes", "Terminal", "Common", "Files", "smc")


def _resolve_path(symbol: str, timeframe: str = "") -> str:
    """Acha o arquivo do simbolo/timeframe; se TF vazio e houver 1 unico arquivo do simbolo, usa-o."""
    d = _smc_dir()
    if timeframe:
        p = os.path.join(d, f"{symbol}_{timeframe}.json")
        if os.path.exists(p):
            return p
    matches = sorted(glob.glob(os.path.join(d, f"{symbol}_*.json"))) if symbol else []
    if len(matches) == 1:
        return matches[0]
    raise FileNotFoundError(
        f"Estado SMC nao encontrado para symbol='{symbol}', timeframe='{timeframe}' em {d}. "
        f"Confirme que o indicador SMC_Suite esta no grafico com InpExportJSON=true, "
        f"ou ajuste a variavel de ambiente SMC_JSON_DIR."
    )


def _load(symbol: str, timeframe: str = "") -> dict:
    with open(_resolve_path(symbol, timeframe), "r", encoding="utf-8", errors="ignore") as f:
        return json.load(f)


def register_smc_tools(mcp):
    """Registra as tools de leitura do SMC na instancia FastMCP `mcp`."""

    @mcp.tool()
    def list_smc_states() -> list:
        """Lista os estados SMC disponiveis (formato 'SIMBOLO_TIMEFRAME') exportados pelo indicador."""
        d = _smc_dir()
        if not os.path.isdir(d):
            return []
        return [os.path.basename(f)[:-5] for f in sorted(glob.glob(os.path.join(d, "*.json")))]

    @mcp.tool()
    def get_smc_snapshot(symbol: str, timeframe: str = "") -> dict:
        """
        Estado SMC COMPLETO do simbolo/timeframe: trend (maior/menor/HTF), premium/discount,
        indicadores (ATR/RSI/ADR/EMA/VWAP), niveis (PDH/PDL/PWH/PWL), zonas/POIs, liquidez,
        sinais e summary. Ex.: symbol='WINM26', timeframe='H1'.
        Se timeframe vazio e houver so um arquivo do simbolo, usa esse.
        """
        return _load(symbol, timeframe)

    @mcp.tool()
    def get_smc_bias(symbol: str, timeframe: str = "") -> dict:
        """Resumo de contexto p/ decisao: tendencias, zona premium/discount, indicadores, niveis e summary."""
        s = _load(symbol, timeframe)
        return {
            "symbol": s.get("symbol"),
            "timeframe": s.get("timeframe"),
            "htf": s.get("htf"),
            "ltf": s.get("ltf"),
            "trend": s.get("trend"),
            "premium_discount": s.get("premium_discount"),
            "indicators": s.get("indicators"),
            "levels": s.get("levels"),
            "summary": s.get("summary"),
            "generated_at": s.get("generated_at"),
        }

    @mcp.tool()
    def get_smc_signals(symbol: str, timeframe: str = "", signal_type: str = "") -> list:
        """
        Sinais SMC (BUY/SELL com mode, entry, sl, tp1, tp2, rr).
        signal_type opcional: 'BUY' ou 'SELL' para filtrar.
        """
        sigs = _load(symbol, timeframe).get("signals", [])
        if signal_type:
            sigs = [x for x in sigs if str(x.get("type", "")).upper() == signal_type.upper()]
        return sigs

    @mcp.tool()
    def get_smc_zones(symbol: str, timeframe: str = "", category: str = "", direction: str = "") -> list:
        """
        Zonas/POIs SMC. category opcional: order_block | volumized_ob | fvg | breaker | demand | supply.
        direction opcional: 'bullish' | 'bearish'.
        """
        zones = _load(symbol, timeframe).get("zones", [])
        if category:
            zones = [z for z in zones if z.get("cat") == category]
        if direction:
            zones = [z for z in zones if z.get("dir") == direction]
        return zones

    @mcp.tool()
    def get_smc_liquidity(symbol: str, timeframe: str = "") -> dict:
        """Liquidez (EQH/EQL) e niveis dia/semana (PDH/PDL/PWH/PWL) do simbolo/timeframe."""
        s = _load(symbol, timeframe)
        return {"liquidity": s.get("liquidity", []), "levels": s.get("levels", {})}
