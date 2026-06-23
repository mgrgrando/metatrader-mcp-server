//+------------------------------------------------------------------+
//|                                            SMC_LLM_Tester.mq5   |
//|  EA de backtest que delega a decisao ao LLM via ponte FastAPI.   |
//|                                                                  |
//|  Pre-requisitos:                                                  |
//|   1) restmql_x64.dll em MQL5\Libraries\                         |
//|   2) Strategy Tester: marcar "Allow DLL imports"                 |
//|   3) Bridge rodando em InpBridgeURL (ex.: 192.168.100.55:8000)  |
//+------------------------------------------------------------------+
#property copyright "EstrategiaSmc"
#property version   "1.00"

#import "restmql_x64.dll"
   string PostJson(string url, string jsonBody, string headers, int timeoutSeconds);
#import

#include <Trade\Trade.mqh>

//=== Inputs =========================================================
input group "Bridge LLM"
input string          InpBridgeURL     = "http://192.168.100.55:8000/decide";
input int             InpBridgeTimeout = 60;    // timeout da chamada (segundos)
input string          InpOnTimeout     = "HOLD"; // HOLD | INVALIDATE

input group "Contexto de mercado"
input ENUM_TIMEFRAMES InpBiasTF   = PERIOD_H1; // TF do vies (HTF p/ DI bias)
input int             InpLookback = 50;          // barras p/ calcular range premium/discount
input int             InpADXLen   = 14;
input int             InpATRLen   = 14;
input int             InpWPRLen   = 14;

input group "Simbolo"
input string InpSymbolName  = "WINQ26"; // nome no payload (troca com rollover)
input string InpInstrument  = "WIN";    // raiz (WIN, DOL, etc.)

input group "Risco / Volume"
input double InpFixedLots = 1.0;

input group "Janela de operacao"
input bool InpUseWindow   = true;
input int  InpStartHour   = 9;
input int  InpStartMin    = 15;
input int  InpEndHour     = 16;
input int  InpEndMin      = 45;
input bool InpUseEODClose = true;
input int  InpEODHour     = 17;
input int  InpEODMin      = 50;

input group "Execucao"
input ulong InpMagic        = 260613;
input int   InpDeviationPts = 50;

//=== Globais ========================================================
CTrade   g_trade;
int      g_hADX_LTF = INVALID_HANDLE;
int      g_hADX_HTF = INVALID_HANDLE;
int      g_hATR     = INVALID_HANDLE;
int      g_hWPR     = INVALID_HANDLE;
datetime g_lastBar  = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpDeviationPts);
   long fill = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fill & SYMBOL_FILLING_FOK) != 0)      g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fill & SYMBOL_FILLING_IOC) != 0) g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else                                       g_trade.SetTypeFilling(ORDER_FILLING_RETURN);

   g_hADX_LTF = iADX(_Symbol, _Period,   InpADXLen);
   g_hADX_HTF = iADX(_Symbol, InpBiasTF, InpADXLen);
   g_hATR     = iATR(_Symbol, _Period,   InpATRLen);
   g_hWPR     = iWPR(_Symbol, _Period,   InpWPRLen);

   if(g_hADX_LTF == INVALID_HANDLE || g_hADX_HTF == INVALID_HANDLE ||
      g_hATR     == INVALID_HANDLE || g_hWPR     == INVALID_HANDLE)
     {
      Print("SMC_LLM_Tester: falha ao criar handles de indicadores.");
      return INIT_FAILED;
     }
   Print("SMC_LLM_Tester iniciado. Bridge=", InpBridgeURL);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   IndicatorRelease(g_hADX_LTF);
   IndicatorRelease(g_hADX_HTF);
   IndicatorRelease(g_hATR);
   IndicatorRelease(g_hWPR);
  }

//=== Helpers ========================================================
bool NewBar()
  {
   datetime t = iTime(_Symbol, _Period, 0);
   if(t == g_lastBar) return false;
   g_lastBar = t;
   return true;
  }

bool InEntryWindow()
  {
   if(!InpUseWindow) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int now = dt.hour * 60 + dt.min;
   return now >= InpStartHour*60+InpStartMin && now <= InpEndHour*60+InpEndMin;
  }

bool PastEOD()
  {
   if(!InpUseEODClose) return false;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   return dt.hour*60+dt.min >= InpEODHour*60+InpEODMin;
  }

bool MyPosition()
  {
   if(!PositionSelect(_Symbol)) return false;
   return (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic;
  }

string TF2Str(ENUM_TIMEFRAMES tf)
  {
   switch(tf)
     {
      case PERIOD_M1:  return "M1";
      case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      case PERIOD_H4:  return "H4";
      case PERIOD_D1:  return "D1";
      default:         return "UNKNOWN";
     }
  }

//=== Coleta indicadores e monta JSON ================================
string BuildContext()
  {
   // --- ADX/DI no LTF (barras 1 e 2: fechadas, sem look-ahead) ---
   double adxLTF[2], diPLTF[2], diMLTF[2];
   if(CopyBuffer(g_hADX_LTF, 0, 1, 2, adxLTF) < 2) return "";
   if(CopyBuffer(g_hADX_LTF, 1, 1, 2, diPLTF) < 2) return "";
   if(CopyBuffer(g_hADX_LTF, 2, 1, 2, diMLTF) < 2) return "";
   // [0]=barra mais antiga, [1]=barra fechada mais recente
   double adx      = adxLTF[1];
   double adx_prev = adxLTF[0];
   double diP      = diPLTF[1];
   double diM      = diMLTF[1];

   // --- ATR ---
   double atrBuf[1];
   if(CopyBuffer(g_hATR, 0, 1, 1, atrBuf) < 1) return "";
   double atr = atrBuf[0] / _Point;  // em points

   // --- Williams %R ---
   double wprBuf[1];
   if(CopyBuffer(g_hWPR, 0, 1, 1, wprBuf) < 1) return "";
   double wpr = wprBuf[0];

   // --- ADX/DI no HTF (bias) ---
   double adxHTF[1], diPHTF[1], diMHTF[1];
   if(CopyBuffer(g_hADX_HTF, 0, 1, 1, adxHTF) < 1) return "";
   if(CopyBuffer(g_hADX_HTF, 1, 1, 1, diPHTF) < 1) return "";
   if(CopyBuffer(g_hADX_HTF, 2, 1, 1, diMHTF) < 1) return "";
   string htf_bias    = (diPHTF[0] > diMHTF[0]) ? "bullish" : "bearish";
   string trend_major = htf_bias;
   string trend_minor = (diP > diM) ? "bullish" : "bearish";

   // --- Range premium/discount (ultimas InpLookback barras fechadas) ---
   int highIdx = iHighest(_Symbol, _Period, MODE_HIGH, InpLookback, 1);
   int lowIdx  = iLowest (_Symbol, _Period, MODE_LOW,  InpLookback, 1);
   double rangeHigh = iHigh(_Symbol, _Period, highIdx);
   double rangeLow  = iLow (_Symbol, _Period, lowIdx);
   double equil     = (rangeHigh + rangeLow) / 2.0;
   double close1    = iClose(_Symbol, _Period, 1);
   string zone      = (close1 > equil) ? "PREMIUM" : "DISCOUNT";

   // --- Precos atuais ---
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // --- Conta ---
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

   // --- Posicao ---
   string posDir  = "none";
   double posVol  = 0, posSL = 0, posTP = 0, posOpen = 0;
   long   posId   = 0;
   if(MyPosition())
     {
      long ptype = PositionGetInteger(POSITION_TYPE);
      posDir  = (ptype == POSITION_TYPE_BUY) ? "buy" : "sell";
      posVol  = PositionGetDouble(POSITION_VOLUME);
      posSL   = PositionGetDouble(POSITION_SL);
      posTP   = PositionGetDouble(POSITION_TP);
      posId   = (long)PositionGetInteger(POSITION_IDENTIFIER);
      posOpen = PositionGetDouble(POSITION_PRICE_OPEN);
     }

   // --- Timestamp da barra fechada (server_time) ---
   datetime t = iTime(_Symbol, _Period, 1);
   MqlDateTime mdt; TimeToStruct(t, mdt);
   string ts = StringFormat("%04d-%02d-%02dT%02d:%02d:%02d",
                            mdt.year, mdt.mon, mdt.day,
                            mdt.hour, mdt.min, mdt.sec);

   // --- Monta JSON ---
   string j = "{";
   j += "\"symbol\":\""     + InpSymbolName + "\",";
   j += "\"instrument\":\"" + InpInstrument + "\",";
   j += "\"server_time\":\"" + ts + "\",";
   j += "\"tf_signal\":\""  + TF2Str(_Period) + "\",";
   j += "\"snapshot\":{";
     j += "\"price\":{";
       j += "\"bid\":"        + DoubleToString(bid,   0) + ",";
       j += "\"ask\":"        + DoubleToString(ask,   0) + ",";
       j += "\"last_close\":" + DoubleToString(close1,0);
     j += "},";
     j += "\"trend\":{";
       j += "\"major\":\"" + trend_major + "\",";
       j += "\"minor\":\"" + trend_minor + "\"";
     j += "},";
     j += "\"premium_discount\":{";
       j += "\"range_high\":"  + DoubleToString(rangeHigh, 0) + ",";
       j += "\"range_low\":"   + DoubleToString(rangeLow,  0) + ",";
       j += "\"equilibrium\":" + DoubleToString(equil,     0) + ",";
       j += "\"current_zone\":\"" + zone + "\"";
     j += "},";
     j += "\"indicators\":{";
       j += "\"atr\":"      + DoubleToString(atr,      1) + ",";
       j += "\"adx\":"      + DoubleToString(adx,      1) + ",";
       j += "\"adx_prev\":" + DoubleToString(adx_prev, 1) + ",";
       j += "\"di_plus\":"  + DoubleToString(diP,      1) + ",";
       j += "\"di_minus\":" + DoubleToString(diM,      1) + ",";
       j += "\"wpr\":"      + DoubleToString(wpr,      1);
     j += "},";
     j += "\"zones\":[]";
   j += "},";
   j += "\"htf_bias\":\"" + htf_bias + "\",";
   j += "\"account\":{";
     j += "\"balance\":" + DoubleToString(balance, 2) + ",";
     j += "\"equity\":"  + DoubleToString(equity,  2);
   j += "},";
   j += "\"position\":{";
     j += "\"dir\":\""  + posDir + "\",";
     j += "\"volume\":" + DoubleToString(posVol,  2) + ",";
     j += "\"open\":"   + DoubleToString(posOpen, 0) + ",";
     j += "\"sl\":"     + DoubleToString(posSL,   0) + ",";
     j += "\"tp\":"     + DoubleToString(posTP,   0) + ",";
     j += "\"id\":"     + IntegerToString(posId);
   j += "}";
   j += "}";
   return j;
  }

//=== Parser minimo de JSON ==========================================
string ParseStr(const string json, const string key)
  {
   string srch = "\"" + key + "\":\"";
   int p = StringFind(json, srch);
   if(p < 0) return "";
   int start = p + StringLen(srch);
   int end   = StringFind(json, "\"", start);
   if(end < 0) return "";
   return StringSubstr(json, start, end - start);
  }

double ParseNum(const string json, const string key)
  {
   string srch = "\"" + key + "\":";
   int p = StringFind(json, srch);
   if(p < 0) return 0.0;
   int start = p + StringLen(srch);
   int end   = start;
   while(end < StringLen(json) && json[end] != ',' && json[end] != '}') end++;
   return StringToDouble(StringSubstr(json, start, end - start));
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(!NewBar()) return;

   // EOD: fechar posicao e nao mais entrar
   if(PastEOD())
     {
      if(MyPosition()) g_trade.PositionClose(_Symbol);
      return;
     }

   // Coleta contexto
   string ctx = BuildContext();
   if(ctx == "")
     {
      Print("SMC_LLM_Tester: BuildContext falhou (indicadores ainda nao prontos)");
      return;
     }

   // Chama bridge (sincrono via DLL)
   string resp = PostJson(InpBridgeURL, ctx, "", InpBridgeTimeout);

   if(StringFind(resp, "ERROR:") == 0 || resp == "")
     {
      Print("SMC_LLM_Tester: bridge error [", resp, "] -> ", InpOnTimeout);
      // InpOnTimeout == "HOLD": nao faz nada (mantem posicao)
      return;
     }

   string action  = ParseStr(resp, "action");
   double sl      = ParseNum(resp, "sl");
   double tp      = ParseNum(resp, "tp");
   long   closeId = (long)ParseNum(resp, "close_id");

   PrintFormat("LLM bar=%s action=%s sl=%.0f tp=%.0f",
               TimeToString(iTime(_Symbol,_Period,1)), action, sl, tp);

   if(action == "BUY")
     {
      if(MyPosition()) g_trade.PositionClose(_Symbol);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(sl > 0 && sl < ask && tp > ask)
         g_trade.Buy(InpFixedLots, _Symbol, 0.0,
                     NormalizeDouble(sl, _Digits),
                     NormalizeDouble(tp, _Digits), "LLM-BUY");
     }
   else if(action == "SELL")
     {
      if(MyPosition()) g_trade.PositionClose(_Symbol);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(sl > 0 && sl > bid && tp < bid)
         g_trade.Sell(InpFixedLots, _Symbol, 0.0,
                      NormalizeDouble(sl, _Digits),
                      NormalizeDouble(tp, _Digits), "LLM-SELL");
     }
   else if(action == "CLOSE")
     {
      if(MyPosition()) g_trade.PositionClose(_Symbol);
     }
   // HOLD: nao faz nada
  }
//+------------------------------------------------------------------+
