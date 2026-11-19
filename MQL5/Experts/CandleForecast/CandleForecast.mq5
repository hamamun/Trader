#property strict
#property version   "1.00"
#property description "Closed-candle M5/M15 forecasts. Monitor only; does not send orders."

#include "CandleLogic.mqh"

input bool ReadM5          = true;  // Read M5 candles
input bool ReadM15         = true;  // Read M15 candles
input bool ShowLevels      = true;  // Plot active targets and invalidation levels
input bool AlertOnNewSetup = false; // MT5 popup for a new forecast
input bool SaveCsv         = true;  // Log readings, forecasts and outcomes to CSV

#define CF_OBJECTS "CandleForecast."
#define CF_CATCHUP 256

struct CFStream
{
   ENUM_TIMEFRAMES period;
   bool enabled;
   bool waiting_for_new_close;
   datetime last_bar;
   CFReading reading;
   CFForecast forecast;
   string last_outcome;
};

CFStream streams[2];
double chart_tick_size;
int csv = INVALID_HANDLE;
bool log_error = false;
bool show_panel = false;

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
                "invalidation", "estimated_min_bars", "expiry_bars", "elapsed_bars", "status") == 0)
   {
      LogFailed();
      return;
   }
   Print("Candle Forecast: CSV in MQL5/Files/", path, " (tester uses its agent's Files folder).");
}

void Log(const string event, const CFStream &s, const CFReading &r, const datetime bar_time,
         const datetime signal_time, const int elapsed, const CFStatus status)
{
   if(csv == INVALID_HANDLE) return;
   const bool setup = r.decision == CF_SETUP;
   if(FileWrite(csv, event, _Symbol, FrameName(s.period), Stamp(bar_time),
                signal_time > 0 ? Stamp(signal_time) : "", CFCategoryName(r.category), CFDecisionName(r),
                r.direction > 0 ? "Up" : (r.direction < 0 ? "Down" : ""), r.reason, r.qualifier,
                Price(r.entry), setup ? Price(r.target) : "", setup ? Price(r.invalidation) : "",
                setup ? IntegerToString(r.min_bars) : "", setup ? IntegerToString(r.max_bars) : "",
                elapsed >= 0 ? IntegerToString(elapsed) : "",
                status != CF_IDLE ? CFStatusName(status) : "") == 0)
   {
      LogFailed();
      return;
   }
   FileFlush(csv);
}

void EndForecast(CFStream &s, const datetime event_bar)
{
   s.last_outcome = CFStatusName(s.forecast.status) + " (" + IntegerToString(s.forecast.bars) + " bars)";
   Log("outcome", s, s.forecast.setup, event_bar, s.forecast.signal_bar, s.forecast.bars, s.forecast.status);
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
      if(s.forecast.status != CF_ACTIVE) EndForecast(s, s.last_bar);
   }
   CFRead(w, chart_tick_size, s.reading);
   Log(event, s, s.reading, s.last_bar, 0, -1, CF_IDLE);
   if(!allow_start || s.reading.decision != CF_SETUP || s.forecast.status == CF_ACTIVE) return;

   CFStart(s.forecast, s.reading, s.last_bar);
   Log("forecast", s, s.forecast.setup, s.last_bar, s.forecast.signal_bar, 0, CF_ACTIVE);
   if(AlertOnNewSetup && !MQLInfoInteger(MQL_TESTER))
      Alert(_Symbol, " ", FrameName(s.period), " ", CFDecisionName(s.reading), " | ",
            CFCategoryName(s.reading.category), " | Target ", Price(s.reading.target),
            " | Invalidation ", Price(s.reading.invalidation));
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
   ObjectSetInteger(0, name, OBJPROP_YSIZE, 309);
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
   const bool active = ready && s.forecast.status == CF_ACTIVE;
   string heading = frame;
   if(!s.enabled)   heading += "  |  Disabled";
   else if(!ready)  heading += "  |  Waiting for closed candle history";
   else             heading += "  |  Last closed bar opened " + Stamp(s.last_bar);
   Label(frame + "title", heading, x, y, accent, 10);
   Label(frame + "reading", ready ? CFCategoryName(s.reading.category) + "  |  " + s.reading.reason : "",
         x, y + 21, clrWhite);
   const string decision = ready ? CFDecisionName(s.reading) + "  |  " + s.reading.qualifier : "";
   const color decision_color = ready && s.reading.decision == CF_SETUP ? accent : muted;
   Label(frame + "decision", decision, x, y + 39, decision_color);

   string details = s.waiting_for_new_close ? "Waiting for the next close to start forecasting" : "No active forecast";
   string progress = "";
   if(active)
   {
      const int mins = PeriodSeconds(s.period) / 60;
      const string direction = s.forecast.setup.direction > 0 ? "UP" : "DOWN";
      details = "Active " + direction + " (" + CFCategoryName(s.forecast.setup.category) +
                ")  |  Target " + Price(s.forecast.setup.target) +
                "  |  Invalidation " + Price(s.forecast.setup.invalidation);
      progress = "Est. " + IntegerToString(s.forecast.setup.min_bars * mins) + "-" +
                 IntegerToString(s.forecast.setup.max_bars * mins) + " trading min  |  " +
                 IntegerToString(s.forecast.bars) + "/" + IntegerToString(s.forecast.setup.max_bars) + " bars elapsed";
      if(s.reading.decision == CF_SETUP && s.reading.direction != s.forecast.setup.direction)
         progress += "  |  Opposite setup now";
   }
   Label(frame + "forecast", ready ? details : "", x, y + 57, clrWhite);
   Label(frame + "progress", ready ? progress : "", x, y + 75, muted);
   Label(frame + "outcome", ready && s.last_outcome != "" ? "Last outcome: " + s.last_outcome : "",
         x, y + 93, muted);
   Level(frame, " target", active && ShowLevels, active ? s.forecast.setup.target : 0,
         accent, s.period == PERIOD_M5 ? STYLE_DOT : STYLE_DASH);
   Level(frame, " invalidation", active && ShowLevels, active ? s.forecast.setup.invalidation : 0,
         s.period == PERIOD_M5 ? C'248,136,136' : C'247,183,117',
         s.period == PERIOD_M5 ? STYLE_DOT : STYLE_DASH);
}

void Draw()
{
   Background();
   Label("title", "Candle Forecast  /  " + _Symbol, 23, 30, clrWhite, 12);
   Label("mode", "Monitor only - orders off  |  " + (SaveCsv ? (log_error ? "CSV unavailable" : "CSV logging on") : "CSV logging off"),
         23, 53, C'164,179,198');
   DrawStream(streams[0], 77);
   DrawStream(streams[1], 199);
   ChartRedraw(0);
}

void ResetStream(CFStream &s, const ENUM_TIMEFRAMES period, const bool enabled)
{
   s.period = period;
   s.enabled = enabled;
   s.last_bar = 0;
   s.waiting_for_new_close = true;
   s.forecast.status = CF_IDLE;
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
      if(streams[i].forecast.status == CF_ACTIVE)
         Log("session_end", streams[i], streams[i].forecast.setup, streams[i].last_bar,
             streams[i].forecast.signal_bar, streams[i].forecast.bars, CF_ACTIVE);
   if(csv != INVALID_HANDLE) FileClose(csv);
   csv = INVALID_HANDLE;
   if(show_panel)
   {
      ObjectsDeleteAll(0, CF_OBJECTS);
      ChartRedraw(0);
   }
}
