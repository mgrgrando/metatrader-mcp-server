//+------------------------------------------------------------------+
//|                                                   SMC_Tester.mq5 |
//|        EstrategiaSmc - EA de backtest dos sinais do SMC_Suite    |
//|                                                                  |
//|  Le os sinais do indicador SMC_Suite (v0.96+) via IndicatorCreate|
//|  (buffers 3..8) e executa no Strategy Tester. O indicador        |
//|  continua sendo o MOTOR UNICO de SMC - este EA nao recalcula     |
//|  nada, apenas executa e gerencia.                                |
//|                                                                  |
//|  USO: anexar no TF do SINAL (curta). Ex.: intraday = grafico M5  |
//|  ou M15 com InpBiasTF=H1; swing = grafico H1 ou H4 com           |
//|  InpBiasTF=D1. Testar UM modo por passada (InpMode).             |
//|                                                                  |
//|  Buffers do SMC_Suite:                                           |
//|   3=SigType(+1/-1) 4=SigMode(1..5) 5=Entry 6=SL 7=TP1 8=TP2      |
//+------------------------------------------------------------------+
#property copyright "EstrategiaSmc"
#property version   "1.02"
// Obrigatorio: com IndicatorCreate o tester nao detecta a dependencia
// sozinho; esta property manda o SMC_Suite.ex5 junto para o agente.
#property tester_indicator "SMC_Suite.ex5"

#include <Trade\Trade.mqh>

//=== Enums (espelham o indicador) ===================================
enum ENUM_SLTP    { SLTP_STRUCT_ATR=0, SLTP_STRUCT, SLTP_ATR };
enum ENUM_SIGMODE { MODE_ZONE_CHOCH=1,   // Zona (OB pos-BOS) + toque + CHoCH
                    MODE_SWEEP_CHOCH=2,  // Sweep de liquidez + CHoCH
                    MODE_POI_CONF=3,     // POI do HTF + confirmacao interna
                    MODE_APLUS=4,        // A+ (OB HTF pos-sweep + MSS + FVG)
                    MODE_ADX_CROSS=5 };  // Cruzamento ADX/DI
enum ENUM_TPMODE  { TP_TP1=0,            // Alvo unico no TP1
                    TP_TP2=1,            // Alvo unico no TP2
                    TP_PARTIAL=2 };      // Parcial no TP1 + BE, resto ate TP2

//=== Inputs =========================================================
input group "Estrategia"
input ENUM_SIGMODE    InpMode       = MODE_APLUS;     // Modo de sinal a testar
input ENUM_TIMEFRAMES InpBiasTF     = PERIOD_H1;      // TF do vies/POIs (HTF); sinal = TF do grafico
input bool            InpUseHTFBias = true;           // Usar tendencia do HTF como vies
input bool            InpTrendOnly  = true;           // Operar so a favor da tendencia

input group "Estrutura (pass-through p/ indicador)"
input int    InpSwingExt    = 10;     // Swing externo (M5: 15-20 | M15: 10-12 | H1+: 6-8)
input int    InpSwingInt    = 5;      // Swing interno (~metade do externo)
input int    InpBarsProc    = 1500;   // Barras processadas pelo indicador
input bool   InpOBRequireImb= true;   // OB exige imbalance
input int    InpOBLookback  = 20;     // Lookback origem do OB
input int    InpFVGMinPts   = 0;      // FVG minimo (points)
input int    InpZoneMaxAge  = 300;    // Idade max de zona (barras)
input int    InpZoneTapLook = 20;     // ZONE_CHOCH: janela do toque
input int    InpSweepLook   = 10;     // SWEEP_CHOCH: janela do sweep
input int    InpHTFBars     = 500;    // Barras do HTF
input int    InpLTFBars     = 1000;   // Barras do LTF
input int    InpAPlusMSSLook= 15;     // A+: janela do MSS
input bool   InpAPlusReqSweep=true;   // A+: exigir sweep antes do OB
input int    InpADXLen      = 14;     // ADX: periodo
input int    InpADXTh       = 20;     // ADX: limiar
input int    InpATRPeriod   = 14;     // ATR (SL/TP)

input group "SL / TP"
input ENUM_SLTP   InpSLTPMode  = SLTP_STRUCT_ATR; // Modo de SL/TP
input double      InpATRBufMult= 0.5;             // Buffer SL x ATR (estrutural+ATR)
input double      InpATRSLMult = 1.5;             // SL x ATR (modo so ATR)
input double      InpTP1R      = 1.5;             // TP1 em R
input double      InpTP2R      = 3.0;             // TP2 em R
input ENUM_TPMODE InpTPMode    = TP_TP1;          // Gestao do alvo
input double      InpPartialPct= 50.0;            // % fechada no TP1 (modo parcial)
input bool        InpBEatTP1   = true;            // Mover SL p/ entrada ao tocar TP1

input group "Risco / Volume"
input bool   InpUseRiskMoney = false;  // true = volume por risco financeiro
input double InpRiskMoney    = 100.0;  // Risco por trade (moeda da conta)
input double InpFixedLots    = 1.0;    // Volume fixo (contratos)
input double InpDailyLoss    = 0.0;    // Perda maxima diaria em moeda (0 = sem limite)
input int    InpMaxTradesDay = 0;      // Max trades por dia (0 = sem limite)

input group "Janela de operacao (hora do servidor)"
input bool InpUseWindow   = true;   // Filtrar horario de entrada
input int  InpStartHour   = 9;     // Inicio - hora
input int  InpStartMin    = 15;    // Inicio - minuto
input int  InpEndHour     = 16;    // Fim de ENTRADAS - hora
input int  InpEndMin      = 30;    // Fim de ENTRADAS - minuto
input bool InpUseEODClose = true;  // Fechar posicoes no fim do dia
input int  InpEODHour     = 17;    // EOD - hora
input int  InpEODMin      = 45;    // EOD - minuto

input group "Execucao"
input bool   InpCloseOnOpposite = true;   // Fechar posicao em sinal contrario
input ulong  InpMagic           = 260611; // Magic number
input int    InpDeviationPts    = 50;     // Desvio maximo (points)
input string InpIndName = "SMC_Suite";    // Caminho do indicador (relativo a MQL5\Indicators)

//=== Globais ========================================================
CTrade   g_trade;
int      g_hSMC = INVALID_HANDLE;
datetime g_lastBar     = 0;
datetime g_lastSigTime = 0;
int      g_curDay      = -1;
int      g_tradesToday = 0;
bool     g_blockedToday= false;
double   g_dayStartEq  = 0.0;
double   g_tp1Level    = 0.0;
bool     g_partialDone = false;
// --- diagnostico
bool     g_scanned     = false;
int      g_cntSig=0, g_cntOpen=0, g_cntFail=0, g_cntWindow=0,
         g_cntMaxTrd=0, g_cntSLSide=0, g_cntTPSide=0, g_cntLots=0, g_cntPos=0;

//+------------------------------------------------------------------+
//| Preenchimento de MqlParam (IndicatorCreate aceita ate 256 params;|
//| uma chamada iCustom estoura o limite de 64 argumentos do MQL5)   |
//+------------------------------------------------------------------+
void PB(MqlParam &q,const bool v)   { q.type=TYPE_BOOL;   q.integer_value=(v?1:0); }
void PI(MqlParam &q,const long v)   { q.type=TYPE_INT;    q.integer_value=v;       }
void PD(MqlParam &q,const double v) { q.type=TYPE_DOUBLE; q.double_value =v;       }
void PC(MqlParam &q,const color v)  { q.type=TYPE_COLOR;  q.integer_value=v;       }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpDeviationPts);
   long fill=SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
   if((fill & SYMBOL_FILLING_FOK)!=0)      g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fill & SYMBOL_FILLING_IOC)!=0) g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else                                    g_trade.SetTypeFilling(ORDER_FILLING_RETURN);

   // Bloco EA do SMC_Suite v0.96+: nome + os 31 PRIMEIROS inputs do
   // indicador, na ordem exata. Os demais inputs assumem default.
   // (MT5 limita IndicatorCreate/iCustom a 64 parametros.)
   MqlParam p[32];
   int i=0;
   p[i].type=TYPE_STRING; p[i].string_value=InpIndName; i++;   // nome do indicador
   PI(p[i++],InpSwingExt);                  //  1 InpSwingExternal
   PI(p[i++],InpSwingInt);                  //  2 InpSwingInternal
   PI(p[i++],InpBarsProc);                  //  3 InpBarsToProcess
   PB(p[i++],InpMode==MODE_ZONE_CHOCH);     //  4 InpSigZoneChoCh
   PI(p[i++],InpZoneTapLook);               //  5 InpZoneTapLook
   PB(p[i++],InpTrendOnly);                 //  6 InpSigTrendOnly
   PB(p[i++],InpMode==MODE_SWEEP_CHOCH);    //  7 InpSigSweepChoCH
   PI(p[i++],InpSweepLook);                 //  8 InpSweepLook
   PI(p[i++],InpSLTPMode);                  //  9 InpSLTPMode
   PD(p[i++],InpATRBufMult);                // 10 InpATRBufferMult
   PD(p[i++],InpATRSLMult);                 // 11 InpATRSLMult
   PD(p[i++],InpTP1R);                      // 12 InpTP1R
   PD(p[i++],InpTP2R);                      // 13 InpTP2R
   PB(p[i++],InpMode==MODE_POI_CONF);       // 14 InpSigPOIConfirm
   PI(p[i++],InpBiasTF);                    // 15 InpHTF (TF do POI / vies)
   PI(p[i++],InpHTFBars);                   // 16 InpHTFBars
   PB(p[i++],InpUseHTFBias);                // 17 InpSigUseHTFBias
   PI(p[i++],PERIOD_CURRENT);               // 18 InpLTF = TF do grafico do EA
   PI(p[i++],InpLTFBars);                   // 19 InpLTFBars
   PB(p[i++],InpMode==MODE_APLUS);          // 20 InpSigAPlus
   PI(p[i++],InpAPlusMSSLook);              // 21 InpAPlusMSSLook
   PB(p[i++],InpAPlusReqSweep);             // 22 InpAPlusReqSweep
   PB(p[i++],InpMode==MODE_ADX_CROSS);      // 23 InpSigADX
   PI(p[i++],InpADXLen);                    // 24 InpADXLen
   PI(p[i++],InpADXTh);                     // 25 InpADXTh
   PI(p[i++],InpATRPeriod);                 // 26 InpATRPeriod
   PB(p[i++],InpOBRequireImb);              // 27 InpOBRequireImb
   PI(p[i++],InpOBLookback);                // 28 InpOBLookback
   PI(p[i++],InpFVGMinPts);                 // 29 InpFVGMinPts
   PI(p[i++],InpZoneMaxAge);                // 30 InpZoneMaxAgeBars
   PB(p[i++],false);                        // 31 InpExportJSON (off no tester)

   if(i!=32)
     {
      Print("SMC_Tester: contagem de parametros inesperada: ",i," (esperado 32).");
      return(INIT_FAILED);
     }
   g_hSMC=IndicatorCreate(_Symbol,_Period,IND_CUSTOM,i,p);

   if(g_hSMC==INVALID_HANDLE)
     {
      Print("SMC_Tester: falha ao criar handle de '",InpIndName,
            "'. GetLastError=",GetLastError(),
            ". Confira: SMC_Suite.ex5 v0.96+ compilado em MQL5\\Indicators deste terminal.");
      return(INIT_FAILED);
     }
   if(InpTPMode==TP_PARTIAL && (InpPartialPct<=0.0 || InpPartialPct>=100.0))
     {
      Print("SMC_Tester: InpPartialPct deve estar entre 0 e 100.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   Print("SMC_Tester resumo: sinais=",g_cntSig,
         " abertos=",g_cntOpen," falhaOrdem=",g_cntFail,
         " bloq[janela/EOD]=",g_cntWindow," bloq[maxDia]=",g_cntMaxTrd,
         " bloq[posicao]=",g_cntPos," desc[SL lado/minDist]=",g_cntSLSide,
         " desc[TP lado]=",g_cntTPSide," desc[volume]=",g_cntLots);
   if(g_hSMC!=INVALID_HANDLE) IndicatorRelease(g_hSMC);
  }

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
bool NewBar()
  {
   datetime t=iTime(_Symbol,_Period,0);
   if(t==g_lastBar) return(false);
   g_lastBar=t;
   return(true);
  }

void ResetDailyIfNeeded()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   if(dt.day_of_year!=g_curDay)
     {
      g_curDay=dt.day_of_year;
      g_tradesToday=0;
      g_blockedToday=false;
      g_dayStartEq=AccountInfoDouble(ACCOUNT_EQUITY);
     }
  }

bool InEntryWindow()
  {
   if(!InpUseWindow) return(true);
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   int now=dt.hour*60+dt.min;
   return(now>=InpStartHour*60+InpStartMin && now<=InpEndHour*60+InpEndMin);
  }

bool PastEOD()
  {
   if(!InpUseEODClose) return(false);
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   return(dt.hour*60+dt.min >= InpEODHour*60+InpEODMin);
  }

bool MyPosition()
  {
   if(!PositionSelect(_Symbol)) return(false);
   return((ulong)PositionGetInteger(POSITION_MAGIC)==InpMagic);
  }

double NormalizeLots(double lots)
  {
   double minL =SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxL =SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step =SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0.0) step=minL;
   lots=MathFloor(lots/step)*step;
   if(lots<minL) lots=0.0;          // abaixo do minimo: nao opera
   if(lots>maxL) lots=maxL;
   return(lots);
  }

double CalcLots(double entry,double sl)
  {
   if(!InpUseRiskMoney) return(NormalizeLots(InpFixedLots));
   double dist=MathAbs(entry-sl);
   if(dist<=0.0) return(0.0);
   double tickSize =SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tickValue=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   if(tickSize<=0.0 || tickValue<=0.0) return(0.0);
   double moneyPerLot=dist/tickSize*tickValue;   // risco por 1 lote
   if(moneyPerLot<=0.0) return(0.0);
   return(NormalizeLots(InpRiskMoney/moneyPerLot));
  }

bool ReadSignal(int shift,double &typ,double &mode,double &entry,double &sl,double &tp1,double &tp2)
  {
   double b[1];
   if(CopyBuffer(g_hSMC,3,shift,1,b)<1) return(false); typ  =b[0];
   if(CopyBuffer(g_hSMC,4,shift,1,b)<1) return(false); mode =b[0];
   if(CopyBuffer(g_hSMC,5,shift,1,b)<1) return(false); entry=b[0];
   if(CopyBuffer(g_hSMC,6,shift,1,b)<1) return(false); sl   =b[0];
   if(CopyBuffer(g_hSMC,7,shift,1,b)<1) return(false); tp1  =b[0];
   if(CopyBuffer(g_hSMC,8,shift,1,b)<1) return(false); tp2  =b[0];
   return(true);
  }

//+------------------------------------------------------------------+
//| Gestao da posicao aberta (BE, parcial, EOD, perda diaria)        |
//+------------------------------------------------------------------+
void ManageOpen()
  {
   // limite de perda diaria
   if(InpDailyLoss>0.0 && !g_blockedToday)
     {
      if(AccountInfoDouble(ACCOUNT_EQUITY)-g_dayStartEq <= -InpDailyLoss)
        {
         g_blockedToday=true;
         if(MyPosition()) g_trade.PositionClose(_Symbol);
         return;
        }
     }
   if(!MyPosition()){ g_tp1Level=0.0; g_partialDone=false; return; }

   // fechamento EOD
   if(PastEOD()){ g_trade.PositionClose(_Symbol); return; }

   long   ptype=PositionGetInteger(POSITION_TYPE);
   double entry=PositionGetDouble(POSITION_PRICE_OPEN);
   double sl   =PositionGetDouble(POSITION_SL);
   double tp   =PositionGetDouble(POSITION_TP);
   double vol  =PositionGetDouble(POSITION_VOLUME);
   double bid  =SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask  =SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   bool   isBuy=(ptype==POSITION_TYPE_BUY);

   if(g_tp1Level<=0.0) return;
   bool hitTP1=(isBuy ? bid>=g_tp1Level : ask<=g_tp1Level);
   if(!hitTP1) return;

   // parcial no TP1
   if(InpTPMode==TP_PARTIAL && !g_partialDone)
     {
      double minL =SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
      double step =SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
      double part =NormalizeLots(vol*InpPartialPct/100.0);
      if(part>=minL && (vol-part)>=minL)
         g_trade.PositionClosePartial(_Symbol,part);
      g_partialDone=true;   // mesmo se volume nao permitir, nao tenta de novo
     }

   // breakeven no TP1
   if(InpBEatTP1)
     {
      bool needBE=(isBuy ? sl<entry : (sl>entry || sl==0.0));
      if(needBE && MyPosition())
        {
         double newSL=NormalizeDouble(entry,_Digits);
         double curTP=PositionGetDouble(POSITION_TP);
         g_trade.PositionModify(_Symbol,newSL,curTP);
        }
     }
   g_tp1Level=0.0;  // gestao do TP1 concluida
  }

//+------------------------------------------------------------------+
//| Abertura                                                         |
//+------------------------------------------------------------------+
void TryOpen(double typ,double sl,double tp1,double tp2)
  {
   bool isBuy=(typ>0.0);
   double price=(isBuy ? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                       : SymbolInfoDouble(_Symbol,SYMBOL_BID));

   // SL precisa estar do lado certo do preco de mercado
   if(isBuy  && sl>=price) return;
   if(!isBuy && sl<=price) return;

   // distancia minima de stops do simbolo
   double minDist=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   if(MathAbs(price-sl)<minDist) return;

   double tp=(InpTPMode==TP_TP1 ? tp1 : tp2);
   if(isBuy  && tp<=price) return;
   if(!isBuy && tp>=price) return;

   double lots=CalcLots(price,sl);
   if(lots<=0.0) return;

   sl=NormalizeDouble(sl,_Digits);
   tp=NormalizeDouble(tp,_Digits);

   bool ok=(isBuy ? g_trade.Buy (lots,_Symbol,0.0,sl,tp,"SMC "+EnumToString(InpMode))
                  : g_trade.Sell(lots,_Symbol,0.0,sl,tp,"SMC "+EnumToString(InpMode)));
   if(ok)
     {
      g_tradesToday++;
      g_tp1Level=((InpTPMode==TP_PARTIAL||InpBEatTP1) ? tp1 : 0.0);
      g_partialDone=false;
     }
  }

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
  {
   ResetDailyIfNeeded();
   ManageOpen();

   if(!NewBar()) return;
   if(g_blockedToday || PastEOD() || !InEntryWindow()) return;
   if(InpMaxTradesDay>0 && g_tradesToday>=InpMaxTradesDay) return;

   // sinal na ultima barra FECHADA (shift=1) - no-repaint
   double typ,mode,entry,sl,tp1,tp2;
   if(!ReadSignal(1,typ,mode,entry,sl,tp1,tp2)) return;
   if(typ==0.0) return;

   datetime sigTime=iTime(_Symbol,_Period,1);
   if(sigTime==g_lastSigTime) return;   // ja processado
   g_lastSigTime=sigTime;

   if(MyPosition())
     {
      long ptype=PositionGetInteger(POSITION_TYPE);
      bool opposite=((typ>0.0 && ptype==POSITION_TYPE_SELL) ||
                     (typ<0.0 && ptype==POSITION_TYPE_BUY));
      if(opposite && InpCloseOnOpposite) g_trade.PositionClose(_Symbol);
      else return;                       // ja posicionado a favor: ignora
     }

   TryOpen(typ,sl,tp1,tp2);
  }
//+------------------------------------------------------------------+
