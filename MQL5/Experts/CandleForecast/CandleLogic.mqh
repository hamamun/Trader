#ifndef CANDLE_FORECAST_LOGIC_MQH
#define CANDLE_FORECAST_LOGIC_MQH

#define CF_HISTORY 24

enum CFCategory { CF_NONE, CF_REVERSAL, CF_CONTINUATION, CF_BREAKOUT,
                  CF_FAILED_BREAKOUT, CF_RANGE_BOUNCE };
enum CFDecision { CF_SKIP, CF_WAIT, CF_SETUP };
enum CFStatus { CF_IDLE, CF_ACTIVE, CF_TARGET, CF_INVALIDATED, CF_EXPIRED,
                CF_AMBIGUOUS, CF_DATA_GAP };

// Always newest closed candle first. No current (forming) candle is passed in.
struct CFWindow { MqlRates bar[CF_HISTORY]; };

struct CFReading
{
   CFCategory category;
   CFDecision decision;
   int direction;
   string reason;
   string qualifier;
   double entry, target, invalidation;
   int min_bars, max_bars;
};

struct CFForecast
{
   CFStatus status;
   CFReading setup;
   datetime signal_bar, last_checked_bar;
   int bars;
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

void CFRead(const CFWindow &w, const double tick_size, CFReading &r)
{
   r.category = CF_NONE;
   r.decision = CF_SKIP;
   r.direction = 0;
   r.reason = "No clear directional candle sequence";
   r.qualifier = "No qualified setup";
   r.entry = w.bar[0].close;
   r.target = r.invalidation = 0.0;
   r.min_bars = r.max_bars = 0;
   if(tick_size <= 0.0) return;

   double typical = 0.0;
   for(int i = 1; i <= 16; ++i) typical += w.bar[i].high - w.bar[i].low;
   typical /= 16.0;
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
      r.reason = r.direction > 0 ? "Price closed above the recent high" :
                                   "Price closed below the recent low";
      if((r.direction > 0 && !strong_up) || (r.direction < 0 && !strong_down))
      {
         r.decision = CF_WAIT;
         r.qualifier = "Breakout close lacks conviction";
         return;
      }
      stop_anchor = r.direction > 0 ? ref.high : ref.low;
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
   const double risk = r.direction * (r.entry - r.invalidation);
   const double reward = r.direction * (r.target - r.entry);
   if(risk < 0.5 * tick_size || reward < 1.10 * risk)
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

#endif
