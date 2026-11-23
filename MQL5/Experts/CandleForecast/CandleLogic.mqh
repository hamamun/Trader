#ifndef CANDLE_FORECAST_LOGIC_MQH
#define CANDLE_FORECAST_LOGIC_MQH

#define CF_HISTORY 24
#define CF_CATCHUP 5000 // Bars replayable after downtime (weekend/holiday/terminal restart); older is untrackable

enum CFHistoryState { CF_HISTORY_RETRY, CF_HISTORY_READY, CF_HISTORY_GAP };

enum CFCategory { CF_NONE, CF_REVERSAL, CF_CONTINUATION, CF_BREAKOUT,
                  CF_FAILED_BREAKOUT, CF_RANGE_BOUNCE };
enum CFDecision { CF_SKIP, CF_WAIT, CF_SETUP };
enum CFStatus { CF_IDLE, CF_ACTIVE, CF_TARGET, CF_INVALIDATED, CF_EXPIRED,
                CF_AMBIGUOUS, CF_DATA_GAP, CF_STRUCTURE_EXIT, CF_BREAKOUT_EXIT, CF_CANDLE_EXIT };

enum CFExperiment { CF_SWING_FILTER = 1, CF_REVERSAL_CONFIRM = 2, CF_EARLY_WARNING = 4,
                    CF_BREAKOUT_FAILURE = 8, CF_BREAKOUT_RETEST = 16 };

// Always newest closed candle first. No current (forming) candle is passed in.
struct CFWindow { MqlRates bar[CF_HISTORY]; };

// The current bar's timestamp is only a clock here; no forming OHLC is read.
bool CFFreshClose(const datetime closed_open, const datetime current_open, const int seconds)
{
   return closed_open > 0 && seconds > 0 && current_open - closed_open == seconds;
}

bool CFValidBar(const MqlRates &value)
{
   return value.time > 0 && MathIsValidNumber(value.open) && MathIsValidNumber(value.high) &&
          MathIsValidNumber(value.low) && MathIsValidNumber(value.close) &&
          value.low <= MathMin(value.open, value.close) && MathMax(value.open, value.close) <= value.high;
}

CFHistoryState CFReplayState(const int copied, const int requested, const int anchor_index)
{
   if(copied < CF_HISTORY) return CF_HISTORY_RETRY;
   if(anchor_index > 0 && anchor_index <= CF_CATCHUP)
   {
      // Oldest replayed bar has index anchor_index - 1 and needs CF_HISTORY bars.
      if(copied >= anchor_index + CF_HISTORY - 1) return CF_HISTORY_READY;
      return copied < requested ? CF_HISTORY_RETRY : CF_HISTORY_GAP;
   }
   return copied < requested ? CF_HISTORY_RETRY : CF_HISTORY_GAP;
}

struct CFReading
{
   CFCategory category;
   CFDecision decision;
   int direction;
   string reason;
   string qualifier;
   double entry, target, invalidation, breakout_level;
   int min_bars, max_bars;
};

struct CFForecast
{
   CFStatus status;
   CFReading setup;
   datetime signal_bar, last_checked_bar;
   int bars;
};

struct CFTrial
{
   CFForecast forecast;
   CFReading pending;
   double pending_level;
   int pending_bars; // Zero means no pending confirmation.
};

enum CFAdvice { CF_STANDBY, CF_NEW, CF_HOLD, CF_SUPPORTED, CF_WATCH, CF_EXIT };
enum CFMarket { CF_MARKET_UNKNOWN, CF_MARKET_UP, CF_MARKET_DOWN, CF_MARKET_RANGE, CF_MARKET_MIXED };

struct CFManaged
{
   CFForecast forecast;
   CFAdvice advice;
   string explanation;
   double warning_adverse, warning_favorable;
   int warning_bars, quiet_bars;
   double best_progress;
};

struct CFLevels { double high, low; bool sideways; };

string CFCategoryName(const CFCategory category)
{
   switch(category)
   {
      case CF_REVERSAL:        return "Reversal";
      case CF_CONTINUATION:    return "Continuation";
      case CF_BREAKOUT:        return "Breakout";
      case CF_FAILED_BREAKOUT: return "Failed breakout";
      case CF_RANGE_BOUNCE:    return "Range bounce";
      default:                return "Candle context";
   }
}

string CFStatusName(const CFStatus status)
{
   switch(status)
   {
      case CF_ACTIVE:      return "Active";
      case CF_TARGET:      return "Target reached";
      case CF_INVALIDATED: return "Invalidated";
      case CF_EXPIRED:     return "Expired";
      case CF_AMBIGUOUS:   return "Both levels touched (order unknown)";
      case CF_STRUCTURE_EXIT: return "Early exit: opposite structure break";
      case CF_BREAKOUT_EXIT:  return "Early exit: breakout failed";
      case CF_CANDLE_EXIT:    return "Early exit: opposing candles confirmed";
      case CF_DATA_GAP:    return "Untracked (data gap)";
      default:            return "No forecast";
   }
}

string CFDecisionName(const CFReading &r)
{
   if(r.decision == CF_SETUP) return r.direction > 0 ? "Buy setup" : "Sell setup";
   if(r.decision == CF_WAIT)  return "Waiting for confirmation";
   return "No trade";
}

CFLevels CFReference(const CFWindow &w, const int start, const double typical)
{
   CFLevels levels;
   levels.high = w.bar[start].high;
   levels.low = w.bar[start].low;
   for(int i = start + 1; i < start + 8; ++i)
   {
      levels.high = MathMax(levels.high, w.bar[i].high);
      levels.low = MathMin(levels.low, w.bar[i].low);
   }
   int upper = 0, lower = 0;
   const double width = levels.high - levels.low;
   for(int i = start; i < start + 8; ++i)
   {
      if(w.bar[i].high >= levels.high - 0.25 * typical) ++upper;
      if(w.bar[i].low <= levels.low + 0.25 * typical) ++lower;
   }
   levels.sideways = width >= 1.5 * typical && width <= 4.2 * typical &&
                     MathAbs(w.bar[start].close - w.bar[start + 7].close) <= 0.45 * width &&
                     upper >= 2 && lower >= 2;
   return levels;
}

int CFTrend(const CFWindow &w, const int start, const double typical)
{
   int up = 0, down = 0;
   for(int i = start; i < start + 5; ++i)
   {
      if(w.bar[i].close > w.bar[i + 1].close) ++up;
      if(w.bar[i].close < w.bar[i + 1].close) ++down;
   }
   const double move = w.bar[start].close - w.bar[start + 5].close;
   if(up >= 4 && move >= 1.5 * typical) return 1;
   if(down >= 4 && move <= -1.5 * typical) return -1;
   return 0;
}

bool CFImpulse(const MqlRates &b, const int direction, const double typical)
{
   const double span = b.high - b.low;
   const double finish = direction > 0 ? b.high - b.close : b.close - b.low;
   return span >= 0.65 * typical && direction * (b.close - b.open) >= 0.5 * span &&
          finish <= 0.25 * span;
}

bool CFRejects(const MqlRates &b, const int direction, const double typical)
{
   const double span = b.high - b.low;
   const double wick = direction > 0 ? MathMin(b.open, b.close) - b.low :
                                        b.high - MathMax(b.open, b.close);
   const double finish = direction > 0 ? b.high - b.close : b.close - b.low;
   return span >= 0.60 * typical && wick >= 0.45 * span && finish <= 0.40 * span;
}

// Older local highs/lows provide the first visible obstacle, not a guaranteed target.
double CFNearestSwing(const CFWindow &w, const int direction, const double entry,
                      const double epsilon)
{
   double best = entry;
   for(int i = 2; i < CF_HISTORY - 1; ++i)
   {
      const double level = direction > 0 ? w.bar[i].high : w.bar[i].low;
      const double near_level = direction > 0 ? w.bar[i - 1].high : w.bar[i - 1].low;
      const double far_level = direction > 0 ? w.bar[i + 1].high : w.bar[i + 1].low;
      if(direction * (level - near_level) < 0 || direction * (level - far_level) < 0 ||
         (level == near_level && level == far_level)) continue;
      const double distance = direction * (level - entry);
      if(distance > epsilon && (best == entry || distance < direction * (best - entry)))
         best = level;
   }
   return best;
}

double CFTypicalRange(const CFWindow &w, const int start)
{
   double total = 0.0;
   for(int i = start; i < start + 16; ++i) total += w.bar[i].high - w.bar[i].low;
   return total / 16.0;
}

enum CFEntryTrigger { CF_ENTRY_MARKET, CF_ENTRY_PENDING };

// Autotrading trigger decision made on the signal candle itself.
// Turning and continuation entries (reversals, failed breaks, range rejections,
// pullback resumptions) already have their edge at the decision close, so they use
// the market. Plain breakouts only deserve the market when the close is a
// convincing move beyond the level; a marginal break is armed as a pending stop
// instead so a fakeout never fills.
int CFEntryMode(const CFCategory category, const int direction,
                const double close, const double breakout_level,
                const double typical, const bool strong_close)
{
   if(category != CF_BREAKOUT) return CF_ENTRY_MARKET;
   const double beyond = direction * (close - breakout_level);
   if(strong_close && typical > 0.0 && beyond >= 0.25 * typical) return CF_ENTRY_MARKET;
   return CF_ENTRY_PENDING;
}

void CFQualify(CFReading &r, const double tick_size, const double typical)
{
   r.decision = CF_SKIP;
   r.min_bars = r.max_bars = 0;
   const double risk = r.direction * (r.entry - r.invalidation);
   const double reward = r.direction * (r.target - r.entry);
   if(typical <= 0.0 || risk < 0.5 * tick_size || reward < 1.10 * risk)
   {
      r.qualifier = "Too little room before the next objective";
      return;
   }

   // A heuristic, in bars of the source timeframe (not a probability or wall-clock promise).
   double pace = 0.45;
   if(r.category == CF_BREAKOUT || r.category == CF_CONTINUATION) pace = 0.65;
   if(r.category == CF_REVERSAL) pace = 0.35;
   const double estimate = reward / (typical * pace);
   r.min_bars = (int)MathMin(12.0, MathMax(1.0, MathFloor(0.70 * estimate)));
   r.max_bars = (int)MathMin(18.0, MathMax(r.min_bars + 1.0, MathCeil(1.60 * estimate)));
   r.decision = CF_SETUP;
   r.qualifier = "Clear direction with objective and invalidation";
}

void CFRead(const CFWindow &w, const double tick_size, CFReading &r)
{
   r.category = CF_NONE;
   r.decision = CF_SKIP;
   r.direction = 0;
   r.reason = "No clear directional candle sequence";
   r.qualifier = "No qualified setup";
   r.entry = w.bar[0].close;
   r.target = r.invalidation = r.breakout_level = 0.0;
   r.min_bars = r.max_bars = 0;
   if(tick_size <= 0.0) return;

   const double typical = CFTypicalRange(w, 1);
   if(typical < tick_size)
   {
      r.reason = "Recent candles have too little movement";
      return;
   }

   const MqlRates b = w.bar[0];
   const MqlRates previous = w.bar[1];
   const CFLevels ref = CFReference(w, 1, typical);
   const CFLevels older = CFReference(w, 2, typical);
   const double edge = MathMax(tick_size, 0.08 * typical);
   const double pad = MathMax(tick_size, 0.10 * typical);
   const bool strong_up = CFImpulse(b, 1, typical);
   const bool strong_down = CFImpulse(b, -1, typical);
   const bool upper_wick = CFRejects(b, -1, typical);
   const bool lower_wick = CFRejects(b, 1, typical);
   // A failed breakout returns inside the level's reference range. If price closes
   // through the opposite side instead, leave it for the breakout check below.
   const bool inside_ref = b.close > ref.low && b.close < ref.high;
   const bool inside_older = b.close > older.low && b.close < older.high;
   const bool failed_up_now = b.high >= ref.high + edge && inside_ref && upper_wick;
   const bool failed_down_now = b.low <= ref.low - edge && inside_ref && lower_wick;
   const bool failed_up_later = previous.close >= older.high + edge && inside_older && strong_down;
   const bool failed_down_later = previous.close <= older.low - edge && inside_older && strong_up;
   double stop_anchor = b.close;
   double target = b.close;

   // Structural events take priority over generic turn/pullback readings.
   if(b.high >= ref.high + edge && b.low <= ref.low - edge &&
      b.close <= ref.high && b.close >= ref.low)
   {
      r.decision = CF_WAIT;
      r.reason = "Candle swept both sides of the recent structure";
      r.qualifier = "Direction is unclear";
      return;
   }
   if(failed_up_now || failed_down_now || failed_up_later || failed_down_later)
   {
      r.category = CF_FAILED_BREAKOUT;
      // The one- and two-candle readings can reference different boundaries.
      if((failed_up_now || failed_up_later) && (failed_down_now || failed_down_later))
      {
         r.decision = CF_WAIT;
         r.reason = "Conflicting failed breaks on both sides";
         r.qualifier = "Direction is unclear";
         return;
      }
      r.direction = (failed_up_now || failed_up_later) ? -1 : 1;
      r.reason = r.direction > 0 ? "Price broke the recent low but closed back above it" :
                                   "Price broke the recent high but closed back below it";
      stop_anchor = r.direction > 0 ? (failed_down_later ? MathMin(b.low, previous.low) : b.low) :
                                      (failed_up_later ? MathMax(b.high, previous.high) : b.high);
      if(failed_up_later || failed_down_later) target = (older.high + older.low) / 2.0;
      else target = (ref.high + ref.low) / 2.0;
   }
   else if(b.close >= ref.high + edge || b.close <= ref.low - edge)
   {
      r.category = CF_BREAKOUT;
      r.direction = b.close > ref.high ? 1 : -1;
      r.breakout_level = r.direction > 0 ? ref.high : ref.low;
      r.reason = r.direction > 0 ? "Price closed above the recent high" :
                                   "Price closed below the recent low";
      if((r.direction > 0 && !strong_up) || (r.direction < 0 && !strong_down))
      {
         r.decision = CF_WAIT;
         r.qualifier = "Breakout close lacks conviction";
         return;
      }
      stop_anchor = r.breakout_level;
   }
   else if(ref.sideways)
   {
      if(lower_wick && b.low <= ref.low + 0.25 * typical && b.close > ref.low)
         r.direction = 1;
      else if(upper_wick && b.high >= ref.high - 0.25 * typical && b.close < ref.high)
         r.direction = -1;
      if(r.direction == 0)
      {
         r.reason = "Sideways range with no confirmed edge rejection";
         return;
      }
      r.category = CF_RANGE_BOUNCE;
      r.reason = r.direction > 0 ? "Lower wick rejected the bottom of a sideways range" :
                                   "Upper wick rejected the top of a sideways range";
      stop_anchor = r.direction > 0 ? MathMin(b.low, ref.low) : MathMax(b.high, ref.high);
      target = (ref.high + ref.low) / 2.0;
   }
   else
   {
      const int prior = CFTrend(w, 2, typical);
      if(prior != 0 && CFRejects(previous, -prior, typical) &&
         (prior < 0 ? previous.low <= older.low + edge : previous.high >= older.high - edge))
      {
         r.category = CF_REVERSAL;
         r.direction = -prior;
         r.reason = "A wick rejected an extreme after a clear move";
         if(!(r.direction > 0 ? strong_up && b.close > previous.high :
                                strong_down && b.close < previous.low))
         {
            r.decision = CF_WAIT;
            r.qualifier = "Need a strong close beyond the rejection candle";
            return;
         }
         stop_anchor = r.direction > 0 ? MathMin(b.low, previous.low) : MathMax(b.high, previous.high);
      }
      else
      {
         // Try short counter-moves, then require a close beyond their entire span.
         for(int n = 1; n <= 3; ++n)
         {
            const int trend = CFTrend(w, n + 1, typical);
            if(trend == 0 || trend * (previous.close - w.bar[n + 1].close) > -edge) continue;
            double pull_high = previous.high, pull_low = previous.low;
            for(int i = 2; i <= n; ++i)
            {
               pull_high = MathMax(pull_high, w.bar[i].high);
               pull_low = MathMin(pull_low, w.bar[i].low);
            }
            r.category = CF_CONTINUATION;
            r.direction = trend;
            r.reason = "A short pullback followed a clear directional move";
            if(!(trend > 0 ? strong_up && b.close > pull_high : strong_down && b.close < pull_low))
               continue;
            r.reason = "Strong close beyond the pullback in the trend direction";
            stop_anchor = trend > 0 ? MathMin(b.low, pull_low) : MathMax(b.high, pull_high);
            break;
         }
         if(r.category == CF_NONE) return;
         if(stop_anchor == b.close)
         {
            r.decision = CF_WAIT;
            r.qualifier = "Pullback has not broken in the trend direction";
            return;
         }
      }
   }

   const double swing = CFNearestSwing(w, r.direction, r.entry, 0.5 * tick_size);
   if(r.category == CF_RANGE_BOUNCE || r.category == CF_FAILED_BREAKOUT)
   {
      if(swing != r.entry && r.direction * (swing - target) < 0) target = swing;
   }
   else if(swing != r.entry) target = swing;
   else if(r.category == CF_BREAKOUT)
      target = (r.direction > 0 ? ref.high : ref.low) + r.direction * (ref.high - ref.low);
   else
   {
      r.qualifier = "No clear swing target ahead";
      return;
   }

   // Round invalidation away from entry and target toward entry to the symbol's tick size.
   const double raw_stop = (stop_anchor - r.direction * pad) / tick_size;
   r.invalidation = tick_size * (r.direction > 0 ? MathFloor(raw_stop + 1e-8) :
                                                  MathCeil(raw_stop - 1e-8));
   const double raw_target = target / tick_size;
   r.target = tick_size * (r.direction > 0 ? MathFloor(raw_target + 1e-8) :
                                            MathCeil(raw_target - 1e-8));
   CFQualify(r, tick_size, typical);
}

// +1 finds lows and -1 finds highs. Callers exclude not-yet-confirmed pivots.
bool CFIsPivot(const CFWindow &w, const int i, const int side, double &level)
{
   level = side > 0 ? w.bar[i].low : w.bar[i].high;
   for(int j = i - 2; j <= i + 2; ++j)
   {
      if(j == i) continue;
      const double neighbor = side > 0 ? w.bar[j].low : w.bar[j].high;
      if(side * (neighbor - level) <= 0) return false;
   }
   return true;
}

string CFMarketName(const CFMarket market)
{
   switch(market)
   {
      case CF_MARKET_UP:    return "Uptrend";
      case CF_MARKET_DOWN:  return "Downtrend";
      case CF_MARKET_RANGE: return "Sideways range";
      case CF_MARKET_MIXED: return "Mixed structure";
      default:              return "Unavailable";
   }
}

int CFMarketDirection(const CFMarket market)
{
   if(market == CF_MARKET_UP) return 1;
   if(market == CF_MARKET_DOWN) return -1;
   return 0;
}

bool CFTwoPivots(const CFWindow &w, const int side, double &latest, double &older)
{
   bool found = false;
   for(int i = 3; i < CF_HISTORY - 2; ++i)
   {
      double level = 0.0;
      if(!CFIsPivot(w, i, side, level)) continue;
      if(found) { older = level; return true; }
      latest = level;
      found = true;
   }
   return false;
}

// Latest bar can test already-known structure, but cannot confirm a new pivot.
CFMarket CFReadMarket(const CFWindow &w, const double tick_size, const bool include_latest)
{
   const int start = include_latest ? 0 : 1;
   const double typical = CFTypicalRange(w, 1);
   if(typical < tick_size) return CF_MARKET_MIXED;
   const CFLevels reference = CFReference(w, start, typical);
   if(reference.sideways) return CF_MARKET_RANGE;
   double high = 0.0, old_high = 0.0, low = 0.0, old_low = 0.0;
   const bool known_highs = CFTwoPivots(w, -1, high, old_high);
   const bool known_lows = CFTwoPivots(w, 1, low, old_low);
   const double edge = MathMax(tick_size, typical * 0.10);
   if(known_highs && known_lows)
   {
      if(high - old_high >= edge && low - old_low >= edge && w.bar[start].close >= low - edge)
         return CF_MARKET_UP;
      if(old_high - high >= edge && old_low - low >= edge && w.bar[start].close <= high + edge)
         return CF_MARKET_DOWN;
      return CF_MARKET_MIXED;
   }
   // A strong sequence can establish direction before four swings exist.
   const int direction = CFTrend(w, start, typical);
   if(direction > 0) return CF_MARKET_UP;
   if(direction < 0) return CF_MARKET_DOWN;
   return CF_MARKET_MIXED;
}

bool CFClosedBy(const datetime bar_open, const int seconds, const datetime decision_time)
{
   return bar_open > 0 && seconds > 0 && bar_open + seconds <= decision_time;
}

// Keep every baseline rule. In the comparison run only, a qualified reversal
// or range bounce must also reject a level that was confirmed beforehand.
void CFRequireConfirmedSwing(const CFWindow &w, const double tick_size, CFReading &r)
{
   if(r.decision != CF_SETUP || (r.category != CF_REVERSAL && r.category != CF_RANGE_BOUNCE)) return;
   const int reaction = r.category == CF_REVERSAL ? 1 : 0;
   const int direction = r.direction;
   const double extreme = direction > 0 ? w.bar[reaction].low : w.bar[reaction].high;
   const double tolerance = MathMax(tick_size, 0.25 * CFTypicalRange(w, reaction + 1));

   // Two closed neighbors on either side. Both newer neighbors must predate
   // the rejection itself; neither the rejection nor its confirmation can form the pivot.
   for(int i = reaction + 3; i < CF_HISTORY - 2; ++i)
   {
      double level = 0.0;
      if(!CFIsPivot(w, i, direction, level)) continue;
      if(MathAbs(extreme - level) > tolerance || direction * (w.bar[reaction].close - level) <= 0) continue;

      bool broken = false;
      for(int j = i - 1; j >= 0; --j)
      {
         if(direction * (w.bar[j].close - level) < -tolerance) { broken = true; break; }
      }
      if(!broken)
      {
         r.qualifier = "Rejection at a confirmed swing level";
         return;
      }
   }
   r.decision = CF_SKIP;
   r.qualifier = "No nearby unbroken swing confirmed before rejection";
}

void CFStart(CFForecast &f, const CFReading &r, const datetime time)
{
   f.setup = r;
   f.status = CF_ACTIVE;
   f.signal_bar = f.last_checked_bar = time;
   f.bars = 0;
}

void CFAdvance(CFForecast &f, const MqlRates &closed, const double tick_size)
{
   if(f.status != CF_ACTIVE || closed.time <= f.last_checked_bar) return;
   f.last_checked_bar = closed.time;
   ++f.bars;
   const bool up = f.setup.direction > 0;
   // Tick-rounded levels and the broker OHLC can differ by floating-point noise.
   const double epsilon = tick_size * 1e-6;
   const bool hit_target = up ? closed.high >= f.setup.target - epsilon : closed.low <= f.setup.target + epsilon;
   const bool hit_stop = up ? closed.low <= f.setup.invalidation + epsilon : closed.high >= f.setup.invalidation - epsilon;
   if(hit_target && hit_stop) f.status = CF_AMBIGUOUS;
   else if(hit_target)        f.status = CF_TARGET;
   else if(hit_stop)          f.status = CF_INVALIDATED;
   else if(f.bars >= f.setup.max_bars) f.status = CF_EXPIRED;
}

// Read only pivots fully known before the candle that tests the level.
// +1 direction requires a lower high for a reversal or a higher low for an exit.
bool CFStructureLevel(const CFWindow &w, const int direction, const bool exit_check,
                      const double edge, double &level)
{
   const int side = exit_check ? direction : -direction;
   int newer = -1;
   for(int i = exit_check ? 3 : 4; i < CF_HISTORY - 2; ++i)
   {
      double pivot = 0.0;
      if(!CFIsPivot(w, i, side, pivot)) continue;
      if(newer >= 0)
      {
         if(side * (level - pivot) <= 0) return false;
         // Ignore a level that had already been broken before the test sequence.
         for(int j = newer - 1; j >= (exit_check ? 1 : 2); --j)
            if(side * (w.bar[j].close - level) <= -edge) return false;
         return true;
      }
      level = pivot;
      newer = i;
   }
   return false;
}

void CFAdvanceTrial(CFForecast &f, const CFWindow &w, const double tick_size, const int flags)
{
   if(f.status != CF_ACTIVE || w.bar[0].time <= f.last_checked_bar) return;
   CFAdvance(f, w.bar[0], tick_size);
   // Target/stop touches happened during the candle; they take precedence over a close-based exit.
   if(f.status != CF_ACTIVE) return;
   const int direction = f.setup.direction;
   const double edge = tick_size * (1.0 - 1e-6);
   if((flags & CF_BREAKOUT_FAILURE) != 0 && f.setup.category == CF_BREAKOUT &&
      direction * (w.bar[0].close - f.setup.breakout_level) <= -edge)
   {
      f.status = CF_BREAKOUT_EXIT;
      return;
   }
   double level = 0.0;
   if((flags & CF_EARLY_WARNING) != 0 && CFStructureLevel(w, direction, true, edge, level) &&
      direction * (w.bar[1].close - level) > -edge &&
      direction * (w.bar[0].close - level) <= -edge)
      f.status = CF_STRUCTURE_EXIT;
}

string CFAdviceName(const CFAdvice advice)
{
   switch(advice)
   {
      case CF_NEW:   return "New forecast";
      case CF_HOLD:  return "Hold";
      case CF_SUPPORTED: return "Hold (supported)";
      case CF_WATCH: return "Watch";
      case CF_EXIT:  return "Exit early";
      default:       return "Wait";
   }
}

// One managed forecast per timeframe. A closed forecast cannot be replaced on
// the exit candle: wait for a new qualifying close instead of auto-flipping.
void CFManageOnBar(CFManaged &m, const CFWindow &w, const CFReading &reading,
                   const double tick_size, const bool allow_start)
{
   if(m.forecast.status != CF_IDLE && w.bar[0].time <= m.forecast.last_checked_bar) return;
   if(m.forecast.status != CF_ACTIVE)
   {
      m.advice = CF_STANDBY;
      m.explanation = allow_start && reading.decision == CF_WAIT ? reading.qualifier : "Waiting for a new setup";
      if(!allow_start || reading.decision != CF_SETUP) return;
      CFStart(m.forecast, reading, w.bar[0].time);
      m.warning_bars = m.quiet_bars = 0;
      m.best_progress = 0.0;
      m.advice = CF_NEW;
      m.explanation = "Setup has a target and a level that proves it wrong";
      return;
   }

   CFAdvanceTrial(m.forecast, w, tick_size, CF_EARLY_WARNING | CF_BREAKOUT_FAILURE);
   if(m.forecast.status != CF_ACTIVE)
   {
      m.warning_bars = 0;
      if(m.forecast.status == CF_STRUCTURE_EXIT || m.forecast.status == CF_BREAKOUT_EXIT)
      {
         m.advice = CF_EXIT;
         m.explanation = CFStatusName(m.forecast.status);
         return;
      }
      // The outcome line already reports what happened; return the advice line
      // to the watching state instead of repeating it there.
      m.advice = CF_STANDBY;
      m.explanation = "Waiting for a new setup";
      return;
   }

   const int direction = m.forecast.setup.direction;
   const double edge = tick_size * (1.0 - 1e-6);
   const double typical = CFTypicalRange(w, 1);
   const MqlRates latest = w.bar[0];
   const MqlRates previous = w.bar[1];
   const double previous_adverse = direction > 0 ? previous.low : previous.high;
   const double favorable = direction > 0 ? latest.high : latest.low;
   const double progress = direction * (favorable - m.forecast.setup.entry);
   const double improvement = MathMax(tick_size, 0.15 * typical);
   const bool new_progress = progress >= m.best_progress + improvement;
   if(new_progress)
   {
      m.best_progress = progress;
      m.quiet_bars = 0;
   }
   else ++m.quiet_bars;
   const bool opposite_setup = reading.decision == CF_SETUP && reading.direction == -direction;
   if(opposite_setup && CFImpulse(latest, -direction, typical) &&
      direction * (latest.close - previous_adverse) <= -edge)
   {
      m.forecast.status = CF_CANDLE_EXIT;
      m.warning_bars = 0;
      m.advice = CF_EXIT;
      m.explanation = "Strong opposite setup broke the previous candle";
      return;
   }

   if(m.warning_bars > 0)
   {
      if(direction * (latest.close - m.warning_adverse) <= -edge)
      {
         m.forecast.status = CF_CANDLE_EXIT;
         m.warning_bars = 0;
         m.advice = CF_EXIT;
         m.explanation = "Close confirmed the warning candle's break";
         return;
      }
      --m.warning_bars;
      if(direction * (latest.close - m.warning_favorable) >= edge || m.warning_bars == 0)
      {
         m.warning_bars = m.quiet_bars = 0;
         m.advice = CF_HOLD;
         m.explanation = "Warning did not confirm";
      }
      return;
   }

   const double target_distance = direction * (m.forecast.setup.target - m.forecast.setup.entry);
   const bool rejection = CFRejects(latest, -direction, typical) &&
                          progress >= MathMax(0.50 * typical, 0.40 * target_distance) &&
                          direction * (latest.close - previous.close) < 0.0;
   const bool stalled = m.forecast.bars >= (int)MathMax(2, m.forecast.setup.min_bars) &&
                        m.quiet_bars >= 3 && direction * (latest.close - previous.close) <= 0.0;
   if(opposite_setup || rejection || stalled)
   {
      m.warning_bars = 2;
      m.warning_adverse = direction > 0 ? latest.low : latest.high;
      m.warning_favorable = favorable;
      m.advice = CF_WATCH;
      m.explanation = opposite_setup ? "Opposite setup appeared; waiting for follow-through" :
                                       (rejection ? "Price rejected the move; watching the next closes" :
                                                    "Move stalled; watching for an adverse close");
      return;
   }
   const bool follows_through = new_progress && direction * (latest.close - previous.close) >= edge &&
                                CFImpulse(latest, direction, typical);
   m.advice = follows_through ? CF_SUPPORTED : CF_HOLD;
   m.explanation = follows_through ? "Strong close made fresh progress toward target" : "No confirmed reason to exit";
}

// A pending candidate holds its original level and target for up to three later
// closes. The trigger close becomes the reference; do not assume an earlier fill.
void CFTrialRead(CFTrial &trial, const CFWindow &w, const double tick_size,
                 const int flags, const bool allow_start, CFReading &r)
{
   const double edge = tick_size * (1.0 - 1e-6);
   if(trial.pending_bars > 0)
   {
      r = trial.pending;
      r.decision = CF_WAIT;
      const int direction = r.direction;
      const bool retest = r.category == CF_BREAKOUT;
      const double level = trial.pending_level;
      const double favorable = direction > 0 ? w.bar[0].high : w.bar[0].low;
      const double adverse = direction > 0 ? w.bar[0].low : w.bar[0].high;
      const double beyond = direction * (w.bar[0].close - level);
      const double typical = CFTypicalRange(w, 1);
      const double epsilon = tick_size * 1e-6;
      const bool touched_target = direction * (favorable - r.target) >= -epsilon;
      const bool failed = retest ? beyond <= -edge : direction * (adverse - r.invalidation) <= epsilon;
      const bool confirmed = beyond >= edge &&
                             (!retest || MathAbs(adverse - level) <= MathMax(tick_size, 0.25 * typical));
      --trial.pending_bars;
      if(touched_target || failed)
      {
         trial.pending_bars = 0;
         r.decision = CF_SKIP;
         r.qualifier = touched_target ? "Target already touched before entry" : "Setup invalidated before confirmation";
      }
      else if(confirmed)
      {
         trial.pending_bars = 0;
         r.entry = w.bar[0].close;
         if(retest)
         {
            const double raw = (adverse - direction * MathMax(tick_size, 0.10 * typical)) / tick_size;
            const double stop = tick_size * (direction > 0 ? MathFloor(raw + 1e-8) : MathCeil(raw - 1e-8));
            r.invalidation = direction > 0 ? MathMin(r.invalidation, stop) : MathMax(r.invalidation, stop);
         }
         CFQualify(r, tick_size, typical);
         if(r.decision == CF_SETUP)
            r.qualifier = retest ? "Retest held the original breakout level" :
                          (r.category == CF_FAILED_BREAKOUT ? "Strong reclaim was followed by a close past the signal candle" :
                                                            "Close confirmed the reversal through a prior swing");
      }
      else if(trial.pending_bars == 0)
      {
         r.decision = CF_SKIP;
         r.qualifier = "Confirmation window expired";
      }
      return;
   }

   if((flags & CF_SWING_FILTER) != 0) CFRequireConfirmedSwing(w, tick_size, r);
   if(r.decision != CF_SETUP || trial.forecast.status == CF_ACTIVE || !allow_start) return;
   if(r.category == CF_REVERSAL && (flags & CF_REVERSAL_CONFIRM) != 0)
   {
      double level = 0.0;
      if(!CFStructureLevel(w, r.direction, false, edge, level))
      {
         r.decision = CF_SKIP;
         r.qualifier = "No confirmed prior swing structure to break";
         return;
      }
      if(r.direction * (r.entry - level) >= edge)
      {
         r.qualifier = "Close confirmed the reversal through a prior swing";
         return;
      }
      trial.pending_level = level;
      r.qualifier = "Waiting for a close through the prior swing";
   }
   else if(r.category == CF_BREAKOUT && (flags & CF_BREAKOUT_RETEST) != 0)
   {
      trial.pending_level = r.breakout_level;
      r.qualifier = "Waiting for a retest of the original breakout level";
   }
   else return;
   trial.pending = r;
   trial.pending_bars = 3;
   r.decision = CF_WAIT;
}

// Context affects the managed entry only. The original reader and experiments
// remain independent benchmarks. Pending ideas keep their original target.
void CFContextualPlan(CFTrial &plan, const CFWindow &w, const double tick_size,
                      const CFMarket local_market, const CFMarket higher_market,
                      const bool allow_start, CFReading &r)
{
   if(plan.pending_bars > 0)
   {
      CFTrialRead(plan, w, tick_size, 0, allow_start, r);
      return;
   }
   if(r.decision != CF_SETUP || !allow_start) return;
   const int local = CFMarketDirection(local_market);
   const int higher = CFMarketDirection(higher_market);
   const bool counter_local = local == -r.direction;
   const bool counter_higher = higher == -r.direction;
   if(r.category == CF_CONTINUATION && (local != r.direction || counter_higher))
   {
      r.decision = CF_SKIP;
      r.qualifier = "Continuation needs a clear trend without M15 opposition";
      return;
   }
   if(r.category == CF_REVERSAL && (counter_local || counter_higher))
   {
      CFTrialRead(plan, w, tick_size, CF_REVERSAL_CONFIRM, allow_start, r);
      return;
   }
   if(r.category == CF_BREAKOUT)
   {
      const double normal = CFTypicalRange(w, 1);
      const bool stretched = r.direction * (r.entry - r.breakout_level) > normal;
      if(counter_local || counter_higher || stretched)
         CFTrialRead(plan, w, tick_size, CF_BREAKOUT_RETEST, allow_start, r);
      return;
   }
   if(r.category == CF_RANGE_BOUNCE && counter_higher)
   {
      CFRequireConfirmedSwing(w, tick_size, r);
      return;
   }
   if(r.category == CF_FAILED_BREAKOUT && (counter_local || counter_higher))
   {
      plan.pending_level = r.direction > 0 ? w.bar[0].high : w.bar[0].low;
      plan.pending = r;
      plan.pending_bars = 3;
      r.decision = CF_WAIT;
      r.qualifier = "Countertrend reclaim needs a follow-through close";
   }
}

#endif
