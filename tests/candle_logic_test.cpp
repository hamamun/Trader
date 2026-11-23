// Host-side tests for the exact rule and lifecycle code included by the MT5 EA.
// These small stand-ins provide the types and math functions used from MQL5.
#include <algorithm>
#include <cassert>
#include <cmath>
#include <iostream>
#include <limits>
#include <random>
#include <string>
using string = std::string;
using datetime = long long;
struct MqlRates { datetime time; double open, high, low, close; };
bool MathIsValidNumber(double a) { return std::isfinite(a); }
double MathAbs(double a) { return std::abs(a); }
double MathMin(double a, double b) { return std::min(a, b); }
double MathMax(double a, double b) { return std::max(a, b); }
double MathCeil(double a) { return std::ceil(a); }
double MathFloor(double a) { return std::floor(a); }
#include "../MQL5/Experts/CandleForecast/CandleLogic.mqh"

constexpr double tick = 0.05;

void set(CFWindow &w, int i, double o, double h, double l, double c) {
    assert(l <= std::min(o, c) && std::max(o, c) <= h);
    w.bar[i] = {10000 - 300*i, o, h, l, c};
}

CFWindow baseline() {
    CFWindow w;
    for (int i = 0; i < CF_HISTORY; ++i) set(w,i,100,102,98,100);
    return w;
}

CFWindow range() {
    CFWindow w = baseline();
    for (int i = 1; i <= 8; ++i) {
        if (i==2 || i==4 || i==6) set(w,i,101.8,103.4,101,102.1);
        else set(w,i,98.2,99,96.6,97.9);
    }
    for (int i = 9; i < CF_HISTORY; ++i) set(w,i,100,101,99,100);
    return w;
}

CFWindow reflect(CFWindow w) {
    for (auto &b : w.bar) b = {b.time, 200 - b.open, 200 - b.low, 200 - b.high, 200 - b.close};
    return w;
}

CFReading expect(const CFWindow &w, CFCategory category, CFDecision decision, int direction) {
    CFReading r;
    CFRead(w, tick, r);
    if (r.category != category || r.decision != decision || r.direction != direction)
        std::cerr << "Expected " << CFCategoryName(category) << " " << decision << " " << direction
                  << " but got " << CFCategoryName(r.category) << " " << CFDecisionName(r) << " "
                  << r.direction << ": " << r.reason << " / " << r.qualifier << '\n';
    assert(r.category == category && r.decision == decision && r.direction == direction);
    if (decision == CF_SETUP) {
        assert(direction*(r.target - r.entry) >= 1.1*direction*(r.entry - r.invalidation));
        assert(direction*(r.entry - r.invalidation) > 0);
        assert(r.min_bars >= 1 && r.min_bars < r.max_bars && r.max_bars <= 18);
        assert(std::abs(r.target / tick - std::round(r.target / tick)) < 1e-8);
        assert(std::abs(r.invalidation / tick - std::round(r.invalidation / tick)) < 1e-8);
    }
    return r;
}

void both(const CFWindow &w, CFCategory category, CFDecision decision, int direction) {
    const CFReading r = expect(w, category, decision, direction);
    const CFReading mirror = expect(reflect(w), category, decision, -direction);
    if (decision == CF_SETUP) {
        assert(std::abs(r.target + mirror.target - 200) < 1e-8);
        assert(std::abs(r.invalidation + mirror.invalidation - 200) < 1e-8);
        assert(r.min_bars == mirror.min_bars && r.max_bars == mirror.max_bars);
    }
}

void lifecycle(CFReading r) {
    const bool up = r.direction > 0;
    const MqlRates both_touched = {110, r.entry, std::max(r.target, r.invalidation),
                                   std::min(r.target, r.invalidation), r.entry};
    MqlRates target_touched = {110, r.entry, up ? r.target : r.entry, up ? r.entry : r.target, r.entry};
    MqlRates stop_touched = {110, r.entry, up ? r.entry : r.invalidation, up ? r.invalidation : r.entry, r.entry};
    CFForecast f;
    CFStart(f, r, 110);
    CFAdvance(f, both_touched, tick);
    assert(f.status == CF_ACTIVE && f.bars == 0); // Signal bar never counts toward the outcome.
    CFStart(f, r, 100);
    CFAdvance(f, both_touched, tick);
    assert(f.status == CF_AMBIGUOUS && f.bars == 1);
    CFAdvance(f, target_touched, tick);
    assert(f.status == CF_AMBIGUOUS && f.bars == 1);
    CFStart(f, r, 100);
    CFAdvance(f, target_touched, tick);
    assert(f.status == CF_TARGET && f.bars == 1);
    CFStart(f, r, 100);
    CFAdvance(f, stop_touched, tick);
    assert(f.status == CF_INVALIDATED && f.bars == 1);
    CFStart(f, r, 100);
    for (int i = 1; i <= r.max_bars; ++i) {
        CFAdvance(f, {100+10*i, r.entry, r.entry, r.entry, r.entry}, tick);
        CFAdvance(f, {100+10*i, r.entry, r.entry, r.entry, r.entry}, tick); // A re-read never increments twice.
        assert(f.bars == i);
        assert(f.status == (i == r.max_bars ? CF_EXPIRED : CF_ACTIVE));
    }
    CFStart(f, r, 100);
    for (int i = 1; i < r.max_bars; ++i)
        CFAdvance(f, {100+10*i, r.entry, r.entry, r.entry, r.entry}, tick);
    target_touched.time = 100 + 10*r.max_bars;
    CFAdvance(f, target_touched, tick);
    assert(f.status == CF_TARGET && f.bars == r.max_bars); // The expiry bar can still touch a level.
}

void swing_comparison() {
    auto w = range();
    set(w,0,97.5,98.3,96.6,97.9);
    auto original = expect(w, CF_RANGE_BOUNCE, CF_SETUP, 1);
    auto comparison = original;
    CFRequireConfirmedSwing(w, tick, comparison);
    assert(comparison.decision == CF_SKIP); // Repeated equal lows do not make a strict swing.
    assert(expect(w, CF_RANGE_BOUNCE, CF_SETUP, 1).target == original.target);

    set(w,3,98.2,99,96.55,97.9);
    for (int direction : {1, -1}) {
        const auto bars = direction > 0 ? w : reflect(w);
        const auto base = expect(bars, CF_RANGE_BOUNCE, CF_SETUP, direction);
        comparison = base;
        CFRequireConfirmedSwing(bars, tick, comparison);
        assert(comparison.decision == CF_SETUP && comparison.qualifier == "Rejection at a confirmed swing level");
        assert(comparison.target == base.target && comparison.invalidation == base.invalidation);
        assert(comparison.min_bars == base.min_bars && comparison.max_bars == base.max_bars);
    }

    // Isolate the location check from the baseline classifier in these fixtures.
    w = baseline();
    set(w,0,99,100,97.1,99.5);
    set(w,2,99,101,97.0,100);
    comparison = original;
    CFRequireConfirmedSwing(w, tick, comparison);
    assert(comparison.decision == CF_SKIP); // Only one newer bar before the bounce.
    set(w,2,100,102,98,100);
    set(w,5,99,101,97.0,100);
    comparison = original;
    CFRequireConfirmedSwing(w, tick, comparison);
    assert(comparison.decision == CF_SETUP);
    set(w,1,98,99,95.8,95.9);
    comparison = original;
    CFRequireConfirmedSwing(w, tick, comparison);
    assert(comparison.decision == CF_SKIP); // A later close already broke support.

    // For reversals, the rejection bar is one bar earlier than the signal close.
    w = baseline();
    set(w,0,99.2,101.5,98.8,101.2);
    set(w,1,98.6,99.8,97.1,99.2);
    set(w,3,99,101,97.0,100);
    original.category = CF_REVERSAL;
    comparison = original;
    CFRequireConfirmedSwing(w, tick, comparison);
    assert(comparison.decision == CF_SKIP); // The rejection cannot double as pivot confirmation.
    set(w,3,100,102,98,100);
    set(w,4,99,101,97.0,100);
    comparison = original;
    CFRequireConfirmedSwing(w, tick, comparison);
    assert(comparison.decision == CF_SETUP);

    comparison = original;
    comparison.category = CF_BREAKOUT;
    CFRequireConfirmedSwing(w, tick, comparison);
    assert(comparison.decision == CF_SETUP && comparison.qualifier == original.qualifier);
}

void breakout_experiments(const int direction) {
    auto w = baseline();
    set(w,0,100.4,103.5,100,103.0);
    const auto initial = direction > 0 ? w : reflect(w);
    const auto signal = expect(initial, CF_BREAKOUT, CF_SETUP, direction);
    const int flags = CF_SWING_FILTER | CF_REVERSAL_CONFIRM | CF_BREAKOUT_RETEST |
                      CF_BREAKOUT_FAILURE | CF_EARLY_WARNING;
    CFTrial trial{};
    auto reading = signal;
    CFTrialRead(trial, initial, tick, flags, false, reading);
    assert(trial.pending_bars == 0); // Startup/replayed closes cannot start a candidate.
    CFTrialRead(trial, initial, tick, flags, true, reading);
    assert(reading.decision == CF_WAIT && trial.pending_bars == 3);
    const auto waiting = trial;
    set(w,0,103,104,102,102.4);
    auto closed = direction > 0 ? w : reflect(w);
    CFTrialRead(trial, closed, tick, flags, true, reading);
    assert(reading.decision == CF_SETUP && trial.pending_bars == 0);
    assert(reading.entry == closed.bar[0].close && reading.target == signal.target);
    assert(reading.breakout_level == signal.breakout_level);
    const auto retested = reading;
    trial = waiting;
    set(w,0,103,105.6,102,105.5); // Retest held, but the confirmation is too close to the target.
    closed = direction > 0 ? w : reflect(w);
    CFTrialRead(trial, closed, tick, flags, true, reading);
    assert(reading.decision == CF_SKIP && reading.qualifier == "Too little room before the next objective");
    CFForecast control{}, experiment{};
    CFStart(control, retested, 9000);
    CFStart(experiment, retested, 9000);
    set(w,0,102.1,102.5,101.9,101.95); // Closes one tick inside; no target or stop touch.
    closed = direction > 0 ? w : reflect(w);
    CFAdvanceTrial(control, closed, tick, 0);
    CFAdvanceTrial(experiment, closed, tick, flags);
    assert(experiment.status == CF_BREAKOUT_EXIT && control.status == CF_ACTIVE);
    trial = waiting;
    CFTrialRead(trial, closed, tick, flags, true, reading);
    assert(reading.decision == CF_SKIP && trial.pending_bars == 0);

    trial = waiting;
    set(w,0,103,107,102,103.5);
    closed = direction > 0 ? w : reflect(w);
    CFTrialRead(trial, closed, tick, flags, true, reading);
    assert(reading.decision == CF_SKIP && reading.qualifier == "Target already touched before entry");
    trial = waiting;
    for (int left = 2; left >= 0; --left) {
        set(w,0,103.4,104,103.3,103.5); // No return to the original level.
        closed = direction > 0 ? w : reflect(w);
        CFTrialRead(trial, closed, tick, flags, true, reading);
        assert(trial.pending_bars == left && reading.decision == (left ? CF_WAIT : CF_SKIP));
    }
}

void structure_experiments(const int direction) {
    CFReading signal{};
    signal.category = CF_REVERSAL;
    signal.decision = CF_SETUP;
    signal.direction = direction;
    signal.entry = 100 + direction;
    signal.invalidation = 100 - 3*direction;
    signal.target = 100 + 10*direction;
    signal.max_bars = 12;
    auto w = baseline();
    set(w,4,100,103,98,101);
    set(w,10,100,104,98,101);
    auto closed = direction > 0 ? w : reflect(w);
    CFTrial trial{};
    auto reading = signal;
    CFTrialRead(trial, closed, tick, CF_REVERSAL_CONFIRM, true, reading);
    assert(reading.decision == CF_WAIT && trial.pending_bars == 3);
    assert(trial.pending_level == 100 + 3*direction);
    set(w,0,102,103.15,101,103.05);
    closed = direction > 0 ? w : reflect(w);
    CFTrialRead(trial, closed, tick, CF_REVERSAL_CONFIRM, true, reading);
    assert(reading.decision == CF_SETUP && reading.entry == closed.bar[0].close);
    assert(reading.target == signal.target && trial.pending_bars == 0);

    for (int j=0; j<CF_HISTORY; ++j) set(w,j,101,102,100,101);
    set(w,3,101,102,99,101);
    set(w,8,101,102,98,101);
    CFForecast experiment{};
    CFStart(experiment, signal, 9000);
    set(w,0,101,102,98.7,99.2);
    closed = direction > 0 ? w : reflect(w);
    CFAdvanceTrial(experiment, closed, tick, CF_EARLY_WARNING);
    assert(experiment.status == CF_ACTIVE); // A wick alone isn't an exit.
    CFStart(experiment, signal, 9000);
    set(w,0,101,102,98.7,98.95);
    closed = direction > 0 ? w : reflect(w);
    CFAdvanceTrial(experiment, closed, tick, CF_EARLY_WARNING);
    assert(experiment.status == CF_STRUCTURE_EXIT);
    CFStart(experiment, signal, 9000);
    set(w,0,101,102,96,98.95);
    closed = direction > 0 ? w : reflect(w);
    CFAdvanceTrial(experiment, closed, tick, CF_EARLY_WARNING);
    assert(experiment.status == CF_INVALIDATED); // Intrabar invalidation precedes a warning at the close.
}

void managed_forecast(const int direction) {
    auto w = baseline();
    CFReading signal{};
    signal.category = CF_REVERSAL;
    signal.decision = CF_SETUP;
    signal.direction = direction;
    signal.entry = 100;
    signal.invalidation = 100 - 6*direction;
    signal.target = 100 + 10*direction;
    signal.max_bars = 10;
    auto opposite = signal;
    opposite.direction = -direction;
    opposite.invalidation = signal.target;
    opposite.target = signal.invalidation;
    CFReading neutral{};
    CFRead(w, tick, neutral);
    CFManaged managed{};
    set(w,0,99,100.5,97,100);
    w.bar[0].time = 9000;
    auto bar = direction > 0 ? w : reflect(w);
    CFManageOnBar(managed, bar, signal, tick, false);
    assert(managed.forecast.status == CF_IDLE);
    CFManageOnBar(managed, bar, signal, tick, true);
    assert(managed.forecast.status == CF_ACTIVE && managed.advice == CF_NEW);
    set(w,0,100,104,99,103);
    w.bar[0].time = 9300;
    bar = direction > 0 ? w : reflect(w);
    CFManageOnBar(managed, bar, neutral, tick, true);
    assert(managed.advice == CF_SUPPORTED);
    const auto holding = managed;

    set(w,1,104,107,103.9,106);
    set(w,0,105,108,103.8,104.3);
    w.bar[0].time = 9600;
    bar = direction > 0 ? w : reflect(w);
    CFManageOnBar(managed, bar, neutral, tick, true);
    assert(managed.advice == CF_WATCH && managed.warning_bars == 2);
    CFManageOnBar(managed, bar, neutral, tick, true); // Repeated data does not age the warning.
    assert(managed.warning_bars == 2 && managed.forecast.bars == 2);
    assert(managed.forecast.setup.target == signal.target && managed.forecast.setup.invalidation == signal.invalidation);
    const auto watching = managed;

    set(w,0,104,104.4,102.7,103.2);
    bar = direction > 0 ? w : reflect(w);
    CFManageOnBar(managed, bar, opposite, tick, true);
    assert(managed.advice == CF_EXIT && managed.forecast.status == CF_CANDLE_EXIT);
    assert(direction * (bar.bar[0].close - signal.entry) > 0); // An early exit can preserve some of the price move.
    CFManageOnBar(managed, bar, opposite, tick, true);
    assert(managed.forecast.status == CF_CANDLE_EXIT); // Never flip on the exit bar.
    bar.bar[0].time += 300;
    CFManageOnBar(managed, bar, opposite, tick, true);
    assert(managed.advice == CF_NEW && managed.forecast.setup.direction == -direction);

    managed = watching;
    set(w,0,104.3,109,104,108.6);
    bar = direction > 0 ? w : reflect(w);
    CFManageOnBar(managed, bar, neutral, tick, true);
    assert(managed.advice == CF_HOLD && managed.warning_bars == 0);
    managed = watching;
    set(w,0,104,110,102,105);
    bar = direction > 0 ? w : reflect(w);
    CFManageOnBar(managed, bar, opposite, tick, true);
    assert(managed.forecast.status == CF_TARGET); // Intrabar target beats a close-based decision.
    // The outcome line reports what happened; the advice line returns to watching.
    assert(managed.advice == CF_STANDBY && managed.explanation == "Waiting for a new setup");

    managed = holding;
    set(w,1,104,108,103,106);
    set(w,0,107,107.4,100.6,101.1);
    w.bar[0].time = 9600;
    bar = direction > 0 ? w : reflect(w);
    CFManageOnBar(managed, bar, opposite, tick, true);
    assert(managed.forecast.status == CF_CANDLE_EXIT && managed.advice == CF_EXIT);
}

void contextual_planning(const int direction) {
    assert(CFClosedBy(9000, 900, 9900));
    assert(!CFClosedBy(9000, 900, 9899));
    assert(!CFClosedBy(0, 900, 9900));
    assert(CFReadMarket(range(), tick, false) == CF_MARKET_RANGE);
    assert(CFReadMarket(baseline(), tick, false) == CF_MARKET_MIXED);
    auto w = baseline();
    for (int i = 0; i < CF_HISTORY; ++i) set(w,i,100-i,100.5-i,99.5-i,100-i);
    const CFMarket trend = direction > 0 ? CF_MARKET_UP : CF_MARKET_DOWN;
    const CFMarket against = direction > 0 ? CF_MARKET_DOWN : CF_MARKET_UP;
    auto bars = direction > 0 ? w : reflect(w);
    assert(CFReadMarket(bars, tick, false) == trend);
    set(w,0,99,101,80,82); // The latest candle cannot rewrite the context used to judge itself.
    bars = direction > 0 ? w : reflect(w);
    assert(CFReadMarket(bars, tick, false) == trend);

    CFTrial plan{};
    CFReading r{};
    r.category = CF_CONTINUATION;
    r.decision = CF_SETUP;
    r.direction = direction;
    auto candidate = r;
    CFContextualPlan(plan, bars, tick, trend, against, true, candidate);
    assert(candidate.decision == CF_SKIP);
    candidate = r;
    CFContextualPlan(plan, bars, tick, CF_MARKET_MIXED, CF_MARKET_UNKNOWN, true, candidate);
    assert(candidate.decision == CF_SKIP);
    candidate = r;
    CFContextualPlan(plan, bars, tick, trend, CF_MARKET_UNKNOWN, true, candidate);
    assert(candidate.decision == CF_SETUP && plan.pending_bars == 0);

    w = baseline();
    set(w,0,100.4,103.5,100,103.0);
    bars = direction > 0 ? w : reflect(w);
    const auto broken = expect(bars, CF_BREAKOUT, CF_SETUP, direction);
    candidate = broken;
    CFContextualPlan(plan, bars, tick, CF_MARKET_RANGE, CF_MARKET_UNKNOWN, true, candidate);
    assert(candidate.decision == CF_SETUP);
    candidate = broken;
    CFContextualPlan(plan, bars, tick, trend, against, true, candidate);
    assert(candidate.decision == CF_WAIT && plan.pending_bars == 3 && plan.pending_level == broken.breakout_level);
    plan.pending_bars = 0;
    candidate = broken;
    candidate.entry = broken.breakout_level + 5 * direction;
    CFContextualPlan(plan, bars, tick, trend, CF_MARKET_UNKNOWN, true, candidate);
    assert(candidate.decision == CF_WAIT);

    plan.pending_bars = 0;
    candidate = broken;
    candidate.category = CF_FAILED_BREAKOUT;
    candidate.target = 100 + 10*direction;
    candidate.invalidation = 100 - 3*direction;
    CFContextualPlan(plan, bars, tick, against, CF_MARKET_UNKNOWN, true, candidate);
    assert(candidate.decision == CF_WAIT && plan.pending_bars == 3);
    const auto trigger = plan.pending_level;
    set(w,0,103,104.5,102,104.2);
    bars = direction > 0 ? w : reflect(w);
    CFContextualPlan(plan, bars, tick, against, CF_MARKET_UNKNOWN, true, candidate);
    assert(candidate.decision == CF_SKIP); // Genuine follow-through still needs room for the risk.
    assert(direction * (candidate.entry - trigger) > 0 && plan.pending_bars == 0);
}

void stalled_management() {
    auto w = baseline();
    CFReading candidate{};
    candidate.category = CF_REVERSAL;
    candidate.decision = CF_SETUP;
    candidate.direction = 1;
    candidate.entry = 100;
    candidate.target = 110;
    candidate.invalidation = 95;
    candidate.min_bars = 3;
    candidate.max_bars = 10;
    CFManaged managed{};
    CFManageOnBar(managed, w, candidate, tick, true);
    CFReading neutral{};
    for (int i = 1; i <= 3; ++i) {
        set(w,0,100,100.4,99.6,100);
        w.bar[0].time += 300*i;
        CFManageOnBar(managed, w, neutral, tick, true);
    }
    assert(managed.advice == CF_WATCH && managed.forecast.status == CF_ACTIVE);
    assert(managed.explanation == "Move stalled; watching for an adverse close");
}

void closed_history_checks() {
    for (const int timeframe : {300, 900}) {
        assert(CFFreshClose(9000, 9000 + timeframe, timeframe));
        assert(!CFFreshClose(9000, 9000 + timeframe + 86400, timeframe));
        assert(!CFFreshClose(9000, 9000, timeframe));
        assert(!CFFreshClose(0, timeframe, timeframe));
    }
    // Test both sides of the oldest replayed bar's lookback boundary.
    assert(CFReplayState(CF_HISTORY, CF_HISTORY + 1, 1) == CF_HISTORY_READY);
    assert(CFReplayState(CF_HISTORY + 2, CF_HISTORY + 4, 4) == CF_HISTORY_RETRY);
    assert(CFReplayState(CF_HISTORY + 3, CF_HISTORY + 4, 4) == CF_HISTORY_READY);
    assert(CFReplayState(CF_HISTORY, CF_HISTORY + 25, -1) == CF_HISTORY_RETRY);
    assert(CFReplayState(CF_HISTORY, CF_HISTORY, -1) == CF_HISTORY_GAP);
    assert(CFReplayState(CF_HISTORY + CF_CATCHUP, CF_HISTORY + CF_CATCHUP, CF_CATCHUP) == CF_HISTORY_READY);
    assert(CFReplayState(CF_HISTORY + CF_CATCHUP + 1, CF_HISTORY + CF_CATCHUP + 1,
                         CF_CATCHUP + 1) == CF_HISTORY_GAP);
    assert(CFReplayState(CF_HISTORY - 1, CF_HISTORY, -1) == CF_HISTORY_RETRY);

    MqlRates bar{9000,-1,1,-4,0}; // Negative/zero prices aren't inherently malformed.
    assert(CFValidBar(bar));
    bar.low = 0.5;
    assert(!CFValidBar(bar));
    bar.low = -4;
    bar.close = std::numeric_limits<double>::quiet_NaN();
    assert(!CFValidBar(bar));
    bar.close = 0;
    bar.time = 0;
    assert(!CFValidBar(bar));

    CFManaged managed{};
    CFReading reading{};
    reading.decision = CF_WAIT;
    reading.qualifier = "Waiting for a retest of the original breakout level";
    CFManageOnBar(managed, baseline(), reading, tick, true);
    assert(managed.forecast.status == CF_IDLE && managed.advice == CF_STANDBY);
    assert(managed.explanation == reading.qualifier);
}

void check_setup_invariants(const CFReading &reading) {
    if(reading.decision != CF_SETUP) return;
    assert(reading.direction == 1 || reading.direction == -1);
    assert(reading.category != CF_NONE);
    const double risk = reading.direction * (reading.entry - reading.invalidation);
    const double reward = reading.direction * (reading.target - reading.entry);
    assert(std::isfinite(risk) && std::isfinite(reward));
    assert(risk > 0 && reward >= 1.10 * risk);
    assert(reading.min_bars > 0 && reading.max_bars > reading.min_bars && reading.max_bars <= 18);
}

void stream_smoke_test() {
    // Fixture-independent audit: replay multiple deterministic price paths with
    // varying movement, exercise plan & management together, and assert invariants.
    std::mt19937 rng(20261119);
    CFWindow w = baseline();
    CFTrial planner{};
    CFManaged managed{};
    int starts = 0, ends = 0;
    for(int i = 0; i < 20000; ++i) {
        for(int j = CF_HISTORY - 1; j > 0; --j) w.bar[j] = w.bar[j - 1];
        const double o = w.bar[1].close;
        const int bias = ((i / 41) % 3 - 1) * 7;
        const double c = o + (static_cast<int>(rng() % 61) - 30 + bias) * tick;
        w.bar[0] = {w.bar[1].time + 300, o, std::max(o,c) + (rng() % 12)*tick,
                    std::min(o,c) - (rng() % 12)*tick, c};
        assert(CFValidBar(w.bar[0]));
        CFReading reading{};
        CFRead(w, tick, reading);
        check_setup_invariants(reading);
        const bool was_active = managed.forecast.status == CF_ACTIVE;
        const auto original = managed.forecast;
        const bool fresh = i % 19 != 0;
        if(!was_active) CFContextualPlan(planner, w, tick, CFReadMarket(w, tick, false),
                                       CF_MARKET_UNKNOWN, fresh, reading);
        check_setup_invariants(reading);
        CFManageOnBar(managed, w, reading, tick, fresh);
        if(was_active) {
            assert(managed.forecast.signal_bar == original.signal_bar);
            assert(managed.forecast.setup.target == original.setup.target);
            assert(managed.forecast.setup.invalidation == original.setup.invalidation);
            assert(managed.forecast.bars == original.bars + 1);
            if(managed.forecast.status != CF_ACTIVE) ++ends;
        } else if(managed.forecast.status == CF_ACTIVE) {
            ++starts;
            assert(fresh && managed.forecast.signal_bar == w.bar[0].time);
            assert(managed.forecast.bars == 0 && managed.advice == CF_NEW);
        }
    }
    assert(starts > 100 && ends > 100 && starts - ends <= 1);
}

int main() {
    closed_history_checks();
    stream_smoke_test();
    stalled_management();
    for (int direction : {1, -1}) {
        breakout_experiments(direction);
        structure_experiments(direction);
        managed_forecast(direction);
        contextual_planning(direction);
    }
    swing_comparison();
    auto w = baseline();
    expect(w, CF_NONE, CF_SKIP, 0);
    set(w,0,100.4,103.5,100,103.0);
    both(w, CF_BREAKOUT, CF_SETUP, 1);
    auto breakout = expect(w, CF_BREAKOUT, CF_SETUP, 1);
    lifecycle(breakout);
    lifecycle(expect(reflect(w), CF_BREAKOUT, CF_SETUP, -1));
    set(w,0,102.8,104.5,100.5,103);
    both(w, CF_BREAKOUT, CF_WAIT, 1);
    set(w,0,101,103,97,100);
    expect(w, CF_NONE, CF_WAIT, 0);
    set(w,0,101.4,102.6,100.1,100.5);
    both(w, CF_FAILED_BREAKOUT, CF_SKIP, -1); // Midpoint too close vs. invalidation.
    // A strong close through the opposite edge is a new breakout, not a return inside.
    w = baseline();
    set(w,1,101.9,103,101.5,102.8);
    set(w,0,103,103.1,97.1,97.2);
    both(w, CF_BREAKOUT, CF_SETUP, -1);

    w = range();
    set(w,0,97.5,98.3,96.6,97.9);
    both(w, CF_RANGE_BOUNCE, CF_SETUP, 1);
    set(w,0,97.5,98.3,96.25,97.9);
    both(w, CF_FAILED_BREAKOUT, CF_SETUP, 1);
    // Failed at the following close: first close beyond the high, then impulse back inside.
    w = baseline();
    for (int i=1; i < CF_HISTORY; ++i) set(w,i,100,106,94,100);
    set(w,1,106,108,105.8,107.3);
    set(w,0,107.3,107.4,99.0,100.4);
    both(w, CF_FAILED_BREAKOUT, CF_SKIP, -1); // Clear reading, but inadequate room to midpoint.
    set(w,0,107.3,107.5,104.4,104.6);
    // Tighter failure after a close beyond the high of an older, wider context.
    for (int i=2; i < CF_HISTORY; ++i) set(w,i,99,106,90,99);
    // Keep the longer-term average small enough for the return candle to count as an impulse.
    for (int i=3; i < CF_HISTORY; ++i) set(w,i,100,102,98,100);
    both(w, CF_FAILED_BREAKOUT, CF_SETUP, -1);

    w = baseline();
    for (int i = 10; i < CF_HISTORY; ++i) set(w,i,103.5,104,103,103.5);
    for (int i = 2; i <= 8; ++i) {
        const double close = 97 + (i-2);
        set(w,i,close+0.45,close+0.65,close-0.2,close);
    }
    set(w,9,103.0,105.5,102.9,103.4);
    set(w,1,96.9,97.25,96.3,97.05);
    set(w,0,97.05,98.45,96.95,98.35);
    both(w, CF_REVERSAL, CF_SETUP, 1);
    set(w,0,97.05,97.2,96.7,97.1);
    both(w, CF_REVERSAL, CF_WAIT, 1);

    w = baseline();
    for (int i = 2; i <= 7; ++i) {
        const double close = 103 - (i-2);
        set(w,i,close-0.45,close+0.25,close-0.6,close);
    }
    set(w,8,99,108,97.5,99.4);
    for (int i = 9; i < CF_HISTORY; ++i) set(w,i,100,100.5,99.5,100);
    set(w,1,102.65,102.85,101.8,102.0);
    set(w,0,102.0,103.55,101.95,103.45);
    both(w, CF_CONTINUATION, CF_SETUP, 1);
    auto continuation = expect(w, CF_CONTINUATION, CF_SETUP, 1);
    assert(continuation.max_bars != breakout.max_bars);
    set(w,0,102,102.5,101.9,102.2);
    both(w, CF_CONTINUATION, CF_WAIT, 1);

    std::cout << "Candle logic: five categories, mirrored directions, qualification, forecast windows, outcomes, side-by-side experiments, managed advice, contextual planning, and history checks passed.\n";
}
