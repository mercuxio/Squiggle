import Foundation
import Testing
@testable import TickerCore

@Test func noErrorIsAHealthyCheck() {
    #expect(Diagnosis.status(for: nil) == .ok)
}

@Test func aRateLimitIsDegradedRatherThanBroken() {
    // Being throttled means the endpoint is working and Squiggle asked too
    // often. Reporting it as "broken" sends the user hunting for a fault
    // that does not exist.
    #expect(Diagnosis.status(for: .rateLimited(retryAfterSeconds: nil)) == .degraded)
    #expect(Diagnosis.status(for: .rateLimited(retryAfterSeconds: 120)) == .degraded)
}

@Test func beingOfflineIsDegradedBecauseItIsAlmostNeverSquigglesFault() {
    #expect(Diagnosis.status(for: .offline) == .degraded)
    #expect(Diagnosis.status(for: .transport(.urlSession(code: -1005))) == .degraded)
}

@Test func aServerErrorIsDegraded() {
    #expect(Diagnosis.status(for: .serverError(status: 503)) == .degraded)
}

@Test func aContractFaultIsBrokenBecauseNoAmountOfWaitingFixesIt() {
    // Spec §4.3: if the response shape changed, every future request fails
    // identically. That is the one class of fault worth a loud red line.
    #expect(Diagnosis.status(for: .missingField(path: "chart.result[0].meta")) == .broken)
    #expect(Diagnosis.status(for: .wrongType(path: "meta.regularMarketPrice",
                                             expected: "number")) == .broken)
    #expect(Diagnosis.status(for: .noResult) == .broken)
    #expect(Diagnosis.status(for: .notJSON) == .broken)
}

@Test func anUnauthorizedResponseIsBroken() {
    // Spec §3.1: this is the failure mode that ends the project. It must
    // never be reported as a transient blip.
    #expect(Diagnosis.status(for: .unauthorized(status: 401)) == .broken)
}

@Test func aMissingSymbolIsTheUsersTypoAndNotAFault() throws {
    let symbol = try #require(Symbol("AAPL"))
    #expect(Diagnosis.status(for: .symbolNotFound(symbol)) == .degraded)
    #expect(Diagnosis.status(for: .invalidSymbol("not a symbol")) == .degraded)
}

@Test func everyErrorCaseHasAStatusAndNoneFallThrough() throws {
    // A new TickerError case that nobody classified would silently report as
    // whatever a `default:` branch says — so `status(for:)` has none, and the
    // compiler refuses the build until the new case is classified. This list
    // is the second line of defence, and it is hand-maintained: when it goes
    // stale it under-tests silently, which is exactly why it may not be the
    // only one.
    let symbol = try #require(Symbol("AAPL"))
    let all: [TickerError] = [
        .invalidSymbol("not a symbol"), .offline, .transport(.urlSession(code: -1005)),
        .rateLimited(retryAfterSeconds: nil),
        .serverError(status: 500), .unauthorized(status: 401), .symbolNotFound(symbol),
        .emptyBody, .notJSON, .noResult, .missingField(path: "x"),
        .wrongType(path: "x", expected: "number"), .nonFiniteNumber(path: "x"),
        .negativeValue(path: "x", value: -1),
        .storeSchemaUnsupported(version: 99),
        .storeVersionUnreadable,
        .storeCorrupt(quarantinedAt: URL(fileURLWithPath: "/tmp/x")),
        .storeQuarantineFailed(at: URL(fileURLWithPath: "/tmp/x")),
    ]
    for error in all {
        #expect(Diagnosis.status(for: error) != .skipped,
                "\(error) was never classified")
    }
}

@Test func theWorstCheckDecidesTheOverallResult() {
    #expect(Diagnosis.overall([Check(id: .quoteEndpoint, status: .ok)]) == .ok)
    #expect(Diagnosis.overall([
        Check(id: .quoteEndpoint, status: .ok),
        Check(id: .searchEndpoint, status: .degraded),
    ]) == .degraded)
    #expect(Diagnosis.overall([
        Check(id: .quoteEndpoint, status: .degraded),
        Check(id: .searchEndpoint, status: .broken),
    ]) == .broken)
}

@Test func skippedChecksDoNotDragTheOverallResultDown() {
    // A check skipped because an earlier one already failed says nothing
    // about health, and counting it would double-report one fault.
    #expect(Diagnosis.overall([
        Check(id: .quoteEndpoint, status: .ok),
        Check(id: .searchEndpoint, status: .skipped),
    ]) == .ok)
}

@Test func anEmptyRunIsNotSilentlyHealthy() {
    // Zero checks means the run itself failed. Reporting "ok" would be worse
    // than useless.
    #expect(Diagnosis.overall([]) == .broken)
}

@Test func exitCodesDistinguishTheThreeOutcomes() {
    // A script wrapping `doctor` needs to tell "throttled, try later" from
    // "this build is finished".
    #expect(Diagnosis.exitCode(for: .ok) == 0)
    #expect(Diagnosis.exitCode(for: .degraded) == 1)
    #expect(Diagnosis.exitCode(for: .broken) == 2)
    #expect(Diagnosis.exitCode(for: .skipped) == 0)
}

@Test func theBudgetEstimateMatchesTheSweepsWorstCase() {
    // Task 12 measures the real number by simulation; this is the closed-form
    // version the user sees. They must not contradict each other: the
    // estimate has to be a genuine upper bound on what `DaySimulation`
    // measures, everywhere `BudgetSweepTests` sweeps, and it must not drift
    // far above that measurement either.
    //
    // The margin below covers the one gap the closed form cannot close
    // exactly: `DaySimulation` runs one continuous timeline, so a cycle
    // already under way when a session boundary passes carries its deadline
    // across that boundary. A per-session split can't see that carry-over,
    // so rounding each session's `sessionSeconds / cycle` up (rather than
    // down) sometimes credits a partial final cycle the simulation never
    // gets to start. Measured worst case across this grid is 40, at 900s x
    // 20 symbols — 580 simulated against 620 estimated, re-taken after F1
    // changed the day model (the pair used to read 760 and 800; the gap of 40
    // survived the change, the two endpoints did not). Widening this number
    // later should be a visible, deliberate act, not a quiet tolerance creep.
    let acceptableOvershoot = 40

    for interval in RateConstants.refreshIntervalChoices {
        for count in [1, 2, 4, 10, 20] {
            let sim = DaySimulation.run(userInterval: interval, watchlistCount: count)
            let estimate = Diagnosis.estimatedDailyRequests(userIntervalSeconds: interval,
                                                            watchlistCount: count)
            let label = "interval \(interval)s x \(count) symbols -> estimate \(estimate), sim \(sim.requests)"
            #expect(estimate >= sim.requests, "\(label): estimate undercuts the sweep")
            #expect(estimate <= sim.requests + acceptableOvershoot,
                    "\(label): estimate overshoots the sweep by more than \(acceptableOvershoot)")

            // Spec §4.2's cap is deliberately *not* asserted here, and the
            // reason has changed, so it is worth writing down again.
            //
            // It used to be unfalsifiable because `estimatedDailyRequests`
            // ended in `min(naive, pacerDailyCeiling)` — a constant with no
            // argument in it — so the assertion held for any implementation
            // that kept the clamp, including one wrong by hundreds at every
            // point on this grid. That clamp is gone (see `Diagnosis`).
            //
            // It is still unfalsifiable, for a better reason, and this one is
            // measured rather than argued: this estimator prices a *US equity*
            // day, and 6.5h of regular session against a 30s spacing floor
            // cannot buy 1,200 requests. Swept over every watchlist size 1...20
            // and intervals down to 1s, with `cycleInterval`'s budget floor
            // deleted, the largest number this function returns is 1,197 — at
            // 1s x 19 symbols, a point the Settings menu cannot even reach.
            // An assertion that survives deleting the mechanism it is meant to
            // guard is decoration, and this file has already been burned once
            // by keeping one.
            //
            // The budget is asserted where it can fail: on a calendar that
            // offers no overnight relief, in
            // `thePolicyHoldsTheBudgetWithoutHelpFromThePacersBackstop` below
            // (1,440/1,920/2,880 against 1,200 with the floor deleted), and
            // end-to-end in `theDailyBudgetHoldsAcrossEveryReachableConfiguration`.
            // What this grid checks is that the estimate tracks the simulation,
            // which is the only claim it is in a position to make.
        }
    }
}

@Test func thePolicyHoldsTheBudgetWithoutHelpFromThePacersBackstop() {
    // The pacer's daily bucket is the backstop, and a backstop that binds in
    // normal operation is not a backstop — it is the mechanism, running with no
    // margin behind it. So the policy has to hold the budget on its own, on the
    // calendar that offers it no help at all: an instrument that never closes,
    // where every second of the day is a `.regular` second and there is no
    // overnight stretch to average the cost down.
    //
    // This is the claim the removed `pacerDailyCeiling` constant used to make
    // and could not keep. That constant summed a 6.5h regular session and two
    // quiet ones — a US equity calendar — and so asserted the budget held only
    // where the calendar was already holding it. Here the calendar contributes
    // nothing.
    for interval in RateConstants.refreshIntervalChoices {
        for count in [1, 2, 4, 10, 20] {
            let cycle = RefreshPolicy.cycleInterval(userIntervalSeconds: interval,
                                                    watchlistCount: count,
                                                    marketState: .regular,
                                                    lowPowerMode: false)
            let perDay = Double(count) * RateConstants.secondsPerDay / cycle
            #expect(perDay <= Double(RateConstants.dailyRequestBudget),
                    "interval \(interval)s x \(count) symbols -> \(perDay) requests/day, never closing")
        }
    }
}

@Test func aSettingTheFloorsCannotHonourIsReportedAsThrottled() {
    // R79. 20 symbols sit on a 1,440s cycle — the budget floor's 72s a symbol,
    // not the spacing floor's 30 — so a user who asked for 60s is getting a
    // twenty-fourth of the refresh rate they configured and nothing in the app
    // told them. The name and this arithmetic both used to say 600s and "a
    // tenth", which was the spacing floor; F19 established that the spacing
    // floor can never be the binding term on its own, and the sibling test
    // below was renamed for that reason while this one was not. This is the condition `doctor`'s budget check
    // reports, in place of a comparison against the daily budget that no input
    // could ever satisfy.
    #expect(Diagnosis.pacerThrottlesSettings(userIntervalSeconds: 60, watchlistCount: 20))
    #expect(Diagnosis.pacerThrottlesSettings(userIntervalSeconds: 60, watchlistCount: 3))
}

@Test func aSettingEveryFloorCanHonourIsNotReportedAsThrottled() {
    // Warning a user with nothing to fix spends the signal. These are the
    // settings both floors clear: one symbol at 15 minutes wants a cycle 12.5
    // times the 72s the budget floor asks for, and four symbols at 5 minutes
    // want 300s against a 288s floor.
    //
    // The rows here used to be `60 x 2` and `900 x 20`, chosen when `n x 30s`
    // was the only floor. The budget floor is the larger one at every watchlist
    // size — 72s a symbol against 30 — so both of those are now genuinely
    // throttled and belong in the test above, not this one. The name changed
    // with them: it is no longer the spacing floor that decides this.
    #expect(!Diagnosis.pacerThrottlesSettings(userIntervalSeconds: 900, watchlistCount: 1))
    #expect(!Diagnosis.pacerThrottlesSettings(userIntervalSeconds: 300, watchlistCount: 4))
    #expect(!Diagnosis.pacerThrottlesSettings(userIntervalSeconds: 60, watchlistCount: 0))
}

@Test func anIntervalThisBuildCannotHonourIsJudgedAgainstTheOneItSubstitutes() {
    // A hand-edited `7200` is not a setting `cycleInterval` honours — it runs
    // the 180s default instead — so the comparison has to be against 180 too.
    // Judged against the raw 7200 this would report "not throttled" for a
    // 20-symbol watchlist actually running a 1,440s cycle.
    let throttled = Diagnosis.pacerThrottlesSettings(userIntervalSeconds: 7_200,
                                                     watchlistCount: 20)
    #expect(throttled)
}

@Test func theBudgetEstimateIsFlatAcrossWatchlistSizesOnceTheFloorsBind() {
    // The invariant from spec §4.2, restated where a user can see it: once a
    // floor binds, adding symbols costs nothing per day. Both floors scale
    // linearly in the count, so `count / (k x count)` does not depend on the
    // count at all — a twentieth symbol is free.
    //
    // Asserted on the rate first, because that is where the invariant is exact,
    // and the number it lands on is the budget itself: at a 60s setting the
    // budget floor binds at every size, so a never-closing day costs exactly
    // the budget and not a request more.
    for count in [1, 2, 4, 10, 20] {
        let cycle = RefreshPolicy.cycleInterval(userIntervalSeconds: 60, watchlistCount: count,
                                                marketState: .regular, lowPowerMode: false)
        let perDay = Double(count) * RateConstants.secondsPerDay / cycle
        #expect(perDay == Double(RateConstants.dailyRequestBudget),
                "\(count) symbols -> \(perDay) requests/day")
    }

    // The reported estimate inherits that flatness only approximately, and only
    // from two symbols up. Two things get in the way, and neither is a cost
    // that grew:
    //
    // One symbol is genuinely cheaper, in the quiet sessions alone: `3 x max(60,
    // 30 x 1)` is 180s, which clears the 72s budget floor, so pre- and
    // post-market still run on the user's own interval there. It reports 515
    // against 706 at two symbols, and that gap is measured exactly in
    // `BudgetSweepTests.theFloorsMakeCostFlatInWatchlistSize`.
    //
    // Above that, each of the three sessions rounds its own `sessionSeconds /
    // cycle` up, so the estimate can carry as much as one extra pass per
    // session — 3 x count requests — over the flat rate. That is the envelope
    // asserted here. Measured across 2, 4, 10 and 20 symbols the spread is 14
    // requests (706 to 720) where the envelope allows 66, so this stays a bound
    // on a rounding artefact and not a licence for cost to track size: a cost
    // that tracked size would put twenty symbols at ten times two.
    let reference = 2
    let base = Diagnosis.estimatedDailyRequests(userIntervalSeconds: 60,
                                                watchlistCount: reference)
    for count in [4, 10, 20] {
        let estimate = Diagnosis.estimatedDailyRequests(userIntervalSeconds: 60,
                                                        watchlistCount: count)
        let envelope = 3 * (count + reference)
        #expect(abs(estimate - base) <= envelope,
                "\(reference) symbols -> \(base), \(count) symbols -> \(estimate)")
    }
}

@Test func aLongerRefreshIntervalEstimatesFewerRequests() {
    let fast = Diagnosis.estimatedDailyRequests(userIntervalSeconds: 60, watchlistCount: 2)
    let slow = Diagnosis.estimatedDailyRequests(userIntervalSeconds: 900, watchlistCount: 2)
    #expect(slow < fast)
}

@Test func anEmptyWatchlistEstimatesNoRequests() {
    #expect(Diagnosis.estimatedDailyRequests(userIntervalSeconds: 60, watchlistCount: 0) == 0)
}

@Test func theEstimatorCannotReachTheBudgetOnAnyInput() {
    // Pins the measurement that `pacerThrottlesSettings`' documentation rests
    // on, because that documentation once claimed the opposite and nothing
    // would have caught it.
    //
    // `estimatedDailyRequests` prices a US equity day — 6.5h regular, 5.5h
    // pre, 4h post, eight hours shut — so no interval it can be handed buys
    // 1,200 requests. Swept far outside the offered menu, down to a tenth of a
    // second, the largest figure it returns is 741, at 19 symbols. (Nineteen
    // rather than twenty because `budgetFloor` scales with the count: at 20 the
    // floor is 1,440s a cycle against 19's 1,368s, and the extra symbol does
    // not pay for the longer cycle.)
    //
    // The exact figure is asserted, not just "under budget": a bound the code
    // cannot approach is decoration, and this file has been burned twice now
    // by keeping one. 741 fails the moment the day model or the floor moves,
    // which is when someone should be looking.
    var worst = 0
    var worstAt = ""
    for tenths in 1...36_000 {
        let interval = Double(tenths) / 10
        for count in 1...RateConstants.maxWatchlistCount {
            let estimate = Diagnosis.estimatedDailyRequests(userIntervalSeconds: interval,
                                                            watchlistCount: count)
            if estimate > worst {
                worst = estimate
                worstAt = "\(interval)s x \(count) symbols"
            }
        }
    }
    let reached = "the estimator reached \(worst) at \(worstAt)"
    #expect(worst == 741, "\(reached)")
    #expect(worst < RateConstants.dailyRequestBudget, "\(reached)")
}
