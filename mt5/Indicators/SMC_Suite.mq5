//+------------------------------------------------------------------+
//|                                                    SMC_Suite.mq5  |
//|              EstrategiaSmc - Smart Money Concepts Suite (MT5)     |
//|                                                                  |
//|  FASE 2 - Nucleo de estrutura de mercado                         |
//|   - Swing/pivos configuraveis (forca externa e interna)          |
//|   - Classificacao HH / HL / LH / LL                              |
//|   - BOS / CHoCH (estrutura externa / major)                      |
//|   - mBOS / mCHoCH (estrutura interna / minor)                    |
//|   - Tendencia maior e menor + painel                             |
//|                                                                  |
//|  No-repaint: pivos so sao confirmados apos `forca` barras a       |
//|  direita e rompimentos so sao testados em barras FECHADAS.        |
//|                                                                  |
//|  FASE 3: POIs - Order Blocks (origem da quebra + imbalance,       |
//|  refino/mitigacao 50%) e FVG; apenas zonas nao-mitigadas.        |
//|  + Breaker Blocks, Volumized OB, Supply/Demand e limite de idade.|
//|  Estrutura SMC + contexto + EXPORT JSON. Sinais proprios         |
//|  DESLIGADOS por padrao (gatilho externo: indicador ADX_DI).     |
//+------------------------------------------------------------------+
#property copyright "EstrategiaSmc"
#property version   "0.97"
#property description "SMC Suite - Fase 2: estrutura de mercado (BOS/CHoCH, mBOS/mCHoCH, HH/HL/LH/LL, tendencia)."
#property indicator_chart_window
#property indicator_buffers 9
#property indicator_plots   3
// Buffers 3..8 (INDICATOR_CALCULATIONS, leitura via iCustom/EA):
//   3=SigType (+1 BUY / -1 SELL / 0 nada)   4=SigMode (1=ZONE_CHOCH 2=SWEEP_CHOCH 3=POI_CONF 4=APLUS 5=ADX_CROSS)
//   5=Entry   6=SL   7=TP1   8=TP2   (no indice da barra do sinal)

//=== Enums ==========================================================
enum ENUM_SMC_DIR  { SMC_SIDE=0, SMC_BULL=1, SMC_BEAR=-1 };
enum ENUM_SW_KIND  { SK_NONE=0, SK_HH, SK_HL, SK_LH, SK_LL };
enum ENUM_VOLSRC   { VOL_AUTO=0, VOL_REAL, VOL_TICK };
enum ENUM_SLTP     { SLTP_STRUCT_ATR=0, SLTP_STRUCT, SLTP_ATR };

//=== Inputs =========================================================
//--- PRESETS recomendados de swing (Externo / Interno) por timeframe:
//      M1 / M5   (indices e acoes, ruidoso) ...... 15-20 / 7-10
//      M15 / M30 (intraday) ...................... 10-12 / 5-6
//      H1 / H4 / D1 (swing trade) ................ 6-8   / 3-4
//    Regra pratica: Interno ~ metade do Externo.
//    Maior  = estrutura mais estavel (menos sinais, confirma mais tarde / no-repaint).
//    Menor  = mais sensivel (mais sinais, mais ruido / ping-pong em lateral).
// >>> BLOCO EA/iCustom: os 31 PRIMEIROS inputs sao os que o SMC_Tester
// passa via IndicatorCreate (o MT5 limita a 64 parametros por handle).
// NAO reordenar e NAO inserir nada antes ou no meio deste bloco.
input group "EA / Tester (ordem fixa 1-31 - nao reordenar)"
input int   InpSwingExternal = 10;     // 1  Swing EXTERNO/major (M5:15-20 M15:10-12 H1+:6-8)
input int   InpSwingInternal = 5;      // 2  Swing INTERNO/minor (~metade do externo)
input int   InpBarsToProcess = 1500;   // 3  Barras de historico a processar
input bool      InpSigZoneChoCh = false;           // 4  Sinal: Zona (OB pos-BOS) + toque + CHoCH
input int       InpZoneTapLook  = 20;              // 5  Janela (barras) do toque na zona
input bool      InpSigTrendOnly = true;            // 6  Apenas a favor da tendencia maior
input bool      InpSigSweepChoCH= false;           // 7  Sinal: Sweep de liquidez + CHoCH
input int       InpSweepLook    = 10;              // 8  Janela (barras) do sweep
input ENUM_SLTP InpSLTPMode     = SLTP_STRUCT_ATR; // 9  Modo de SL/TP
input double    InpATRBufferMult = 0.5;            // 10 Buffer de SL em x ATR (estrutural+ATR)
input double    InpATRSLMult     = 1.5;            // 11 SL em x ATR (modo so ATR)
input double    InpTP1R          = 1.5;            // 12 TP1 em multiplos de R
input double    InpTP2R          = 3.0;            // 13 TP2 em multiplos de R
input bool            InpSigPOIConfirm = false;          // 14 Sinal: POI + confirmacao interna
input ENUM_TIMEFRAMES InpHTF           = PERIOD_CURRENT; // 15 TF do POI/vies (HTF)
input int             InpHTFBars       = 500;            // 16 Barras do HTF
input bool            InpSigUseHTFBias = true;           // 17 Vies do HTF em todos os sinais
input ENUM_TIMEFRAMES InpLTF           = PERIOD_CURRENT; // 18 TF do SINAL (curta)
input int             InpLTFBars       = 1000;           // 19 Barras do LTF
input bool            InpSigAPlus      = false;          // 20 Sinal: A+ (OB HTF + MSS + FVG)
input int             InpAPlusMSSLook  = 15;             // 21 A+: janela do MSS
input bool            InpAPlusReqSweep = true;           // 22 A+: exigir sweep antes do OB
input bool  InpSigADX     = true;      // 23 Sinal por cruzamento ADX/DI
input int   InpADXLen     = 14;        // 24 Periodo ADX/DI
input int   InpADXTh      = 20;        // 25 Limiar do ADX
input int   InpATRPeriod  = 14;        // 26 Periodo ATR (SL/risco/painel)
input bool  InpOBRequireImb   = true;  // 27 OB exige imbalance (FVG) no impulso
input int   InpOBLookback     = 20;    // 28 Max velas p/ achar a origem do OB
input int   InpFVGMinPts      = 0;     // 29 Tamanho minimo do FVG em points
input int   InpZoneMaxAgeBars = 300;   // 30 Idade max das zonas em barras (0 = sem)
input bool  InpExportJSON = true;      // 31 Exportar estado SMC em JSON (MCP/LLM)
// <<< fim do bloco EA/iCustom

input group "Estrutura - Exibicao"
input bool  InpShowExternal  = true;   // Mostrar estrutura principal (BOS / CHoCH)
input bool  InpShowInternal  = true;   // Mostrar estrutura interna (mBOS / mCHoCH)
input bool  InpShowSwings    = true;   // Mostrar rotulos HH/HL/LH/LL (externo)

input group "Estrutura - Visual"
input color InpColBosBull    = clrSeaGreen;        // BOS de alta (externo)
input color InpColBosBear    = clrFireBrick;       // BOS de baixa (externo)
input color InpColChochBull  = clrMediumSeaGreen;  // CHoCH de alta (externo)
input color InpColChochBear  = clrIndianRed;       // CHoCH de baixa (externo)
input color InpColInternal   = clrSlateGray;       // Estrutura interna
input color InpColSwing      = clrDimGray;         // Rotulos de swing

input group "Painel"
input bool  InpShowDashboard = true;               // Mostrar painel de tendencia
input color InpColTrendUp    = clrLimeGreen;       // Cor tendencia de ALTA
input color InpColTrendDown  = clrTomato;          // Cor tendencia de BAIXA
input color InpColTrendSide  = clrSilver;          // Cor tendencia LATERAL
input color InpColPanelTitle = clrSilver;          // Cor do titulo / infos do painel
input int   InpPanelFont     = 10;                 // Tamanho da fonte do painel

input group "POIs - Order Blocks"
input bool  InpShowOB         = true;            // Mostrar Order Blocks
input color InpColOBBull      = clrSteelBlue;    // OB de alta (demanda)
input color InpColOBBear      = clrSienna;       // OB de baixa (oferta)

input group "POIs - FVG"
input bool  InpShowFVG        = true;            // Mostrar Fair Value Gaps
input color InpColFVGBull     = clrDarkSeaGreen; // FVG de alta
input color InpColFVGBear     = clrRosyBrown;    // FVG de baixa

input group "POIs - Volumized OB"
input bool        InpHighlightVOB = true;        // Destacar OBs com volume alto (VOB)
input ENUM_VOLSRC InpVolumeSource = VOL_AUTO;    // Fonte de volume (auto = real, senao tick)
input int         InpVolLookback  = 20;          // Media de volume (barras)
input double      InpVOBThreshold = 1.5;         // Multiplo p/ Volumized (vol da vela / media)
input color       InpColVOBBull   = clrDodgerBlue; // VOB de alta (demanda forte)
input color       InpColVOBBear   = clrCrimson;    // VOB de baixa (oferta forte)

input group "POIs - Breaker Blocks"
input bool  InpShowBreaker    = true;            // Mostrar Breaker Blocks (OB violado que inverte)
input color InpColBreakerBull = clrMediumBlue;   // Breaker de alta (suporte)
input color InpColBreakerBear = clrDarkViolet;   // Breaker de baixa (resistencia)

input group "POIs - Supply/Demand"
input bool   InpShowSD        = false;           // Mostrar zonas Supply/Demand (base + impulso)
input double InpSDImpulseMult = 1.8;             // Forca do impulso (range / media) p/ validar
input int    InpSDLookback    = 10;              // Media de range p/ medir o impulso
input color  InpColSDBull     = clrSeaGreen;     // Demanda (S&D)
input color  InpColSDBear     = clrSaddleBrown;  // Oferta (S&D)

input group "POIs - Geral"
input bool  InpUnmitigatedOnly = true;           // Mostrar apenas zonas nao-mitigadas
input bool  InpShowMidLine     = true;           // Mostrar linha de 50% (equilibrium) das zonas
input color InpColMidLine      = clrGoldenrod;   // Cor da linha de 50% (equilibrium)
input bool  InpZoneFill        = true;           // Preencher zonas (false = apenas contorno)

input group "Premium / Discount + Fib"
input bool  InpShowPremDisc = true;          // Mostrar Premium/Discount + Fibonacci
input bool  InpFillPremDisc = false;         // Sombrear as metades premium/discount
input bool  InpShowOTE      = true;          // Mostrar nivel OTE (0.705)
input color InpColPremium   = clrIndianRed;  // Premium (caro / venda)
input color InpColDiscount  = clrSeaGreen;   // Discount (barato / compra)
input color InpColEq        = clrGoldenrod;  // Equilibrium (50%)
input color InpColFibLine   = clrGray;       // Linha OTE / fib auxiliar

input group "Niveis dia / semana"
input bool  InpShowPDHL = true;              // Mostrar PDH/PDL (dia anterior)
input bool  InpShowPWHL = true;              // Mostrar PWH/PWL (semana anterior)
input color InpColPDHL  = clrDarkGray;       // Cor PDH/PDL
input color InpColPWHL  = clrSlateGray;      // Cor PWH/PWL

input group "Liquidez EQH / EQL"
input bool   InpShowEQ       = true;          // Mostrar Equal Highs/Lows (liquidez)
input int    InpEQSwing      = 3;             // Forca do swing p/ EQ (menor = mais EQ)
input int    InpEQDepth      = 5;             // Comparar com os ultimos N pivos
input double InpEQTolFactor  = 0.15;          // Tolerancia de igualdade (x range medio)
input bool   InpHideSweptLiq = true;          // Esconder liquidez ja varrida
input color  InpColEQH       = clrOrangeRed;  // EQH (buy-side liquidity)
input color  InpColEQL       = clrDeepSkyBlue;// EQL (sell-side liquidity)

input group "Indicadores auxiliares"
input bool   InpShowEMA    = true;          // Mostrar EMAs (50/200)
input int    InpEMA1       = 50;            // EMA rapida
input int    InpEMA2       = 200;           // EMA lenta
input color  InpColEMA1    = clrDeepPink;   // Cor EMA rapida
input color  InpColEMA2    = clrGold;       // Cor EMA lenta
input bool   InpShowVWAP   = true;          // Mostrar VWAP (ancorada no dia, intraday)
input color  InpColVWAP    = clrAqua;       // Cor VWAP
input int    InpRSIPeriod  = 14;            // Periodo RSI (painel)
input int    InpWPRPeriod  = 14;            // Periodo Williams %R (exportado no JSON)
input int    InpADRPeriod  = 14;            // Periodo ADR (range diario medio)

input group "Sessoes (intraday)"
input bool  InpShowSessions = true;          // Mostrar sessoes (so intraday)
input bool  InpSessTokyo    = true;          // Sessao Toquio
input int   InpTokyoStart   = 0;             // Toquio inicio (hora do servidor)
input int   InpTokyoEnd     = 9;             // Toquio fim
input color InpColTokyo     = C'40,40,80';   // Cor Toquio
input bool  InpSessLondon   = true;          // Sessao Londres
input int   InpLondonStart  = 8;             // Londres inicio
input int   InpLondonEnd    = 17;            // Londres fim
input color InpColLondon    = C'25,55,35';   // Cor Londres
input bool  InpSessNY       = true;          // Sessao Nova York
input int   InpNYStart      = 13;            // NY inicio
input int   InpNYEnd        = 22;            // NY fim
input color InpColNY        = C'80,50,30';   // Cor NY

input group "Sinais - Visual"
input bool      InpShowSLTP      = false;          // Desenhar linhas de SL/TP do ultimo sinal
input color     InpColBuy        = clrLime;        // Cor sinal de compra
input color     InpColSell       = clrRed;         // Cor BUY/SELL Continuacao (venda)
input color     InpColBuy2       = clrDodgerBlue;  // Cor BUY Sweep+CHoCH
input color     InpColSell2      = clrOrange;      // Cor SELL Sweep+CHoCH
input bool      InpDrawHTFPoi    = true;           // Desenhar os POIs do HTF no grafico
input color     InpColBuy3       = clrMagenta;          // Cor BUY POI+confirmacao
input color     InpColSell3      = clrMediumVioletRed;  // Cor SELL POI+confirmacao
input color     InpColHTFPoi     = clrSlateBlue;        // Cor das zonas POI do HTF
input color     InpColAPlusBuy   = clrChartreuse;       // Cor BUY A+
input color     InpColAPlusSell  = clrCrimson;          // Cor SELL A+
input bool      InpDrawHTFOB     = true;                // Desenhar os Order Blocks do HTF (A+)
input color     InpColHTFOB      = clrChocolate;        // Cor dos OB do HTF (A+)

//=== Constantes =====================================================
#define PFX "SMCS_"   // prefixo dos objetos no grafico

//=== Estado por escala de estrutura =================================
struct StructScale
  {
   double   lastHigh;   datetime lastHighTime;   bool lastHighCrossed;
   double   lastLow;    datetime lastLowTime;    bool lastLowCrossed;
   double   prevHigh;   // swing high anterior (para HH/LH)
   double   prevLow;    // swing low anterior  (para HL/LL)
   int      trend;      // ENUM_SMC_DIR
  };

struct Signal
  {
   datetime time;
   int      type;     // +1 compra / -1 venda
   string   mode;     // FVG_CONT, etc.
   double   entry,sl,tp1,tp2,rr;
  };

StructScale g_ext, g_int;
Signal      g_sigs[];
int         g_trendBar[];
double      g_eqBar[];
int         g_intChochBar[];
int         g_htfTrendBar[];
int         g_htfNow=SMC_SIDE;
double      g_poiTop[],g_poiBot[];
int         g_poiDir[];
datetime    g_poiT1[],g_poiFill[];
double      g_aobTop[],g_aobBot[];
int         g_aobDir[];
datetime    g_aobT1[],g_aobFill[];
int         g_aobSwept[];
double      g_znTop[],g_znBot[];
int         g_znDir[];
string      g_znCat[];
datetime    g_znT1[];
double      g_lqPrice[];
string      g_lqType[];
datetime    g_lqT1[];
string      g_lastSig="-";
double      g_adxDIp[],g_adxDIm[],g_adxADX[];
datetime    g_lastBarTime = 0;
long        g_tickv[];
long        g_realv[];
string      g_pdState="-";
int         g_hEMA1=INVALID_HANDLE,g_hEMA2=INVALID_HANDLE,g_hRSI=INVALID_HANDLE;
double      bufEMA50[],bufEMA200[],bufVWAP[];
double      bufSigType[],bufSigMode[],bufSigEntry[],bufSigSL[],bufSigTP1[],bufSigTP2[];
double      g_atr=0,g_rsi=0,g_adr=0,g_adrRem=0;
int         g_hWPR=INVALID_HANDLE;
double      g_wpr=0.0,g_wprPrev=0.0;
string      g_emaBias="-",g_vwapBias="-";

//+------------------------------------------------------------------+
//| Init / Deinit                                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   IndicatorSetString(INDICATOR_SHORTNAME,"SMC Suite");
   Print("SMC_Suite v0.97 carregado (bloco EA = 31 primeiros inputs, buffers de sinal 3..8).");
   g_lastBarTime=0;

   SetIndexBuffer(0,bufEMA50 ,INDICATOR_DATA);
   SetIndexBuffer(1,bufEMA200,INDICATOR_DATA);
   SetIndexBuffer(2,bufVWAP  ,INDICATOR_DATA);
   SetIndexBuffer(3,bufSigType ,INDICATOR_CALCULATIONS);
   SetIndexBuffer(4,bufSigMode ,INDICATOR_CALCULATIONS);
   SetIndexBuffer(5,bufSigEntry,INDICATOR_CALCULATIONS);
   SetIndexBuffer(6,bufSigSL   ,INDICATOR_CALCULATIONS);
   SetIndexBuffer(7,bufSigTP1  ,INDICATOR_CALCULATIONS);
   SetIndexBuffer(8,bufSigTP2  ,INDICATOR_CALCULATIONS);
   PlotIndexSetString (0,PLOT_LABEL,"EMA"+(string)InpEMA1);
   PlotIndexSetString (1,PLOT_LABEL,"EMA"+(string)InpEMA2);
   PlotIndexSetString (2,PLOT_LABEL,"VWAP");
   PlotIndexSetInteger(0,PLOT_DRAW_TYPE,InpShowEMA ?DRAW_LINE:DRAW_NONE);
   PlotIndexSetInteger(1,PLOT_DRAW_TYPE,InpShowEMA ?DRAW_LINE:DRAW_NONE);
   PlotIndexSetInteger(2,PLOT_DRAW_TYPE,InpShowVWAP?DRAW_LINE:DRAW_NONE);
   PlotIndexSetInteger(0,PLOT_LINE_COLOR,InpColEMA1);
   PlotIndexSetInteger(1,PLOT_LINE_COLOR,InpColEMA2);
   PlotIndexSetInteger(2,PLOT_LINE_COLOR,InpColVWAP);
   PlotIndexSetInteger(0,PLOT_DRAW_BEGIN,InpEMA1);
   PlotIndexSetInteger(1,PLOT_DRAW_BEGIN,InpEMA2);
   PlotIndexSetDouble (2,PLOT_EMPTY_VALUE,EMPTY_VALUE);

   g_hEMA1=iMA(_Symbol,_Period,InpEMA1,0,MODE_EMA,PRICE_CLOSE);
   g_hEMA2=iMA(_Symbol,_Period,InpEMA2,0,MODE_EMA,PRICE_CLOSE);
   // ATR calculado manualmente via AtrSeries() (evita "cannot load indicator
   // 'Average True Range' [4002]" no tester quando o iATR e criado dentro de
   // indicador carregado via IndicatorCreate/iCustom).
   g_hRSI =iRSI(_Symbol,_Period,InpRSIPeriod,PRICE_CLOSE);
   g_hWPR =iWPR(_Symbol,_Period,InpWPRPeriod);

   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0,PFX);
   Comment("");
   if(g_hEMA1!=INVALID_HANDLE) IndicatorRelease(g_hEMA1);
   if(g_hEMA2!=INVALID_HANDLE) IndicatorRelease(g_hEMA2);
   if(g_hRSI !=INVALID_HANDLE) IndicatorRelease(g_hRSI);
   if(g_hWPR !=INVALID_HANDLE) IndicatorRelease(g_hWPR);
  }

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
void ResetScale(StructScale &s)
  {
   s.lastHigh=0.0; s.lastHighTime=0; s.lastHighCrossed=true;
   s.lastLow =0.0; s.lastLowTime =0; s.lastLowCrossed =true;
   s.prevHigh=0.0; s.prevLow=0.0;    s.trend=SMC_SIDE;
  }

bool IsPivotHigh(const double &h[],int i,int strength,int total)
  {
   if(i-strength<0 || i+strength>total-1) return(false);
   double v=h[i];
   for(int k=1;k<=strength;k++)
      if(h[i-k]>=v || h[i+k]>=v) return(false);
   return(true);
  }

bool IsPivotLow(const double &l[],int i,int strength,int total)
  {
   if(i-strength<0 || i+strength>total-1) return(false);
   double v=l[i];
   for(int k=1;k<=strength;k++)
      if(l[i-k]<=v || l[i+k]<=v) return(false);
   return(true);
  }

string DirTxt(int d) { return (d==SMC_BULL ? "ALTA" : d==SMC_BEAR ? "BAIXA" : "LATERAL"); }

//+------------------------------------------------------------------+
//| Desenho                                                          |
//+------------------------------------------------------------------+
void DrawBreak(const string id,datetime t1,datetime t2,double price,
               color col,int width,int style,const string txt)
  {
   string ln=PFX+"L_"+id;
   if(ObjectFind(0,ln)<0) ObjectCreate(0,ln,OBJ_TREND,0,t1,price,t2,price);
   ObjectSetInteger(0,ln,OBJPROP_TIME,0,t1);
   ObjectSetDouble (0,ln,OBJPROP_PRICE,0,price);
   ObjectSetInteger(0,ln,OBJPROP_TIME,1,t2);
   ObjectSetDouble (0,ln,OBJPROP_PRICE,1,price);
   ObjectSetInteger(0,ln,OBJPROP_COLOR,col);
   ObjectSetInteger(0,ln,OBJPROP_WIDTH,width);
   ObjectSetInteger(0,ln,OBJPROP_STYLE,style);
   ObjectSetInteger(0,ln,OBJPROP_RAY_RIGHT,false);
   ObjectSetInteger(0,ln,OBJPROP_BACK,true);
   ObjectSetInteger(0,ln,OBJPROP_SELECTABLE,false);

   string lb=PFX+"T_"+id;
   if(ObjectFind(0,lb)<0) ObjectCreate(0,lb,OBJ_TEXT,0,t2,price);
   ObjectSetInteger(0,lb,OBJPROP_TIME,0,t2);
   ObjectSetDouble (0,lb,OBJPROP_PRICE,0,price);
   ObjectSetString (0,lb,OBJPROP_TEXT," "+txt);
   ObjectSetInteger(0,lb,OBJPROP_COLOR,col);
   ObjectSetInteger(0,lb,OBJPROP_FONTSIZE,8);
   ObjectSetInteger(0,lb,OBJPROP_ANCHOR,ANCHOR_LEFT);
   ObjectSetInteger(0,lb,OBJPROP_SELECTABLE,false);
  }

void DrawSwingLabel(const string id,datetime t,double price,int kind,bool isHigh)
  {
   string txt = (kind==SK_HH?"HH":kind==SK_HL?"HL":kind==SK_LH?"LH":kind==SK_LL?"LL":"");
   if(txt=="") return;
   string nm=PFX+"SW_"+id;
   if(ObjectFind(0,nm)<0) ObjectCreate(0,nm,OBJ_TEXT,0,t,price);
   ObjectSetInteger(0,nm,OBJPROP_TIME,0,t);
   ObjectSetDouble (0,nm,OBJPROP_PRICE,0,price);
   ObjectSetString (0,nm,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,nm,OBJPROP_COLOR,InpColSwing);
   ObjectSetInteger(0,nm,OBJPROP_FONTSIZE,7);
   ObjectSetInteger(0,nm,OBJPROP_ANCHOR, isHigh?ANCHOR_LOWER:ANCHOR_UPPER);
   ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
  }

void DrawEvent(bool internalScale,bool bull,int type,datetime t1,datetime t2,double price)
  {
   // type: 0 = BOS, 1 = CHoCH
   string txt; color col; int width; int style;
   if(internalScale)
     {
      txt   = (type==0 ? "mBOS" : "mCHoCH");
      col   = InpColInternal;
      width = 1;
      style = STYLE_DOT;
     }
   else
     {
      if(bull) col = (type==0 ? InpColBosBull : InpColChochBull);
      else     col = (type==0 ? InpColBosBear : InpColChochBear);
      txt   = (type==0 ? "BOS" : "CHoCH");
      width = 2;
      style = STYLE_SOLID;
     }
   string id=(internalScale?"i":"e")+(string)(long)t2+(bull?"U":"D");
   DrawBreak(id,t1,t2,price,col,width,style,txt);
  }

//+------------------------------------------------------------------+
//| Processa uma escala de estrutura (externa ou interna)            |
//+------------------------------------------------------------------+
void ProcessScale(StructScale &s,int strength,bool internalScale,
                  const datetime &time[],const double &open[],const double &high[],
                  const double &low[],const double &close[],int total)
  {
   if(strength<1) strength=1;
   bool draw=(internalScale ? InpShowInternal : InpShowExternal);   // estrutura (principal/interna) pode ser ocultada
   int startBar=(int)MathMax(strength*2, total-InpBarsToProcess);

   // varre apenas barras FECHADAS (ate total-2; total-1 e a barra em formacao)
   for(int j=startBar;j<total-1;j++)
     {
      int c=j-strength;   // centro do pivo potencialmente confirmado nesta barra

      // --- deteccao de pivos (confirmados, sem repaint) ---
      if(c>=strength && c<=total-1-strength)
        {
         if(IsPivotHigh(high,c,strength,total))
           {
            int kind=SK_NONE;
            if(s.prevHigh>0.0) kind=(high[c]>s.prevHigh)?SK_HH:SK_LH;
            s.prevHigh=high[c];
            s.lastHigh=high[c]; s.lastHighTime=time[c]; s.lastHighCrossed=false;
            if(!internalScale && InpShowSwings)
               DrawSwingLabel((string)(long)time[c]+"H",time[c],high[c],kind,true);
           }
         if(IsPivotLow(low,c,strength,total))
           {
            int kind=SK_NONE;
            if(s.prevLow>0.0) kind=(low[c]>s.prevLow)?SK_HL:SK_LL;
            s.prevLow=low[c];
            s.lastLow=low[c]; s.lastLowTime=time[c]; s.lastLowCrossed=false;
            if(!internalScale && InpShowSwings)
               DrawSwingLabel((string)(long)time[c]+"L",time[c],low[c],kind,false);
           }
        }

      // --- rompimentos (BOS / CHoCH) usando o fechamento da barra j ---
      if(!s.lastHighCrossed && s.lastHigh>0.0 && close[j]>s.lastHigh)
        {
         // CHoCH so ao reverter uma tendencia de BAIXA estabelecida; lateral/continuacao = BOS
         int type=(s.trend==SMC_BEAR)?1:0;   // 0=BOS , 1=CHoCH
         s.trend=SMC_BULL; s.lastHighCrossed=true;
         if(internalScale && type==1) g_intChochBar[j]=1;
         if(draw) DrawEvent(internalScale,true,type,s.lastHighTime,time[j],s.lastHigh);
         if(!internalScale) DetectOB(true,j,time,open,high,low,close,total);
        }
      if(!s.lastLowCrossed && s.lastLow>0.0 && close[j]<s.lastLow)
        {
         // CHoCH so ao reverter uma tendencia de ALTA estabelecida; lateral/continuacao = BOS
         int type=(s.trend==SMC_BULL)?1:0;   // 0=BOS , 1=CHoCH
         s.trend=SMC_BEAR; s.lastLowCrossed=true;
         if(internalScale && type==1) g_intChochBar[j]=-1;
         if(draw) DrawEvent(internalScale,false,type,s.lastLowTime,time[j],s.lastLow);
         if(!internalScale) DetectOB(false,j,time,open,high,low,close,total);
        }
      if(!internalScale)
        {
         g_trendBar[j]=s.trend;
         g_eqBar[j]=(s.lastHigh>0.0 && s.lastLow>0.0 && s.lastHigh>s.lastLow)?(s.lastHigh+s.lastLow)*0.5:0.0;
        }
     }
   if(!internalScale && total>0)
     {
      g_trendBar[total-1]=s.trend;
      g_eqBar[total-1]=(s.lastHigh>0.0 && s.lastLow>0.0 && s.lastHigh>s.lastLow)?(s.lastHigh+s.lastLow)*0.5:0.0;
     }
  }

//+------------------------------------------------------------------+
//| Painel                                                           |
//+------------------------------------------------------------------+
color DirColor(int d) { return (d==SMC_BULL ? InpColTrendUp : d==SMC_BEAR ? InpColTrendDown : InpColTrendSide); }

void PanelLabel(int idx,int y,const string txt,color col)
  {
   string nm=PFX+"PANEL_"+(string)idx;
   if(ObjectFind(0,nm)<0) ObjectCreate(0,nm,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,nm,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,nm,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0,nm,OBJPROP_XDISTANCE,12);
   ObjectSetInteger(0,nm,OBJPROP_YDISTANCE,y);
   ObjectSetString (0,nm,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,nm,OBJPROP_COLOR,col);
   ObjectSetInteger(0,nm,OBJPROP_FONTSIZE,InpPanelFont);
   ObjectSetString (0,nm,OBJPROP_FONT,"Arial");
   ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
  }

void UpdateDashboard()
  {
   int y=22;
   PanelLabel(0,y,"SMC Suite  -  Estrutura",InpColPanelTitle);                            y+=20;
   PanelLabel(1,y,"Tendencia maior ("+TfName((ENUM_TIMEFRAMES)_Period)+"): "+DirTxt(g_ext.trend),DirColor(g_ext.trend));         y+=18;
   if(InpShowInternal)
     { PanelLabel(2,y,"Tendencia menor ("+TfName((ENUM_TIMEFRAMES)_Period)+"): "+DirTxt(g_int.trend),DirColor(g_int.trend));     y+=18; }
   if(InpSigUseHTFBias && InpHTF!=PERIOD_CURRENT && PeriodSeconds(InpHTF)>PeriodSeconds(_Period))
     { PanelLabel(9,y,"Vies HTF ("+TfName(InpHTF)+"): "+DirTxt(g_htfNow),DirColor(g_htfNow)); y+=18; }
   if(InpShowPremDisc)
     { PanelLabel(4,y,"Zona atual: "+g_pdState,InpColPanelTitle);                          y+=18; }
   PanelLabel(5,y,"ATR: "+DoubleToString(g_atr,_Digits)+"   RSI: "+DoubleToString(g_rsi,1),InpColPanelTitle);          y+=18;
   PanelLabel(6,y,"ADR: "+DoubleToString(g_adr,_Digits)+"  (resta "+DoubleToString(g_adrRem,_Digits)+")",InpColPanelTitle); y+=18;
   PanelLabel(7,y,"EMA"+(string)InpEMA2+": "+g_emaBias+"   VWAP: "+g_vwapBias,InpColPanelTitle);                        y+=18;
   PanelLabel(8,y,"Sinal: "+g_lastSig,InpColPanelTitle);                                                               y+=18;
   PanelLabel(3,y,"Swing ext/int: "+(string)InpSwingExternal+" / "+(string)InpSwingInternal,InpColPanelTitle);
  }

//+------------------------------------------------------------------+
//| POIs - Fase 3 (Order Blocks + FVG)                               |
//+------------------------------------------------------------------+
double VolAt(int i)
  {
   if(i<0 || i>=ArraySize(g_tickv)) return(0.0);
   if(InpVolumeSource==VOL_TICK) return((double)g_tickv[i]);
   if(InpVolumeSource==VOL_REAL) return((double)g_realv[i]);
   return(g_realv[i]>0 ? (double)g_realv[i] : (double)g_tickv[i]); // auto
  }

bool ZoneTooOld(int createdBar,int total)
  {
   return(InpZoneMaxAgeBars>0 && (total-1-createdBar)>InpZoneMaxAgeBars);
  }

void ZoneTag(const string id,datetime t,double price,const string txt,color col)
  {
   string nm=PFX+"TAG_"+id;
   if(ObjectFind(0,nm)<0) ObjectCreate(0,nm,OBJ_TEXT,0,t,price);
   ObjectSetInteger(0,nm,OBJPROP_TIME,0,t);
   ObjectSetDouble (0,nm,OBJPROP_PRICE,0,price);
   ObjectSetString (0,nm,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,nm,OBJPROP_COLOR,col);
   ObjectSetInteger(0,nm,OBJPROP_FONTSIZE,8);
   ObjectSetInteger(0,nm,OBJPROP_ANCHOR,ANCHOR_RIGHT);
   ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
  }

void DrawZone(const string id,datetime t1,datetime t2,double top,double bottom,color col)
  {
   string nm=PFX+"Z_"+id;
   if(ObjectFind(0,nm)<0) ObjectCreate(0,nm,OBJ_RECTANGLE,0,t1,top,t2,bottom);
   ObjectSetInteger(0,nm,OBJPROP_TIME,0,t1);
   ObjectSetDouble (0,nm,OBJPROP_PRICE,0,top);
   ObjectSetInteger(0,nm,OBJPROP_TIME,1,t2);
   ObjectSetDouble (0,nm,OBJPROP_PRICE,1,bottom);
   ObjectSetInteger(0,nm,OBJPROP_COLOR,col);
   ObjectSetInteger(0,nm,OBJPROP_FILL,InpZoneFill);
   ObjectSetInteger(0,nm,OBJPROP_BACK,true);
   ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);

   if(InpShowMidLine)
     {
      double mid=(top+bottom)/2.0;
      string ml=PFX+"M_"+id;
      if(ObjectFind(0,ml)<0) ObjectCreate(0,ml,OBJ_TREND,0,t1,mid,t2,mid);
      ObjectSetInteger(0,ml,OBJPROP_TIME,0,t1);
      ObjectSetDouble (0,ml,OBJPROP_PRICE,0,mid);
      ObjectSetInteger(0,ml,OBJPROP_TIME,1,t2);
      ObjectSetDouble (0,ml,OBJPROP_PRICE,1,mid);
      ObjectSetInteger(0,ml,OBJPROP_COLOR,InpColMidLine);
      ObjectSetInteger(0,ml,OBJPROP_STYLE,STYLE_DOT);
      ObjectSetInteger(0,ml,OBJPROP_RAY_RIGHT,false);
      ObjectSetInteger(0,ml,OBJPROP_BACK,true);
      ObjectSetInteger(0,ml,OBJPROP_SELECTABLE,false);
     }
  }

//--- Order Block a partir de uma quebra de estrutura (caminho inverso)
void DetectOB(bool bull,int breakBar,const datetime &time[],const double &open[],
              const double &high[],const double &low[],const double &close[],int total)
  {
   if(!InpShowOB && !InpShowBreaker) return;
   int lim=MathMax(2,breakBar-InpOBLookback);
   int ob=-1;
   // origem = ultima vela oposta antes do impulso que rompeu a estrutura
   for(int k=breakBar-1;k>=lim;k--)
     {
      if(bull && close[k]<open[k]) { ob=k; break; }
      if(!bull && close[k]>open[k]){ ob=k; break; }
     }
   if(ob<2) return;
   if(ZoneTooOld(ob,total)) return;

   // imbalance (FVG) dentro do impulso (ob .. breakBar)
   bool imb=false;
   for(int m=ob+2;m<=breakBar && m<total;m++)
     {
      if(bull && low[m]>high[m-2])  { imb=true; break; }
      if(!bull && high[m]<low[m-2]) { imb=true; break; }
     }
   if(InpOBRequireImb && !imb) return;

   double top=high[ob], bottom=low[ob], mid=(top+bottom)/2.0;
   string base=(bull?"OBb":"OBs")+(string)(long)time[ob];

   // violacao total da zona -> vira Breaker (inverte o papel)
   int viol=-1;
   for(int k=breakBar+1;k<total;k++)
     {
      if(bull && close[k]<bottom){ viol=k; break; }
      if(!bull && close[k]>top)  { viol=k; break; }
     }

   if(viol>=0)
     {
      if(!InpShowBreaker) return;
      bool brkBull=!bull;   // demanda falha -> resistencia(bear) ; oferta falha -> suporte(bull)
      bool bmit=false; datetime bt=0;
      for(int k=viol+1;k<total;k++)
        {
         if(brkBull && low[k]<=mid)  { bmit=true; bt=time[k]; break; }
         if(!brkBull && high[k]>=mid){ bmit=true; bt=time[k]; break; }
        }
      if(InpUnmitigatedOnly && bmit) return;
      color bcol=(brkBull?InpColBreakerBull:InpColBreakerBear);
      datetime bt2=(bmit?bt:time[total-1]);
      DrawZone("BB"+base, time[ob], bt2, top, bottom, bcol);
      RegZone(top,bottom,(brkBull?1:-1),"breaker",time[ob]);
      ZoneTag("BB"+base, time[ob], top, "BB ", bcol);
      return;
     }

   if(!InpShowOB) return;

   // OB normal (nao violado): mitigacao pela regra dos 50%
   bool mit=false; datetime tmit=0;
   for(int k=breakBar+1;k<total;k++)
     {
      if(bull && low[k]<=mid)  { mit=true; tmit=time[k]; break; }
      if(!bull && high[k]>=mid){ mit=true; tmit=time[k]; break; }
     }
   if(InpUnmitigatedOnly && mit) return;

   // Volumized OB? volume da vela de origem vs media
   double sum=0; int cnt=0;
   for(int b=ob-1;b>=MathMax(0,ob-InpVolLookback);b--){ sum+=VolAt(b); cnt++; }
   double avg=(cnt>0?sum/cnt:0.0);
   double vrel=(avg>0?VolAt(ob)/avg:0.0);
   bool isVOB=(InpHighlightVOB && vrel>=InpVOBThreshold);

   color col = isVOB ? (bull?InpColVOBBull:InpColVOBBear)
                     : (bull?InpColOBBull :InpColOBBear);
   datetime t2=(mit?tmit:time[total-1]);
   DrawZone(base, time[ob], t2, top, bottom, col);
   RegZone(top,bottom,(bull?1:-1),(isVOB?"volumized_ob":"order_block"),time[ob]);
   if(isVOB) ZoneTag(base, time[ob], top, "VOB ", col);
  }

//--- Varre e desenha Fair Value Gaps (imbalance de 3 velas)
void ScanFVG(const datetime &time[],const double &open[],const double &high[],
             const double &low[],const double &close[],int total)
  {
   if(!InpShowFVG) return;
   int startBar=(int)MathMax(2,total-InpBarsToProcess);
   double minsz=InpFVGMinPts*_Point;
   for(int i=startBar;i<total-1;i++)   // i = 3a vela; apenas barras fechadas
     {
      if(ZoneTooOld(i,total)) continue;
      // FVG de alta: gap entre maxima de [i-2] e minima de [i]
      if(low[i]>high[i-2] && (low[i]-high[i-2])>=minsz)
        {
         double top=low[i], bottom=high[i-2], mid=(top+bottom)/2.0;
         bool mit=false; datetime tmit=0; int kmit=-1;
         for(int k=i+1;k<total;k++) if(low[k]<=mid){ mit=true; tmit=time[k]; kmit=k; break; }
         if(!(InpUnmitigatedOnly && mit))
           {
            DrawZone("FVGb"+(string)(long)time[i-1], time[i-2], (mit?tmit:time[total-1]), top, bottom, InpColFVGBull);
            RegZone(top,bottom,1,"fvg",time[i-2]);
           }
         // FVG desenhado aqui; os sinais sao gerados em RunSignals (multi-TF)
        }
      // FVG de baixa
      if(high[i]<low[i-2] && (low[i-2]-high[i])>=minsz)
        {
         double top=low[i-2], bottom=high[i], mid=(top+bottom)/2.0;
         bool mit=false; datetime tmit=0; int kmit=-1;
         for(int k=i+1;k<total;k++) if(high[k]>=mid){ mit=true; tmit=time[k]; kmit=k; break; }
         if(!(InpUnmitigatedOnly && mit))
           {
            DrawZone("FVGs"+(string)(long)time[i-1], time[i-2], (mit?tmit:time[total-1]), top, bottom, InpColFVGBear);
            RegZone(top,bottom,-1,"fvg",time[i-2]);
           }
         // FVG desenhado aqui; os sinais sao gerados em RunSignals (multi-TF)
        }
     }
  }

//--- Supply/Demand: base (vela anterior) + impulso forte (range >= mult x media)
void ScanSD(const datetime &time[],const double &open[],const double &high[],
            const double &low[],const double &close[],int total)
  {
   if(!InpShowSD) return;
   int startBar=(int)MathMax(InpSDLookback+1,total-InpBarsToProcess);
   for(int i=startBar;i<total-1;i++)
     {
      double rng=high[i]-low[i];
      if(rng<=0.0) continue;
      double sum=0; for(int b=i-InpSDLookback;b<i;b++) sum+=(high[b]-low[b]);
      double avg=sum/InpSDLookback;
      if(avg<=0.0 || rng<InpSDImpulseMult*avg) continue;   // nao e impulso forte
      int basei=i-1;
      if(basei<1 || ZoneTooOld(basei,total)) continue;
      bool up=(close[i]>open[i]);
      double top=high[basei], bottom=low[basei], mid=(top+bottom)/2.0;
      bool mit=false; datetime tmit=0;
      for(int k=i+1;k<total;k++)
        {
         if(up && low[k]<=mid)  { mit=true; tmit=time[k]; break; }
         if(!up && high[k]>=mid){ mit=true; tmit=time[k]; break; }
        }
      if(InpUnmitigatedOnly && mit) continue;
      color col=(up?InpColSDBull:InpColSDBear);
      DrawZone((up?"SDb":"SDs")+(string)(long)time[basei], time[basei], (mit?tmit:time[total-1]), top, bottom, col);
      RegZone(top,bottom,(up?1:-1),(up?"demand":"supply"),time[basei]);
     }
  }

//+------------------------------------------------------------------+
//| FASE 4 - Contexto: Premium/Discount, Fib e niveis dia/semana     |
//+------------------------------------------------------------------+
void DrawSeg(const string id,datetime t1,datetime t2,double price,color col,int style,int width)
  {
   string nm=PFX+"S_"+id;
   if(ObjectFind(0,nm)<0) ObjectCreate(0,nm,OBJ_TREND,0,t1,price,t2,price);
   ObjectSetInteger(0,nm,OBJPROP_TIME,0,t1);
   ObjectSetDouble (0,nm,OBJPROP_PRICE,0,price);
   ObjectSetInteger(0,nm,OBJPROP_TIME,1,t2);
   ObjectSetDouble (0,nm,OBJPROP_PRICE,1,price);
   ObjectSetInteger(0,nm,OBJPROP_COLOR,col);
   ObjectSetInteger(0,nm,OBJPROP_STYLE,style);
   ObjectSetInteger(0,nm,OBJPROP_WIDTH,width);
   ObjectSetInteger(0,nm,OBJPROP_RAY_RIGHT,false);
   ObjectSetInteger(0,nm,OBJPROP_BACK,true);
   ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
  }

void LevelTag(const string id,datetime t,double price,const string txt,color col)
  {
   string nm=PFX+"LT_"+id;
   if(ObjectFind(0,nm)<0) ObjectCreate(0,nm,OBJ_TEXT,0,t,price);
   ObjectSetInteger(0,nm,OBJPROP_TIME,0,t);
   ObjectSetDouble (0,nm,OBJPROP_PRICE,0,price);
   ObjectSetString (0,nm,OBJPROP_TEXT," "+txt);
   ObjectSetInteger(0,nm,OBJPROP_COLOR,col);
   ObjectSetInteger(0,nm,OBJPROP_FONTSIZE,8);
   ObjectSetInteger(0,nm,OBJPROP_ANCHOR,ANCHOR_LEFT);
   ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
  }

void DrawHLine(const string id,double price,color col,int style)
  {
   string nm=PFX+"HL_"+id;
   if(ObjectFind(0,nm)<0) ObjectCreate(0,nm,OBJ_HLINE,0,0,price);
   ObjectSetDouble (0,nm,OBJPROP_PRICE,0,price);
   ObjectSetInteger(0,nm,OBJPROP_COLOR,col);
   ObjectSetInteger(0,nm,OBJPROP_STYLE,style);
   ObjectSetInteger(0,nm,OBJPROP_WIDTH,1);
   ObjectSetInteger(0,nm,OBJPROP_BACK,true);
   ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
  }

void RectFill(const string id,datetime t1,datetime t2,double top,double bottom,color col)
  {
   string nm=PFX+"R_"+id;
   if(ObjectFind(0,nm)<0) ObjectCreate(0,nm,OBJ_RECTANGLE,0,t1,top,t2,bottom);
   ObjectSetInteger(0,nm,OBJPROP_TIME,0,t1);
   ObjectSetDouble (0,nm,OBJPROP_PRICE,0,top);
   ObjectSetInteger(0,nm,OBJPROP_TIME,1,t2);
   ObjectSetDouble (0,nm,OBJPROP_PRICE,1,bottom);
   ObjectSetInteger(0,nm,OBJPROP_COLOR,col);
   ObjectSetInteger(0,nm,OBJPROP_FILL,true);
   ObjectSetInteger(0,nm,OBJPROP_BACK,true);
   ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
  }

void DrawPremiumDiscount(const datetime &time[],const double &close[],int total)
  {
   g_pdState="-";
   if(!InpShowPremDisc) return;
   double hi=g_ext.lastHigh, lo=g_ext.lastLow;
   if(hi<=0.0 || lo<=0.0 || hi<=lo) return;
   datetime t1=(g_ext.lastHighTime<g_ext.lastLowTime?g_ext.lastHighTime:g_ext.lastLowTime);
   datetime t2=time[total-1];
   double eq=(hi+lo)/2.0;
   double ote=lo+(hi-lo)*0.705;

   if(InpFillPremDisc)
     {
      RectFill("PRM",t1,t2,hi,eq,InpColPremium);
      RectFill("DSC",t1,t2,eq,lo,InpColDiscount);
     }
   DrawSeg("F1",t1,t2,hi,InpColPremium ,STYLE_SOLID,1); LevelTag("F1",t2,hi,"1.0 Premium",InpColPremium);
   DrawSeg("FE",t1,t2,eq,InpColEq      ,STYLE_DASH ,1); LevelTag("FE",t2,eq,"0.5 EQ",InpColEq);
   DrawSeg("F0",t1,t2,lo,InpColDiscount,STYLE_SOLID,1); LevelTag("F0",t2,lo,"0.0 Discount",InpColDiscount);
   if(InpShowOTE){ DrawSeg("FO",t1,t2,ote,InpColFibLine,STYLE_DOT,1); LevelTag("FO",t2,ote,"0.705 OTE",InpColFibLine); }

   double c=close[total-1];
   g_pdState=(c>eq?"PREMIUM":(c<eq?"DESCONTO":"EQUILIBRIO"));
  }

void DrawDayWeekLevels(const datetime &time[],int total)
  {
   datetime td=time[MathMax(0,total-9)];    // rotulos do dia: ~8 barras a esquerda
   datetime tw=time[MathMax(0,total-15)];   // rotulos da semana: ~14 barras a esquerda
   if(InpShowPDHL && Bars(_Symbol,PERIOD_D1)>=2)
     {
      double pdh=iHigh(_Symbol,PERIOD_D1,1), pdl=iLow(_Symbol,PERIOD_D1,1);
      if(pdh>0.0){ DrawHLine("PDH",pdh,InpColPDHL,STYLE_DOT); LevelTag("PDH",td,pdh,"PDH",InpColPDHL); }
      if(pdl>0.0){ DrawHLine("PDL",pdl,InpColPDHL,STYLE_DOT); LevelTag("PDL",td,pdl,"PDL",InpColPDHL); }
     }
   if(InpShowPWHL && Bars(_Symbol,PERIOD_W1)>=2)
     {
      double pwh=iHigh(_Symbol,PERIOD_W1,1), pwl=iLow(_Symbol,PERIOD_W1,1);
      if(pwh>0.0){ DrawHLine("PWH",pwh,InpColPWHL,STYLE_DASHDOT); LevelTag("PWH",tw,pwh,"PWH",InpColPWHL); }
      if(pwl>0.0){ DrawHLine("PWL",pwl,InpColPWHL,STYLE_DASHDOT); LevelTag("PWL",tw,pwl,"PWL",InpColPWHL); }
     }
  }

//--- media simples de range (high-low) para tolerancia adaptativa
double AvgRange(const double &high[],const double &low[],int idx,int n)
  {
   double s=0; int cnt=0;
   for(int b=idx-1;b>=MathMax(0,idx-n);b--){ s+=(high[b]-low[b]); cnt++; }
   return(cnt>0?s/cnt:0.0);
  }

//--- Equal Highs / Equal Lows (liquidez buy-side / sell-side)
void ScanEQ(const datetime &time[],const double &high[],const double &low[],int total)
  {
   if(!InpShowEQ) return;
   int st=InpEQSwing; if(st<1) st=1;
   int depth=MathMax(1,InpEQDepth);
   int startBar=(int)MathMax(2*st,total-InpBarsToProcess);

   double hp[]; datetime ht[]; double lp[]; datetime lt[];
   ArrayResize(hp,0); ArrayResize(ht,0); ArrayResize(lp,0); ArrayResize(lt,0);

   for(int j=startBar;j<total-1;j++)
     {
      int c=j-st;
      if(c<st || c>total-1-st) continue;

      if(IsPivotHigh(high,c,st,total))
        {
         double h=high[c];
         double tol=InpEQTolFactor*AvgRange(high,low,c,14);
         int n=ArraySize(hp);
         for(int p=n-1;p>=MathMax(0,n-depth);p--)
            if(tol>0.0 && MathAbs(h-hp[p])<=tol)
              {
               double lvl=MathMax(h,hp[p]);
               bool swept=false;
               for(int k=c+1;k<total;k++) if(high[k]>lvl+tol){ swept=true; break; }
               if(!(InpHideSweptLiq && swept) && !ZoneTooOld(c,total))
                 {
                  DrawSeg("EQH"+(string)(long)time[c],ht[p],time[total-1],lvl,InpColEQH,STYLE_DOT,1);
                  LevelTag("EQH"+(string)(long)time[c],ht[p],lvl,"EQH",InpColEQH);
                  RegLiq(lvl,"buy_side_EQH",ht[p]);
                 }
               break;
              }
         int sz=ArraySize(hp); ArrayResize(hp,sz+1); hp[sz]=h; ArrayResize(ht,sz+1); ht[sz]=time[c];
        }

      if(IsPivotLow(low,c,st,total))
        {
         double l=low[c];
         double tol=InpEQTolFactor*AvgRange(high,low,c,14);
         int n=ArraySize(lp);
         for(int p=n-1;p>=MathMax(0,n-depth);p--)
            if(tol>0.0 && MathAbs(l-lp[p])<=tol)
              {
               double lvl=MathMin(l,lp[p]);
               bool swept=false;
               for(int k=c+1;k<total;k++) if(low[k]<lvl-tol){ swept=true; break; }
               if(!(InpHideSweptLiq && swept) && !ZoneTooOld(c,total))
                 {
                  DrawSeg("EQL"+(string)(long)time[c],lt[p],time[total-1],lvl,InpColEQL,STYLE_DOT,1);
                  LevelTag("EQL"+(string)(long)time[c],lt[p],lvl,"EQL",InpColEQL);
                  RegLiq(lvl,"sell_side_EQL",lt[p]);
                 }
               break;
              }
         int sz=ArraySize(lp); ArrayResize(lp,sz+1); lp[sz]=l; ArrayResize(lt,sz+1); lt[sz]=time[c];
        }
     }
  }

//--- Indicadores auxiliares: EMA/VWAP (buffers) + ATR/RSI/ADR (valores)
void UpdateIndicators(const datetime &time[],const double &high[],
                      const double &low[],const double &close[],int total)
  {
   double tmp[];
   if(g_hEMA1!=INVALID_HANDLE) CopyBuffer(g_hEMA1,0,0,total,bufEMA50);   // sempre copia (EMA tambem filtra sinal)
   if(g_hEMA2!=INVALID_HANDLE) CopyBuffer(g_hEMA2,0,0,total,bufEMA200);

   bool intraday=(PeriodSeconds(_Period)<86400);
   if(InpShowVWAP && intraday)
     {
      double cumPV=0,cumV=0; int prevDay=-1;
      for(int i=0;i<total;i++)
        {
         MqlDateTime dt; TimeToStruct(time[i],dt);
         if(dt.day_of_year!=prevDay){ cumPV=0; cumV=0; prevDay=dt.day_of_year; }
         double tp=(high[i]+low[i]+close[i])/3.0;
         double v=VolAt(i);
         cumPV+=tp*v; cumV+=v;
         bufVWAP[i]=(cumV>0.0?cumPV/cumV:tp);
        }
     }
   else
      for(int i=0;i<total;i++) bufVWAP[i]=EMPTY_VALUE;

   { double atrS[]; AtrSeries(high,low,close,total,InpATRPeriod,atrS); g_atr=atrS[total-1]; }
   if(g_hRSI!=INVALID_HANDLE && CopyBuffer(g_hRSI,0,0,1,tmp)>0) g_rsi=tmp[0];
   double wprBuf[2];
   if(g_hWPR!=INVALID_HANDLE && CopyBuffer(g_hWPR,0,0,2,wprBuf)>=2)
     { g_wpr=wprBuf[0]; g_wprPrev=wprBuf[1]; }

   // ADR: so consulta D1 se houver historico suficiente (evita "history
   // cache build error" no tester com simbolos de historico curto).
   g_adr=0.0; g_adrRem=0.0;
   if(Bars(_Symbol,PERIOD_D1)>=2)
     {
      double sum=0; int cnt=0;
      for(int d=1;d<=InpADRPeriod;d++)
        {
         double dh=iHigh(_Symbol,PERIOD_D1,d), dl=iLow(_Symbol,PERIOD_D1,d);
         if(dh>0.0 && dl>0.0){ sum+=(dh-dl); cnt++; }
        }
      g_adr=(cnt>0?sum/cnt:0.0);
      double th=iHigh(_Symbol,PERIOD_D1,0), tl=iLow(_Symbol,PERIOD_D1,0);
      double used=(th>0.0 && tl>0.0?th-tl:0.0);
      g_adrRem=MathMax(0.0,g_adr-used);
     }

   double c=close[total-1];
   double e2=bufEMA200[total-1];
   g_emaBias=(InpShowEMA && e2>0.0 ? (c>e2?"acima":"abaixo") : "-");
   g_vwapBias=(InpShowVWAP && intraday && bufVWAP[total-1]!=EMPTY_VALUE ? (c>bufVWAP[total-1]?"acima":"abaixo") : "-");
  }

//--- Sessoes de mercado (caixas de range por dia, somente intraday)
bool HourInRange(int h,int sh,int eh){ if(sh<=eh) return(h>=sh && h<eh); return(h>=sh || h<eh); }

void DrawOneSession(int sh,int eh,color col,const string nm,
                    const datetime &time[],const double &high[],const double &low[],int total)
  {
   bool inSess=false; double hi=0,lo=0; datetime t0=0,t1=0; int curDay=-1;
   int startBar=(int)MathMax(0,total-InpBarsToProcess);
   for(int i=startBar;i<total;i++)
     {
      MqlDateTime dt; TimeToStruct(time[i],dt);
      bool within=HourInRange(dt.hour,sh,eh);
      if(within)
        {
         if(!inSess || dt.day_of_year!=curDay)
           {
            if(inSess){ RectFill("SS"+nm+(string)(long)t0,t0,t1,hi,lo,col); ZoneTag("SS"+nm+(string)(long)t0,t0,hi,nm,col); }
            inSess=true; curDay=dt.day_of_year; hi=high[i]; lo=low[i]; t0=time[i]; t1=time[i];
           }
         else
           { if(high[i]>hi) hi=high[i]; if(low[i]<lo) lo=low[i]; t1=time[i]; }
        }
      else if(inSess)
        {
         RectFill("SS"+nm+(string)(long)t0,t0,t1,hi,lo,col); ZoneTag("SS"+nm+(string)(long)t0,t0,hi,nm,col);
         inSess=false;
        }
     }
   if(inSess){ RectFill("SS"+nm+(string)(long)t0,t0,t1,hi,lo,col); ZoneTag("SS"+nm+(string)(long)t0,t0,hi,nm,col); }
  }

void DrawSessions(const datetime &time[],const double &high[],const double &low[],int total)
  {
   if(!InpShowSessions) return;
   if(PeriodSeconds(_Period)>=86400) return;   // sessoes so fazem sentido em intraday
   if(InpSessTokyo)  DrawOneSession(InpTokyoStart ,InpTokyoEnd ,InpColTokyo ,"Toquio" ,time,high,low,total);
   if(InpSessLondon) DrawOneSession(InpLondonStart,InpLondonEnd,InpColLondon,"Londres",time,high,low,total);
   if(InpSessNY)     DrawOneSession(InpNYStart    ,InpNYEnd    ,InpColNY    ,"NY"     ,time,high,low,total);
  }

//+------------------------------------------------------------------+
//| FASE 5 - Sinais                                                  |
//+------------------------------------------------------------------+
void EmitSignal(int type,int bar,double entry,double structSL,const string mode,color col,double atr,
                const datetime &time[],const double &high[],const double &low[],int total,
                double slOverride=0.0,double tpOverride=0.0)
  {
   if(ZoneTooOld(bar,total)) return;
   double sl;
   if(slOverride>0.0)                sl=slOverride;
   else if(InpSLTPMode==SLTP_ATR)    sl=(type>0? entry-InpATRSLMult*atr : entry+InpATRSLMult*atr);
   else if(InpSLTPMode==SLTP_STRUCT) sl=structSL;
   else                              sl=(type>0? structSL-InpATRBufferMult*atr : structSL+InpATRBufferMult*atr);
   double risk=MathAbs(entry-sl);
   if(risk<=0.0) return;
   double tp1,tp2;
   if(tpOverride>0.0){ tp1=tpOverride; tp2=tpOverride; }
   else { tp1=(type>0? entry+InpTP1R*risk : entry-InpTP1R*risk); tp2=(type>0? entry+InpTP2R*risk : entry-InpTP2R*risk); }

   int n=ArraySize(g_sigs); ArrayResize(g_sigs,n+1);
   g_sigs[n].time=time[bar]; g_sigs[n].type=type; g_sigs[n].mode=mode;
   g_sigs[n].entry=entry; g_sigs[n].sl=sl; g_sigs[n].tp1=tp1; g_sigs[n].tp2=tp2; g_sigs[n].rr=InpTP1R;

   string id=PFX+"SIG_"+(string)(long)time[bar]+(type>0?"B":"S");
   double off=(atr>0?atr*0.3:0.0);
   double ap=(type>0? low[bar]-off : high[bar]+off);
   if(ObjectFind(0,id)<0) ObjectCreate(0,id,OBJ_ARROW,0,time[bar],ap);
   ObjectSetInteger(0,id,OBJPROP_TIME,0,time[bar]);
   ObjectSetDouble (0,id,OBJPROP_PRICE,0,ap);
   ObjectSetInteger(0,id,OBJPROP_ARROWCODE,(type>0?233:234));
   ObjectSetInteger(0,id,OBJPROP_COLOR,col);
   ObjectSetInteger(0,id,OBJPROP_WIDTH,2);
   ObjectSetInteger(0,id,OBJPROP_ANCHOR,(type>0?ANCHOR_TOP:ANCHOR_BOTTOM));
   ObjectSetInteger(0,id,OBJPROP_SELECTABLE,false);
  }

//--- Exporta os sinais para os buffers 3..8 (consumo por EA via iCustom)
int ModeCode(const string m)
  {
   if(m=="ZONE_CHOCH")  return(1);
   if(m=="SWEEP_CHOCH") return(2);
   if(m=="POI_CONF")    return(3);
   if(m=="APLUS")       return(4);
   if(m=="ADX_CROSS")   return(5);
   return(0);
  }

void FillSignalBuffers(const datetime &time[],int total)
  {
   for(int i=0;i<total;i++)
     { bufSigType[i]=0.0; bufSigMode[i]=0.0; bufSigEntry[i]=0.0; bufSigSL[i]=0.0; bufSigTP1[i]=0.0; bufSigTP2[i]=0.0; }
   int ns=ArraySize(g_sigs);
   for(int s=0;s<ns;s++)
     {
      // sinal pode vir do LTF: mapeia o tempo do sinal para a barra do grafico que o contem
      int sh=iBarShift(_Symbol,_Period,g_sigs[s].time,false);
      if(sh<0) continue;
      int idx=total-1-sh;
      if(idx<0 || idx>=total) continue;
      bufSigType [idx]=(double)g_sigs[s].type;
      bufSigMode [idx]=(double)ModeCode(g_sigs[s].mode);
      bufSigEntry[idx]=g_sigs[s].entry;
      bufSigSL   [idx]=g_sigs[s].sl;
      bufSigTP1  [idx]=g_sigs[s].tp1;
      bufSigTP2  [idx]=g_sigs[s].tp2;
     }
  }

void DrawLastSignalLevels(const datetime &time[],int total)
  {
   g_lastSig="-";
   int ns=ArraySize(g_sigs); if(ns==0) return;
   int bi=-1; datetime best=0;
   for(int s=0;s<ns;s++) if(g_sigs[s].time>=best){ best=g_sigs[s].time; bi=s; }
   if(bi<0) return;
   g_lastSig=(g_sigs[bi].type>0?"BUY ":"SELL ")+g_sigs[bi].mode+" @ "+DoubleToString(g_sigs[bi].entry,_Digits);
   if(!InpShowSLTP) return;
   datetime t1=g_sigs[bi].time, t2=time[total-1];
   DrawSeg("SIGE" ,t1,t2,g_sigs[bi].entry,clrGoldenrod,STYLE_SOLID,1);
   DrawSeg("SIGSL",t1,t2,g_sigs[bi].sl  ,InpColSell  ,STYLE_DOT  ,1);
   DrawSeg("SIGT1",t1,t2,g_sigs[bi].tp1 ,InpColBuy   ,STYLE_DOT  ,1);
   DrawSeg("SIGT2",t1,t2,g_sigs[bi].tp2 ,InpColBuy   ,STYLE_DASH ,1);
  }

//=== MOTOR DE SINAIS (multi-timeframe: opera sobre o TF da curta) ===
void AtrSeries(const double &h[],const double &l[],const double &c[],int n,int period,double &out[])
  {
   ArrayResize(out,n); ArrayInitialize(out,0.0);
   if(period<1) period=1;
   double tr[]; ArrayResize(tr,n);
   for(int i=0;i<n;i++)
     {
      double hl=h[i]-l[i];
      if(i==0) tr[i]=hl;
      else { double a=MathMax(hl,MathAbs(h[i]-c[i-1])); a=MathMax(a,MathAbs(l[i]-c[i-1])); tr[i]=a; }
     }
   double sum=0;
   for(int i=0;i<n;i++)
     {
      sum+=tr[i]; if(i>=period) sum-=tr[i-period];
      out[i]=(i>=period-1 ? sum/period : (i>0? sum/(i+1):tr[0]));
     }
  }

void EmaSeries(const double &c[],int n,int period,double &out[])
  {
   ArrayResize(out,n); if(n==0) return;
   double k=2.0/(period+1.0); out[0]=c[0];
   for(int i=1;i<n;i++) out[i]=c[i]*k+out[i-1]*(1.0-k);
  }

void ComputeChoch(const double &h[],const double &l[],const double &c[],int n,int strength,int &outChoch[])
  {
   ArrayResize(outChoch,n); ArrayInitialize(outChoch,0);
   if(strength<1) strength=1;
   double lastHigh=0,lastLow=0; bool hC=true,lC=true; int trend=SMC_SIDE;
   for(int j=2*strength;j<n-1;j++)
     {
      int cc=j-strength;
      if(cc>=strength && cc<=n-1-strength)
        {
         if(IsPivotHigh(h,cc,strength,n)){ lastHigh=h[cc]; hC=false; }
         if(IsPivotLow (l,cc,strength,n)){ lastLow =l[cc]; lC=false; }
        }
      if(!hC && lastHigh>0.0 && c[j]>lastHigh){ if(trend==SMC_BEAR) outChoch[j]=1;  trend=SMC_BULL; hC=true; }
      if(!lC && lastLow >0.0 && c[j]<lastLow ){ if(trend==SMC_BULL) outChoch[j]=-1; trend=SMC_BEAR; lC=true; }
     }
  }

void ComputeTrendEq(const double &h[],const double &l[],const double &c[],int n,int strength,int &outTrend[],double &outEq[])
  {
   ArrayResize(outTrend,n); ArrayInitialize(outTrend,SMC_SIDE);
   ArrayResize(outEq,n);    ArrayInitialize(outEq,0.0);
   if(strength<1) strength=1;
   double lastHigh=0,lastLow=0; bool hC=true,lC=true; int trend=SMC_SIDE;
   for(int j=2*strength;j<n;j++)
     {
      int cc=j-strength;
      if(cc>=strength && cc<=n-1-strength)
        {
         if(IsPivotHigh(h,cc,strength,n)){ lastHigh=h[cc]; hC=false; }
         if(IsPivotLow (l,cc,strength,n)){ lastLow =l[cc]; lC=false; }
        }
      if(j<n-1)
        {
         if(!hC && lastHigh>0.0 && c[j]>lastHigh){ trend=SMC_BULL; hC=true; }
         if(!lC && lastLow >0.0 && c[j]<lastLow ){ trend=SMC_BEAR; lC=true; }
        }
      outTrend[j]=trend;
      outEq[j]=(lastHigh>0.0 && lastLow>0.0 && lastHigh>lastLow)?(lastHigh+lastLow)*0.5:0.0;
     }
  }

void MapHTFToBars(const datetime &times[],int n,int &out[],ENUM_TIMEFRAMES tf)
  {
   ArrayResize(out,n); ArrayInitialize(out,SMC_SIDE);
   MqlRates r[]; ArraySetAsSeries(r,false);
   int m=CopyRates(_Symbol,tf,0,InpHTFBars,r);
   if(m<InpSwingExternal*2+5) return;
   datetime ht[]; double hh[],hl[],hc[];
   ArrayResize(ht,m);ArrayResize(hh,m);ArrayResize(hl,m);ArrayResize(hc,m);
   for(int i=0;i<m;i++){ ht[i]=r[i].time; hh[i]=r[i].high; hl[i]=r[i].low; hc[i]=r[i].close; }
   int tr[]; ComputeTrendSeries(ht,hh,hl,hc,m,InpSwingExternal,tr);
   int hi=0;
   for(int k=0;k<n;k++){ while(hi+1<m && ht[hi+1]<=times[k]) hi++; out[k]=(ht[hi]<=times[k]?tr[hi]:SMC_SIDE); }
  }

void SigZoneChoCh(const datetime &t[],const double &o[],const double &h[],const double &l[],const double &c[],int n,
                  const int &bias[],const int &choch[],const double &atr[])
  {
   if(!InpSigZoneChoCh) return;
   int W=MathMax(1,InpZoneTapLook);
   for(int k=2;k<n;k++)
     {
      int d=choch[k]; if(d==0) continue;                                  // precisa de um CHoCH no LTF
      if(InpSigTrendOnly && ((d>0 && bias[k]!=SMC_BULL)||(d<0 && bias[k]!=SMC_BEAR))) continue;
      int p=TappedAOBIndex(h,l,t,k-W,k,d,false);                          // preco tocou a zona (OB pos-BOS)
      if(p<0) continue;
      double entry=c[k], a=atr[k];
      if(d>0)
        {
         double sl=g_aobBot[p]-InpATRBufferMult*a;                        // stop abaixo da zona de demanda
         double tp=LastPivotHigh(h,k,InpSwingExternal,n);                 // target = ultimo topo
         if(tp>entry) EmitSignal(+1,k,entry,sl,"ZONE_CHOCH",InpColBuy,a,t,h,l,n,sl,tp);
        }
      else
        {
         double sl=g_aobTop[p]+InpATRBufferMult*a;                        // stop acima da zona de oferta
         double tp=LastPivotLow(l,k,InpSwingExternal,n);                  // target = ultimo fundo
         if(tp>0.0 && tp<entry) EmitSignal(-1,k,entry,sl,"ZONE_CHOCH",InpColSell,a,t,h,l,n,sl,tp);
        }
     }
  }

void SigSweep(const datetime &t[],const double &h[],const double &l[],const double &c[],int n,
              const int &choch[],const int &bias[],const double &atr[])
  {
   if(!InpSigSweepChoCH) return;
   int W=MathMax(1,InpSweepLook), back=MathMax(1,InpSwingExternal);
   for(int k=W+back+1;k<n;k++)
     {
      int d=choch[k]; if(d==0) continue;
      if(InpSigTrendOnly && ((d>0 && bias[k]!=SMC_BULL)||(d<0 && bias[k]!=SMC_BEAR))) continue;
      if(d>0)
        {
         double sweepLow=DBL_MAX; for(int b=k-W;b<=k;b++)      if(l[b]<sweepLow) sweepLow=l[b];
         double priorLow=DBL_MAX; for(int b=k-W-back;b<k-W;b++) if(l[b]<priorLow) priorLow=l[b];
         if(sweepLow<priorLow) EmitSignal(+1,k,c[k],sweepLow,"SWEEP_CHOCH",InpColBuy2,atr[k],t,h,l,n);
        }
      else
        {
         double sweepHigh=-DBL_MAX; for(int b=k-W;b<=k;b++)      if(h[b]>sweepHigh) sweepHigh=h[b];
         double priorHigh=-DBL_MAX; for(int b=k-W-back;b<k-W;b++) if(h[b]>priorHigh) priorHigh=h[b];
         if(sweepHigh>priorHigh) EmitSignal(-1,k,c[k],sweepHigh,"SWEEP_CHOCH",InpColSell2,atr[k],t,h,l,n);
        }
     }
  }

void ComputeADXSeries(const double &h[],const double &l[],const double &c[],int n,int len)
  {
   ArrayResize(g_adxDIp,n); ArrayResize(g_adxDIm,n); ArrayResize(g_adxADX,n);
   if(n<2 || len<1) return;
   double STR[],SDMP[],SDMM[],DX[];
   ArrayResize(STR,n);ArrayResize(SDMP,n);ArrayResize(SDMM,n);ArrayResize(DX,n);
   STR[0]=h[0]-l[0]; SDMP[0]=0.0; SDMM[0]=0.0; DX[0]=0.0;
   g_adxDIp[0]=0.0; g_adxDIm[0]=0.0; g_adxADX[0]=0.0;
   for(int i=1;i<n;i++)
     {
      double tr=MathMax(MathMax(h[i]-l[i],MathAbs(h[i]-c[i-1])),MathAbs(l[i]-c[i-1]));
      double up=h[i]-h[i-1], dn=l[i-1]-l[i];
      double dmp=(up>dn)?MathMax(up,0.0):0.0, dmm=(dn>up)?MathMax(dn,0.0):0.0;
      STR[i]=STR[i-1]-STR[i-1]/len+tr;
      SDMP[i]=SDMP[i-1]-SDMP[i-1]/len+dmp;
      SDMM[i]=SDMM[i-1]-SDMM[i-1]/len+dmm;
      double diP=(STR[i]!=0.0)?SDMP[i]/STR[i]*100.0:0.0;
      double diM=(STR[i]!=0.0)?SDMM[i]/STR[i]*100.0:0.0;
      g_adxDIp[i]=diP; g_adxDIm[i]=diM;
      double den=diP+diM; DX[i]=(den!=0.0)?MathAbs(diP-diM)/den*100.0:0.0;
      if(i>=len){ double s=0.0; for(int k=0;k<len;k++) s+=DX[i-k]; g_adxADX[i]=s/len; }
      else g_adxADX[i]=0.0;
     }
  }

void SigADX(const datetime &time[],const double &high[],const double &low[],const double &close[],int total)
  {
   if(!InpSigADX) return;
   double atrS[]; AtrSeries(high,low,close,total,InpATRPeriod,atrS);
   int startBar=(int)MathMax(InpADXLen+2, total-InpBarsToProcess);
   for(int k=startBar;k<total-1;k++)   // apenas barras fechadas
     {
      if(g_adxADX[k]<InpADXTh) continue;                 // exige forca de tendencia
      bool buy =(g_adxDIp[k-1]<=g_adxDIm[k-1] && g_adxDIp[k]>g_adxDIm[k]);
      bool sell=(g_adxDIp[k-1]>=g_adxDIm[k-1] && g_adxDIp[k]<g_adxDIm[k]);
      if(buy)
        {
         double sl=LastPivotLow(low,k,InpSwingInternal,total); if(sl<=0.0) sl=low[k];
         EmitSignal(+1,k,close[k],sl,"ADX_CROSS",InpColBuy,atrS[k],time,high,low,total);
        }
      else if(sell)
        {
         double sh=LastPivotHigh(high,k,InpSwingInternal,total); if(sh<=0.0) sh=high[k];
         EmitSignal(-1,k,close[k],sh,"ADX_CROSS",InpColSell,atrS[k],time,high,low,total);
        }
     }
  }

void RunSignals(const datetime &time[],const double &open[],const double &high[],const double &low[],const double &close[],int total)
  {
   bool useLTF=(InpLTF!=PERIOD_CURRENT && PeriodSeconds(InpLTF)>0 && PeriodSeconds(InpLTF)<PeriodSeconds(_Period));
   if(!useLTF)
     {
      double atrS[]; AtrSeries(high,low,close,total,InpATRPeriod,atrS);
      SigZoneChoCh(time,open,high,low,close,total,g_htfTrendBar,g_intChochBar,atrS);
      SigSweep(time,high,low,close,total,g_intChochBar,g_htfTrendBar,atrS);
      SigPOI(time,high,low,close,total,g_intChochBar,g_htfTrendBar,atrS);
      SigAPlus(time,open,high,low,close,total,g_htfTrendBar,g_intChochBar,atrS);
      return;
     }
   MqlRates r[]; ArraySetAsSeries(r,false);
   int n=CopyRates(_Symbol,InpLTF,0,InpLTFBars,r);
   if(n<InpSwingExternal*2+5) return;
   datetime lt[]; double lo[],lh[],ll[],lc[];
   ArrayResize(lt,n);ArrayResize(lo,n);ArrayResize(lh,n);ArrayResize(ll,n);ArrayResize(lc,n);
   for(int i=0;i<n;i++){ lt[i]=r[i].time; lo[i]=r[i].open; lh[i]=r[i].high; ll[i]=r[i].low; lc[i]=r[i].close; }
   int ltfTrend[],ltfChoch[],ltfBias[]; double ltfEq[],ltfEma[],ltfAtr[];
   ComputeTrendEq(lh,ll,lc,n,InpSwingExternal,ltfTrend,ltfEq);
   ComputeChoch(lh,ll,lc,n,InpSwingInternal,ltfChoch);
   EmaSeries(lc,n,InpEMA2,ltfEma);
   AtrSeries(lh,ll,lc,n,InpATRPeriod,ltfAtr);
   ENUM_TIMEFRAMES effHTF=(InpHTF==PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : InpHTF);
   bool isHTF=(InpSigUseHTFBias && PeriodSeconds(effHTF)>PeriodSeconds(InpLTF));   // longa vs curta (nao o grafico)
   if(isHTF) MapHTFToBars(lt,n,ltfBias,effHTF);
   else { ArrayResize(ltfBias,n); for(int i=0;i<n;i++) ltfBias[i]=ltfTrend[i]; }
   SigZoneChoCh(lt,lo,lh,ll,lc,n,ltfBias,ltfChoch,ltfAtr);
   SigSweep(lt,lh,ll,lc,n,ltfChoch,ltfBias,ltfAtr);
   SigPOI(lt,lh,ll,lc,n,ltfChoch,ltfBias,ltfAtr);
   SigAPlus(lt,lo,lh,ll,lc,n,ltfBias,ltfChoch,ltfAtr);
  }

//--- POI + confirmacao interna (POI no timeframe InpHTF, CHoCH no grafico)
void AddPoi(double top,double bot,int dir,datetime t1,datetime fill)
  {
   int m=ArraySize(g_poiTop);
   ArrayResize(g_poiTop ,m+1); g_poiTop[m]=top;
   ArrayResize(g_poiBot ,m+1); g_poiBot[m]=bot;
   ArrayResize(g_poiDir ,m+1); g_poiDir[m]=dir;
   ArrayResize(g_poiT1  ,m+1); g_poiT1[m]=t1;
   ArrayResize(g_poiFill,m+1); g_poiFill[m]=fill;
  }

void BuildFvgList(const datetime &t[],const double &h[],const double &l[],int n)
  {
   for(int i=2;i<n-1;i++)
     {
      if(l[i]>h[i-2])
        {
         double top=l[i],bottom=h[i-2],mid=(top+bottom)*0.5;
         datetime fill=0; for(int k=i+1;k<n;k++) if(l[k]<=mid){ fill=t[k]; break; }
         AddPoi(top,bottom,+1,t[i-2],fill);
        }
      if(h[i]<l[i-2])
        {
         double top=l[i-2],bottom=h[i],mid=(top+bottom)*0.5;
         datetime fill=0; for(int k=i+1;k<n;k++) if(h[k]>=mid){ fill=t[k]; break; }
         AddPoi(top,bottom,-1,t[i-2],fill);
        }
     }
  }

void BuildPOIFvgs(const datetime &time[],const double &high[],const double &low[],int total)
  {
   ArrayResize(g_poiTop,0);ArrayResize(g_poiBot,0);ArrayResize(g_poiDir,0);ArrayResize(g_poiT1,0);ArrayResize(g_poiFill,0);
   if(!InpSigPOIConfirm) return;
   bool useChart=(InpHTF==PERIOD_CURRENT || PeriodSeconds(InpHTF)<=PeriodSeconds(_Period));
   if(useChart)
      BuildFvgList(time,high,low,total);
   else
     {
      MqlRates r[]; ArraySetAsSeries(r,false);
      int n=CopyRates(_Symbol,InpHTF,0,InpHTFBars,r);
      if(n<5) return;
      datetime ht[]; double hh[],hl[];
      ArrayResize(ht,n);ArrayResize(hh,n);ArrayResize(hl,n);
      for(int i=0;i<n;i++){ ht[i]=r[i].time; hh[i]=r[i].high; hl[i]=r[i].low; }
      BuildFvgList(ht,hh,hl,n);
     }
  }

void DrawHTFPois(const datetime &time[],int total)
  {
   if(!(InpSigPOIConfirm && InpDrawHTFPoi)) return;
   if(InpHTF==PERIOD_CURRENT || PeriodSeconds(InpHTF)<=PeriodSeconds(_Period)) return; // desenha so se for HTF
   int np=ArraySize(g_poiTop);
   for(int p=0;p<np;p++)
     {
      if(g_poiFill[p]!=0) continue;
      string nm=PFX+"Z_HTF"+(string)(long)g_poiT1[p]+(g_poiDir[p]>0?"b":"s");
      if(ObjectFind(0,nm)<0) ObjectCreate(0,nm,OBJ_RECTANGLE,0,g_poiT1[p],g_poiTop[p],time[total-1],g_poiBot[p]);
      ObjectSetInteger(0,nm,OBJPROP_TIME,0,g_poiT1[p]);
      ObjectSetDouble (0,nm,OBJPROP_PRICE,0,g_poiTop[p]);
      ObjectSetInteger(0,nm,OBJPROP_TIME,1,time[total-1]);
      ObjectSetDouble (0,nm,OBJPROP_PRICE,1,g_poiBot[p]);
      ObjectSetInteger(0,nm,OBJPROP_COLOR,InpColHTFPoi);
      ObjectSetInteger(0,nm,OBJPROP_FILL,false);            // apenas contorno, nao cobre os OBs
      ObjectSetInteger(0,nm,OBJPROP_STYLE,STYLE_DOT);
      ObjectSetInteger(0,nm,OBJPROP_BACK,true);
      ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
     }
  }

void SigPOI(const datetime &t[],const double &h[],const double &l[],const double &c[],int n,
            const int &choch[],const int &bias[],const double &atr[])
  {
   if(!InpSigPOIConfirm) return;
   int np=ArraySize(g_poiTop); if(np==0) return;
   for(int k=2;k<n;k++)
     {
      int d=choch[k]; if(d==0) continue;
      if(InpSigTrendOnly && ((d>0 && bias[k]!=SMC_BULL)||(d<0 && bias[k]!=SMC_BEAR))) continue;
      double cc=c[k]; datetime tk=t[k];
      for(int p=0;p<np;p++)
        {
         if(g_poiDir[p]!=d) continue;
         if(g_poiT1[p]>tk) continue;
         if(g_poiFill[p]!=0 && g_poiFill[p]<=tk) continue;
         if(cc>=g_poiBot[p] && cc<=g_poiTop[p])
           {
            EmitSignal(d,k,cc,(d>0?g_poiBot[p]:g_poiTop[p]),"POI_CONF",(d>0?InpColBuy3:InpColSell3),atr[k],t,h,l,n);
            break;
           }
        }
     }
  }

//--- A+ Setup: Order Block do HTF (de sweep/BOS) + MSS no LTF + entrada no FVG do LTF
void AddHTFOB(bool bull,int breakBar,const datetime &t[],const double &o[],const double &h[],
              const double &l[],const double &c[],int n)
  {
   int lim=MathMax(2,breakBar-InpOBLookback); int ob=-1;
   for(int k=breakBar-1;k>=lim;k--){ if(bull && c[k]<o[k]){ ob=k; break; } if(!bull && c[k]>o[k]){ ob=k; break; } }
   if(ob<2) return;
   bool imb=false;
   for(int m=ob+2;m<=breakBar && m<n;m++){ if(bull && l[m]>h[m-2]){ imb=true; break; } if(!bull && h[m]<l[m-2]){ imb=true; break; } }
   if(InpOBRequireImb && !imb) return;

   // sweep de liquidez antes do OB (armazenado por OB; A+ pode exigir, Zona+CHoCH nao exige)
   int W=MathMax(1,InpSweepLook), back=MathMax(1,InpSwingExternal);
   bool swept=false;
   if(bull)
     {
      double sLow=DBL_MAX; for(int b=MathMax(0,ob-W);b<=ob;b++)        if(l[b]<sLow) sLow=l[b];
      double pLow=DBL_MAX; for(int b=MathMax(0,ob-W-back);b<ob-W;b++)  if(l[b]<pLow) pLow=l[b];
      swept=(pLow<DBL_MAX && sLow<pLow);
     }
   else
     {
      double sHigh=-DBL_MAX; for(int b=MathMax(0,ob-W);b<=ob;b++)       if(h[b]>sHigh) sHigh=h[b];
      double pHigh=-DBL_MAX; for(int b=MathMax(0,ob-W-back);b<ob-W;b++) if(h[b]>pHigh) pHigh=h[b];
      swept=(pHigh>-DBL_MAX && sHigh>pHigh);
     }

   double top=h[ob],bot=l[ob],mid=(top+bot)*0.5;
   datetime fill=0;
   for(int k=breakBar+1;k<n;k++){ if(bull && l[k]<=mid){ fill=t[k]; break; } if(!bull && h[k]>=mid){ fill=t[k]; break; } }
   int m2=ArraySize(g_aobTop);
   ArrayResize(g_aobTop,m2+1); g_aobTop[m2]=top;
   ArrayResize(g_aobBot,m2+1); g_aobBot[m2]=bot;
   ArrayResize(g_aobDir,m2+1); g_aobDir[m2]=(bull?1:-1);
   ArrayResize(g_aobT1,m2+1);  g_aobT1[m2]=t[ob];
   ArrayResize(g_aobFill,m2+1);g_aobFill[m2]=fill;
   ArrayResize(g_aobSwept,m2+1);g_aobSwept[m2]=(swept?1:0);
  }

void BuildHTFOBs()
  {
   ArrayResize(g_aobTop,0);ArrayResize(g_aobBot,0);ArrayResize(g_aobDir,0);ArrayResize(g_aobT1,0);ArrayResize(g_aobFill,0);ArrayResize(g_aobSwept,0);
   if(!InpSigAPlus && !InpSigZoneChoCh) return;
   ENUM_TIMEFRAMES tf=(InpHTF==PERIOD_CURRENT?(ENUM_TIMEFRAMES)_Period:InpHTF);
   MqlRates r[]; ArraySetAsSeries(r,false);
   int n=CopyRates(_Symbol,tf,0,InpHTFBars,r);
   if(n<InpSwingExternal*2+5) return;
   datetime t[]; double o[],h[],l[],c[];
   ArrayResize(t,n);ArrayResize(o,n);ArrayResize(h,n);ArrayResize(l,n);ArrayResize(c,n);
   for(int i=0;i<n;i++){ t[i]=r[i].time; o[i]=r[i].open; h[i]=r[i].high; l[i]=r[i].low; c[i]=r[i].close; }
   int strength=InpSwingExternal; if(strength<1) strength=1;
   double lastHigh=0,lastLow=0; bool hC=true,lC=true;
   for(int j=2*strength;j<n-1;j++)
     {
      int cc=j-strength;
      if(cc>=strength && cc<=n-1-strength)
        {
         if(IsPivotHigh(h,cc,strength,n)){ lastHigh=h[cc]; hC=false; }
         if(IsPivotLow (l,cc,strength,n)){ lastLow =l[cc]; lC=false; }
        }
      if(!hC && lastHigh>0.0 && c[j]>lastHigh){ hC=true; AddHTFOB(true ,j,t,o,h,l,c,n); }
      if(!lC && lastLow >0.0 && c[j]<lastLow ){ lC=true; AddHTFOB(false,j,t,o,h,l,c,n); }
     }
  }

void DrawHTFOBs(const datetime &time[],int total)
  {
   if(!(InpSigAPlus && InpDrawHTFOB)) return;
   int np=ArraySize(g_aobTop);
   for(int p=0;p<np;p++)
     {
      string nm=PFX+"Z_AOB"+(string)(long)g_aobT1[p]+(g_aobDir[p]>0?"b":"s");
      if(ObjectFind(0,nm)<0) ObjectCreate(0,nm,OBJ_RECTANGLE,0,g_aobT1[p],g_aobTop[p],time[total-1],g_aobBot[p]);
      ObjectSetInteger(0,nm,OBJPROP_TIME,0,g_aobT1[p]);
      ObjectSetDouble (0,nm,OBJPROP_PRICE,0,g_aobTop[p]);
      ObjectSetInteger(0,nm,OBJPROP_TIME,1,time[total-1]);
      ObjectSetDouble (0,nm,OBJPROP_PRICE,1,g_aobBot[p]);
      ObjectSetInteger(0,nm,OBJPROP_COLOR,InpColHTFOB);
      ObjectSetInteger(0,nm,OBJPROP_FILL,false);
      ObjectSetInteger(0,nm,OBJPROP_STYLE,STYLE_DASH);
      ObjectSetInteger(0,nm,OBJPROP_WIDTH,2);
      ObjectSetInteger(0,nm,OBJPROP_BACK,false);          // na frente, p/ nao ficar escondido
      ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
     }
  }

int TappedAOBIndex(const double &h[],const double &l[],const datetime &t[],int from,int to,int dir,bool reqSwept)
  {
   int np=ArraySize(g_aobTop);
   for(int b=MathMax(0,from);b<=to;b++)
      for(int p=0;p<np;p++)
        {
         if(g_aobDir[p]!=dir) continue;
         if(reqSwept && g_aobSwept[p]==0) continue;
         if(g_aobT1[p]>t[b]) continue;                    // OB criado depois da barra
         double price=(dir>0 ? l[b] : h[b]);               // demanda: fundo da barra ; oferta: topo
         if(price>=g_aobBot[p] && price<=g_aobTop[p]) return(p);
        }
   return(-1);
  }

double LastPivotHigh(const double &h[],int k,int strength,int n)
  {
   for(int c=k-strength;c>=strength;c--) if(IsPivotHigh(h,c,strength,n)) return(h[c]);
   return(0.0);
  }

double LastPivotLow(const double &l[],int k,int strength,int n)
  {
   for(int c=k-strength;c>=strength;c--) if(IsPivotLow(l,c,strength,n)) return(l[c]);
   return(0.0);
  }

void SigAPlus(const datetime &t[],const double &o[],const double &h[],const double &l[],const double &c[],int n,
              const int &bias[],const int &choch[],const double &atr[])
  {
   if(!InpSigAPlus) return;
   double minsz=InpFVGMinPts*_Point;
   int W=MathMax(1,InpAPlusMSSLook);
   for(int i=2;i<n-1;i++)
     {
      if(l[i]>h[i-2] && (l[i]-h[i-2])>=minsz)   // FVG de alta -> entrada de compra
        {
         double bottom=h[i-2],mid=(l[i]+h[i-2])*0.5; int kmit=-1;
         for(int k=i+1;k<n;k++) if(l[k]<=mid){ kmit=k; break; }
         if(kmit>0 && bias[kmit]==SMC_BULL)
           {
            bool mss=false; for(int b=MathMax(0,i-W);b<i;b++) if(choch[b]==1){ mss=true; break; }
            if(mss && TappedAOBIndex(h,l,t,i-W,i,1,InpAPlusReqSweep)>=0)
               EmitSignal(+1,kmit,mid,bottom,"APLUS",InpColAPlusBuy,atr[kmit],t,h,l,n);
           }
        }
      if(h[i]<l[i-2] && (l[i-2]-h[i])>=minsz)    // FVG de baixa -> entrada de venda
        {
         double topb=l[i-2],mid=(l[i-2]+h[i])*0.5; int kmit=-1;
         for(int k=i+1;k<n;k++) if(h[k]>=mid){ kmit=k; break; }
         if(kmit>0 && bias[kmit]==SMC_BEAR)
           {
            bool mss=false; for(int b=MathMax(0,i-W);b<i;b++) if(choch[b]==-1){ mss=true; break; }
            if(mss && TappedAOBIndex(h,l,t,i-W,i,-1,InpAPlusReqSweep)>=0)
               EmitSignal(-1,kmit,mid,topb,"APLUS",InpColAPlusSell,atr[kmit],t,h,l,n);
           }
        }
     }
  }

//--- Vies do HTF (tendencia "longa") aplicado a todos os sinais
string TfName(ENUM_TIMEFRAMES tf){ string s=EnumToString(tf); StringReplace(s,"PERIOD_",""); return(s); }

int EffBias(int idx)
  {
   if(idx<0) return(SMC_SIDE);
   if(InpSigUseHTFBias && idx<ArraySize(g_htfTrendBar)) return(g_htfTrendBar[idx]);
   if(idx<ArraySize(g_trendBar)) return(g_trendBar[idx]);
   return(SMC_SIDE);
  }

void ComputeTrendSeries(const datetime &t[],const double &h[],const double &l[],const double &c[],int n,int strength,int &outTrend[])
  {
   ArrayResize(outTrend,n); ArrayInitialize(outTrend,SMC_SIDE);
   if(strength<1) strength=1;
   double lastHigh=0,lastLow=0; bool hC=true,lC=true; int trend=SMC_SIDE;
   for(int j=2*strength;j<n;j++)
     {
      int cc=j-strength;
      if(cc>=strength && cc<=n-1-strength)
        {
         if(IsPivotHigh(h,cc,strength,n)){ lastHigh=h[cc]; hC=false; }
         if(IsPivotLow (l,cc,strength,n)){ lastLow =l[cc]; lC=false; }
        }
      if(j<n-1)
        {
         if(!hC && lastHigh>0.0 && c[j]>lastHigh){ trend=SMC_BULL; hC=true; }
         if(!lC && lastLow >0.0 && c[j]<lastLow ){ trend=SMC_BEAR; lC=true; }
        }
      outTrend[j]=trend;
     }
   if(n>0) outTrend[n-1]=trend;
  }

void BuildHTFTrend(const datetime &time[],int total)
  {
   ArrayResize(g_htfTrendBar,total);
   bool isHTF=(InpHTF!=PERIOD_CURRENT && PeriodSeconds(InpHTF)>PeriodSeconds(_Period));
   if(!isHTF)
     {
      for(int i=0;i<total;i++) g_htfTrendBar[i]=(i<ArraySize(g_trendBar)?g_trendBar[i]:SMC_SIDE);
      if(total>0) g_htfNow=g_htfTrendBar[total-1];
      return;
     }
   MqlRates r[]; ArraySetAsSeries(r,false);
   int n=CopyRates(_Symbol,InpHTF,0,InpHTFBars,r);
   if(n<InpSwingExternal*2+5)
     {
      for(int i=0;i<total;i++) g_htfTrendBar[i]=(i<ArraySize(g_trendBar)?g_trendBar[i]:SMC_SIDE);
      if(total>0) g_htfNow=g_htfTrendBar[total-1];
      return;
     }
   datetime ht[]; double hh[],hl[],hc[];
   ArrayResize(ht,n);ArrayResize(hh,n);ArrayResize(hl,n);ArrayResize(hc,n);
   for(int i=0;i<n;i++){ ht[i]=r[i].time; hh[i]=r[i].high; hl[i]=r[i].low; hc[i]=r[i].close; }
   int htfTrend[]; ComputeTrendSeries(ht,hh,hl,hc,n,InpSwingExternal,htfTrend);
   int hi=0;
   for(int k=0;k<total;k++)
     {
      while(hi+1<n && ht[hi+1]<=time[k]) hi++;
      g_htfTrendBar[k]=(ht[hi]<=time[k]?htfTrend[hi]:SMC_SIDE);
     }
   if(total>0) g_htfNow=g_htfTrendBar[total-1];
  }

//+------------------------------------------------------------------+
//| EXPORT JSON do estado SMC (para o MCP/LLM)                        |
//+------------------------------------------------------------------+
string Iso(datetime t){ MqlDateTime d; TimeToStruct(t,d); return(StringFormat("%04d-%02d-%02dT%02d:%02d:%02d",d.year,d.mon,d.day,d.hour,d.min,d.sec)); }
string DirStr(int d){ return(d==SMC_BULL?"bullish":d==SMC_BEAR?"bearish":"side"); }

void RegZone(double top,double bot,int dir,const string cat,datetime t1)
  {
   int m=ArraySize(g_znTop);
   ArrayResize(g_znTop,m+1); g_znTop[m]=top;
   ArrayResize(g_znBot,m+1); g_znBot[m]=bot;
   ArrayResize(g_znDir,m+1); g_znDir[m]=dir;
   ArrayResize(g_znCat,m+1); g_znCat[m]=cat;
   ArrayResize(g_znT1,m+1);  g_znT1[m]=t1;
  }

void RegLiq(double price,const string type,datetime t1)
  {
   int m=ArraySize(g_lqPrice);
   ArrayResize(g_lqPrice,m+1); g_lqPrice[m]=price;
   ArrayResize(g_lqType,m+1);  g_lqType[m]=type;
   ArrayResize(g_lqT1,m+1);    g_lqT1[m]=t1;
  }

void ExportJSON(const datetime &time[],const double &open[],const double &high[],
                const double &low[],const double &close[],int total)
  {
   if(!InpExportJSON || total<2) return;
   int dg=_Digits, lb=total-1;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID), ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double hi=g_ext.lastHigh, lo=g_ext.lastLow, eq=(hi>0&&lo>0?(hi+lo)*0.5:0.0);
   double pdh=0,pdl=0,pwh=0,pwl=0;
   if(Bars(_Symbol,PERIOD_D1)>=2){ pdh=iHigh(_Symbol,PERIOD_D1,1); pdl=iLow(_Symbol,PERIOD_D1,1); }
   if(Bars(_Symbol,PERIOD_W1)>=2){ pwh=iHigh(_Symbol,PERIOD_W1,1); pwl=iLow(_Symbol,PERIOD_W1,1); }

   string s="{";
   s+="\"schema_version\":\"0.1.0\",";
   s+="\"generated_at\":\""+Iso(TimeGMT())+"\",";
   s+="\"server_time\":\""+Iso(TimeCurrent())+"\",";
   s+="\"source\":{\"indicator\":\"SMC Suite\",\"version\":\"0.90\"},";
   s+="\"symbol\":\""+_Symbol+"\",\"digits\":"+(string)dg+",\"point\":"+DoubleToString(_Point,dg)+",";
   s+="\"account_currency\":\""+AccountInfoString(ACCOUNT_CURRENCY)+"\",";
   s+="\"timeframe\":\""+TfName((ENUM_TIMEFRAMES)_Period)+"\",\"htf\":\""+TfName(InpHTF)+"\",\"ltf\":\""+TfName(InpLTF)+"\",";
   s+="\"price\":{\"bid\":"+DoubleToString(bid,dg)+",\"ask\":"+DoubleToString(ask,dg)+",\"last_close\":"+DoubleToString(close[lb],dg)+"},";
   s+="\"bar\":{\"time\":\""+Iso(time[lb])+"\",\"open\":"+DoubleToString(open[lb],dg)+",\"high\":"+DoubleToString(high[lb],dg)+",\"low\":"+DoubleToString(low[lb],dg)+",\"close\":"+DoubleToString(close[lb],dg)+"},";
   s+="\"config\":{\"swing_ext\":"+(string)InpSwingExternal+",\"swing_int\":"+(string)InpSwingInternal+",\"sl_tp_mode\":"+(string)InpSLTPMode+",\"atr_period\":"+(string)InpATRPeriod+",\"r1\":"+DoubleToString(InpTP1R,2)+",\"r2\":"+DoubleToString(InpTP2R,2)+"},";
   s+="\"trend\":{\"major\":\""+DirStr(g_ext.trend)+"\",\"minor\":\""+DirStr(g_int.trend)+"\",\"htf_bias\":\""+DirStr(g_htfNow)+"\"},";
   s+="\"premium_discount\":{\"range_high\":"+DoubleToString(hi,dg)+",\"range_low\":"+DoubleToString(lo,dg)+",\"equilibrium\":"+DoubleToString(eq,dg)+",\"current_zone\":\""+g_pdState+"\"},";
   bool adxRising=(lb>0 && g_adxADX[lb]>g_adxADX[lb-1]);
   bool wprRising=(g_wpr>g_wprPrev);
   s+="\"indicators\":{\"atr\":"+DoubleToString(g_atr,dg)+",\"rsi\":"+DoubleToString(g_rsi,1)+",\"adr\":"+DoubleToString(g_adr,dg)+",\"adr_remaining\":"+DoubleToString(g_adrRem,dg)+",\"ema_fast\":"+DoubleToString(bufEMA50[lb],dg)+",\"ema_slow\":"+DoubleToString(bufEMA200[lb],dg)+",\"ema_bias\":\""+g_emaBias+"\",\"vwap_bias\":\""+g_vwapBias+"\",\"adx\":"+DoubleToString(g_adxADX[lb],1)+",\"adx_prev\":"+DoubleToString(lb>0?g_adxADX[lb-1]:0.0,1)+",\"adx_rising\":"+(adxRising?"true":"false")+",\"di_plus\":"+DoubleToString(g_adxDIp[lb],1)+",\"di_minus\":"+DoubleToString(g_adxDIm[lb],1)+",\"wpr\":"+DoubleToString(g_wpr,1)+",\"wpr_prev\":"+DoubleToString(g_wprPrev,1)+",\"wpr_rising\":"+(wprRising?"true":"false")+"},";
   s+="\"levels\":{\"PDH\":"+DoubleToString(pdh,dg)+",\"PDL\":"+DoubleToString(pdl,dg)+",\"PWH\":"+DoubleToString(pwh,dg)+",\"PWL\":"+DoubleToString(pwl,dg)+"},";

   s+="\"zones\":[";
   int nz=ArraySize(g_znTop);
   for(int i=0;i<nz;i++){ if(i>0) s+=","; s+="{\"cat\":\""+g_znCat[i]+"\",\"dir\":\""+(g_znDir[i]>0?"bullish":"bearish")+"\",\"top\":"+DoubleToString(g_znTop[i],dg)+",\"bottom\":"+DoubleToString(g_znBot[i],dg)+",\"mid\":"+DoubleToString((g_znTop[i]+g_znBot[i])*0.5,dg)+",\"time\":\""+Iso(g_znT1[i])+"\"}"; }
   s+="],";

   s+="\"liquidity\":[";
   int nl=ArraySize(g_lqPrice);
   for(int i=0;i<nl;i++){ if(i>0) s+=","; s+="{\"type\":\""+g_lqType[i]+"\",\"price\":"+DoubleToString(g_lqPrice[i],dg)+",\"time\":\""+Iso(g_lqT1[i])+"\"}"; }
   s+="],";

   s+="\"signals\":[";
   int ns=ArraySize(g_sigs);
   for(int i=0;i<ns;i++){ if(i>0) s+=","; s+="{\"time\":\""+Iso(g_sigs[i].time)+"\",\"type\":\""+(g_sigs[i].type>0?"BUY":"SELL")+"\",\"mode\":\""+g_sigs[i].mode+"\",\"entry\":"+DoubleToString(g_sigs[i].entry,dg)+",\"sl\":"+DoubleToString(g_sigs[i].sl,dg)+",\"tp1\":"+DoubleToString(g_sigs[i].tp1,dg)+",\"tp2\":"+DoubleToString(g_sigs[i].tp2,dg)+",\"rr\":"+DoubleToString(g_sigs[i].rr,2)+"}"; }
   s+="],";

   s+="\"summary\":{\"bias\":\""+DirStr(g_htfNow!=SMC_SIDE?g_htfNow:g_ext.trend)+"\",\"last_signal\":\""+g_lastSig+"\",\"zone_count\":"+(string)nz+",\"signal_count\":"+(string)ns+"}";
   s+="}";

   string fn="smc\\"+_Symbol+"_"+TfName((ENUM_TIMEFRAMES)_Period)+".json";
   string tmp="smc\\_"+_Symbol+"_"+TfName((ENUM_TIMEFRAMES)_Period)+".tmp";
   int fh=FileOpen(tmp,FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(fh!=INVALID_HANDLE)
     {
      FileWriteString(fh,s);
      FileClose(fh);
      FileMove(tmp,FILE_COMMON,fn,FILE_COMMON|FILE_REWRITE);
     }
  }

//+------------------------------------------------------------------+
//| OnCalculate                                                      |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   if(rates_total < (InpSwingExternal*2+5)) return(rates_total);

   // recalcula somente quando uma nova barra abre (estado e no-repaint)
   datetime curBar=time[rates_total-1];
   bool newBar=(curBar!=g_lastBarTime);
   if(prev_calculated>0 && !newBar) return(rates_total);
   g_lastBarTime=curBar;

   ObjectsDeleteAll(0,PFX);
   ResetScale(g_ext);
   ResetScale(g_int);

   ArrayResize(g_tickv,rates_total); ArrayCopy(g_tickv,tick_volume);
   ArrayResize(g_realv,rates_total); ArrayCopy(g_realv,volume);

   UpdateIndicators(time,high,low,close,rates_total);

   ArrayResize(g_trendBar,rates_total);    ArrayInitialize(g_trendBar,SMC_SIDE);
   ArrayResize(g_eqBar,rates_total);       ArrayInitialize(g_eqBar,0.0);
   ArrayResize(g_intChochBar,rates_total); ArrayInitialize(g_intChochBar,0);
   ArrayResize(g_sigs,0);
   ArrayResize(g_znTop,0);ArrayResize(g_znBot,0);ArrayResize(g_znDir,0);ArrayResize(g_znCat,0);ArrayResize(g_znT1,0);
   ArrayResize(g_lqPrice,0);ArrayResize(g_lqType,0);ArrayResize(g_lqT1,0);

   ProcessScale(g_ext,InpSwingExternal,false,time,open,high,low,close,rates_total);
   if(InpShowInternal || InpSigSweepChoCH || InpSigPOIConfirm || InpSigZoneChoCh)
      ProcessScale(g_int,InpSwingInternal,true,time,open,high,low,close,rates_total);
   BuildHTFTrend(time,rates_total);
   ScanFVG(time,open,high,low,close,rates_total);
   BuildPOIFvgs(time,high,low,rates_total);
   BuildHTFOBs();
   RunSignals(time,open,high,low,close,rates_total);
   ComputeADXSeries(high,low,close,rates_total,InpADXLen);
   SigADX(time,high,low,close,rates_total);
   FillSignalBuffers(time,rates_total);
   ScanSD(time,open,high,low,close,rates_total);
   DrawPremiumDiscount(time,close,rates_total);
   DrawDayWeekLevels(time,rates_total);
   ScanEQ(time,high,low,rates_total);
   DrawSessions(time,high,low,rates_total);
   DrawHTFPois(time,rates_total);
   DrawHTFOBs(time,rates_total);
   DrawLastSignalLevels(time,rates_total);

   if(InpShowDashboard) UpdateDashboard();
   ExportJSON(time,open,high,low,close,rates_total);

   ChartRedraw(0);
   return(rates_total);
  }
//+------------------------------------------------------------------+
