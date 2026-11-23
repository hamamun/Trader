#property strict
#property version   "1.54"
#property description "Closed-candle M5/M15 forecasts. Monitor-only unless the AutoTrading input is on; can place and manage entries."

#include <Trade/Trade.mqh>
#include "CandleLogic.mqh"

input bool ReadM5          = true;  // Read M5 candles
input bool ReadM15         = true;  // Read M15 candles
input bool ShowLevels      = true;  // Plot active targets and invalidation levels
input bool AlertOnNewSetup = false; // MT5 popup for a new forecast
input bool SaveCsv         = true;  // Log readings, forecasts and outcomes to CSV
input bool CompareSwings   = true;  // Log the standalone confirmed-swing comparison
input bool CompareVariants = true;  // Log the other experiments and all upgrades together
input bool   AutoTrading  = true;   // Send real orders when a setup qualifies (false = monitor only)
input bool   UseStopLoss  = true;   // Attach the invalidation level as stop loss
input double TradeLots    = 0.01;    // Fixed trade size per order (no risk-based sizing)
input int    PendingBars  = 3;       // Candles a pending stop order waits before auto-cancelling
input long   Magic        = 20261123;// Magic number for Trader orders
input int    MaxSlippage  = 100;     // Max slippage in points for market orders

#define CF_OBJECTS "CandleForecast."
#define CF_TRIAL_COUNT 6

struct CFStream
{
   ENUM_TIMEFRAMES period;
   bool enabled;
   bool waiting_for_new_close;
   datetime last_bar;
   CFReading reading;
   CFForecast forecast;
   CFTrial trials[CF_TRIAL_COUNT];
   CFManaged managed;
   CFTrial planner;
   CFReading plan;
   CFMarket local_market, higher_market;
   string last_outcome;
   CFStatus last_outcome_code;
   double last_outcome_close;
   ulong auto_ticket;      // Pending order we placed (0 = none)
   datetime auto_created;  // When it was placed
   double auto_dead_level; // Close back through this level cancels the idea (0 = none)
   int auto_direction;     // +1 buy stop, -1 sell stop
   CFReading auto_signal;  // Reading that armed the pending order (for CSV logging)
   datetime auto_exit_bar; // Bar whose close banned re-entry (set on any Trader exit)
};

CFStream streams[2];
CTrade auto_trade;
double chart_tick_size;
int csv[2] = {INVALID_HANDLE, INVALID_HANDLE};
bool log_error[2] = {false, false};
bool show_panel = false;
datetime higher_cache_bar = 0;
CFMarket higher_cache_market = CF_MARKET_UNKNOWN;

enum CMMarketStatus { CM_OPEN, CM_WITHHELD, CM_CLOSED };
CMMarketStatus g_market_status = CM_OPEN;
string g_market_text = "";
color g_market_color = C'80,200,120';
bool g_market_was_closed = false;
bool out_of_range = false;
string g_drawn_status = "";
datetime g_last_beat = 0;

string FrameName(const ENUM_TIMEFRAMES period) { return period == PERIOD_M5 ? "M5" : "M15"; }
int CsvIndex(const ENUM_TIMEFRAMES period) { return period == PERIOD_M5 ? 0 : 1; }
string Price(const double value) { return DoubleToString(value, _Digits); }
string Stamp(const datetime value) { return TimeToString(value, TIME_DATE | TIME_SECONDS); }

string SafeSymbol(const string symbol)
{
   string safe = symbol;
   StringReplace(safe, "\\", "_");
   StringReplace(safe, "/", "_");
   StringReplace(safe, ":", "_");
   StringReplace(safe, "*", "_");
   StringReplace(safe, "?", "_");
   StringReplace(safe, "\"", "_");
   StringReplace(safe, "<", "_");
   StringReplace(safe, ">", "_");
   StringReplace(safe, "|", "_");
   StringReplace(safe, " ", "_");
   return safe;
}

// ----------------------------------------------------------------------
// Market status: broker trade mode + trade session schedule are the
// source of truth. If the symbol defines no trade sessions at all,
// the market is treated as 24/7 (e.g. typical crypto CFDs).
// ----------------------------------------------------------------------
bool SessionsDefined()
{
   for(int day = 0; day < 7; ++day)
   {
      datetime from, to;
      for(uint i = 0; i < 16; ++i)
         if(SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)day, i, from, to)) return true;
   }
   return false;
}

int DayOfWeek(const datetime when)
{
   MqlDateTime mdt;
   if(!TimeToStruct(when, mdt)) return 0;
   return (int)mdt.day_of_week; // 0 = Sunday ... 6 = Saturday
}

bool InTradeSession(const datetime when)
{
   datetime from, to;
   const int today = DayOfWeek(when);
   const long second = ((long)when) % 86400;
   for(uint i = 0; i < 16; ++i)
   {
      if(!SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)today, i, from, to)) break;
      const long f = ((long)from) % 86400;
      // 24:00 comes back as exactly 86400 seconds.
      const long t = (to == (datetime)86400) ? 86400 : ((long)to) % 86400;
      if(f <= t)
      {
         if(second >= f && second < t) return true;
      }
      else if(second >= f || second < t) return true; // Session wraps midnight.
   }
   return false;
}

datetime NextSessionOpen(const datetime when)
{
   const long second = ((long)when) % 86400;
   const datetime midnight = (datetime)((long)when - second);
   const int today = DayOfWeek(when);
   for(int offset = 0; offset < 10; ++offset)
   {
      const int day = (today + offset) % 7;
      datetime from, to;
      for(uint i = 0; i < 16; ++i)
      {
         if(!SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)day, i, from, to)) break;
         const datetime open_at = (datetime)((long)midnight + (long)offset * 86400 + ((long)from) % 86400);
         if(open_at > when) return open_at;
      }
   }
   return 0;
}

void UpdateMarketStatus()
{
   const color green = C'80,200,120';
   const color orange = C'247,183,117';
   const color red = C'248,136,136';
   datetime when = TimeTradeServer();
   if(when == 0) when = TimeCurrent();
   if(when == 0) when = TimeLocal();

   const long trade_mode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(trade_mode == SYMBOL_TRADE_MODE_DISABLED)
      { g_market_status = CM_WITHHELD; g_market_text = "Withheld | Trade disabled by broker | Monitoring continues"; g_market_color = orange; return; }
   if(trade_mode == SYMBOL_TRADE_MODE_CLOSEONLY)
      { g_market_status = CM_WITHHELD; g_market_text = "Withheld | Close-only mode | Monitoring continues"; g_market_color = orange; return; }
   if(trade_mode == SYMBOL_TRADE_MODE_LONGONLY)
      { g_market_status = CM_WITHHELD; g_market_text = "Withheld | Long-only mode | Monitoring continues"; g_market_color = orange; return; }
   if(trade_mode == SYMBOL_TRADE_MODE_SHORTONLY)
      { g_market_status = CM_WITHHELD; g_market_text = "Withheld | Short-only mode | Monitoring continues"; g_market_color = orange; return; }
   if(!SessionsDefined())
      { g_market_status = CM_OPEN; g_market_text = "Market open | 24/7"; g_market_color = green; return; }
   if(InTradeSession(when))
      { g_market_status = CM_OPEN; g_market_text = "Market open"; g_market_color = green; return; }
   const datetime opens = NextSessionOpen(when);
   g_market_status = CM_CLOSED;
   g_market_text = opens > 0 ? "Market closed | Opens " + Stamp(opens) + " server time"
                              : "Market closed | Open time unknown";
   g_market_color = red;
}

// ----------------------------------------------------------------------
// Session memory via terminal global variables - the same mechanism the
// terminal itself uses (they survive terminal restarts and keep values
// while no chart changes reset the program's memory). The Strategy
// Tester keeps a separate set, so persistence is disabled there and
// every test starts from a clean state.
// ----------------------------------------------------------------------
string GvPrefix(const ENUM_TIMEFRAMES period)
{
   return "Trader." + SafeSymbol(_Symbol) + "." + FrameName(period) + ".";
}

string StatePath(const ENUM_TIMEFRAMES period)
{
   return "CandleForecast\\state_" + SafeSymbol(_Symbol) + "_" + FrameName(period) + ".dat";
}

string ActiveSummary()
{
   string summary = "";
   if(streams[0].managed.forecast.status == CF_ACTIVE) summary += "  |  M5 forecast active";
   if(streams[1].managed.forecast.status == CF_ACTIVE) summary += "  |  M15 forecast active";
   return summary;
}

bool FindAutoPosition(const CFStream &s, ulong &ticket, int &type, double &open_price, double &sl, double &tp)
{
   const string tag = FrameName(s.period);
   for(int i = 0; i < PositionsTotal(); ++i)
   {
      const ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != (long)Magic) continue;
      if(StringFind(PositionGetString(POSITION_COMMENT), tag) < 0) continue;
      ticket = pt;
      type = (int)PositionGetInteger(POSITION_TYPE);
      open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      sl = PositionGetDouble(POSITION_SL);
      tp = PositionGetDouble(POSITION_TP);
      return true;
   }
   ticket = 0; type = -1; open_price = 0.0; sl = 0.0; tp = 0.0;
   return false;
}

void AutoCancelPending(CFStream &s, const string reason)
{
   const ulong ticket = s.auto_ticket;
   if(ticket == 0) return;
   if(auto_trade.OrderDelete(ticket))
   {
      Print("Trader: pending order ", ticket, " cancelled - ", reason, ".");
      LogAuto("order_cancel", s, 0.0, 0.0, 0.0, ticket, "reason=" + reason);
   }
   else
   {
      Print("Trader: could not cancel pending order ", ticket, ": ", auto_trade.ResultRetcodeDescription());
      LogAuto("order_fail", s, 0.0, 0.0, 0.0, ticket,
              "reason=cancel_failed;detail=" + auto_trade.ResultRetcodeDescription());
   }
   s.auto_ticket = 0;
   s.auto_dead_level = 0.0;
}

void CloseAuto(CFStream &s, const string reason)
{
   ulong ticket; int type; double open_price, sl, tp;
   if(!FindAutoPosition(s, ticket, type, open_price, sl, tp)) return; // no Trader position on this TF
   if(!auto_trade.PositionClose(ticket))
   {
      Print("Trader: could not close position ", ticket, " (", reason, "): ", auto_trade.ResultRetcodeDescription());
      LogAuto("order_fail", s, 0.0, 0.0, 0.0, ticket,
              "reason=close_failed;detail=" + auto_trade.ResultRetcodeDescription());
      return;
   }
   const double price = auto_trade.ResultPrice();
   s.auto_exit_bar = iTime(_Symbol, s.period, 0);
   Print("Trader: position ", ticket, " closed (", reason, ") at ", Price(price));
   LogAuto("exit", s, price, 0.0, 0.0, ticket, "reason=" + reason);
}

// Exit machinery, per stream, evaluated every refresh (closed or withheld — closing
// is always permitted even in close-only mode).
void AutoExits(CFStream &s)
{
   if(MQLInfoInteger(MQL_TESTER)) return;
   if(!AutoTrading) return;
   ulong ticket; int type; double open_price, sl, tp;
   if(!FindAutoPosition(s, ticket, type, open_price, sl, tp)) return;
   const int direction = (type == (int)POSITION_TYPE_BUY) ? 1 : -1;

   // 1) Mid-candle invalidation — only when the broker stop loss is disabled;
   //    with UseStopLoss=true the broker already handles this outcome.
   if(!UseStopLoss && s.forecast.status == CF_ACTIVE)
   {
      const double level = s.forecast.setup.invalidation;
      const double price = direction > 0 ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                         : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(direction * (price - level) <= 0.0)
      {
         CloseAuto(s, "invalidation_midcandle");
         return;
      }
   }
   // 2) Managed early exit (adverse close confirmation / opposite impulse / structure break).
   if(s.managed.advice == CF_EXIT)
   {
      CloseAuto(s, "early_exit;detail=" + s.managed.explanation);
      return;
   }
   // 3) Forecast over (target / invalidation / expiry / ambiguous / untracked).
   if(s.forecast.status != CF_ACTIVE && s.forecast.status != CF_IDLE)
   {
      string reason;
      switch(s.forecast.status)
      {
         case CF_TARGET:     reason = "target"; break;
         case CF_INVALIDATED: reason = "invalidation"; break;
         case CF_EXPIRED:    reason = "expiry"; break;
         case CF_AMBIGUOUS:  reason = "ambiguous"; break;
         case CF_DATA_GAP:   reason = "data_gap"; break;
         default:            reason = CFStatusName(s.forecast.status); break;
      }
      CloseAuto(s, reason);
   }
}

int MarketFilling()
{
   const long mode = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((mode & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   if((mode & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

// One Trader trade per symbol PER TIMEFRAME. Manual trades (any magic other
// than ours) are never considered for any Trader decision.
bool AutoBusy(const CFStream &s)
{
   const string tag = FrameName(s.period);
   for(int i = 0; i < PositionsTotal(); ++i)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != (long)Magic) continue; // manual trades excluded
      if(StringFind(PositionGetString(POSITION_COMMENT), tag) >= 0) return true;
   }
   return false;
}

bool AutoHasPending(const CFStream &s)
{
   const string tag = FrameName(s.period);
   for(int i = 0; i < OrdersTotal(); ++i)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != (long)Magic) continue;
      if(StringFind(OrderGetString(ORDER_COMMENT), tag) >= 0) return true;
   }
   return false;
}

// Record every order action in the per-stream CSV (event = order / order_cancel /
// order_fail / order_fill). Variant carries the mode; management_reason carries
// ticket/lots/sl/tp/price; no commas inside fields.
void LogAuto(const string event, const CFStream &s, const double price, const double sl, const double tp,
             const ulong ticket, const string note)
{
   const int index = CsvIndex(s.period);
   if(csv[index] == INVALID_HANDLE) return;
   string details = "lots=" + DoubleToString(TradeLots, 2);
   if(ticket != 0) details += ";ticket=" + IntegerToString((long)ticket);
   if(price > 0.0) details += ";price=" + Price(price);
   details += sl > 0.0 ? ";sl=" + Price(sl) : ";sl=off";
   details += tp > 0.0 ? ";tp=" + Price(tp) : ";tp=off";
   if(note != "") details += ";" + note;
   StringReplace(details, ",", ";"); // keep the CSV single-column safe
   if(s.auto_signal.category != CF_NONE && s.auto_signal.decision == CF_SETUP)
   {
      // market vs pending is distinguished by the mode=... field in management_reason
      Log(event, s.period, s.auto_signal, s.last_bar, s.last_bar, -1, CF_ACTIVE,
          "autotrade", Price(price), "", details, CFMarketName(s.local_market),
          s.period == PERIOD_M5 ? CFMarketName(s.higher_market) : "");
      return;
   }
   // No live reading (e.g. after a restart): minimal row, no fake context.
   if(FileWrite(csv[index], event, _Symbol, FrameName(s.period),
                s.last_bar > 0 ? Stamp(s.last_bar) : "", "", "", "", "", "", "",
                "", "", "", "", "", "", "", "", "autotrade", Price(price), "", "",
                details, "", "") == 0)
      LogFailed(s.period);
   FileFlush(csv[index]);
}

void AutoStopsAndTarget(const int direction, const double ref, const double invalidation,
                        const double target, double &sl, double &tp)
{
   const double stops = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   sl = 0.0;
   tp = 0.0;
   if(UseStopLoss && invalidation > 0.0)
   {
      if(direction * (ref - invalidation) >= stops) sl = NormalizeDouble(invalidation, _Digits);
      else Print("Trader: stop loss ", Price(invalidation), " is closer than the broker minimum (",
                 Price(stops), "); order will go WITHOUT a stop loss.");
   }
   if(target > 0.0)
   {
      if(direction * (target - ref) >= stops) tp = NormalizeDouble(target, _Digits);
      else Print("Trader: take profit ", Price(target), " is closer than the broker minimum (",
                 Price(stops), "); order will go WITHOUT a take profit.");
   }
}

// Entry gate (points 1-3, precise rules). Fires on a fresh closed signal candle only.
// A = market when the candle proved the move (or is a turning/continuation setup);
// B = pending stop beyond the candle when a breakout only hinted at it.
void AutoTradeSignal(CFStream &s, const CFWindow &w)
{
   if(!AutoTrading) return;
   if(MQLInfoInteger(MQL_TESTER)) return;   // never send orders from backtests
   if(out_of_range) return;
   if(s.auto_exit_bar != 0 && iTime(_Symbol, s.period, 0) == s.auto_exit_bar)
   {
      Print("Trader: an exit happened on this candle; no re-entry until the next close.");
      return;
   }
   const CFReading r = s.reading; // value copy: MetaEditor rejects local refs bound to members
   if(r.decision != CF_SETUP || r.category == CF_NONE) return;
   if(g_market_status != CM_OPEN)
   {
      Print("Trader: setup found but trading is withheld/closed (", g_market_text, "); no order sent.");
      return;
   }
   if(AutoBusy(s) || AutoHasPending(s))
   {
      Print("Trader: ", FrameName(s.period), " has a setup but a Trader ", FrameName(s.period),
            " position/order is already open on ", _Symbol, " (the other timeframe is unaffected); no new trade.");
      return;
   }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
   {
      Print("Trader: AutoTrading input is on but terminal/account does not allow automated trading; no order sent.");
      return;
   }
   const MqlRates b = w.bar[0];   // value copy, same reason
   const int direction = r.direction;
   const double typical = CFTypicalRange(w, 1);
   const bool strong = CFImpulse(b, direction, typical);
   const int mode = CFEntryMode(r.category, direction, b.close, r.breakout_level, typical, strong);
   const string tag = StringFormat("Trader %s %s", FrameName(s.period), mode == CF_ENTRY_MARKET ? "MKT" : "STP");
   const double current = direction > 0 ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                        : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool ok = false;
   double sl, tp;
   double placed_price = current;  // market: filled near here; pending: the stop level

   if(mode == CF_ENTRY_MARKET)
   {
      AutoStopsAndTarget(direction, current, r.invalidation, r.target, sl, tp);
      ok = direction > 0 ? auto_trade.Buy(TradeLots, _Symbol, 0.0, sl, tp, tag)
                         : auto_trade.Sell(TradeLots, _Symbol, 0.0, sl, tp, tag);
   }
   else
   {
      const double buffer = MathMax(chart_tick_size, 0.05 * typical);
      const double price = NormalizeDouble(direction > 0 ? b.high + buffer : b.low - buffer, _Digits);
      placed_price = price;
      const double stops = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
      if(direction * (price - current) < stops)
      {
         Print("Trader: pending level ", Price(price), " too close to current price; signal skipped.");
         return;
      }
      AutoStopsAndTarget(direction, price, r.invalidation, r.target, sl, tp);
      ok = direction > 0 ? auto_trade.BuyStop(TradeLots, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, tag)
                         : auto_trade.SellStop(TradeLots, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, tag);
      if(ok)
      {
         s.auto_ticket = auto_trade.ResultOrder();
         s.auto_created = TimeCurrent();
         s.auto_dead_level = r.breakout_level;
         s.auto_direction = direction;
         s.auto_signal = r;
      }
   }
   if(ok)
   {
      const double fill = auto_trade.ResultPrice() > 0.0 ? auto_trade.ResultPrice() : placed_price;
      Print("Trader: ", mode == CF_ENTRY_MARKET ? "market" : "pending", " order placed (", tag, ") ",
            direction > 0 ? "BUY" : "SELL", " ", DoubleToString(TradeLots, 2),
            " SL ", sl > 0 ? Price(sl) : "off", " TP ", tp > 0 ? Price(tp) : "off");
      if(mode == CF_ENTRY_MARKET)
         LogAuto("order", s, fill, sl, tp, auto_trade.ResultOrder(), "mode=market;filled=" + Price(fill));
      else
         LogAuto("order", s, fill, sl, tp, auto_trade.ResultOrder(), "mode=pending;pending_price=" + Price(fill));
   }
   else
   {
      Print("Trader: order rejected: ", auto_trade.ResultRetcode(), " ", auto_trade.ResultRetcodeDescription());
      s.auto_signal = r;
      LogAuto("order_fail", s, 0.0, 0.0, 0.0, 0,
              StringFormat("mode=%s;retcode=%d;reason=%s", mode == CF_ENTRY_MARKET ? "market" : "pending",
                           (int)auto_trade.ResultRetcode(), auto_trade.ResultRetcodeDescription()));
   }
}

void RecoverAutoOrders()
{
   if(MQLInfoInteger(MQL_TESTER)) return;
   for(int i = 0; i < OrdersTotal(); ++i)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != (long)Magic) continue;
      const ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_STOP && type != ORDER_TYPE_SELL_STOP) continue;
      const string comment = OrderGetString(ORDER_COMMENT);
      int index = -1;
      if(StringFind(comment, "M15") >= 0) index = 1;
      else if(StringFind(comment, "M5") >= 0) index = 0;
      if(index < 0 || streams[index].auto_ticket != 0) continue;
      streams[index].auto_ticket = ticket;
      streams[index].auto_created = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      streams[index].auto_direction = (type == ORDER_TYPE_BUY_STOP ? 1 : -1);
      streams[index].auto_dead_level = 0.0; // unknown after restart; lifetime cancel still applies
      Print("Trader: recovered pending order ", ticket, " for ", FrameName(streams[index].period),
            " (placed ", TimeToString(streams[index].auto_created, TIME_DATE | TIME_SECONDS), ").");
   }
}

void AutoSweepStream(CFStream &s)
{
      if(s.auto_ticket == 0) return;
      const ulong ticket = s.auto_ticket;
      bool found = false;
      for(int j = 0; j < OrdersTotal(); ++j)
      {
         if(OrderGetTicket(j) == ticket) { found = true; break; }
      }
      if(!found)
      {
         // Filled? Look for the resulting Trader position with this timeframe's tag.
         double open_price = 0.0, sl = 0.0, tp = 0.0;
         ulong pos_ticket = 0;
         int ptype = -1;
         FindAutoPosition(s, pos_ticket, ptype, open_price, sl, tp);
         if(pos_ticket != 0)
         {
            Print("Trader: pending order ", ticket, " filled -> position ", pos_ticket, " at ", Price(open_price));
            LogAuto("order_fill", s, open_price, sl, tp, ticket, "reason=pending_filled;position=" + IntegerToString((long)pos_ticket));
         }
         else
         {
            Print("Trader: pending order ", ticket, " no longer exists (filled or cancelled externally); clearing.");
            LogAuto("order_fill", s, 0.0, 0.0, 0.0, ticket, "reason=pending_gone_fill_or_external");
         }
         s.auto_ticket = 0;
         s.auto_dead_level = 0.0;
         return;
      }
      const double bars = (double)(TimeCurrent() - s.auto_created) / (double)PeriodSeconds(s.period);
      bool kill = PendingBars > 0 && bars >= PendingBars;
      string why = "expired after " + IntegerToString(PendingBars) + " " + FrameName(s.period) + " bars without triggering";
      if(!kill && s.auto_dead_level != 0.0)
      {
         const double closed = iClose(_Symbol, s.period, 1);
         if(closed > 0.0 && s.auto_direction * (closed - s.auto_dead_level) < 0.0)
         {
            kill = true;
            why = "price closed back through " + Price(s.auto_dead_level);
         }
      }
      if(kill) AutoCancelPending(s, why);
}

void AutoOrdersSweep()
{
   if(MQLInfoInteger(MQL_TESTER)) return;
   AutoSweepStream(streams[0]);
   AutoSweepStream(streams[1]);
}

void GvSet(const string &prefix, const string key, const double value)
{
   if(!GlobalVariableSet(prefix + key, value)) Print("Trader: could not save state '", key, "'");
}

double GvGet(const string &prefix, const string key, const double fallback)
{
   if(!GlobalVariableCheck(prefix + key)) return fallback;
   return GlobalVariableGet(prefix + key);
}

string OutcomeText(const CFStatus code, const double close)
{
   if(code == CF_IDLE) return "";
   string text = CFStatusName(code);
   if((code == CF_STRUCTURE_EXIT || code == CF_BREAKOUT_EXIT || code == CF_CANDLE_EXIT) && close > 0)
      text += " @ close " + Price(close);
   return text;
}

bool ForecastValid(const CFForecast &f)
{
   if(f.status < CF_IDLE || f.status > CF_CANDLE_EXIT) return false;
   if(f.status == CF_IDLE) return true;
   if(f.signal_bar <= 0 || f.last_checked_bar < f.signal_bar) return false;
   if(f.setup.direction != 1 && f.setup.direction != -1) return false;
   if(f.setup.entry == 0.0 || f.setup.target == 0.0 || f.setup.invalidation == 0.0) return false;
   return true;
}

void SaveForecast(const string &prefix, const string tag, const CFForecast &f)
{
   GvSet(prefix, tag + "status", (double)f.status);
   GvSet(prefix, tag + "signal", (double)f.signal_bar);
   GvSet(prefix, tag + "checked", (double)f.last_checked_bar);
   GvSet(prefix, tag + "bars", (double)f.bars);
   GvSet(prefix, tag + "cat", (double)f.setup.category);
   GvSet(prefix, tag + "dir", (double)f.setup.direction);
   GvSet(prefix, tag + "entry", f.setup.entry);
   GvSet(prefix, tag + "target", f.setup.target);
   GvSet(prefix, tag + "inval", f.setup.invalidation);
   GvSet(prefix, tag + "brk", f.setup.breakout_level);
   GvSet(prefix, tag + "minbars", (double)f.setup.min_bars);
   GvSet(prefix, tag + "maxbars", (double)f.setup.max_bars);
}

void LoadForecast(const string &prefix, const string tag, CFForecast &f)
{
   CFForecast g = {};
   g.status = (CFStatus)(int)GvGet(prefix, tag + "status", (double)CF_IDLE);
   g.signal_bar = (datetime)GvGet(prefix, tag + "signal", 0);
   g.last_checked_bar = (datetime)GvGet(prefix, tag + "checked", (double)g.signal_bar);
   g.bars = (int)GvGet(prefix, tag + "bars", 0);
   g.setup.category = (CFCategory)(int)GvGet(prefix, tag + "cat", 0);
   g.setup.direction = (int)GvGet(prefix, tag + "dir", 0);
   g.setup.entry = GvGet(prefix, tag + "entry", 0);
   g.setup.target = GvGet(prefix, tag + "target", 0);
   g.setup.invalidation = GvGet(prefix, tag + "inval", 0);
   g.setup.breakout_level = GvGet(prefix, tag + "brk", 0);
   g.setup.min_bars = (int)GvGet(prefix, tag + "minbars", 0);
   g.setup.max_bars = (int)GvGet(prefix, tag + "maxbars", 0);
   if(!ForecastValid(g)) { f.status = CF_IDLE; return; }
   f = g;
}

void SaveReading(const string &prefix, const string tag, const CFReading &r)
{
   GvSet(prefix, tag + "cat", (double)r.category);
   GvSet(prefix, tag + "dec", (double)r.decision);
   GvSet(prefix, tag + "dir", (double)r.direction);
   GvSet(prefix, tag + "entry", r.entry);
   GvSet(prefix, tag + "target", r.target);
   GvSet(prefix, tag + "inval", r.invalidation);
   GvSet(prefix, tag + "brk", r.breakout_level);
   GvSet(prefix, tag + "minbars", (double)r.min_bars);
   GvSet(prefix, tag + "maxbars", (double)r.max_bars);
}

void LoadReading(const string &prefix, const string tag, CFReading &r, bool &valid)
{
   CFReading g = {};
   g.category = (CFCategory)(int)GvGet(prefix, tag + "cat", 0);
   g.decision = (CFDecision)(int)GvGet(prefix, tag + "dec", 0);
   g.direction = (int)GvGet(prefix, tag + "dir", 0);
   g.entry = GvGet(prefix, tag + "entry", 0);
   g.target = GvGet(prefix, tag + "target", 0);
   g.invalidation = GvGet(prefix, tag + "inval", 0);
   g.breakout_level = GvGet(prefix, tag + "brk", 0);
   g.min_bars = (int)GvGet(prefix, tag + "minbars", 0);
   g.max_bars = (int)GvGet(prefix, tag + "maxbars", 0);
   valid = (g.category >= CF_NONE && g.category <= CF_RANGE_BOUNCE &&
            g.decision >= CF_SKIP && g.decision <= CF_SETUP &&
            (g.direction == -1 || g.direction == 0 || g.direction == 1));
   if(!valid) { CFReading empty = {}; r = empty; return; }
   r = g;
}

void SaveTrial(const string &prefix, const string tag, const CFTrial &t)
{
   SaveForecast(prefix, tag + "f.", t.forecast);
   SaveReading(prefix, tag + "p.", t.pending);
   GvSet(prefix, tag + "plevel", t.pending_level);
   GvSet(prefix, tag + "pbars", (double)t.pending_bars);
}

void LoadTrial(const string &prefix, const string tag, CFTrial &t)
{
   LoadForecast(prefix, tag + "f.", t.forecast);
   bool valid = false;
   LoadReading(prefix, tag + "p.", t.pending, valid);
   t.pending_level = GvGet(prefix, tag + "plevel", 0);
   t.pending_bars = (int)GvGet(prefix, tag + "pbars", 0);
   if(!valid || t.pending_bars <= 0)
   {
      CFReading empty = {};
      t.pending = empty;
      t.pending_level = 0;
      t.pending_bars = 0;
   }
}

void WriteForecastFile(const int handle, const CFForecast &f)
{
   FileWriteDouble(handle, (double)f.status);
   FileWriteDouble(handle, (double)f.signal_bar);
   FileWriteDouble(handle, (double)f.last_checked_bar);
   FileWriteDouble(handle, (double)f.bars);
   FileWriteDouble(handle, (double)f.setup.category);
   FileWriteDouble(handle, (double)f.setup.direction);
   FileWriteDouble(handle, f.setup.entry);
   FileWriteDouble(handle, f.setup.target);
   FileWriteDouble(handle, f.setup.invalidation);
   FileWriteDouble(handle, f.setup.breakout_level);
   FileWriteDouble(handle, (double)f.setup.min_bars);
   FileWriteDouble(handle, (double)f.setup.max_bars);
}

void WriteTrialFile(const int handle, const CFTrial &t)
{
   WriteForecastFile(handle, t.forecast);
   FileWriteDouble(handle, (double)t.pending.category);
   FileWriteDouble(handle, (double)t.pending.decision);
   FileWriteDouble(handle, (double)t.pending.direction);
   FileWriteDouble(handle, t.pending.entry);
   FileWriteDouble(handle, t.pending.target);
   FileWriteDouble(handle, t.pending.invalidation);
   FileWriteDouble(handle, t.pending.breakout_level);
   FileWriteDouble(handle, (double)t.pending.min_bars);
   FileWriteDouble(handle, (double)t.pending.max_bars);
   FileWriteDouble(handle, t.pending_level);
   FileWriteDouble(handle, (double)t.pending_bars);
}

bool ReadDoubleChecked(const int handle, double &value)
{
   if(FileIsEnding(handle)) return false;
   value = FileReadDouble(handle);
   return true;
}

bool ReadForecastFile(const int handle, CFForecast &f)
{
   CFForecast g = {};
   double v;
   if(!ReadDoubleChecked(handle, v)) return false; g.status = (CFStatus)(int)v;
   if(!ReadDoubleChecked(handle, v)) return false; g.signal_bar = (datetime)v;
   if(!ReadDoubleChecked(handle, v)) return false; g.last_checked_bar = (datetime)v;
   if(!ReadDoubleChecked(handle, v)) return false; g.bars = (int)v;
   if(!ReadDoubleChecked(handle, v)) return false; g.setup.category = (CFCategory)(int)v;
   if(!ReadDoubleChecked(handle, v)) return false; g.setup.direction = (int)v;
   if(!ReadDoubleChecked(handle, v)) return false; g.setup.entry = v;
   if(!ReadDoubleChecked(handle, v)) return false; g.setup.target = v;
   if(!ReadDoubleChecked(handle, v)) return false; g.setup.invalidation = v;
   if(!ReadDoubleChecked(handle, v)) return false; g.setup.breakout_level = v;
   if(!ReadDoubleChecked(handle, v)) return false; g.setup.min_bars = (int)v;
   if(!ReadDoubleChecked(handle, v)) return false; g.setup.max_bars = (int)v;
   if(!ForecastValid(g)) { f.status = CF_IDLE; return true; }
   f = g;
   return true;
}

bool ReadTrialFile(const int handle, CFTrial &t)
{
   if(!ReadForecastFile(handle, t.forecast)) return false;
   CFReading g = {};
   double v;
   if(!ReadDoubleChecked(handle, v)) return false; g.category = (CFCategory)(int)v;
   if(!ReadDoubleChecked(handle, v)) return false; g.decision = (CFDecision)(int)v;
   if(!ReadDoubleChecked(handle, v)) return false; g.direction = (int)v;
   if(!ReadDoubleChecked(handle, v)) return false; g.entry = v;
   if(!ReadDoubleChecked(handle, v)) return false; g.target = v;
   if(!ReadDoubleChecked(handle, v)) return false; g.invalidation = v;
   if(!ReadDoubleChecked(handle, v)) return false; g.breakout_level = v;
   if(!ReadDoubleChecked(handle, v)) return false; g.min_bars = (int)v;
   if(!ReadDoubleChecked(handle, v)) return false; g.max_bars = (int)v;
   if(!ReadDoubleChecked(handle, v)) return false; t.pending_level = v;
   if(!ReadDoubleChecked(handle, v)) return false; t.pending_bars = (int)v;
   const bool valid = (g.category >= CF_NONE && g.category <= CF_RANGE_BOUNCE &&
                       g.decision >= CF_SKIP && g.decision <= CF_SETUP &&
                       (g.direction == -1 || g.direction == 0 || g.direction == 1));
   if(!valid || t.pending_bars <= 0)
   {
      CFReading empty = {};
      t.pending = empty;
      t.pending_level = 0;
      t.pending_bars = 0;
      return true;
   }
   t.pending = g;
   return true;
}

void SaveStreamState(CFStream &s)
{
   if(MQL_TESTER) return;
   if(!s.enabled) return;
   const string prefix = GvPrefix(s.period);
   GvSet(prefix, "ver", 1.0);
   GvSet(prefix, "last_bar", (double)s.last_bar);
   GvSet(prefix, "waiting", s.waiting_for_new_close ? 1.0 : 0.0);
   GvSet(prefix, "oc_code", (double)s.last_outcome_code);
   GvSet(prefix, "oc_close", s.last_outcome_close);
   SaveForecast(prefix, "base.", s.forecast);
   SaveForecast(prefix, "mgmt.", s.managed.forecast);
   GvSet(prefix, "mgmt.warn_adv", s.managed.warning_adverse);
   GvSet(prefix, "mgmt.warn_fav", s.managed.warning_favorable);
   GvSet(prefix, "mgmt.warn_bars", (double)s.managed.warning_bars);
   GvSet(prefix, "mgmt.quiet", (double)s.managed.quiet_bars);
   GvSet(prefix, "mgmt.progress", s.managed.best_progress);
   SaveTrial(prefix, "plan.", s.planner);
   for(int i = 0; i < CF_TRIAL_COUNT; ++i) SaveTrial(prefix, "t" + IntegerToString(i) + ".", s.trials[i]);
   // Independent mirror: a tiny positional file, if the terminal's global variables misbehave.
   const string path = StatePath(s.period);
   int handle = FileOpen(path, FILE_WRITE | FILE_BIN | FILE_SHARE_READ);
   if(handle == INVALID_HANDLE) return;
   FileWriteDouble(handle, 20261123.0); // format marker
   FileWriteDouble(handle, 1.0);        // version
   FileWriteDouble(handle, (double)s.last_bar);
   FileWriteDouble(handle, s.waiting_for_new_close ? 1.0 : 0.0);
   FileWriteDouble(handle, (double)s.last_outcome_code);
   FileWriteDouble(handle, s.last_outcome_close);
   WriteForecastFile(handle, s.forecast);
   WriteForecastFile(handle, s.managed.forecast);
   FileWriteDouble(handle, s.managed.warning_adverse);
   FileWriteDouble(handle, s.managed.warning_favorable);
   FileWriteDouble(handle, (double)s.managed.warning_bars);
   FileWriteDouble(handle, (double)s.managed.quiet_bars);
   FileWriteDouble(handle, s.managed.best_progress);
   WriteTrialFile(handle, s.planner);
   for(int i = 0; i < CF_TRIAL_COUNT; ++i) WriteTrialFile(handle, s.trials[i]);
   FileClose(handle);
}

void SaveStateAll()
{
   if(MQL_TESTER || out_of_range) return;
   SaveStreamState(streams[0]);
   SaveStreamState(streams[1]);
   GlobalVariablesFlush();
}

bool LoadStreamStateGlobals(CFStream &s, const string &prefix)
{
   s.last_bar = (datetime)GvGet(prefix, "last_bar", 0);
   s.waiting_for_new_close = GvGet(prefix, "waiting", 1.0) != 0;
   s.last_outcome_code = (CFStatus)(int)GvGet(prefix, "oc_code", 0.0);
   s.last_outcome_close = GvGet(prefix, "oc_close", 0.0);
   s.last_outcome = OutcomeText(s.last_outcome_code, s.last_outcome_close);
   LoadForecast(prefix, "base.", s.forecast);
   LoadForecast(prefix, "mgmt.", s.managed.forecast);
   s.managed.warning_adverse = GvGet(prefix, "mgmt.warn_adv", 0);
   s.managed.warning_favorable = GvGet(prefix, "mgmt.warn_fav", 0);
   s.managed.warning_bars = (int)GvGet(prefix, "mgmt.warn_bars", 0);
   s.managed.quiet_bars = (int)GvGet(prefix, "mgmt.quiet", 0);
   s.managed.best_progress = GvGet(prefix, "mgmt.progress", 0);
   // Advice is rebuilt on the next closed candle; be honest until then.
   s.managed.advice = CF_STANDBY;
   s.managed.explanation = "Restored after session restart; decide on the next close";
   LoadTrial(prefix, "plan.", s.planner);
   for(int i = 0; i < CF_TRIAL_COUNT; ++i) LoadTrial(prefix, "t" + IntegerToString(i) + ".", s.trials[i]);
   return true;
}

bool LoadStreamStateFile(CFStream &s)
{
   const string path = StatePath(s.period);
   const int handle = FileOpen(path, FILE_READ | FILE_BIN | FILE_SHARE_READ);
   if(handle == INVALID_HANDLE) return false;
   double marker, version, v;
   if(!ReadDoubleChecked(handle, marker) || !ReadDoubleChecked(handle, version)) { FileClose(handle); return false; }
   if(marker != 20261123.0 || version != 1.0) { FileClose(handle); return false; }
   if(!ReadDoubleChecked(handle, v)) { FileClose(handle); return false; }
   s.last_bar = (datetime)v;
   if(!ReadDoubleChecked(handle, v)) { FileClose(handle); return false; }
   s.waiting_for_new_close = v != 0;
   if(!ReadDoubleChecked(handle, v)) { FileClose(handle); return false; }
   s.last_outcome_code = (CFStatus)(int)v;
   if(!ReadDoubleChecked(handle, v)) { FileClose(handle); return false; }
   s.last_outcome_close = v;
   s.last_outcome = OutcomeText(s.last_outcome_code, s.last_outcome_close);
   if(!ReadForecastFile(handle, s.forecast)) { FileClose(handle); return false; }
   if(!ReadForecastFile(handle, s.managed.forecast)) { FileClose(handle); return false; }
   if(!ReadDoubleChecked(handle, v)) { FileClose(handle); return false; }
   s.managed.warning_adverse = v;
   if(!ReadDoubleChecked(handle, v)) { FileClose(handle); return false; }
   s.managed.warning_favorable = v;
   if(!ReadDoubleChecked(handle, v)) { FileClose(handle); return false; }
   s.managed.warning_bars = (int)v;
   if(!ReadDoubleChecked(handle, v)) { FileClose(handle); return false; }
   s.managed.quiet_bars = (int)v;
   if(!ReadDoubleChecked(handle, v)) { FileClose(handle); return false; }
   s.managed.best_progress = v;
   if(!ReadTrialFile(handle, s.planner)) { FileClose(handle); return false; }
   for(int i = 0; i < CF_TRIAL_COUNT; ++i)
      if(!ReadTrialFile(handle, s.trials[i])) { FileClose(handle); return false; }
   FileClose(handle);
   s.managed.advice = CF_STANDBY;
   s.managed.explanation = "Restored after session restart; decide on the next close";
   return true;
}

bool LoadStreamState(CFStream &s)
{
   if(MQL_TESTER) return false;
   if(!s.enabled) return false;
   const string prefix = GvPrefix(s.period);
   if(GvGet(prefix, "ver", -1.0) == 1.0) return LoadStreamStateGlobals(s, prefix);
   return LoadStreamStateFile(s);
}

void RestoreStateAll()
{
   for(int i = 0; i < 2; ++i) LoadStreamState(streams[i]);
}

void LogFailed(const ENUM_TIMEFRAMES period)
{
   const int index = CsvIndex(period);
   if(log_error[index]) return;
   Print("Candle Forecast: CSV logging failed for ", FrameName(period), " (error ", GetLastError(), ").");
   log_error[index] = true;
   if(csv[index] != INVALID_HANDLE) FileClose(csv[index]);
   csv[index] = INVALID_HANDLE;
}

void OpenLogFor(const ENUM_TIMEFRAMES period)
{
   if(!SaveCsv) return;
   const int index = CsvIndex(period);
   if(csv[index] != INVALID_HANDLE || log_error[index]) return;
   const string path = "CandleForecast\\" + SafeSymbol(_Symbol) + "_" + FrameName(period) + ".csv";
   int handle = FileOpen(path, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ, ',', CP_UTF8);
   bool is_new = false;
   if(handle == INVALID_HANDLE)
   {
      handle = FileOpen(path, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ, ',', CP_UTF8);
      is_new = (handle != INVALID_HANDLE);
   }
   if(handle == INVALID_HANDLE)
   {
      LogFailed(period);
      return;
   }
   csv[index] = handle;
   const ulong size = FileSize(handle);
   if(is_new || size == 0)
   {
      if(FileWrite(handle, "event", "symbol", "timeframe", "bar_open_broker_time", "signal_bar_open_broker_time",
                   "category", "decision", "direction", "reason", "qualifier", "reference_close", "target",
                   "invalidation", "estimated_min_bars", "expiry_bars", "elapsed_bars", "status", "variant", "observed_close", "original_breakout_level", "advice", "management_reason", "local_market", "higher_market") == 0)
      {
         LogFailed(period);
         return;
      }
   }
   else if(!FileSeek(handle, 0, SEEK_END))
   {
      LogFailed(period);
      return;
   }
   Print("Candle Forecast: CSV in MQL5/Files/", path, " (tester uses its agent's Files folder).");
}

void Log(const string event, const ENUM_TIMEFRAMES period, const CFReading &r, const datetime bar_time,
         const datetime signal_time, const int elapsed, const CFStatus status, const string variant = "baseline", const string observed_close = "",
         const string advice = "", const string management_reason = "",
         const string local_market = "", const string higher_market = "")
{
   const int index = CsvIndex(period);
   if(csv[index] == INVALID_HANDLE) return;
   const bool setup = r.decision == CF_SETUP;
   if(FileWrite(csv[index], event, _Symbol, FrameName(period), Stamp(bar_time),
                signal_time > 0 ? Stamp(signal_time) : "", CFCategoryName(r.category), CFDecisionName(r),
                r.direction > 0 ? "Up" : (r.direction < 0 ? "Down" : ""), r.reason, r.qualifier,
                Price(r.entry), setup ? Price(r.target) : "", setup ? Price(r.invalidation) : "",
                setup ? IntegerToString(r.min_bars) : "", setup ? IntegerToString(r.max_bars) : "",
                elapsed >= 0 ? IntegerToString(elapsed) : "",
                status != CF_IDLE ? CFStatusName(status) : "", variant, observed_close,
                r.category == CF_BREAKOUT && (setup || r.decision == CF_WAIT) ?
                Price(r.breakout_level) : "", advice, management_reason, local_market, higher_market) == 0)
   {
      LogFailed(period);
      return;
   }
   FileFlush(csv[index]);
}

void EndForecast(CFStream &s, const datetime event_bar, const string observed_close = "")
{
   Log("outcome", s.period, s.forecast.setup, event_bar, s.forecast.signal_bar, s.forecast.bars,
       s.forecast.status, "baseline", observed_close);
}

string TrialName(const int index)
{
   switch(index)
   {
      case 0: return "confirmed_swing";
      case 1: return "structure_reversal";
      case 2: return "early_warning";
      case 3: return "fixed_breakout_failure";
      case 4: return "breakout_retest";
      default: return "all_upgrades";
   }
}

int TrialFlags(const int index)
{
   switch(index)
   {
      case 0: return CF_SWING_FILTER;
      case 1: return CF_REVERSAL_CONFIRM;
      case 2: return CF_EARLY_WARNING;
      case 3: return CF_BREAKOUT_FAILURE;
      case 4: return CF_BREAKOUT_RETEST;
      default: return CF_SWING_FILTER | CF_REVERSAL_CONFIRM | CF_EARLY_WARNING |
                      CF_BREAKOUT_FAILURE | CF_BREAKOUT_RETEST;
   }
}

void LogTrial(const string event, const ENUM_TIMEFRAMES period, const CFForecast &f, const int index,
              const datetime bar_time, const string observed_close = "")
{
   Log(event, period, f.setup, bar_time, f.signal_bar, f.bars, f.status, TrialName(index), observed_close);
}

void CompareClosed(CFTrial &trial, const CFWindow &w, const CFReading &baseline,
                   const ENUM_TIMEFRAMES period, const string event, const bool allow_start, const int index)
{
   if(csv[CsvIndex(period)] == INVALID_HANDLE || (index == 0 ? !CompareSwings : !CompareVariants)) return;
   const int flags = TrialFlags(index);
   const string observed_close = Price(w.bar[0].close);
   if(trial.forecast.status == CF_ACTIVE)
   {
      CFAdvanceTrial(trial.forecast, w, chart_tick_size, flags);
      if(trial.forecast.status != CF_ACTIVE)
         LogTrial("outcome", period, trial.forecast, index, w.bar[0].time, observed_close);
   }

   CFReading candidate = baseline;
   CFTrialRead(trial, w, chart_tick_size, flags, allow_start, candidate);
   if(candidate.category != CF_NONE)
      Log(event, period, candidate, w.bar[0].time, 0, -1, CF_IDLE, TrialName(index), observed_close);
   if(!allow_start || candidate.decision != CF_SETUP || trial.forecast.status == CF_ACTIVE) return;
   CFStart(trial.forecast, candidate, w.bar[0].time);
   LogTrial("forecast", period, trial.forecast, index, w.bar[0].time, observed_close);
}

void LogManaged(const string event, const CFStream &s, const datetime bar_time, const string observed_close = "")
{
   Log(event, s.period, s.managed.forecast.setup, bar_time, s.managed.forecast.signal_bar,
       s.managed.forecast.bars, s.managed.forecast.status, "managed", observed_close,
       CFAdviceName(s.managed.advice), s.managed.explanation, CFMarketName(s.local_market),
       s.period == PERIOD_M5 ? CFMarketName(s.higher_market) : "");
}

bool ValidRates(const MqlRates &rates[], const int count)
{
   for(int i = 0; i < count; ++i)
   {
      if(!CFValidBar(rates[i])) return false;
      if(i > 0 && rates[i].time >= rates[i - 1].time) return false;
   }
   return true;
}

// Resolve the M15 snapshot as of this specific M5 close, including catch-up.
// Never substitute today's latest M15 bar when reading an older M5 candle.
CFMarket HigherContext(const datetime cutoff)
{
   if(!ReadM15) return CF_MARKET_UNKNOWN;
   const int seconds = PeriodSeconds(PERIOD_M15);
   if(CFClosedBy(higher_cache_bar, seconds, cutoff) && cutoff < higher_cache_bar + 2 * seconds)
      return higher_cache_market;
   int shift = iBarShift(_Symbol, PERIOD_M15, cutoff - 1, false);
   if(shift < 0) return CF_MARKET_UNKNOWN;
   datetime open = iTime(_Symbol, PERIOD_M15, shift);
   if(!CFClosedBy(open, seconds, cutoff)) ++shift;
   if(shift < 1) return CF_MARKET_UNKNOWN; // Shift zero is still forming in MT5.
   open = iTime(_Symbol, PERIOD_M15, shift);
   if(!CFClosedBy(open, seconds, cutoff) || cutoff >= open + 2 * seconds) return CF_MARKET_UNKNOWN;
   MqlRates context_rates[];
   ArraySetAsSeries(context_rates, true);
   const int copied = CopyRates(_Symbol, PERIOD_M15, shift, CF_HISTORY, context_rates);
   if(copied != CF_HISTORY || context_rates[0].time != open ||
      !SeriesInfoInteger(_Symbol, PERIOD_M15, SERIES_SYNCHRONIZED) ||
      !ValidRates(context_rates, copied)) return CF_MARKET_UNKNOWN;
   CFWindow context = {};
   for(int i = 0; i < CF_HISTORY; ++i) context.bar[i] = context_rates[i];
   higher_cache_market = CFReadMarket(context, chart_tick_size, true);
   higher_cache_bar = open;
   return higher_cache_market;
}

void UpdateManaged(CFStream &s, const CFWindow &w, const bool allow_start)
{
   const CFStatus old_status = s.managed.forecast.status;
   const CFAdvice old_advice = s.managed.advice;
   const string old_explanation = s.managed.explanation;
   s.local_market = CFReadMarket(w, chart_tick_size, false);
   s.higher_market = s.period == PERIOD_M5 ? HigherContext(w.bar[0].time + PeriodSeconds(s.period)) : CF_MARKET_UNKNOWN;
   s.plan = s.reading;
   if(old_status != CF_ACTIVE)
   {
      CFContextualPlan(s.planner, w, chart_tick_size, s.local_market, s.higher_market, allow_start, s.plan);
      if(!allow_start && s.plan.decision == CF_SETUP)
      {
         s.plan.decision = CF_WAIT;
         s.plan.qualifier = "Entry needs a fresh close";
      }
   }
   CFManageOnBar(s.managed, w, s.plan, chart_tick_size, allow_start);
   const string observed_close = Price(w.bar[0].close);
   if(old_status == CF_ACTIVE && s.managed.forecast.status != CF_ACTIVE)
   {
      s.plan.decision = CF_WAIT;
      s.plan.qualifier = "Wait for a fresh setup after this forecast ends";
   }
   if(s.plan.category != CF_NONE || s.plan.decision == CF_WAIT || s.planner.pending_bars > 0)
      Log("plan", s.period, s.plan, s.last_bar, 0, -1, CF_IDLE, "managed", observed_close, "", "",
          CFMarketName(s.local_market), s.period == PERIOD_M5 ? CFMarketName(s.higher_market) : "");
   if(old_status == CF_ACTIVE && s.managed.forecast.status != CF_ACTIVE)
   {
      s.last_outcome_code = s.managed.forecast.status;
      s.last_outcome_close = s.managed.advice == CF_EXIT ? w.bar[0].close : 0.0;
      s.last_outcome = OutcomeText(s.last_outcome_code, s.last_outcome_close);
      LogManaged("outcome", s, s.last_bar, observed_close);
   }
   else if(old_status != CF_ACTIVE && s.managed.forecast.status == CF_ACTIVE)
   {
      LogManaged("forecast", s, s.last_bar, observed_close);
      if(AlertOnNewSetup && !MQLInfoInteger(MQL_TESTER))
         Alert(_Symbol, " ", FrameName(s.period), " ", CFDecisionName(s.managed.forecast.setup), " | ",
               CFCategoryName(s.managed.forecast.setup.category), " | Target ", Price(s.managed.forecast.setup.target),
               " | Invalidation ", Price(s.managed.forecast.setup.invalidation));
   }
   else if(s.managed.forecast.status == CF_ACTIVE &&
           (s.managed.advice != old_advice || s.managed.explanation != old_explanation))
      LogManaged("management", s, s.last_bar, observed_close);
}

void ProcessClosed(CFStream &s, const MqlRates &rates[], const int index, const string event,
                   const bool allow_start)
{
   CFWindow w = {};
   for(int i = 0; i < CF_HISTORY; ++i) w.bar[i] = rates[index + i];
   s.last_bar = w.bar[0].time;
   s.waiting_for_new_close = !allow_start;
   if(s.forecast.status == CF_ACTIVE)
   {
      CFAdvance(s.forecast, w.bar[0], chart_tick_size);
      if(s.forecast.status != CF_ACTIVE) EndForecast(s, s.last_bar, Price(w.bar[0].close));
   }
   CFRead(w, chart_tick_size, s.reading);
   if(AutoTrading && allow_start && s.auto_ticket != 0 &&
      s.reading.decision == CF_SETUP && s.reading.direction == -s.auto_direction)
      AutoCancelPending(s, "opposite setup appeared");
   UpdateManaged(s, w, allow_start);
   Log(event, s.period, s.reading, s.last_bar, 0, -1, CF_IDLE);
   for(int lane = 0; lane < CF_TRIAL_COUNT; ++lane)
      CompareClosed(s.trials[lane], w, s.reading, s.period, event, allow_start, lane);
   if(!allow_start || s.reading.decision != CF_SETUP || s.forecast.status == CF_ACTIVE) return;

   CFStart(s.forecast, s.reading, s.last_bar);
   Log("forecast", s.period, s.forecast.setup, s.last_bar, s.forecast.signal_bar, 0, CF_ACTIVE);
   if(allow_start) AutoTradeSignal(s, w);
}

bool UpdateStream(CFStream &s)
{
   if(!s.enabled) return false;
   const datetime current_open = iTime(_Symbol, s.period, 0);
   const datetime newest = iTime(_Symbol, s.period, 1);
   if(current_open <= newest || newest == 0 || newest <= s.last_bar) return false;

   const int catchup = CF_CATCHUP; // Replay everything that closed while away (weekend/restart).
   int count = CF_HISTORY;
   if(s.last_bar != 0)
   {
      const int previous_shift = iBarShift(_Symbol, s.period, s.last_bar, true);
      if(previous_shift > 1 && previous_shift <= catchup + 1)
         count += previous_shift - 1; // Include the old bar for overlap validation.
   }
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   const int copied = CopyRates(_Symbol, s.period, 1, count, rates);
   if(copied < CF_HISTORY || !SeriesInfoInteger(_Symbol, s.period, SERIES_SYNCHRONIZED)) return false;
   // A new candle may have appeared during the copy. Recalculate the required history next pass.
   if(rates[0].time != newest || iTime(_Symbol, s.period, 0) != current_open ||
      !ValidRates(rates, copied)) return false;
   if(s.last_bar == 0)
   {
      ProcessClosed(s, rates, 0, "initial_reading", false);
      return true;
   }

   int overlap = -1;
   for(int i = 1; i < copied; ++i)
   {
      if(rates[i].time != s.last_bar) continue;
      overlap = i;
      break;
   }
   if(overlap < 0)
   {
      // CopyRates can make more history available after the first anchor lookup.
      // Retry with the longer request if the anchor now exists inside our cap.
      const int loaded_shift = iBarShift(_Symbol, s.period, s.last_bar, true);
      if(loaded_shift > 1 && loaded_shift <= catchup + 1 && copied < CF_HISTORY + loaded_shift - 2)
         return false;
   }
   const CFHistoryState replay = CFReplayState(copied, count, overlap);
   if(replay == CF_HISTORY_RETRY) return false;
   if(replay == CF_HISTORY_READY)
   {
      // Replay older closes for outcomes only. Even the latest closed candle
      // may be stale if the next bar opened after a weekend/session gap.
      const bool fresh = CFFreshClose(newest, current_open, PeriodSeconds(s.period));
      for(int i = overlap - 1; i >= 0; --i)
      {
         const string event = i > 0 ? "catchup_reading" : (fresh ? "reading" : "session_gap_reading");
         ProcessClosed(s, rates, i, event, i == 0 && fresh);
      }
   }
   else
   {
      if(s.forecast.status == CF_ACTIVE)
      {
         s.forecast.status = CF_DATA_GAP;
         EndForecast(s, newest);
      }
      if(s.managed.forecast.status == CF_ACTIVE)
      {
         s.managed.forecast.status = CF_DATA_GAP;
         s.managed.advice = CF_STANDBY;
         s.managed.explanation = "Waiting for a new setup";
         s.managed.warning_bars = 0;
         s.last_outcome_code = CF_DATA_GAP;
         s.last_outcome_close = 0.0;
         s.last_outcome = CFStatusName(CF_DATA_GAP);
         LogManaged("outcome", s, newest);
      }
      s.planner.pending_bars = 0;
      for(int lane = 0; lane < CF_TRIAL_COUNT; ++lane)
      {
         s.trials[lane].pending_bars = 0;
         if(s.trials[lane].forecast.status != CF_ACTIVE) continue;
         s.trials[lane].forecast.status = CF_DATA_GAP;
         LogTrial("outcome", s.period, s.trials[lane].forecast, lane, newest);
      }
      // No new forecast until a close is observed after resynchronizing.
      ProcessClosed(s, rates, 0, "resync_reading", false);
   }
   return true;
}

string PeriodLabel()
{
   switch(Period())
   {
      case PERIOD_M1:  return "M1";
      case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      case PERIOD_H4:  return "H4";
      case PERIOD_D1:  return "D1";
      case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN1";
      default:         return IntegerToString(Period());
   }
}

void Level(const string frame, const string kind, const bool visible, const double price,
           const color ink, const ENUM_LINE_STYLE style)
{
   const string name = CF_OBJECTS + frame + kind;
   if(!visible)
   {
      if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
      return;
   }
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_COLOR, ink);
      ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   }
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, frame + " " + kind + " @ " + Price(price));
}

const color CF_BG     = C'15,21,33';   // deep navy card
const color CF_BORDER = C'44,62,86';   // hairline border
const color CF_WHITE  = C'236,241,248';
const color CF_MUTED  = C'152,167,189';
const color CF_DIM    = C'105,118,140';
const color CF_M5     = C'115,211,251';
const color CF_M15    = C'202,172,249';
const color CF_GOOD   = C'80,220,150';
const color CF_WARN   = C'247,183,117';
const color CF_BAD    = C'248,136,136';
const int CF_PANEL_W  = 760;
const int CF_LINE_H   = 21;
const int CF_GAP      = 10;

string PanelPrice(const double value)
{
   const string raw = DoubleToString(MathAbs(value), _Digits);
   const int dot = StringFind(raw, ".");
   const string whole = dot < 0 ? raw : StringSubstr(raw, 0, dot);
   const string frac = dot < 0 ? "" : StringSubstr(raw, dot);
   string grouped = "";
   const int n = StringLen(whole);
   for(int i = 0; i < n; ++i)
   {
      grouped += StringSubstr(whole, i, 1);
      const int remaining = n - i - 1;
      if(remaining > 0 && remaining % 3 == 0) grouped += ",";
   }
   return (value < 0 ? "-" : "") + grouped + frac;
}

string PanelMoney(const double value)
{
   return (value >= 0 ? "+" : "-") + PanelPrice(MathAbs(value));
}

void PanelRect(const string suffix, const int x, const int y, const int w, const int h,
               const color bg, const color ink)
{
   const string name = CF_OBJECTS + suffix;
   ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_COLOR, ink);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, "\n");
}

void Divider(const string suffix, const int y)
{
   PanelRect(suffix, 22, y, CF_PANEL_W - 44, 1, CF_BORDER, CF_BORDER);
}

void Label(const string suffix, const string text, const int x, const int y,
           const color ink, const bool bold = false)
{
   const string name = CF_OBJECTS + suffix;
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, "\n");
   ObjectSetString(0, name, OBJPROP_FONT, bold ? "Segoe UI Semibold" : "Segoe UI");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 10);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, ink);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
}

string FrameStamp(const datetime value)
{
   return TimeToString(value, TIME_HOURS | TIME_MINUTES);
}

color AdviceInk(const CFAdvice advice)
{
   switch(advice)
   {
      case CF_EXIT:      return CF_BAD;
      case CF_WATCH:     return CF_WARN;
      case CF_SUPPORTED:
      case CF_NEW:       return CF_GOOD;
      case CF_HOLD:      return CF_WHITE;
      default:           return CF_MUTED;
   }
}

string AccountCurrency()
{
   const string ccy = AccountInfoString(ACCOUNT_CURRENCY);
   return ccy == "" ? "USD" : ccy;
}

string PositionLine(const CFStream &s, color &ink)
{
   ulong ticket; int type; double open_price, sl, tp;
   if(!FindAutoPosition(s, ticket, type, open_price, sl, tp)) return "";
   PositionSelectByTicket(ticket);
   const double profit = PositionGetDouble(POSITION_PROFIT);
   const double volume = PositionGetDouble(POSITION_VOLUME);
   const bool is_buy = (type == (int)POSITION_TYPE_BUY);
   const string ccy = AccountCurrency();
   const double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   const double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   ink = profit >= 0 ? CF_GOOD : CF_BAD;
   string line = StringFormat("POSITION %s %.2f @ %s", is_buy ? "BUY" : "SELL", volume,
                              PanelPrice(open_price));
   if(sl > 0)
   {
      line += "   ·   SL " + PanelPrice(sl);
      if(tick_size > 0 && tick_value > 0)
         line += StringFormat(" (-%.2f %s)", volume * MathAbs(open_price - sl) / tick_size * tick_value, ccy);
   }
   else line += "   ·   SL off";
   if(tp > 0)
   {
      line += "   ·   TP " + PanelPrice(tp);
      if(tick_size > 0 && tick_value > 0)
         line += StringFormat(" (+%.2f %s)", volume * MathAbs(tp - open_price) / tick_size * tick_value, ccy);
   }
   else line += "   ·   TP off";
   line += "   ·   P/L " + PanelMoney(profit) + " " + ccy;
   return line;
}

string PositionBidAskLine(const CFStream &s)
{
   ulong ticket; int type; double open_price, sl, tp;
   if(!FindAutoPosition(s, ticket, type, open_price, sl, tp)) return "";
   const bool is_buy = (type == (int)POSITION_TYPE_BUY);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   string line = "Bid " + PanelPrice(bid) + "   ·   Ask " + PanelPrice(ask);
   line += "   ·   exit at " + (is_buy ? "Bid" : "Ask");
   return line;
}

string PendingLine(const CFStream &s, color &ink)
{
   if(s.auto_ticket == 0) return "";
   ink = CF_WARN;
   const string dir = s.auto_direction >= 0 ? "BUY STOP" : "SELL STOP";
   const int elapsed = s.auto_created > 0 ? (int)((TimeCurrent() - s.auto_created) / PeriodSeconds(s.period)) : 0;
   int left = PendingBars - elapsed;
   if(left < 0) left = 0;
   string line = StringFormat("PENDING %s   ·   %d bar%s left   ·   #%I64u", dir, left, left == 1 ? "" : "s", s.auto_ticket);
   return line;
}

// Renders one timeframe block and returns how many lines it used.
int DrawStream(const CFStream &s, const int y)
{
   const string frame = FrameName(s.period);
   const color accent = s.period == PERIOD_M5 ? CF_M5 : CF_M15;
   const int x = 24;
   int lines = 0;
   if(!s.enabled)
   {
      Label(frame + "title", frame + "   Disabled", x, y, CF_DIM, true);
      return 2;
   }
   const bool ready = s.last_bar != 0;
   const int header_y = y;
   Label(frame + "title", frame, x, header_y, accent, true);
   Label(frame + "last", ready ? "last closed  " + FrameStamp(s.last_bar) : "waiting for closed-candle history",
         x + 44, header_y, CF_DIM);
   ++lines;
   if(!ready) return 2;

   string market = "Market: " + CFMarketName(s.local_market);
   if(s.period == PERIOD_M5) market += "   ·   M15 context: " + CFMarketName(s.higher_market);
   Label(frame + "market", market, x, y + CF_LINE_H * lines, CF_MUTED);
   ++lines;

   Label(frame + "reading", CFCategoryName(s.reading.category) + "   ", x, y + CF_LINE_H * lines, CF_WHITE, true);
   Label(frame + "reason", "·  " + s.reading.reason, x + 7 * StringLen(CFCategoryName(s.reading.category)) + 10,
         y + CF_LINE_H * lines, CF_MUTED);
   ++lines;

   const bool active = s.managed.forecast.status == CF_ACTIVE;
   const string cue = active ? "Candle cue: " : "";
   const string decision = ready ? cue + CFDecisionName(s.plan) + "   ·   " + s.plan.qualifier : "";
   const color decision_color = s.plan.decision == CF_SETUP ? accent : CF_MUTED;
   Label(frame + "decision", decision, x, y + CF_LINE_H * lines, decision_color);
   ++lines;

   if(active)
   {
      const string direction = s.managed.forecast.setup.direction > 0 ? "UP" : "DOWN";
      Label(frame + "forecast",
            "Active " + direction, x, y + CF_LINE_H * lines, CF_WHITE, true);
      Label(frame + "levels",
            "Target " + PanelPrice(s.managed.forecast.setup.target) + "   ·   Invalidation " +
            PanelPrice(s.managed.forecast.setup.invalidation),
            x + 90, y + CF_LINE_H * lines, CF_MUTED);
      ++lines;
      const double risk = MathAbs(s.managed.forecast.setup.entry - s.managed.forecast.setup.invalidation);
      const double r_mult = risk > 0 ? s.managed.best_progress / risk : 0.0;
      Label(frame + "progress",
            StringFormat("Bar %d/%d   ·   est %d-%d   ·   peak %+.2fR", s.managed.forecast.bars,
                         s.managed.forecast.setup.max_bars, s.managed.forecast.setup.min_bars,
                         s.managed.forecast.setup.max_bars, r_mult),
            x, y + CF_LINE_H * lines, CF_MUTED);
      ++lines;
   }
   else
   {
      Label(frame + "forecast",
            s.waiting_for_new_close ? "Waiting for the next close to start forecasting"
                                    : "No active forecast — watching for setups",
            x, y + CF_LINE_H * lines, CF_DIM);
      ++lines;
   }

   Label(frame + "advice", CFAdviceName(s.managed.advice) + "   ·   " + s.managed.explanation,
         x, y + CF_LINE_H * lines, AdviceInk(s.managed.advice));
   ++lines;

   color line_ink = CF_WARN;
   const string pos = PositionLine(s, line_ink);
   if(pos != "")
   {
      Label(frame + "position", "●", x, y + CF_LINE_H * lines, line_ink);
      Label(frame + "positiontext", pos, x + 16, y + CF_LINE_H * lines, CF_WHITE);
      ++lines;
      Label(frame + "positionsub", PositionBidAskLine(s), x + 16, y + CF_LINE_H * lines, CF_MUTED);
      ++lines;
   }
   else
   {
      const string pending = PendingLine(s, line_ink);
      if(pending != "")
      {
         Label(frame + "pending", "●", x, y + CF_LINE_H * lines, line_ink);
         Label(frame + "pendingtext", pending, x + 16, y + CF_LINE_H * lines, CF_WHITE);
         ++lines;
      }
   }

   if(s.last_outcome != "")
   {
      Label(frame + "outcome", "Last:  " + s.last_outcome, x, y + CF_LINE_H * lines, CF_DIM);
      ++lines;
   }

   Level(frame, " target", active && ShowLevels, active ? s.managed.forecast.setup.target : 0,
         accent, s.period == PERIOD_M5 ? STYLE_DOT : STYLE_DASH);
   Level(frame, " invalidation", active && ShowLevels, active ? s.managed.forecast.setup.invalidation : 0,
         s.period == PERIOD_M5 ? CF_BAD : CF_WARN,
         s.period == PERIOD_M5 ? STYLE_DOT : STYLE_DASH);
   return lines;
}

// One pulsing line shown when the market is closed/withheld.
void DrawOnlyLine(const string line, const color ink)
{
   const string panel = CF_OBJECTS + "statuspanel";
   const string dot = CF_OBJECTS + "statusdot";
   const string label = CF_OBJECTS + "statusline";
   ObjectsDeleteAll(0, CF_OBJECTS);
   PanelRect("statuspanel", 10, 16, CF_PANEL_W, 44, CF_BG, CF_BORDER);
   ObjectCreate(0, dot, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, dot, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, dot, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, dot, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, dot, OBJPROP_HIDDEN, true);
   ObjectSetString(0, dot, OBJPROP_TOOLTIP, "\n");
   ObjectSetString(0, dot, OBJPROP_FONT, "Segoe UI");
   ObjectSetInteger(0, dot, OBJPROP_FONTSIZE, 10);
   ObjectSetInteger(0, dot, OBJPROP_COLOR, ink);
   ObjectSetInteger(0, dot, OBJPROP_XDISTANCE, 24);
   ObjectSetInteger(0, dot, OBJPROP_YDISTANCE, 30);
   ObjectSetString(0, dot, OBJPROP_TEXT, "●");
   Label("statusline", line, 42, 30, CF_WHITE, true);
   g_drawn_status = line;
   ChartRedraw(0);
}

int StreamLineCount(const CFStream &s)
{
   if(!s.enabled) return 2;
   if(s.last_bar == 0) return 2;
   int lines = 6; // header, market, reading, decision, forecast, advice
   if(s.managed.forecast.status == CF_ACTIVE) ++lines; // progress
   ulong ticket; int type; double price, sl, tp;
   if(FindAutoPosition(s, ticket, type, price, sl, tp)) lines += 2;
   else if(s.auto_ticket != 0) ++lines;
   if(s.last_outcome != "") ++lines;
   return lines;
}

void HeartbeatStream(CFStream &s)
{
   const string frame = FrameName(s.period);
   color ink = CF_WARN;
   const string pos = PositionLine(s, ink);
   if(pos != "")
   {
      if(ObjectFind(0, CF_OBJECTS + frame + "positiontext") >= 0)
         ObjectSetString(0, CF_OBJECTS + frame + "positiontext", OBJPROP_TEXT, pos);
      if(ObjectFind(0, CF_OBJECTS + frame + "positionsub") >= 0)
         ObjectSetString(0, CF_OBJECTS + frame + "positionsub", OBJPROP_TEXT, PositionBidAskLine(s));
      if(ObjectFind(0, CF_OBJECTS + frame + "position") >= 0)
         ObjectSetInteger(0, CF_OBJECTS + frame + "position", OBJPROP_COLOR, ink);
      return;
   }
   const string pending = PendingLine(s, ink);
   if(pending != "" && ObjectFind(0, CF_OBJECTS + frame + "pendingtext") >= 0)
      ObjectSetString(0, CF_OBJECTS + frame + "pendingtext", OBJPROP_TEXT, pending);
}

void Heartbeat()
{
   if(ObjectFind(0, CF_OBJECTS + "footerclock") < 0) return;
   ObjectSetString(0, CF_OBJECTS + "footerclock", OBJPROP_TEXT,
                   "updated " + TimeToString(TimeCurrent(), TIME_SECONDS));
   HeartbeatStream(streams[0]);
   HeartbeatStream(streams[1]);
}

void Draw()
{
   UpdateMarketStatus();
   if(g_market_status == CM_CLOSED || g_market_status == CM_WITHHELD)
   {
      DrawOnlyLine(g_market_text + ActiveSummary(), g_market_color);
      return;
   }
   ObjectsDeleteAll(0, CF_OBJECTS);
   const int m5_lines = StreamLineCount(streams[0]);
   const int m15_lines = StreamLineCount(streams[1]);
   const int header_h = 46;
   const int y_m5 = 16 + header_h + CF_GAP;
   const int y_m15 = y_m5 + m5_lines * CF_LINE_H + CF_GAP + 1 + CF_GAP;
   const int footer_y = y_m15 + m15_lines * CF_LINE_H + CF_GAP + 1 + 8;
   const int height = footer_y + 24;
   PanelRect("panel", 10, 16, CF_PANEL_W, height, CF_BG, CF_BORDER);

   // Header — one glance: what this is, what the market says, what we're allowed to do.
   Label("title", "TRADER  /  " + _Symbol, 24, 26, CF_WHITE, true);
   const color auto_color = AutoTrading ? CF_WARN : CF_DIM;
   string strip = "● " + (AutoTrading ? "AUTOTRADING ON" : "MONITOR ONLY");
   strip += "    ·    CSV " + ((SaveCsv && !(log_error[0] || log_error[1])) ? "on" : (SaveCsv ? "error" : "off"));
   int live = 0;
   ulong t; int ty; double p, slx, tpx;
   if(FindAutoPosition(streams[0], t, ty, p, slx, tpx)) ++live;
   if(FindAutoPosition(streams[1], t, ty, p, slx, tpx)) ++live;
   const int pendings = (streams[0].auto_ticket != 0 ? 1 : 0) + (streams[1].auto_ticket != 0 ? 1 : 0);
   strip += "    ·    ";
   if(live == 0 && pendings == 0) strip += "flat";
   else
   {
      if(live > 0) strip += IntegerToString(live) + (live == 1 ? " position" : " positions");
      if(live > 0 && pendings > 0) strip += "  ·  ";
      if(pendings > 0) strip += IntegerToString(pendings) + (pendings == 1 ? " pending" : " pendings");
   }
   strip += "    ·    " + g_market_text;
   Label("status", strip, 24, 48, auto_color, true);
   Divider("headerdv", 16 + header_h);

   DrawStream(streams[0], y_m5);
   Divider("middv", y_m5 + m5_lines * CF_LINE_H + CF_GAP);
   DrawStream(streams[1], y_m15);
   Divider("footdv", footer_y - 8);
   Label("footer", "Candle Forecast  ·  closed-candle M5 / M15 reading", 24, footer_y, CF_DIM);
   Label("footerclock", "updated " + TimeToString(TimeCurrent(), TIME_SECONDS), 560, footer_y, CF_DIM);

   g_drawn_status = g_market_text;
   ChartRedraw(0);
}

void ResetStream(CFStream &s, const ENUM_TIMEFRAMES period, const bool enabled)
{
   s.period = period;
   s.enabled = enabled;
   s.last_bar = 0;
   s.waiting_for_new_close = true;
   s.forecast.status = CF_IDLE;
   s.managed.forecast.status = CF_IDLE;
   s.managed.advice = CF_STANDBY;
   s.managed.explanation = "Waiting for a new setup";
   s.managed.warning_bars = 0;
   s.planner.pending_bars = 0;
   s.planner.forecast.status = CF_IDLE;
   s.local_market = s.higher_market = CF_MARKET_UNKNOWN;
   s.last_outcome_code = CF_IDLE;
   s.last_outcome_close = 0.0;
   for(int lane = 0; lane < CF_TRIAL_COUNT; ++lane)
   {
      s.trials[lane].forecast.status = CF_IDLE;
      s.trials[lane].pending_bars = 0;
   }
   s.last_outcome = "";
   s.auto_ticket = 0;
   s.auto_created = 0;
   s.auto_dead_level = 0.0;
   s.auto_direction = 0;
   CFReading empty = {};
   s.auto_signal = empty;
   s.auto_exit_bar = 0;
}

int OnInit()
{
   chart_tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(chart_tick_size <= 0) chart_tick_size = _Point;
   if(chart_tick_size <= 0) return INIT_FAILED;
   ResetStream(streams[0], PERIOD_M5, ReadM5);
   ResetStream(streams[1], PERIOD_M15, ReadM15);
   log_error[0] = false;
   log_error[1] = false;
   higher_cache_bar = 0;
   higher_cache_market = CF_MARKET_UNKNOWN;
   g_market_status = CM_OPEN;
   g_market_text = "";
   g_market_was_closed = false;
   out_of_range = (Period() != PERIOD_M5 && Period() != PERIOD_M15);
   show_panel = !MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_VISUAL_MODE);
   if(out_of_range)
   {
      // Inert but harmless: keep saved state untouched, show only one line.
      if(show_panel) DrawOnlyLine("Trader works on M5 / M15 charts only - current chart: " + PeriodLabel(), C'248,136,136');
      return INIT_SUCCEEDED; // No timer, no CSV, no state restore.
   }
   RestoreStateAll();
   auto_trade.SetExpertMagicNumber((ulong)Magic);
   auto_trade.SetTypeFilling((ENUM_ORDER_TYPE_FILLING)MarketFilling());
   auto_trade.SetDeviationInPoints((ulong)MaxSlippage);
   RecoverAutoOrders();
   if(AutoTrading) Print("Candle Forecast: AutoTrading input is ON - real orders will be sent on qualified setups.");
   if(ReadM5) OpenLogFor(PERIOD_M5);
   if(ReadM15) OpenLogFor(PERIOD_M15);
   const bool restored = (streams[0].last_bar != 0 || streams[1].last_bar != 0);
   if(restored) Print("Candle Forecast: state restored from terminal global variables.");
   if(show_panel)
   {
      Draw();
      if(!EventSetTimer(1)) Print("Candle Forecast: timer unavailable; updates will use ticks only.");
   }
   return INIT_SUCCEEDED;
}

void Refresh()
{
   if(out_of_range) return;
   UpdateMarketStatus();
   if(g_market_status == CM_CLOSED)
   {
      if(!g_market_was_closed)
      {
         g_market_was_closed = true;
         Print("Candle Forecast: market closed; monitoring paused.");
      }
      if(show_panel) DrawOnlyLine(g_market_text + ActiveSummary(), g_market_color);
      return;
   }
   if(g_market_was_closed)
   {
      g_market_was_closed = false;
      Print("Candle Forecast: market open; monitoring resumed.");
   }
   const bool m5_changed = UpdateStream(streams[0]);
   const bool m15_changed = UpdateStream(streams[1]);
   if(m5_changed || m15_changed) SaveStateAll();
   AutoOrdersSweep();
   AutoExits(streams[0]);
   AutoExits(streams[1]);
   if(show_panel)
   {
      // Panel self-heal: if MT5 destroyed the chart objects (timeframe switch), rebuild them.
      const bool line_mode = (g_market_status == CM_WITHHELD);
      const bool missing = line_mode
         ? ObjectFind(0, CF_OBJECTS + "statusline") < 0
         : (ObjectFind(0, CF_OBJECTS + "panel") < 0 ||
            ObjectFind(0, CF_OBJECTS + "M5title") < 0 ||
            ObjectFind(0, CF_OBJECTS + "M15title") < 0);
      if(missing || m5_changed || m15_changed || g_market_text != g_drawn_status) Draw();
      if(TimeCurrent() != g_last_beat)
      {
         g_last_beat = TimeCurrent();
         Heartbeat();
      }
   }
}

void OnTick()  { Refresh(); }
void OnTimer() { Refresh(); }

void OnDeinit(const int reason)
{
   EventKillTimer();
   SaveStateAll();
   for(int i = 0; i < 2; ++i)
   {
      if(streams[i].managed.forecast.status == CF_ACTIVE)
         LogManaged("session_end", streams[i], streams[i].last_bar);
      if(streams[i].forecast.status == CF_ACTIVE)
         Log("session_end", streams[i].period, streams[i].forecast.setup, streams[i].last_bar,
             streams[i].forecast.signal_bar, streams[i].forecast.bars, CF_ACTIVE);
      for(int lane = 0; lane < CF_TRIAL_COUNT; ++lane)
         if(streams[i].trials[lane].forecast.status == CF_ACTIVE)
            LogTrial("session_end", streams[i].period, streams[i].trials[lane].forecast, lane, streams[i].last_bar);
   }
   for(int i = 0; i < 2; ++i)
   {
      if(csv[i] != INVALID_HANDLE) FileClose(csv[i]);
      csv[i] = INVALID_HANDLE;
   }
   if(show_panel)
   {
      ObjectsDeleteAll(0, CF_OBJECTS);
      ChartRedraw(0);
   }
}
