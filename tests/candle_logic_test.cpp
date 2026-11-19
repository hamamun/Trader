// Host-side tests for the exact rule and lifecycle code included by the MT5 EA.
// These small stand-ins provide the types and math functions used from MQL5.
#include <algorithm>
#include <cassert>
#include <cmath>
#include <iostream>
#include <string>
using string = std::string;
using datetime = long long;
struct MqlRates { datetime time; double open, high, low, close; };
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

int main() {
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

    std::cout << "Candle logic: five categories, mirrored directions, qualification, forecast windows and outcomes passed.\n";
}
