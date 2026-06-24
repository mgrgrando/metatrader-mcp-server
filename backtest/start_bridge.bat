@echo off
set HERMES_URL=http://192.168.100.56:8644
set HERMES_ROUTE=backtest
set CALLBACK_BASE_URL=http://192.168.100.55:8000
set HERMES_WEBHOOK_TOKEN=97G2nd05aTy9y4Z1E0Sk_3Jg9yYG9EiBA5HGas-vHsc
set DECIDE_TIMEOUT=300
set LOG_FILE=C:\Projetos\metradermcp\metatrader-mcp-server\logs\bridge.log
set CACHE_FILE=C:\Projetos\metradermcp\metatrader-mcp-server\backtest_cache.json

cd /d C:\Projetos\metradermcp\metatrader-mcp-server\backtest
uvicorn bridge:app --host 0.0.0.0 --port 8000
