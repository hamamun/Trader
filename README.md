# Trader for MT5

A rule-based MQL5 Expert Advisor for closed-candle M5/M15 reading. Attach **one copy to one M5 or M15 chart**. It independently reads **both M5 and M15** closed candles for that chart's symbol. It does not use indicators or external data. By default it can place **real orders** (see `AutoTrading`); set `AutoTrading=false` to revert to monitor-only.

## Install

1. In MT5, open **File → Open Data Folder**.
2. Copy the whole [`CandleForecast`](MQL5/Experts/CandleForecast) folder into `MQL5/Experts/` in that data folder. Keep `CandleForecast.mq5` and `CandleLogic.mqh` together.
3. Open `CandleForecast.mq5` in MetaEditor and press **F7** to compile. Refresh **Navigator → Expert Advisors** in MT5 if it does not appear, then attach it to one chart. **Algo Trading must be enabled in the terminal AND the EA must have "Allow Algo Trading" ticked** whenever you want real orders; otherwise Trader only monitors and logs (and says so in the panel). Attach to a demo account first.

## What you see

Trader draws a custom dashboard card (760px wide, roughly 300–510px tall depending on content, all text 10pt). The top strip shows **TRADER / <symbol>** and one glanceable line — a colored dot with **AUTOTRADING ON** (amber) or **MONITOR ONLY** (grey), the CSV state, live flat/position/pending counts, and the market state. Below it are two blocks separated by hairline dividers, one per timeframe (**M5** in cyan, **M15** in purple): the last closed-candle time, the market context (plus the M15 context on the M5 block), the candle reading with its plain-language reason, the plan line, the active forecast (`Active UP · Target … · Invalidation …`, with a bar-progress line showing bars elapsed and the peak R-multiple reached), and the advice line colored by severity (Hold / Watch / Exit). When a Trader trade is open, an **order block** appears as well: a main line — `● POSITION BUY 0.01 @ 97,310.50 · SL 97,180.00 (-13.02 USD) · TP 97,425.00 (+11.47 USD) · P/L +14.50 USD` (green when floating in profit, red otherwise) — and a second line, `Bid 97,322.50 · Ask 97,324.00 · exit at Bid` (ask for sells). When a stop order is armed instead: `● PENDING BUY STOP · 2 bars left · #ticket`. A footer shows the caption and a live `updated HH:MM:SS` clock that ticks once per second. Target/invalidation chart lines are unchanged. Withheld and closed states collapse the card to a single status line. No information appears twice, and no text is truncated.

| Input | Default | What it does |
| --- | --- | --- |
| `ReadM5` | On | Read the chart symbol's M5 candles |
| `ReadM15` | On | Read the chart symbol's M15 candles |
| `ShowLevels` | On | Plot active target and invalidation lines |
| `AlertOnNewSetup` | Off | Show an MT5 popup when a new forecast starts (not in the Strategy Tester) |
| `SaveCsv` | On | Save candle readings, started forecasts, and outcomes |
| `CompareSwings` | On | Log the standalone confirmed-swing comparison; requires `SaveCsv` |
| `CompareVariants` | On | Log the other experiments and the combined version; requires `SaveCsv` |
| `AutoTrading` | On | Place real orders on qualified setups; false = monitor only |
| `UseStopLoss` | On | Attach the invalidation level as the stop loss |
| `TradeLots` | 0.01 | Fixed trade size per order (no risk-based sizing) |
| `PendingBars` | 3 | Candles a pending stop order waits before auto-cancelling |
| `Magic` | 20261123 | Magic number for Trader orders |
| `MaxSlippage` | 100 | Max slippage in points for market orders |

## How Trader enters a trade

An order is placed only when **all** of these hold, evaluated on a freshly closed candle (never on skipped/replayed closes):

1. **A qualified setup exists** — the same `Buy setup` / `Sell setup` signal you see on the panel (direction, defined invalidation, target far enough away).
2. **The bigger picture agrees** — the contextual filter that vetoes counter-trend plans already applies to what reaches the panel (local trend / higher-timeframe opposition). Trader does not fight a clear M15 trend for an M5 entry.
3. **The moment is sane** — the market is open (no order while trading is halted), automated trading allowed, and only **one Trader position/order per symbol per timeframe** (magic `Magic`; M5 and M15 may each hold one simultaneously). **Manual trades are never considered** — Trader reads magic and comment, and only recognizes its own orders/positions.

**Which order: A (market) or B (pending stop)?** Decided at signal time from the signal candle itself, by deterministic rule:

- **Turning or continuation setups** (failed breakout, reversal, range bounce, continuation) already have their edge at the close → **market order immediately**.
- **Breakouts that closed decisively** beyond the level (a strong-close candle at least 0.25 x typical range past it) → **market order immediately**.
- **Breakouts that only just crept past the level** → a **pending stop order** just beyond the signal candle's high/low (small buffer). If price genuinely continues, it fills; if it fakes out and falls back, nothing trades. The pending order lives for `PendingBars` candles, then cancels; it also cancels early if price closes back through the broken level (idea dead).

- **Stop loss** at the invalidation level (unless `UseStopLoss=false` or the broker's minimum stop distance forbids it — then the order goes without a stop and says so in the journal). **Take profit** at the forecast target (same broker-minimum rule). There is no risk-based sizing — `TradeLots` is fixed and you accepted that.
- **Exits are wired** for Trader positions only: invalidation, target, managed early-exit and expiry/forecast-over (see above). The advice line itself still never moves levels — it exits positions, it does not adjust stops/targets.
- Orders never fire in the Strategy Tester. Pending orders survive restarts (recovered on init by magic+comment tag; the dead-level cancel is in-memory only, the lifetime cancel always applies). If a pending vanishes, Trader checks whether a Trader position appeared and logs the real fill price — otherwise it logs the order as gone (filled or cancelled externally).

**What lands in the CSV:** every order action is logged to the same per-symbol `<Symbol>_M5.csv` / `<Symbol>_M15.csv` files as `event=order` (placed — with `mode=market` or `mode=pending` and the fill/pending price), `event=order_fill` (pending filled — `position=<ticket>` and the actual open price/SL/TP from the resulting position), `event=order_cancel` (pending cancelled — `reason=` with lifetime expiry or close-back-through), `event=order_fail` (rejected/failed — `retcode=` and broker reason), or `event=exit` (position closed — `reason=` as above). All carry `variant=autotrade`; the exact details live in `management_reason` as `key=value;key=value` fields (lots, ticket, price, sl, tp, reason) — no commas inside values. `observed_close` carries the price too, so existing analyses can filter `event=order*` without a schema change.

## How Trader exits a trade

Four exits for a live Trader position, evaluated on the candle close (plus one mid-candle rule):

1. **Invalidation.** If `UseStopLoss=true` the broker stop loss does it (Trader stays out of the way). If `UseStopLoss=false`, Trader closes at market **mid-candle** the moment price trades through the invalidation level (checked every tick/second).
2. **Target.** The broker TP does it when present; if the forecast resolves Target on a closed candle Trader closes at market (covers the "broker forced TP off" case). Fill may be better or worse than the target — it is the close price, not a simulated fill.
3. **Managed early exit.** When the managed advice flips to **Exit** (confirmed warning candle breach, opposite impulse closing through the previous candle, structure break, or failed-breakout rejection), Trader closes at market. Reuses the exact same logic it watches with, no duplicate tuning.
4. **Expiry / forecast over.** When the baseline forecast ends — Target, Invalidated, Expired (max bars), Ambiguous or Untracked (data gap) — the position closes. Data gaps close the position too: Trader refuses to ride blind.

Pending (stop) orders additionally cancel when: lifetime `PendingBars` reached, price closes back through the broken level, or a fresh **opposite** setup prints on a closed candle.

An exit sets a same-candle re-entry ban: no new order on that timeframe until the next close. Exits never touch manual trades (magic+comment scoped). During a catch-up replay after downtime, an exit fires at current market price even if the resolving close happened while the EA was away. Every exit is logged as `event=exit` with `reason=` (invalidation / target / expiry / early_exit / ambiguous / data_gap / invalidation_midcandle), `price=`, `ticket=`.

## How it reads candles

The EA compares bodies, wicks, and closes with recent highs and lows. It describes the reading as a **reversal**, **continuation**, **breakout**, **failed breakout**, or **range bounce** when there is enough evidence. A label alone is not a signal. A setup needs a direction, a defined invalidation level, and a target far enough away relative to that invalidation. These are price-based checks only; spreads, commissions, and fills are not modeled in this version.

- **Targets** come from nearby swings, a range midpoint, or a measured range projection for a breakout with no visible swing ahead.
- **Time windows** are estimated from target distance, recent candle sizes, and setup type. They use bars from the source timeframe (up to 18 bars), not clock time across market closures. The lower end is an estimate, not a requirement; an early target touch still counts.
- **Tracking:** At most one forecast is active per timeframe. The EA keeps reading candles while it tracks that forecast; later setups do not replace it. An original baseline forecast finishes when a subsequent closed candle has touched the target or invalidation, or when the bar window expires. The panel instead shows a managed forecast that can also end early (see below). If one candle touches both levels, the outcome is marked ambiguous because OHLC doesn't tell us which came first.
- **Startup:** The EA displays the latest closed candle after loading enough history but waits for the next close before starting a forecast. Changing the chart timeframe still reads the same M5/M15 pair; reinitializing the EA starts a fresh monitoring session. After an interruption, the EA can replay missed closes to update an existing forecast. Only the newest replayed close can start a forecast, and only if the next bar opens at the expected time. A Friday close discovered when the market reopens, for example, cannot start a new forecast. Trader retries incomplete history before replaying; if a complete snapshot no longer contains the required history, the active forecast is recorded as untracked.

## How Trader decides when to act (managed-entry filter)

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

The advice line runs the same way with CSV disabled. It **does** close live Trader positions (that timeframe only) when it says Exit. A price move in the forecast's favor is not a realized profit; early exits use the observed candle close as a reference, not a broker fill. **Order entries fire at most once per setup; exits fire on candle close except the mid-candle invalidation rule when broker SL is off.**

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

Trader keeps its working state in the terminal's global variables (the same mechanism MetaTrader itself uses), under the `Trader.<Symbol>.<Timeframe>.*` namespace, with an independent binary mirror in `MQL5/Files/CandleForecast/state_<Symbol>_<Timeframe>.dat` loaded if the global variables are missing. The active forecast, bars elapsed, warning state, experiment lanes and last outcome are saved on every closed candle and when the EA deinitializes, and restored on the next initialization — so a chart switch, a change of inputs, a terminal restart or a closed-market weekend do not wipe a live forecast. The Strategy Tester ignores these variables and always starts clean. If the EA is attached to any chart other than M5 or M15, it stays inert, leaves saved state untouched and shows a single out-of-range line; switch back to M5/M15 to resume. CSV files are written under `MQL5/Files/CandleForecast/` (or the testing agent's `MQL5/Files/CandleForecast/` directory in the Strategy Tester). Trader keeps one append-only file per symbol and timeframe, named `<Symbol>_M5.csv` and `<Symbol>_M15.csv`, so rows accumulate day after day and the header is written only once. Filter `event` to `forecast` and `outcome`, then match them using **variant + symbol + timeframe + signal-bar open time** within the file. Filter by `variant` and timeframe. `managed` rows include `advice`, `management_reason`, `local_market`, and applicable `higher_market`; `plan` events record the entry decision and `management` events mark changes in active advice. Reading events are context, not started forecasts. The `observed_close` column records the candle close for early-exit comparisons; it does not represent a fill. `session_end` means a forecast was still open when monitoring stopped. Bar times are broker-time **opening** timestamps for completed candles; the reference close is not a fill price.

Run the host-side rule tests with `bash tests/run.sh`. They compile the same candle logic the EA includes, with fixtures for incomplete history, stale closes, and managed outcomes plus a deterministic 20,000-bar stress test. They do not compile or run the EA itself. To verify it in MT5, compile in MetaEditor and run a visual test over several trading sessions. Check that M5 updates at its own closes, M15 only at its own closes, neither uses forming candles, and no orders appear. Repeat with M15 as the test timeframe. Review results by timeframe and setup category before trusting results. Compare signal counts, target hits, invalidations, expiries, and early exits on a later period. Do not count early exits as target hits; when both variants started on the same signal, compare the early-exit close with the baseline outcome. Allow for trading costs before drawing conclusions. Forward-test on a demo account before real money — the entry backtest has not been run yet.
