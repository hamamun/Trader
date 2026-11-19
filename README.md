# Candle Forecast for MT5

A monitor-only MQL5 Expert Advisor. Attach **one copy to one M5 or M15 chart**. It independently reads **both M5 and M15** closed candles for that chart's symbol. It does not use indicators, news, external data, or send orders.

## Install

1. In MT5, open **File → Open Data Folder**.
2. Copy the whole [`CandleForecast`](MQL5/Experts/CandleForecast) folder into `MQL5/Experts/` in that data folder. Keep `CandleForecast.mq5` and `CandleLogic.mqh` together.
3. Open `CandleForecast.mq5` in MetaEditor and press **F7** to compile. Refresh **Navigator → Expert Advisors** in MT5 if it does not appear, then attach it to one chart. **Algo Trading does not have to be enabled** for monitoring.

## What you see

Each timeframe has its own latest closed-bar timestamp, candle reading, and decision: **Buy setup**, **Sell setup**, **Waiting for confirmation**, or **No trade**. The active forecast, if any, shows its own category, direction, target, invalidation level, time estimate, and bars elapsed. The last completed outcome stays visible separately. Optional lines on the price chart show active levels (M5 dotted, M15 dashed).

| Input | Default | What it does |
| --- | --- | --- |
| `ReadM5` | On | Read the chart symbol's M5 candles |
| `ReadM15` | On | Read the chart symbol's M15 candles |
| `ShowLevels` | On | Plot active target and invalidation lines |
| `AlertOnNewSetup` | Off | Show an MT5 popup when a new forecast starts (not in the Strategy Tester) |
| `SaveCsv` | On | Save candle readings, started forecasts, and outcomes |

## How it reads candles

The EA compares bodies, wicks, and closes with recent highs and lows. It describes the reading as a **reversal**, **continuation**, **breakout**, **failed breakout**, or **range bounce** when there is enough evidence. A label alone is not a signal. A setup needs a direction, a defined invalidation level, and a target far enough away relative to that invalidation. These are price-based checks only; spreads, commissions, and fills are not modeled in this version.

- **Targets** come from nearby swings, a range midpoint, or a measured range projection for a breakout with no visible swing ahead.
- **Time windows** are estimated from target distance, recent candle sizes, and setup type. They use bars from the source timeframe (up to 18 bars), not clock time across market closures. The lower end is an estimate, not a requirement; an early target touch still counts.
- **Tracking:** At most one forecast is active per timeframe. The EA keeps reading candles while it tracks that forecast; later setups do not replace it. A forecast finishes when a subsequent closed candle has touched the target or invalidation, or when the bar window expires. If one candle touches both levels, the outcome is marked ambiguous because OHLC doesn't tell us which came first.
- **Startup:** The EA displays the latest closed candle after loading enough history but waits for the next close before starting a forecast. Changing the chart timeframe still reads the same M5/M15 pair; reinitializing the EA starts a fresh monitoring session. After an interruption, the EA can replay missed closes to update an existing forecast. Of the replayed closes, only the newest can start a forecast. If the gap cannot be replayed, the active forecast is recorded as untracked.

## Review and verify

CSV files are written under `MQL5/Files/CandleForecast/` (or the testing agent's `MQL5/Files/CandleForecast/` directory in the Strategy Tester), one file per attachment session. Filter `event` to `forecast` and `outcome`, then match them using **symbol + timeframe + signal-bar open time** within the file. Reading events are context, not started forecasts. `session_end` means a forecast was still open when monitoring stopped. Bar times are broker-time **opening** timestamps for completed candles; the reference close is not a fill price.

Run the host-side rule tests with `bash tests/run.sh`. They compile the same candle logic the EA includes. They do not compile or run the EA itself. To verify it in MT5, compile in MetaEditor and run a visual test over several trading sessions. Check that M5 updates at its own closes, M15 only at its own closes, neither uses forming candles, and no orders appear. Repeat with M15 as the test timeframe and review results by timeframe and setup category before considering trade execution.
