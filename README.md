# Trader for MT5

A monitor-only MQL5 Expert Advisor. Attach **one copy to one M5 or M15 chart**. It independently reads **both M5 and M15** closed candles for that chart's symbol. It does not use indicators, news, external data, or send orders.

## Install

1. In MT5, open **File → Open Data Folder**.
2. Copy the whole [`CandleForecast`](MQL5/Experts/CandleForecast) folder into `MQL5/Experts/` in that data folder. Keep `CandleForecast.mq5` and `CandleLogic.mqh` together.
3. Open `CandleForecast.mq5` in MetaEditor and press **F7** to compile. Refresh **Navigator → Expert Advisors** in MT5 if it does not appear, then attach it to one chart. **Algo Trading does not have to be enabled** for monitoring.

## What you see

A status line at the top of the panel always shows the market state: **Market open** (or **Market open | 24/7** for symbols with no trade sessions), **Withheld | …** when the broker disables or limits trading (trade disabled, close-only, long/short-only), or **Market closed | Opens <time> server time**. When the market is closed, the panel shows only that line — everything else is blank, price levels are hidden, and monitoring/CSV recording pause until the market reopens. Each timeframe has its own latest closed-bar timestamp, market context, candle reading, and decision: **Buy setup**, **Sell setup**, **Waiting for confirmation**, or **No trade**. The active forecast, if any, shows its own category, direction, target, invalidation level, time estimate, and bars elapsed. A separate advice line shows **New forecast**, **Hold**, **Hold (supported)**, **Watch**, **Exit early**, or **Wait**, with the reason. When a forecast completes, its lines clear, the advice line returns to **Wait** (watching for a new setup), and only the last completed outcome stays visible on its own line. Optional lines on the price chart show active levels (M5 dotted, M15 dashed).

| Input | Default | What it does |
| --- | --- | --- |
| `ReadM5` | On | Read the chart symbol's M5 candles |
| `ReadM15` | On | Read the chart symbol's M15 candles |
| `ShowLevels` | On | Plot active target and invalidation lines |
| `AlertOnNewSetup` | Off | Show an MT5 popup when a new forecast starts (not in the Strategy Tester) |
| `SaveCsv` | On | Save candle readings, started forecasts, and outcomes |
| `CompareSwings` | On | Log the standalone confirmed-swing comparison; requires `SaveCsv` |
| `CompareVariants` | On | Log the other experiments and the combined version; requires `SaveCsv` |

## How it reads candles

The EA compares bodies, wicks, and closes with recent highs and lows. It describes the reading as a **reversal**, **continuation**, **breakout**, **failed breakout**, or **range bounce** when there is enough evidence. A label alone is not a signal. A setup needs a direction, a defined invalidation level, and a target far enough away relative to that invalidation. These are price-based checks only; spreads, commissions, and fills are not modeled in this version.

- **Targets** come from nearby swings, a range midpoint, or a measured range projection for a breakout with no visible swing ahead.
- **Time windows** are estimated from target distance, recent candle sizes, and setup type. They use bars from the source timeframe (up to 18 bars), not clock time across market closures. The lower end is an estimate, not a requirement; an early target touch still counts.
- **Tracking:** At most one forecast is active per timeframe. The EA keeps reading candles while it tracks that forecast; later setups do not replace it. An original baseline forecast finishes when a subsequent closed candle has touched the target or invalidation, or when the bar window expires. The panel instead shows a managed forecast that can also end early (see below). If one candle touches both levels, the outcome is marked ambiguous because OHLC doesn't tell us which came first.
- **Startup:** The EA displays the latest closed candle after loading enough history but waits for the next close before starting a forecast. Changing the chart timeframe still reads the same M5/M15 pair; reinitializing the EA starts a fresh monitoring session. After an interruption, the EA can replay missed closes to update an existing forecast. Only the newest replayed close can start a forecast, and only if the next bar opens at the expected time. A Friday close discovered when the market reopens, for example, cannot start a new forecast. Trader retries incomplete history before replaying; if a complete snapshot no longer contains the required history, the active forecast is recorded as untracked.

## How Trader decides when to act

Trader reads the market context **before** it judges the signal candle. It uses confirmed higher highs/lows or lower highs/lows, a clear sequence of closes if swings are sparse, and repeated reactions near the ends of a sideways range. Otherwise the market is mixed. On M5 it also reads the last M15 candle that was already closed at the M5 decision time. If that data is disabled, missing, or stale, the panel shows **Unavailable** and the local rules still work.

| Candle reading | Managed entry decision |
| --- | --- |
| Continuation | Requires a clear local trend in the setup direction. Skip if M15 is clearly against it. |
| Reversal | Against a clear local or M15 trend, require a close through the previous confirmed swing. |
| Breakout | If the break goes against the local or M15 trend, or the close is already stretched beyond the level, wait for a retest. |
| Failed breakout | Against a clear trend, wait for a follow-through close beyond the signal candle. |
| Range bounce | If M15 is clearly against it, require rejection of a confirmed swing. |

A setup still needs a target, an invalidation level, and room to the target. Trader waits up to three later closes for extra confirmation where required. It will not chase if the original target was touched first or if the new reference close leaves too little reward for the risk. These rules are implemented locally from closed candles; the [MQL5 Market Structure Sentinel article](https://www.mql5.com/en/articles/22249) is a conceptual reference, not an imported dependency.

## How Trader manages an active forecast

On each closed candle, Trader checks the original target and invalidation first. If the forecast is still open, it reassesses the new candle:

- **Hold:** The new reading does not confirm a reason to exit. **Hold (supported)** distinguishes a strong candle making fresh progress toward the target. Neither moves the target, widens invalidation, or extends expiry.
- **Watch:** A qualified opposite setup, a strong rejection after progress, or a move that stalls can make the forecast questionable. A stall alert requires three closes without meaningful new progress and is only considered once the earliest estimated bar count has been reached. Watch the next two closes for a break of the warning candle against the forecast. If the warning is not confirmed, return to Hold.
- **Exit early:** A closed candle confirms the warning, a strong opposite setup closes through the previous candle, or a close breaks the structure supporting the forecast. A breakout can also end early on a close back through its original level. Trader shows the reason and records the exit candle's close, then waits for a fresh qualifying close rather than flipping direction on the same candle.

The advice is illustrative only. It runs the same way with CSV disabled and never sends orders. A price move in the forecast's favor is not a realized profit; early exits use the observed candle close as a reference, not a broker fill.

## Side-by-side experiments

The panel, levels, and alerts show **`managed`**. The original, fixed **`baseline`** is still tracked separately in the CSV. With comparison logging enabled, M5 and M15 also track these variants independently on the same closes:

| CSV variant | Difference from the baseline |
| --- | --- |
| `confirmed_swing` | An otherwise qualified reversal or range bounce must reject a nearby swing level confirmed **before** the rejection candle. Two closed neighbors on each side confirm a swing. |
| `structure_reversal` | A reversal additionally needs a close through the prior lower swing high (Buy) or higher swing low (Sell). It can wait up to three further closes. |
| `early_warning` | A still-active Buy ends early when a closed candle breaks its recent higher swing low. A Sell uses the mirror rule. Wicks alone do not trigger this exit. |
| `fixed_breakout_failure` | A still-active breakout ends early if a candle closes back through the **original** breakout level. The reference does not move with the recent high/low window. |
| `breakout_retest` | Wait up to three further closes for price to revisit the original breakout level and close back on the breakout side. |
| `all_upgrades` | Apply all five changes together. |

Each variant has one active forecast or pending confirmation per timeframe. A delayed confirmation uses its own closing price and checks that there is still enough room to the original target; it does not assume a fill at the earlier close. Intrabar target/invalidation touches take precedence over early exits at a candle close. Pending confirmations and forecasts from different variants never replace the baseline.

## Review and verify

Trader keeps its working state in the terminal's global variables (the same mechanism MetaTrader itself uses), under the `Trader.<Symbol>.<Timeframe>.*` namespace. The active forecast, bars elapsed, warning state, experiment lanes and last outcome are saved on every closed candle and when the EA deinitializes, and restored on the next initialization — so a chart switch, a change of inputs, a terminal restart or a closed-market weekend do not wipe a live forecast. The Strategy Tester ignores these variables and always starts clean. If the EA is attached to any chart other than M5 or M15, it stays inert, leaves saved state untouched and shows a single out-of-range line; switch back to M5/M15 to resume. CSV files are written under `MQL5/Files/CandleForecast/` (or the testing agent's `MQL5/Files/CandleForecast/` directory in the Strategy Tester). Trader keeps one append-only file per symbol and timeframe, named `<Symbol>_M5.csv` and `<Symbol>_M15.csv`, so rows accumulate day after day and the header is written only once. Filter `event` to `forecast` and `outcome`, then match them using **variant + symbol + timeframe + signal-bar open time** within the file. Filter by `variant` and timeframe. `managed` rows include `advice`, `management_reason`, `local_market`, and applicable `higher_market`; `plan` events record the entry decision and `management` events mark changes in active advice. Reading events are context, not started forecasts. The `observed_close` column records the candle close for early-exit comparisons; it does not represent a fill. `session_end` means a forecast was still open when monitoring stopped. Bar times are broker-time **opening** timestamps for completed candles; the reference close is not a fill price.

Run the host-side rule tests with `bash tests/run.sh`. They compile the same candle logic the EA includes, with fixtures for incomplete history, stale closes, and managed outcomes plus a deterministic 20,000-bar stress test. They do not compile or run the EA itself. To verify it in MT5, compile in MetaEditor and run a visual test over several trading sessions. Check that M5 updates at its own closes, M15 only at its own closes, neither uses forming candles, and no orders appear. Repeat with M15 as the test timeframe and review results by timeframe and setup category before considering trade execution. Compare signal counts, target hits, invalidations, expiries, and early exits on a later period. Do not count early exits as target hits; when both variants started on the same signal, compare the early-exit close with the baseline outcome. Allow for trading costs before drawing conclusions.
