#property strict
#property version   "1.40"
#property description "Closed-candle M5/M15 forecasts. Monitor only; does not send orders."

#include "CandleLogic.mqh"

input bool ReadM5          = true;  // Read M5 candles
input bool ReadM15         = true;  // Read M15 candles
input bool ShowLevels      = true;  // Plot active targets and invalidation levels
input bool AlertOnNewSetup = false; // MT5 popup for a new forecast
input bool SaveCsv         = true;  // Log readings, forecasts and outcomes to CSV
input bool CompareSwings   = true;  // Log the standalone confirmed-swing comparison
input bool CompareVariants = true;  // Log the other experiments and all upgrades together

#define CF_OBJECTS "CandleForecast."
#define CF_CATCHUP 256
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
};

CFStream streams[2];
double chart_tick_size;
int csv = INVALID_HANDLE;
bool log_error = false;
bool show_panel = false;
datetime higher_cache_bar = 0;
CFMarket higher_cache_market = CF_MARKET_UNKNOWN;

string FrameName(const ENUM_TIMEFRAMES period) { return period == PERIOD_M5 ? "M5" : "M15"; }
string Price(const double value) { return DoubleToString(value, _Digits); }
string Stamp(const datetime value) { return TimeToString(value, TIME_DATE | TIME_SECONDS); }

void LogFailed()
{
   if(log_error) return;
   Print("Candle Forecast: CSV logging failed (error ", GetLastError(), ").");
   log_error = true;
   if(csv != INVALID_HANDLE) FileClose(csv);
   csv = INVALID_HANDLE;
}

void OpenLog()
{
   if(!SaveCsv) return;
   const string path = "CandleForecast\\candles_" + IntegerToString(ChartID()) + "_" +
                       IntegerToString((long)TimeLocal()) + "_" +
                       IntegerToString((long)GetTickCount64()) + ".csv";
   csv = FileOpen(path, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ, ',', CP_UTF8);
   if(csv == INVALID_HANDLE)
   {
      LogFailed();
      return;
   }
   if(FileWrite(csv, "event", "symbol", "timeframe", "bar_open_broker_time", "signal_bar_open_broker_time",
                "category", "decision", "direction", "reason", "qualifier", "reference_close", "target",
                "invalidation", "estimated_min_bars", "expiry_bars", "elapsed_bars", "status", "variant", "observed_close", "original_breakout_level", "advice", "management_reason", "local_market", "higher_market") == 0)
   {
      LogFailed();
      return;
   }
   Print("Candle Forecast: CSV in MQL5/Files/", path, " (tester uses its agent's Files folder).");
}

void Log(const string event, const ENUM_TIMEFRAMES period, const CFReading &r, const datetime bar_time,
         const datetime signal_time, const int elapsed, const CFStatus status, const string variant = "baseline", const string observed_close = "",
         const string advice = "", const string management_reason = "",
         const string local_market = "", const string higher_market = "")
{
   if(csv == INVALID_HANDLE) return;
   const bool setup = r.decision == CF_SETUP;
   if(FileWrite(csv, event, _Symbol, FrameName(period), Stamp(bar_time),
                signal_time > 0 ? Stamp(signal_time) : "", CFCategoryName(r.category), CFDecisionName(r),
                r.direction > 0 ? "Up" : (r.direction < 0 ? "Down" : ""), r.reason, r.qualifier,
                Price(r.entry), setup ? Price(r.target) : "", setup ? Price(r.invalidation) : "",
                setup ? IntegerToString(r.min_bars) : "", setup ? IntegerToString(r.max_bars) : "",
                elapsed >= 0 ? IntegerToString(elapsed) : "",
                status != CF_IDLE ? CFStatusName(status) : "", variant, observed_close,
                r.category == CF_BREAKOUT && (setup || r.decision == CF_WAIT) ?
                Price(r.breakout_level) : "", advice, management_reason, local_market, higher_market) == 0)
   {
      LogFailed();
      return;
   }
   FileFlush(csv);
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
   if(csv == INVALID_HANDLE || (index == 0 ? !CompareSwings : !CompareVariants)) return;
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
      !SeriesInfoInteger(_Symbol, PERIOD_M15, SERIES_SYNCHRONIZED)) return CF_MARKET_UNKNOWN;
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
      CFContextualPlan(s.planner, w, chart_tick_size, s.local_market, s.higher_market, allow_start, s.plan);
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
      s.last_outcome = CFStatusName(s.managed.forecast.status);
      if(s.managed.advice == CF_EXIT) s.last_outcome += " @ close " + observed_close;
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
   UpdateManaged(s, w, allow_start);
   Log(event, s.period, s.reading, s.last_bar, 0, -1, CF_IDLE);
   for(int lane = 0; lane < CF_TRIAL_COUNT; ++lane)
      CompareClosed(s.trials[lane], w, s.reading, s.period, event, allow_start, lane);
   if(!allow_start || s.reading.decision != CF_SETUP || s.forecast.status == CF_ACTIVE) return;

   CFStart(s.forecast, s.reading, s.last_bar);
   Log("forecast", s.period, s.forecast.setup, s.last_bar, s.forecast.signal_bar, 0, CF_ACTIVE);
}

bool UpdateStream(CFStream &s)
{
   if(!s.enabled) return false;
   const datetime newest = iTime(_Symbol, s.period, 1);
   if(newest == 0 || newest == s.last_bar) return false;

   int count = CF_HISTORY;
   if(s.last_bar != 0)
   {
      const int previous_shift = iBarShift(_Symbol, s.period, s.last_bar, true);
      if(previous_shift > 1 && previous_shift <= CF_CATCHUP + 1)
         count += previous_shift - 1; // Include the old bar for overlap validation.
   }
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   const int copied = CopyRates(_Symbol, s.period, 1, count, rates);
   if(copied < CF_HISTORY || !SeriesInfoInteger(_Symbol, s.period, SERIES_SYNCHRONIZED)) return false;
   // A new candle may have appeared during the copy. Recalculate the required history next pass.
   if(rates[0].time != newest) return false;
   if(s.last_bar == 0)
   {
      ProcessClosed(s, rates, 0, "initial_reading", false);
      return true;
   }
   if(newest < s.last_bar) return false;

   int overlap = -1;
   for(int i = 1; i < copied; ++i)
   {
      if(rates[i].time != s.last_bar) continue;
      overlap = i;
      break;
   }
   if(overlap > 0 && overlap <= CF_CATCHUP && copied >= overlap + CF_HISTORY - 1)
   {
      // Catch up chronologically. Don't create forecasts for candles already missed.
      for(int i = overlap - 1; i >= 0; --i)
         ProcessClosed(s, rates, i, i == 0 ? "reading" : "catchup_reading", i == 0);
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
         s.managed.explanation = CFStatusName(CF_DATA_GAP);
         s.managed.warning_bars = 0;
         s.last_outcome = s.managed.explanation;
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

void Label(const string suffix, const string text, const int x, const int y, const color ink, const int size = 9)
{
   const string name = CF_OBJECTS + suffix;
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetString(0, name, OBJPROP_TOOLTIP, "\n");
      ObjectSetString(0, name, OBJPROP_FONT, "Segoe UI");
   }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, ink);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetString(0, name, OBJPROP_TEXT, text == "" ? " " : text);
}

void Background()
{
   const string name = CF_OBJECTS + "panel";
   if(ObjectFind(0, name) >= 0) return;
   ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 22);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, 588);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, 391);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, C'20,29,43');
   ObjectSetInteger(0, name, OBJPROP_COLOR, C'56,73,94');
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, "\n");
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

void DrawStream(const CFStream &s, const int y)
{
   const string frame = FrameName(s.period);
   const color accent = s.period == PERIOD_M5 ? C'115,211,251' : C'202,172,249';
   const color muted = C'164,179,198';
   const int x = 23;
   const bool ready = s.enabled && s.last_bar != 0;
   const bool active = ready && s.managed.forecast.status == CF_ACTIVE;
   string heading = frame;
   if(!s.enabled)   heading += "  |  Disabled";
   else if(!ready)  heading += "  |  Waiting for closed candle history";
   else             heading += "  |  Last closed bar opened " + Stamp(s.last_bar);
   Label(frame + "title", heading, x, y, accent, 10);
   string market = "Market: " + CFMarketName(s.local_market);
   if(s.period == PERIOD_M5) market += "  |  M15 context: " + CFMarketName(s.higher_market);
   Label(frame + "market", ready ? market : "", x, y + 21, muted);
   Label(frame + "reading", ready ? CFCategoryName(s.reading.category) + "  |  " + s.reading.reason : "",
         x, y + 39, clrWhite);
   const string cue = active ? "Candle cue: " : "Plan: ";
   const string decision = ready ? cue + CFDecisionName(s.plan) + "  |  " + s.plan.qualifier : "";
   const color decision_color = ready && s.plan.decision == CF_SETUP ? accent : muted;
   Label(frame + "decision", decision, x, y + 57, decision_color);

   string details = s.waiting_for_new_close ? "Waiting for the next close to start forecasting" : "No active forecast";
   string progress = "";
   if(active)
   {
      const string direction = s.managed.forecast.setup.direction > 0 ? "UP" : "DOWN";
      details = "Active " + direction + " (" + CFCategoryName(s.managed.forecast.setup.category) +
                ")  |  Target " + Price(s.managed.forecast.setup.target) +
                "  |  Invalidation " + Price(s.managed.forecast.setup.invalidation);
      progress = "Ref. " + Price(s.managed.forecast.setup.entry) + "  |  Est. " +
                 IntegerToString(s.managed.forecast.setup.min_bars) + "-" +
                 IntegerToString(s.managed.forecast.setup.max_bars) + " bars  |  " +
                 IntegerToString(s.managed.forecast.bars) + "/" + IntegerToString(s.managed.forecast.setup.max_bars) + " bars elapsed";
   }
   Label(frame + "forecast", ready ? details : "", x, y + 75, clrWhite);
   Label(frame + "progress", ready ? progress : "", x, y + 93, muted);
   const color advice_color = s.managed.advice == CF_EXIT ? C'248,136,136' :
                              (s.managed.advice == CF_WATCH ? C'247,183,117' : accent);
   Label(frame + "advice", ready ? CFAdviceName(s.managed.advice) + "  |  " + s.managed.explanation : "",
         x, y + 111, advice_color);
   Label(frame + "outcome", ready && s.last_outcome != "" ? "Last outcome: " + s.last_outcome : "",
         x, y + 129, muted);
   Level(frame, " target", active && ShowLevels, active ? s.managed.forecast.setup.target : 0,
         accent, s.period == PERIOD_M5 ? STYLE_DOT : STYLE_DASH);
   Level(frame, " invalidation", active && ShowLevels, active ? s.managed.forecast.setup.invalidation : 0,
         s.period == PERIOD_M5 ? C'248,136,136' : C'247,183,117',
         s.period == PERIOD_M5 ? STYLE_DOT : STYLE_DASH);
}

void Draw()
{
   Background();
   Label("title", "Trader  /  " + _Symbol, 23, 30, clrWhite, 12);
   Label("mode", "Monitor only - orders off  |  " + (SaveCsv ? (log_error ? "CSV unavailable" : "CSV logging on") : "CSV logging off"),
         23, 53, C'164,179,198');
   DrawStream(streams[0], 77);
   DrawStream(streams[1], 239);
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
   for(int lane = 0; lane < CF_TRIAL_COUNT; ++lane)
   {
      s.trials[lane].forecast.status = CF_IDLE;
      s.trials[lane].pending_bars = 0;
   }
   s.last_outcome = "";
}

int OnInit()
{
   chart_tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(chart_tick_size <= 0) chart_tick_size = _Point;
   if(chart_tick_size <= 0) return INIT_FAILED;
   ResetStream(streams[0], PERIOD_M5, ReadM5);
   ResetStream(streams[1], PERIOD_M15, ReadM15);
   log_error = false;
   higher_cache_bar = 0;
   higher_cache_market = CF_MARKET_UNKNOWN;
   OpenLog();
   // Nonvisual tests use ticks only and do not need chart objects.
   show_panel = !MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_VISUAL_MODE);
   if(show_panel)
   {
      Draw();
      if(!EventSetTimer(1)) Print("Candle Forecast: timer unavailable; updates will use ticks only.");
   }
   return INIT_SUCCEEDED;
}

void Refresh()
{
   const bool m5_changed = UpdateStream(streams[0]);
   const bool m15_changed = UpdateStream(streams[1]);
   if(show_panel && (m5_changed || m15_changed)) Draw();
}

void OnTick()  { Refresh(); }
void OnTimer() { Refresh(); }

void OnDeinit(const int reason)
{
   EventKillTimer();
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
   if(csv != INVALID_HANDLE) FileClose(csv);
   csv = INVALID_HANDLE;
   if(show_panel)
   {
      ObjectsDeleteAll(0, CF_OBJECTS);
      ChartRedraw(0);
   }
}
