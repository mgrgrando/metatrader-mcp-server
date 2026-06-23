# Artefatos MT5 — EstrategiaSmc

Fontes dos indicadores/EAs do MetaTrader 5 versionados aqui para histórico de
mudanças. Cópia do que está instalado em `…\MQL5\` do terminal.

| Arquivo | Tipo | Versão | Papel |
|---|---|---|---|
| `Indicators/SMC_Suite.mq5` | Indicador | 0.97 | Motor único de SMC (estrutura, POIs, contexto) + export do estado em JSON (`Common\Files\smc\`), lido pelas SMC tools do MCP e pela skill `smc-autotrader` |
| `Indicators/SMC_Suite.ex5` | Compilado | 0.97 | Binário do indicador; exigido pelo `SMC_Tester` no Strategy Tester |
| `Experts/SMC_Tester.mq5` | EA | 1.02 | Backtest dos sinais do `SMC_Suite` via `IndicatorCreate` (buffers 3..8); o indicador é o motor, o EA só executa/gerencia |

## Instalação
Copiar de volta para o terminal:
- `Indicators/*` → `…\MQL5\Indicators\`
- `Experts/*` → `…\MQL5\Experts\`

Depois recompilar os `.mq5` no MetaEditor (gera o `.ex5`). O `SMC_Tester` usa
`#property tester_indicator "SMC_Suite.ex5"`, então o `.ex5` precisa existir para o
backtest rodar.

> O `.ex5` é binário (sem diff útil); o histórico real está nos `.mq5`.
