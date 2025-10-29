//+------------------------------------------------------------------+
//|                                        TheAlien.mq5              |
//|  Moving Average - Improved EA (Risk-managed, ATR & Trend filter)|
//|  Duplicate of MuvAv_Preh4uzd with new name TheAlien             |
//+------------------------------------------------------------------+
#property copyright "2020-2025 treebourks-debug"
#property link      "https://github.com/treebourks-debug/Moving-Average-EA-conversion-from-MT4_The-Alien"
#property version   "3.00"
#property description "Moving Average improved EA with risk management, ATR & trend filters."

#include <Trade\Trade.mqh>

#define MAGICMA  20131111

//--- Inputs
input double FixedLots            = 0.0;    // Fixed lot size (0=use risk %)
input double RiskPercent          = 1.0;    // Risk per trade in %
input double MaximumRisk          = 0.02;   // Maximum risk per trade (not used by default)
input double DecreaseFactor       = 3.0;    // Decrease factor after losses

input int    FastMA_Period        = 10;     // Fast MA Period
input int    SlowMA_Period        = 40;     // Slow MA Period
input ENUM_MA_METHOD MA_Method    = MODE_EMA; // MA Method
input int    MovingShift          = 6;      // MA Shift

input int    StopLoss             = 300;    // Stop Loss in points
input int    TakeProfit           = 0;      // Take Profit in points (0=use RiskReward)
input double RiskReward           = 2.0;    // Risk/Reward Ratio (0=use TP)

input bool   UseTrailingStop      = false;  // Use Trailing Stop
input int    TrailingStop         = 300;    // Trailing Stop in points
input int    TrailingStep         = 100;    // Trailing Step in points

input int    MaxSpread            = 30;     // Maximum spread (0=no limit)
input bool   UseATRFilter         = true;   // Use ATR volatility filter
input int    ATR_Period           = 14;     // ATR Period
input double ATR_MinValue        = 100.0;   // Minimum ATR value in points
input int    MinBarsBetween      = 3;       // Min bars between trades
input bool   UseTrendFilter      = true;    // Only trade with trend

input double MaxDailyLoss        = 0.0;     // Max daily loss in account currency (0=disabled)
input int    MaxOpenTrades       = 1;       // Maximum open trades per symbol

input bool   EnableDebug         = true;    // Enable debug messages

//--- Global variables
CTrade trade;
int    fast_ma_handle = INVALID_HANDLE, slow_ma_handle = INVALID_HANDLE, atr_handle = INVALID_HANDLE;
double fast_ma[], slow_ma[], atr[];
datetime last_bar_time = 0;
datetime last_trade_time = 0;
double daily_profit = 0.0;
datetime current_day = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(EnableDebug) Print("=== TheAlien EA initializing ===");

   // create indicators
   fast_ma_handle = iMA(_Symbol, _Period, FastMA_Period, MovingShift, MA_Method, PRICE_CLOSE);
   slow_ma_handle = iMA(_Symbol, _Period, SlowMA_Period, MovingShift, MA_Method, PRICE_CLOSE);
   atr_handle     = iATR(_Symbol, _Period, ATR_Period);

   if(fast_ma_handle==INVALID_HANDLE || slow_ma_handle==INVALID_HANDLE || atr_handle==INVALID_HANDLE)
     {
      Print("ERROR: Cannot create indicator handles");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(MAGICMA);
   trade.SetDeviationInPoints(50);
   trade.SetAsyncMode(false);

   ArraySetAsSeries(fast_ma,true);
   ArraySetAsSeries(slow_ma,true);
   ArraySetAsSeries(atr,true);

   last_bar_time = 0;
   last_trade_time = 0;
   daily_profit = 0.0;
   current_day = 0;

   if(EnableDebug) Print("EA initialized successfully");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Deinitialization                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(fast_ma_handle!=INVALID_HANDLE) IndicatorRelease(fast_ma_handle);
   if(slow_ma_handle!=INVALID_HANDLE) IndicatorRelease(slow_ma_handle);
   if(atr_handle!=INVALID_HANDLE) IndicatorRelease(atr_handle);
   if(EnableDebug) Print("EA deinitialized");
  }

//+------------------------------------------------------------------+
//| Helper: Get filling mode                                          |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillingMode(string symbol)
  {
   int filling = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

//+------------------------------------------------------------------+
//| Calculate lot size based on risk                                 |
//+------------------------------------------------------------------+
double CalculateLotSize(double sl_points)
  {
   if(FixedLots > 0.0) return(NormalizeDouble(FixedLots,2));

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_money = balance * RiskPercent / 100.0;

   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(tick_value<=0 || tick_size<=0)
     {
      // fallback
      double minlot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      return(minlot);
     }

   double lot = (risk_money / (sl_points * point / tick_size * tick_value));
   double lotstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minlot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxlot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(lotstep <= 0) lotstep = 0.01;
   lot = MathFloor(lot/lotstep) * lotstep;
   if(lot < minlot) lot = minlot;
   if(lot > maxlot) lot = maxlot;

   return(NormalizeDouble(lot,2));
  }

//+------------------------------------------------------------------+
//| Check daily loss limits                                           |
//+------------------------------------------------------------------+
bool CheckDailyLimits()
  {
   if(MaxDailyLoss <= 0.0) return true;

   MqlDateTime tm;
   TimeCurrent(tm);
   datetime today = StringToTime(IntegerToString(tm.year)+"."+IntegerToString(tm.mon)+"."+IntegerToString(tm.day));

   if(current_day != today)
     {
      current_day = today;
      daily_profit = 0.0;
     }

   // compute daily realized P/L for this EA
   HistorySelect(today, TimeCurrent());
   int total = HistoryDealsTotal();
   daily_profit = 0.0;
   for(int i=0;i<total;i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket==0) continue;
      string sym = HistoryDealGetString(ticket, DEAL_SYMBOL);
      if(sym != _Symbol) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != MAGICMA) continue;
      int entry = (int)HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_OUT)
         daily_profit += HistoryDealGetDouble(ticket, DEAL_PROFIT);
     }

   if(daily_profit < -MaxDailyLoss)
     {
      if(EnableDebug) Print("Daily loss limit reached: ", daily_profit);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
  {
   // trade checks
   if(Bars(_Symbol, _Period) < 100) return;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return;

   // new bar check
   datetime cur_time = iTime(_Symbol, _Period, 0);
   if(last_bar_time == cur_time) return;
   last_bar_time = cur_time;

   // copy indicators
   if(CopyBuffer(fast_ma_handle,0,0,3,fast_ma) < 3) { Print("CopyBuffer fast failed"); return; }
   if(CopyBuffer(slow_ma_handle,0,0,3,slow_ma) < 3) { Print("CopyBuffer slow failed"); return; }
   if(UseATRFilter)
     {
      if(CopyBuffer(atr_handle,0,0,1,atr) < 1) { Print("CopyBuffer ATR failed"); return; }
     }

   // ATR filter
   if(UseATRFilter)
     {
      double atrval = atr[0] / SymbolInfoDouble(_Symbol, SYMBOL_POINT); // pts
      if(atrval < ATR_MinValue)
        {
         if(EnableDebug) Print("ATR too low: ", atrval);
         return;
        }
     }

   // spread filter
   if(MaxSpread > 0)
     {
      long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spread > MaxSpread)
        {
         if(EnableDebug) Print("Spread too high: ", spread);
         return;
        }
     }

   // daily limits and max open trades check
   if(!CheckDailyLimits()) return;
   if(CountPositions() >= MaxOpenTrades) return;

   // trend filter
   bool uptrend = fast_ma[0] > slow_ma[0];
   bool downtrend = fast_ma[0] < slow_ma[0];
   if(UseTrendFilter && !uptrend && !downtrend) return;

   // signals: crossover of fast vs slow (bar 1 -> bar 0)
   bool buy_signal = fast_ma[1] <= slow_ma[1] && fast_ma[0] > slow_ma[0];
   bool sell_signal = fast_ma[1] >= slow_ma[1] && fast_ma[0] < slow_ma[0];

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   // close on reverse signals
   CheckForClose();

   if(HasOpenPosition()) return;

   // calculate lots based on SL
   double sl_pts = StopLoss;
   if(sl_pts <= 0) sl_pts = 100; // fallback
   double lot = CalculateLotSize(sl_pts);

   // SL/TP values
   double sl_buy=0, tp_buy=0, sl_sell=0, tp_sell=0;
   if(StopLoss>0)
     {
      sl_buy = ask - StopLoss * point;
      sl_sell = bid + StopLoss * point;
     }
   if(RiskReward>0)
     {
      tp_buy = ask + StopLoss * RiskReward * point;
      tp_sell = bid - StopLoss * RiskReward * point;
     }
   else if(TakeProfit>0)
     {
      tp_buy = ask + TakeProfit * point;
      tp_sell = bid - TakeProfit * point;
     }

   // execute trades
   if(buy_signal)
     {
      if(EnableDebug) Print("BUY signal, lot=",lot);
      if(trade.Buy(lot,_Symbol,ask,sl_buy,tp_buy,"MA_Buy"))
        {
         if(EnableDebug) Print("Buy placed, ticket=",trade.ResultOrder());
         last_trade_time = TimeCurrent();
        }
     }
   else if(sell_signal)
     {
      if(EnableDebug) Print("SELL signal, lot=",lot);
      if(trade.Sell(lot,_Symbol,bid,sl_sell,tp_sell,"MA_Sell"))
        {
         if(EnableDebug) Print("Sell placed, ticket=",trade.ResultOrder());
         last_trade_time = TimeCurrent();
        }
     }
  }

//+------------------------------------------------------------------+
//| Count open positions for this EA                                 |
//+------------------------------------------------------------------+
int CountPositions()
  {
   int cnt=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      if(PositionGetTicket(i)==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==MAGICMA) cnt++;
     }
   return cnt;
  }

//+------------------------------------------------------------------+
//| Check if there is any open position                              |
//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   return (CountPositions()>0);
  }

//+------------------------------------------------------------------+
//| Close positions on reverse signals                                |
//+------------------------------------------------------------------+
void CheckForClose()
  {
   MqlRates rates[];
   ArraySetAsSeries(rates,true);
   if(CopyRates(_Symbol,_Period,0,2,rates) < 2) return;
   double open1 = rates[1].open;
   double close1 = rates[1].close;

   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=MAGICMA) continue;

      int ptype = (int)PositionGetInteger(POSITION_TYPE);
      if(ptype==POSITION_TYPE_BUY)
        {
         if(open1 > fast_ma[1] && close1 < fast_ma[1])
            trade.PositionClose(ticket);
        }
      else if(ptype==POSITION_TYPE_SELL)
        {
         if(open1 < fast_ma[1] && close1 > fast_ma[1])
            trade.PositionClose(ticket);
        }
     }
  }
//+------------------------------------------------------------------+
