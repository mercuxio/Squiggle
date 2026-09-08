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
    #expect(Diagnosis.status(for: .transport("connection reset")) == .degraded)
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
        .invalidSymbol("not a symbol"), .offline, .transport("connection reset"),
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
    // 20 symbols (760 simulated vs 800 estimated). Widening this number
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

            // Spec §4.2's cap is a separate claim from the sweep comparison
            // above and must not be lost just because the name now points at
            // the sweep instead.
            #expect(estimate <= 1_200, "\(label): estimate exceeds the daily budget")
        }
    }
}

@Test func theBudgetEstimateIsFlatAcrossWatchlistSizesAtTheSpacingFloor() {
    // The invariant from spec §4.2, restated where a user can see it: once
    // the 30s floor binds, adding symbols costs nothing per day.
    let small = Diagnosis.estimatedDailyRequests(userIntervalSeconds: 60, watchlistCount: 4)
    let large = Diagnosis.estimatedDailyRequests(userIntervalSeconds: 60, watchlistCount: 20)
    #expect(small == large)
}

@Test func aLongerRefreshIntervalEstimatesFewerRequests() {
    let fast = Diagnosis.estimatedDailyRequests(userIntervalSeconds: 60, watchlistCount: 2)
    let slow = Diagnosis.estimatedDailyRequests(userIntervalSeconds: 900, watchlistCount: 2)
    #expect(slow < fast)
}

@Test func anEmptyWatchlistEstimatesNoRequests() {
    #expect(Diagnosis.estimatedDailyRequests(userIntervalSeconds: 60, watchlistCount: 0) == 0)
}
