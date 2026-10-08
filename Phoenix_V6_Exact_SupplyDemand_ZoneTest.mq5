//+------------------------------------------------------------------+
//| Phoenix V6 - Exact Supply/Demand Zone Test                       |
//| Zone logic ported from DIY Custom Strategy Builder [ZP] - v1     |
//| Research build: zone detection first, neutral trade harness.    |
//+------------------------------------------------------------------+
#property strict
#property version   "1.000"
#property description "Phoenix V6 research build - exact Supply/Demand zone engine."
#property description "Ported from the supplied Pine Script zone module."
#property description "No Leading/Confirmation indicators are included in this sprint."

#include <Trade/Trade.mqh>
CTrade trade;

//--- Exact zone settings from supplied Pine module
input ENUM_TIMEFRAMES InpZoneTF       = PERIOD_M15;
input int             InpSwingLength  = 10;
input int             InpHistoryKeep  = 20;
input double          InpBoxWidth     = 2.5;
input int             InpATRPeriod    = 50;
input int             InpLookbackBars = 1500;

//--- Neutral research trade harness (NOT part of the indicator's zone logic)
input ENUM_TIMEFRAMES InpEntryTF      = PERIOD_M15;
input double          InpFixedLot     = 0.01;
input double          InpSL_ATR_Mult  = 0.25;
input double          InpRiskReward   = 2.00;
input double          InpMaxSpread    = 1.50;
input double          InpDailyLossLimit = 0.0; // disabled for pure zone research
input bool            InpFirstTouchOnly = true;
input bool            InpShowZones    = true;
input bool            InpShowReasons  = true;
input ulong            InpMagic       = 61001;
input int              InpDeviationPts= 30;

struct Zone
{
   bool     valid;
   bool     demand;
   datetime created;
   double   top;
   double   bottom;
   double   poi;
   bool     traded;
};

Zone g_supply[];
Zone g_demand[];
datetime g_last_zone_bar=0;
datetime g_last_entry_bar=0;
double g_day_start_equity=0.0;
int g_day_key=-1;
int g_atr_handle=INVALID_HANDLE;
string PREFIX="PHX6_SD_";

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPts);
   trade.SetTypeFillingBySymbol(_Symbol);

   ArrayResize(g_supply,InpHistoryKeep);
   ArrayResize(g_demand,InpHistoryKeep);
   ClearZones(g_supply);
   ClearZones(g_demand);

   g_atr_handle=iATR(_Symbol,InpZoneTF,InpATRPeriod);
   if(g_atr_handle==INVALID_HANDLE)
      return INIT_FAILED;

   ResetDailyEquityIfNeeded();
   Print("PHX6 Exact S/D initialized | TF=",EnumToString(InpZoneTF),
         " swing=",InpSwingLength," history=",InpHistoryKeep,
         " width=",DoubleToString(InpBoxWidth,1)," ATR=",InpATRPeriod);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_atr_handle!=INVALID_HANDLE) IndicatorRelease(g_atr_handle);
   DeleteObjectsByPrefix(PREFIX);
}

//+------------------------------------------------------------------+
void OnTick()
{
   ResetDailyEquityIfNeeded();
   if(!IsNewZoneBar()) return;

   UpdateZonesExact();
   if(InpShowZones) DrawAllZones();

   if(InpEntryTF!=InpZoneTF) return;
   if(!IsNewEntryBar()) return;
   EvaluateZoneTouch();
}

//+------------------------------------------------------------------+
//| Exact port of the supplied Pine zone construction.               |
//| Pine: pivot high/low = 10 left + 10 right bars.                  |
//| The pivot becomes known only after the right-side 10 bars close.  |
//| Supply: top = pivot high; bottom = top - ATR(50)*2.5/10.         |
//| Demand: bottom = pivot low; top = bottom + ATR(50)*2.5/10.       |
//| New zone is rejected when its POI is within 2*ATR of an existing |
//| same-side zone POI. Oldest zone is removed when history is full.  |
//+------------------------------------------------------------------+
void UpdateZonesExact()
{
   MqlRates r[]; ArraySetAsSeries(r,true);
   int need=MathMax(InpLookbackBars,InpSwingLength*2+InpATRPeriod+20);
   if(CopyRates(_Symbol,InpZoneTF,0,need,r)<need) return;

   double atr=GetATR();
   if(atr<=0) return;

   // Process the newly confirmed pivot at shift = swing length.
   int s=InpSwingLength;
   if(s+InpSwingLength>=ArraySize(r)) return;

   if(IsPivotHighExact(r,s,InpSwingLength))
      AddExactZone(false,r[s].high,r[s].time,atr);

   if(IsPivotLowExact(r,s,InpSwingLength))
      AddExactZone(true,r[s].low,r[s].time,atr);

   // Exact Pine BOS behavior: close beyond the outer zone boundary invalidates it.
   for(int i=0;i<ArraySize(g_supply);i++)
   {
      if(!g_supply[i].valid) continue;
      if(r[1].close>=g_supply[i].top)
         g_supply[i].valid=false;
   }
   for(int i=0;i<ArraySize(g_demand);i++)
   {
      if(!g_demand[i].valid) continue;
      if(r[1].close<=g_demand[i].bottom)
         g_demand[i].valid=false;
   }
}

bool IsPivotHighExact(const MqlRates &r[],int s,int len)
{
   double h=r[s].high;
   for(int i=1;i<=len;i++)
   {
      if(r[s-i].high>=h) return false;
      if(r[s+i].high>h) return false;
   }
   return true;
}

bool IsPivotLowExact(const MqlRates &r[],int s,int len)
{
   double l=r[s].low;
   for(int i=1;i<=len;i++)
   {
      if(r[s-i].low<=l) return false;
      if(r[s+i].low<l) return false;
   }
   return true;
}

void AddExactZone(bool demand,double level,datetime created,double atr)
{
   double buffer=atr*(InpBoxWidth/10.0); // exact Pine formula: ATR * 2.5/10
   Zone z;
   z.valid=true;
   z.demand=demand;
   z.created=created;
   z.traded=false;

   if(demand)
   {
      z.bottom=level;
      z.top=level+buffer;
   }
   else
   {
      z.top=level;
      z.bottom=level-buffer;
   }
   z.poi=(z.top+z.bottom)/2.0;

   if(!OkayToDraw(z.poi,demand,atr)) return;

   if(demand) PushZone(g_demand,z);
   else       PushZone(g_supply,z);
}

bool OkayToDraw(double new_poi,bool demand,double atr)
{
   double threshold=atr*2.0; // exact Pine overlap threshold
   for(int i=0;i<ArraySize(arr);i++)
   {
      if(demand) {
         if(!g_demand[i].valid) continue;
         if(new_poi >= g_demand[i].poi-threshold && new_poi <= g_demand[i].poi+threshold) return false;
      } else {
         if(!g_supply[i].valid) continue;
         if(new_poi >= g_supply[i].poi-threshold && new_poi <= g_supply[i].poi+threshold) return false;
      }
   }
   return true;
}

void PushZone(Zone &arr[],Zone &z)
{
   int n=ArraySize(arr);
   if(n<=0) return;
   for(int i=n-1;i>=1;i--) arr[i]=arr[i-1];
   arr[0]=z;
}

void ClearZones(Zone &arr[])
{
   for(int i=0;i<ArraySize(arr);i++)
   {
      arr[i].valid=false;
      arr[i].traded=false;
      arr[i].created=0;
      arr[i].top=0;
      arr[i].bottom=0;
      arr[i].poi=0;
   }
}

//+------------------------------------------------------------------+
//| Neutral test harness: touch of a live zone = trade.              |
//| This is deliberately separated from the indicator's zone logic. |
//+------------------------------------------------------------------+
void EvaluateZoneTouch()
{
   MqlRates e[]; ArraySetAsSeries(e,true);
   if(CopyRates(_Symbol,InpEntryTF,0,5,e)<5) return;
   if(e[1].time==g_last_entry_bar) return;
   g_last_entry_bar=e[1].time;

   if(HasOpenPosition()) return;
   if(InpMaxSpread>0)
   {
      double spread=SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID);
      if(spread>InpMaxSpread) return;
   }
   if(!TradingAllowed()) return;

   int idx=-1;
   bool demand=false;
   if(FindTouchedZone(g_demand,e[1],idx)) demand=true;
   else if(FindTouchedZone(g_supply,e[1],idx)) demand=false;
   else return;

   Zone z=demand?g_demand[idx]:g_supply[idx];
   if(InpFirstTouchOnly && z.traded) return;

   if(demand) OpenBuy(e[1],idx);
   else OpenSell(e[1],idx);
}

bool FindTouchedZone(Zone &arr[],const MqlRates &c,int &idx)
{
   idx=-1;
   for(int i=0;i<ArraySize(arr);i++)
   {
      if(!arr[i].valid) continue;
      if(c.high>=arr[i].bottom && c.low<=arr[i].top)
      {
         idx=i;
         return true;
      }
   }
   return false;
}

void OpenBuy(const MqlRates &signal,int idx)
{
   Zone z=g_demand[idx];
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double atr=GetATR(); if(atr<=0) return;
   double sl=z.bottom-atr*InpSL_ATR_Mult;
   double risk=ask-sl; if(risk<=0) return;
   double tp=ask+risk*InpRiskReward;
   sl=NormalizeDouble(sl,_Digits); tp=NormalizeDouble(tp,_Digits);
   if(!StopsAreValid(ORDER_TYPE_BUY,ask,sl,tp)) return;
   double lot=NormalizeLot(InpFixedLot);
   if(trade.Buy(lot,_Symbol,0.0,sl,tp,"PHX6-EXACT-SD-Demand-BUY"))
   {
      g_demand[idx].traded=true;
      DrawTrade(true,signal.time,ask,sl,tp,z);
   }
}

void OpenSell(const MqlRates &signal,int idx)
{
   Zone z=g_supply[idx];
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double atr=GetATR(); if(atr<=0) return;
   double sl=z.top+atr*InpSL_ATR_Mult;
   double risk=sl-bid; if(risk<=0) return;
   double tp=bid-risk*InpRiskReward;
   sl=NormalizeDouble(sl,_Digits); tp=NormalizeDouble(tp,_Digits);
   if(!StopsAreValid(ORDER_TYPE_SELL,bid,sl,tp)) return;
   double lot=NormalizeLot(InpFixedLot);
   if(trade.Sell(lot,_Symbol,0.0,sl,tp,"PHX6-EXACT-SD-Supply-SELL"))
   {
      g_supply[idx].traded=true;
      DrawTrade(false,signal.time,bid,sl,tp,z);
   }
}

//+------------------------------------------------------------------+
double GetATR()
{
   double b[]; ArraySetAsSeries(b,true);
   if(g_atr_handle==INVALID_HANDLE) return 0.0;
   if(CopyBuffer(g_atr_handle,0,1,1,b)!=1) return 0.0;
   return b[0];
}

bool StopsAreValid(ENUM_ORDER_TYPE type,double price,double sl,double tp)
{
   long level=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minDist=level*_Point;
   if(type==ORDER_TYPE_BUY) return ((price-sl)>=minDist && (tp-price)>=minDist);
   return ((sl-price)>=minDist && (price-tp)>=minDist);
}

double NormalizeLot(double lot)
{
   double minlot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxlot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   lot=MathMax(minlot,MathMin(maxlot,lot));
   if(step>0) lot=MathFloor(lot/step+1e-8)*step;
   int d=2; if(step==1.0)d=0; else if(step==0.1)d=1; else if(step==0.001)d=3;
   return NormalizeDouble(lot,d);
}

bool HasOpenPosition()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(t==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagic) return true;
   }
   return false;
}

bool IsNewZoneBar()
{
   datetime t=iTime(_Symbol,InpZoneTF,0); if(t<=0) return false;
   if(t!=g_last_zone_bar){g_last_zone_bar=t;return true;}
   return false;
}

bool IsNewEntryBar()
{
   datetime t=iTime(_Symbol,InpEntryTF,0); if(t<=0) return false;
   if(t!=g_last_entry_bar){return true;}
   return false;
}

void ResetDailyEquityIfNeeded()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   int key=dt.year*10000+dt.mon*100+dt.day;
   if(key!=g_day_key){g_day_key=key;g_day_start_equity=AccountInfoDouble(ACCOUNT_EQUITY);}
}

bool TradingAllowed()
{
   if(InpDailyLossLimit<=0) return true;
   if(g_day_start_equity<=0) return true;
   double dd=(g_day_start_equity-AccountInfoDouble(ACCOUNT_EQUITY))/g_day_start_equity*100.0;
   return dd<InpDailyLossLimit;
}

//+------------------------------------------------------------------+
//| Visuals                                                          |
//+------------------------------------------------------------------+
void DrawAllZones()
{
   for(int i=0;i<ArraySize(g_supply);i++) if(g_supply[i].valid) DrawZone(g_supply[i],"S",i);
   for(int i=0;i<ArraySize(g_demand);i++) if(g_demand[i].valid) DrawZone(g_demand[i],"D",i);
}

void DrawZone(const Zone &z,string side,int idx)
{
   string n=PREFIX+side+IntegerToString(idx)+"_"+IntegerToString((long)z.created);
   datetime t2=TimeCurrent()+PeriodSeconds(InpZoneTF)*50;
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_RECTANGLE,0,z.created,z.top,t2,z.bottom);
   else {ObjectMove(0,n,0,z.created,z.top);ObjectMove(0,n,1,t2,z.bottom);}
   ObjectSetInteger(0,n,OBJPROP_COLOR,z.demand?clrAqua:clrTomato);
   ObjectSetInteger(0,n,OBJPROP_STYLE,STYLE_SOLID);
   ObjectSetInteger(0,n,OBJPROP_WIDTH,1);
   ObjectSetInteger(0,n,OBJPROP_FILL,false);
   ObjectSetInteger(0,n,OBJPROP_BACK,true);
}

void DrawTrade(bool buy,datetime t,double entry,double sl,double tp,const Zone &z)
{
   string id=IntegerToString((long)t);
   string n=PREFIX+"ENTRY_"+id;
   ObjectCreate(0,n,OBJ_ARROW,0,t,entry);
   ObjectSetInteger(0,n,OBJPROP_ARROWCODE,buy?233:234);
   ObjectSetInteger(0,n,OBJPROP_COLOR,buy?clrLime:clrRed);
   ObjectSetInteger(0,n,OBJPROP_WIDTH,2);
   if(InpShowReasons) Print("PHX6 EXACT SD | ",buy?"BUY":"SELL"," | zone=",DoubleToString(z.bottom,_Digits),"..",DoubleToString(z.top,_Digits)," | entry=",DoubleToString(entry,_Digits)," SL=",DoubleToString(sl,_Digits)," TP=",DoubleToString(tp,_Digits));
}

void DeleteObjectsByPrefix(string prefix)
{
   int total=ObjectsTotal(0);
   for(int i=total-1;i>=0;i--)
   {
      string n=ObjectName(0,i);
      if(StringFind(n,prefix)==0) ObjectDelete(0,n);
   }
}
//+------------------------------------------------------------------+
