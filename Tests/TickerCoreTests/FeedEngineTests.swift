import Testing
@testable import TickerCore

/// R55: `#expect(x == false)` silently passes for any `x`, and a mutating
/// call or a `try` cannot appear directly inside `#expect(...)` — Swift
/// evaluates the macro's argument in a context that rejects both. Every
/// call here that would otherwise violate that is hoisted to a `let` on the
/// prior line before being compared.
struct FeedEngineTests {

    private func sym(_ raw: String) throws -> Symbol {
        try #require(Symbol(raw))
    }

    private func openMarket(_ nowEpoch: Double = 1_757_000_000) -> EngineContext {
        EngineContext(nowEpoch: nowEpoch, marketState: .regular, visibility: .visible,
                      lowPowerMode: false, nextSessionOpenEpoch: nil)
    }

    private func engine(_ clock: FakeClock, _ symbols: [Symbol],
                        interval: Double = RateConstants.defaultRefreshInterval,
                        random: FakeRandom = FakeRandom()) -> FeedEngine {
        FeedEngine(clock: clock, random: random, symbols: symbols,
                  userIntervalSeconds: interval)
    }

    // MARK: - Fetch order and pacing

    @Test func theFirstActionOnAnOpenMarketIsToFetchTheFirstSymbol() throws {
        let clock = FakeClock()
        var e = engine(clock, [try sym("AAPL"), try sym("MSFT")])
        let aapl = try sym("AAPL")
        let action = e.next(openMarket())
        #expect(action == .fetch(aapl))
    }

    @Test func symbolsAreFetchedInWatchlistOrderOneAtATime() throws {
        let clock = FakeClock()
        let symbols = [try sym("AAPL"), try sym("MSFT"), try sym("NVDA")]
        var e = engine(clock, symbols)

        var fetched: [Symbol] = []
        for _ in 0..<3 {
            guard case .fetch(let s) = e.next(openMarket()) else {
                Issue.record("expected a fetch")
                return
            }
            fetched.append(s)
            e.recordSuccess(stubQuote(s), for: s)
            clock.advance(RateConstants.spacingSeconds)
        }
        #expect(fetched == symbols)
    }

    @Test func aSecondFetchInsideTheSpacingWindowIsRefusedByThePacer() throws {
        let clock = FakeClock()
        let many = try (1...10).map { try sym("SYM\($0)") }
        var e = engine(clock, many, interval: 60)

        var slept = false
        for _ in 0..<12 {
            switch e.next(openMarket()) {
            case .fetch(let s):
                e.recordSuccess(stubQuote(s), for: s)
            case .sleep(let seconds):
                slept = true
                #expect(seconds > 0)
            }
        }
        #expect(slept, "ten symbols went out with no pause; the pacer was bypassed")
    }

    /// Fix round 1, Finding 1: this used to drive a single-symbol watchlist
    /// with the clock frozen, re-fetching the same symbol five times
    /// back-to-back to drain the pacer's whole bucket. That is no longer a
    /// reachable sequence: with `cycleDeadline` restored, a one-symbol
    /// watchlist wraps its cursor after every fetch, and a wrap with the
    /// clock still frozen is refused by the cycle gate before the pacer is
    /// even asked a second time — see
    /// `theCycleGateKeepsFeedEngineUnderBudgetAndInStepWithTheDaySimulation`
    /// for that gate's own coverage.
    ///
    /// So this now uses one symbol per bucket token instead: the cursor
    /// never wraps mid-loop (it reaches `live.count` only on the fetch that
    /// empties the bucket), meaning the cycle gate is not yet in play and
    /// the sleep this test pins is still the pacer's, not the cycle's.
    @Test func theSleepReportedIsTheTimeUntilTheNextTokenAndNotAGuess() throws {
        let clock = FakeClock()
        let symbols = try (1...Int(RateConstants.bucketCapacity)).map { try sym("SYM\($0)") }
        var e = engine(clock, symbols, interval: 60)

        // Drain the bucket: one fetch per symbol, so the cursor reaches
        // `live.count` only once, on the very fetch that empties it.
        for _ in symbols {
            guard case .fetch(let s) = e.next(openMarket()) else {
                Issue.record("expected a fetch while the bucket still had tokens")
                return
            }
            e.recordSuccess(stubQuote(s), for: s)
        }
        guard case .sleep(let seconds) = e.next(openMarket()) else {
            Issue.record("expected a sleep once the bucket was empty")
            return
        }
        // Sleeping longer than necessary wastes a refresh; sleeping shorter
        // wakes the caller up to be refused again.
        #expect(seconds <= RateConstants.spacingSeconds)
        #expect(seconds > 0)
    }

    // MARK: - Visibility and market state

    @Test func anOccludedMenuBarStopsFetchingEntirely() throws {
        let clock = FakeClock()
        var e = engine(clock, [try sym("AAPL")])
        let context = EngineContext(nowEpoch: 1_757_000_000, marketState: .regular,
                                    visibility: .occluded, lowPowerMode: false,
                                    nextSessionOpenEpoch: nil)

        for _ in 0..<20 {
            guard case .sleep = e.next(context) else {
                Issue.record("an occluded menu bar must never fetch")
                return
            }
            clock.advance(60)
        }
    }

    @Test func aClosedMarketSleepsUntilShortlyBeforeTheOpen() throws {
        let clock = FakeClock()
        var e = engine(clock, [try sym("AAPL")])
        let now: Double = 1_757_000_000
        let context = EngineContext(nowEpoch: now, marketState: .closed,
                                    visibility: .visible, lowPowerMode: false,
                                    nextSessionOpenEpoch: now + 7200)

        guard case .sleep(let seconds) = e.next(context) else {
            Issue.record("expected a wait while the market is closed")
            return
        }
        #expect(seconds == 7200 - RateConstants.preOpenWakeLead)

        let noOpen = EngineContext(nowEpoch: now, marketState: .closed,
                                   visibility: .visible, lowPowerMode: false,
                                   nextSessionOpenEpoch: nil)
        guard case .sleep(let fallback) = e.next(noOpen) else {
            Issue.record("expected a fallback wait with no known open")
            return
        }
        #expect(fallback > 0 && fallback <= 3600)
    }

    @Test func anEmptyWatchlistNeverFetchesAndNeverSpins() throws {
        let clock = FakeClock()
        var e = engine(clock, [])

        guard case .sleep(let seconds) = e.next(openMarket()) else {
            Issue.record("an empty watchlist must never fetch")
            return
        }
        #expect(seconds > 0, "a zero-length sleep would spin")
    }

    // MARK: - Dead symbols

    @Test func aDeadSymbolIsSkippedForTheRestOfTheSession() throws {
        let clock = FakeClock()
        let symbols = [try sym("GONE"), try sym("AAPL")]
        var e = engine(clock, symbols)
        let gone = try sym("GONE")

        guard case .fetch(let first) = e.next(openMarket()) else {
            Issue.record("expected the first fetch to go out")
            return
        }
        #expect(first == gone)
        e.record(.symbolNotFound(first), for: first)
        let stillDead = e.deadSymbols.contains(gone)
        #expect(stillDead)

        for _ in 0..<10 {
            clock.advance(RateConstants.spacingSeconds)
            if case .fetch(let s) = e.next(openMarket()) {
                #expect(s != gone)
                e.recordSuccess(stubQuote(s), for: s)
            }
        }
    }

    @Test func aDeadSymbolDoesNotOpenTheCircuitOrStartACooldown() throws {
        let clock = FakeClock()
        let symbols = [try sym("GONE"), try sym("AAPL")]
        var e = engine(clock, symbols)
        let gone = try sym("GONE")

        guard case .fetch = e.next(openMarket()) else {
            Issue.record("expected the first fetch to go out")
            return
        }
        for _ in 0..<10 {
            e.record(.symbolNotFound(gone), for: gone)
        }
        #expect(e.cooldownUntilEpoch(nowEpoch: 1_757_000_000) == nil)

        clock.advance(RateConstants.spacingSeconds)
        guard case .fetch = e.next(openMarket()) else {
            Issue.record("a dead symbol must not stop the rest of the watchlist")
            return
        }
    }

    @Test func everySymbolBeingDeadStopsTheEngineWithoutBusyLooping() throws {
        let clock = FakeClock()
        let symbols = [try sym("GONE1"), try sym("GONE2")]
        var e = engine(clock, symbols)
        e.record(.symbolNotFound(try sym("GONE1")), for: try sym("GONE1"))
        e.record(.symbolNotFound(try sym("GONE2")), for: try sym("GONE2"))

        guard case .sleep(let seconds) = e.next(openMarket()) else {
            Issue.record("every symbol dead must never fetch")
            return
        }
        #expect(seconds > 0)
    }

    // MARK: - Failure classes

    @Test func aRateLimitStopsEverythingForAtLeastTheBackoffBase() throws {
        let clock = FakeClock()
        let s = try sym("AAPL")
        var e = engine(clock, [s])

        guard case .fetch = e.next(openMarket()) else {
            Issue.record("expected an initial fetch")
            return
        }
        e.record(.rateLimited(retryAfterSeconds: nil), for: s)

        guard case .sleep(let seconds) = e.next(openMarket()) else {
            Issue.record("expected a wait after a rate limit")
            return
        }
        #expect(seconds >= RateConstants.rateLimitBackoffBase)
    }

    @Test func aRetryAfterHeaderIsHonouredWhenYahooSendsOne() throws {
        let clock = FakeClock()
        let s = try sym("AAPL")
        var e = engine(clock, [s])

        guard case .fetch = e.next(openMarket()) else {
            Issue.record("expected an initial fetch")
            return
        }
        e.record(.rateLimited(retryAfterSeconds: 300), for: s)

        guard case .sleep(let seconds) = e.next(openMarket()) else {
            Issue.record("expected a wait honouring Retry-After")
            return
        }
        #expect(seconds >= 300)
    }

    @Test func fiveConsecutiveTransportFailuresOpenTheNetworkCircuit() throws {
        let clock = FakeClock()
        let s = try sym("AAPL")
        var e = engine(clock, [s])
        for _ in 0..<RateConstants.circuitFailureThreshold {
            e.record(.transport(.unrecognized), for: s)
        }

        guard case .sleep(let seconds) = e.next(openMarket()) else {
            Issue.record("expected a wait once the network circuit opened")
            return
        }
        #expect(seconds > 0)

        clock.advance(RateConstants.circuitOpenSeconds + 1)
        guard case .fetch = e.next(openMarket()) else {
            Issue.record("expected a half-open probe to be offered")
            return
        }
    }

    @Test func oneContractFaultIsEnoughToStopAsking() throws {
        let clock = FakeClock()
        let s = try sym("AAPL")
        var e = engine(clock, [s])
        e.record(.missingField(path: "chart.result[0].meta.regularMarketPrice"), for: s)

        guard case .sleep(let seconds) = e.next(openMarket()) else {
            Issue.record("expected a wait after a contract fault")
            return
        }
        #expect(seconds > 0)

        clock.advance(RateConstants.contractFaultCooldown / 2)
        guard case .sleep = e.next(openMarket()) else {
            Issue.record("a contract fault must hold for the full hour")
            return
        }
    }

    @Test func aSuccessAfterFailuresClearsTheLadderAndTheCircuit() throws {
        let clock = FakeClock()
        let s = try sym("AAPL")
        var e = engine(clock, [s])
        for _ in 0..<3 {
            e.record(.transport(.unrecognized), for: s)
        }

        clock.advance(RateConstants.rateLimitBackoffCap)
        guard case .fetch = e.next(openMarket()) else {
            Issue.record("still cooling down long after the cap")
            return
        }
        e.recordSuccess(stubQuote(s), for: s)
        #expect(e.cooldownUntilEpoch(nowEpoch: 1_757_000_000) == nil)
    }

    // MARK: - Quotes in memory

    @Test func aSuccessfulQuoteIsHeldInMemoryUnderItsSymbol() throws {
        let clock = FakeClock()
        let s = try sym("AAPL")
        var e = engine(clock, [s])
        e.recordSuccess(stubQuote(s, price: 231.5), for: s)
        #expect(e.latest[s]?.price == 231.5)
    }

    @Test func replacingTheWatchlistDropsQuotesForSymbolsNoLongerWatched() throws {
        let clock = FakeClock()
        let gone = try sym("GONE")
        let kept = try sym("AAPL")
        var e = engine(clock, [gone, kept])
        e.recordSuccess(stubQuote(gone), for: gone)
        e.recordSuccess(stubQuote(kept), for: kept)

        e.replaceWatchlist([kept])
        #expect(e.latest[gone] == nil)
        #expect(e.latest[kept] != nil)
    }

    @Test func replacingTheWatchlistAlsoForgetsWhichSymbolsWereDead() throws {
        let clock = FakeClock()
        let s = try sym("GONE")
        var e = engine(clock, [s])
        e.record(.symbolNotFound(s), for: s)
        #expect(e.deadSymbols.contains(s))

        e.replaceWatchlist([s, try sym("AAPL")])
        #expect(e.deadSymbols.isEmpty)
    }

    @Test func replacingTheWatchlistDoesNotResetTheCooldown() throws {
        let clock = FakeClock()
        let s = try sym("AAPL")
        var e = engine(clock, [s])
        e.record(.rateLimited(retryAfterSeconds: nil), for: s)

        e.replaceWatchlist([s, try sym("MSFT")])
        guard case .sleep(let seconds) = e.next(openMarket()) else {
            Issue.record("a watchlist edit must not clear a live cooldown")
            return
        }
        #expect(seconds >= RateConstants.rateLimitBackoffBase)
    }

    // MARK: - Persisted cooldown

    @Test func aPersistedCooldownSurvivesARestart() throws {
        let clock = FakeClock()
        var e = engine(clock, [try sym("AAPL")])
        let now: Double = 1_757_000_000
        e.adoptPersistedCooldown(untilEpoch: now + 900, nowEpoch: now)

        guard case .sleep(let seconds) = e.next(openMarket(now)) else {
            Issue.record("expected a wait for the adopted cooldown")
            return
        }
        #expect(seconds > 0)
    }

    @Test func aCooldownDeadlineAlreadyInThePastIsIgnored() throws {
        let clock = FakeClock()
        var e = engine(clock, [try sym("AAPL")])
        let now: Double = 1_757_000_000
        e.adoptPersistedCooldown(untilEpoch: now - 5000, nowEpoch: now)

        guard case .fetch = e.next(openMarket(now)) else {
            Issue.record("a cooldown that already elapsed must not block a fetch")
            return
        }
    }

    // MARK: - Invariant sweep

    @Test func theEngineNeverReturnsAZeroLengthSleep() throws {
        let clock = FakeClock()
        var e = engine(clock, [])
        let states: [MarketState] = [.pre, .regular, .post, .closed]
        let visibilities: [Visibility] = [.visible, .occluded]

        for state in states {
            for visibility in visibilities {
                let context = EngineContext(nowEpoch: 1_757_000_000, marketState: state,
                                            visibility: visibility, lowPowerMode: false,
                                            nextSessionOpenEpoch: nil)
                if case .sleep(let seconds) = e.next(context) {
                    #expect(seconds > 0, "a zero-length sleep would spin")
                }
            }
        }
    }

    // MARK: - Budget: the cycle gate against the day simulation

    /// Drives the real `FeedEngine` across one simulated market day, using
    /// exactly the session schedule `BudgetSweepTests.Day` sweeps the whole
    /// configuration space with — not a second, hand-rolled calendar that
    /// could quietly drift from it. On `.sleep`, the clock jumps straight to
    /// the reported wake time (what a real caller does: sleep, then ask
    /// again) rather than ticking one second at a time for a whole day.
    private func driveFeedEngine(userInterval: Double, watchlistCount: Int) throws -> Int {
        let clock = FakeClock()
        let symbols = try (1...watchlistCount).map { try sym("SYM\($0)") }
        var e = engine(clock, symbols, interval: userInterval)

        var fetches = 0
        var t: Double = 0
        while t < Day.length {
            let market = Day.state(atSecondOfDay: t)
            let context = EngineContext(
                nowEpoch: t, marketState: market, visibility: .visible, lowPowerMode: false,
                nextSessionOpenEpoch: Day.nextSessionOpen(afterSecondOfDay: t))

            switch e.next(context) {
            case .fetch(let s):
                fetches += 1
                e.recordSuccess(stubQuote(s), for: s)
            case .sleep(let seconds):
                let step = max(1, seconds)
                t += step
                clock.advance(step)
            }
        }
        return fetches
    }

    /// Finding 1 (fix round 1): `FeedEngine.next(_:)` shipped with no
    /// `cycleDeadline` of any kind, so nothing gated the fetch path on
    /// `RefreshPolicy.cycleInterval` — the engine round-robined continuously
    /// at the token bucket's floor rate (2,880/day) regardless of
    /// `userIntervalSeconds`, against a 1,200/day budget.
    ///
    /// The anti-vacuity move per the fix brief: do not hand-roll an expected
    /// request count. Compare the engine's actual count against
    /// `DaySimulation`, the model that already exists and that this whole
    /// suite's sibling file (`BudgetSweepTests`) trusts as authoritative —
    /// its own doc comment: "if this simulation and the runner ever
    /// disagree, the runner is the bug." Against the pre-fix engine this
    /// fails on both counts: the request count blows through the budget, and
    /// it is nowhere near what the `cycleDeadline`-gated model predicts.
    ///
    /// Finding 4 (fix round 2): a single hard-coded `interval: 60, count: 10`
    /// only ever exercised the floor-dominated regime of
    /// `RefreshPolicy.cycleInterval` — `floor = count * spacingSeconds = 300`
    /// beats `requested = 60`, so `userIntervalSeconds` never actually binds.
    /// Swept across every choice in `RateConstants.refreshIntervalChoices`
    /// and the same watchlist sizes `BudgetSweepTests` uses (1, 2, 4, 10,
    /// 20) — which covers both regimes, e.g. interval 900 / count 4 is
    /// interval-dominated (floor is only 120) while interval 60 / count 10 is
    /// floor-dominated — the measured drift between `FeedEngine` and the
    /// `DaySimulation` oracle equals the watchlist count itself at every
    /// interval except the largest (900), where it falls to 15 at count 20
    /// because the interval, not the spacing floor, is what is binding
    /// there. The worst case seen anywhere in that sweep is 20 requests, at
    /// count 20 — not a number picked to make one lucky configuration pass
    /// with room to spare, but the ceiling the evidence actually supports.
    /// A per-cycle off-by-one that drops or double-serves one symbol costs
    /// roughly 78 requests across a day — four times this bound — so a flat
    /// 20 stays tight enough to catch it.
    @Test func theCycleGateKeepsFeedEngineUnderBudgetAndInStepWithTheDaySimulation() throws {
        let tolerance = 20

        for interval in RateConstants.refreshIntervalChoices {
            for count in [1, 2, 4, 10, 20] {
                let actual = try driveFeedEngine(userInterval: interval, watchlistCount: count)
                let predicted = DaySimulation.run(userInterval: interval,
                                                   watchlistCount: count).requests

                #expect(actual < 1_200,
                        "interval \(interval) x \(count): \(actual) exceeds the 1,200/day budget")

                // Not an exact match: `DaySimulation` paces individual
                // within-cycle fetches by an explicit per-symbol
                // `nextSymbolDue`, while `FeedEngine` paces them through the
                // shared token bucket's burst allowance, so a handful of
                // requests can land on either side of a session boundary.
                let drift = abs(actual - predicted)
                let message = "interval \(interval) x \(count): engine fetched \(actual); "
                    + "the cycleDeadline model predicts \(predicted) (drift \(drift))"
                #expect(drift <= tolerance, "\(message)")
            }
        }
    }

    // MARK: - R57: the half-open probe belongs to the fetch, not the query

    /// `RefreshInput.circuitAllows` decides *whether* the policy will fetch;
    /// it must be built from a query (`wouldAllowRequest()`), never from the
    /// command (`allowsRequest()`). Otherwise the very first call that asks
    /// "would you fetch?" — even one that goes on to return `.wait` for an
    /// unrelated reason, such as a closed market — already spends the one
    /// half-open probe permit, and the next call that could actually use it
    /// finds the breaker refusing again.
    @Test func aHalfOpenProbeSurvivesADecisionThatDoesNotFetch() throws {
        let clock = FakeClock()
        let s = try sym("AAPL")
        var e = engine(clock, [s])

        // Open the network circuit, then let it go half-open.
        for _ in 0..<RateConstants.circuitFailureThreshold {
            e.record(.transport(.unrecognized), for: s)
        }
        clock.advance(RateConstants.circuitOpenSeconds + 1)

        // Ask under conditions the policy will refuse for an unrelated
        // reason — the market is closed with no known next open. This must
        // not consume the half-open probe.
        let closed = EngineContext(nowEpoch: 1_757_000_000, marketState: .closed,
                                   visibility: .visible, lowPowerMode: false,
                                   nextSessionOpenEpoch: nil)
        guard case .sleep = e.next(closed) else {
            Issue.record("expected a wait while the market is closed")
            return
        }

        // Now ask under conditions that would fetch. If the probe survived,
        // this is a fetch; if it was burned above, the breaker is refusing
        // again and this comes back as another sleep.
        let action = e.next(openMarket())
        guard case .fetch = action else {
            Issue.record("the half-open probe was spent on a decision that never fetched")
            return
        }
    }

    // MARK: - Finding 5: setUserInterval must pace the very next cycle

    /// `setUserInterval` exists for plan 2's menu bar app, whose Settings
    /// refresh-interval control can change the interval while the engine
    /// keeps running. Its whole purpose is `cycleDeadline = 0`: without that
    /// reset, a deadline already computed from the *old* interval keeps
    /// gating the next pass, and the new interval would not take effect
    /// until the pass after that — one full cycle late. This test is built
    /// to fail on exactly that regression: it pins the deadline `next()`
    /// computes for the pass immediately following `setUserInterval`, not
    /// merely the stored `userIntervalSeconds` value (a test that only
    /// checked the stored value would pass even if the reset were deleted).
    @Test func setUserIntervalPacesTheVeryNextCycleByTheNewIntervalNotTheOld() throws {
        let clock = FakeClock()
        let s = try sym("AAPL")
        var e = engine(clock, [s], interval: 60)

        // With one symbol, the cursor reaches `live.count` on the very first
        // fetch, but the wrap-and-recompute logic runs at the *top* of
        // `next()`, so `cycleDeadline` is not touched by this call.
        guard case .fetch = e.next(openMarket()) else {
            Issue.record("expected the first fetch to go out")
            return
        }
        e.recordSuccess(stubQuote(s), for: s)

        // This call wraps the cursor and — before immediately refetching,
        // since the pass it just started also has only one symbol —
        // computes `cycleDeadline` from the *old* 60s interval: for one
        // symbol the spacing floor is 30s, so cycle = max(60, 30) = 60.
        guard case .fetch = e.next(openMarket()) else {
            Issue.record("expected the wrap-and-refetch to go out")
            return
        }
        e.recordSuccess(stubQuote(s), for: s)

        // Widen the interval with the clock left exactly where it is. The
        // stale 60s deadline computed above is still 60 seconds in the
        // future at this instant.
        e.setUserInterval(900)

        // The witness for the reset: without it, the stale deadline (60s in
        // the future, per the clock, which has not moved) would still gate
        // the next pass, and this call would come back `.sleep` instead.
        // With the reset, `cycleDeadline` reads 0 — "already due" — so this
        // call both wraps immediately and recomputes the deadline from the
        // interval `setUserInterval` just installed, i.e. 900, not 60.
        guard case .fetch(let symbol) = e.next(openMarket()) else {
            let message = "setUserInterval did not reset cycleDeadline: the stale 60s "
                + "deadline computed before the call is still gating the next pass"
            Issue.record("\(message)")
            return
        }
        #expect(symbol == s)
        e.recordSuccess(stubQuote(s), for: s)

        // And the deadline that call just recomputed must be paced by 900,
        // not 60: with the clock still unmoved, a 60s-paced engine would
        // already be due again (60 <= 0 is false, but so would a much larger
        // stale value be reported as leftover from the old interval) — what
        // actually distinguishes 900 from 60 here is the reported wait
        // itself, which only a correctly-reset, newly-computed deadline
        // reports as ~900s rather than ~60s.
        guard case .sleep(let seconds) = e.next(openMarket()) else {
            let message = "expected the freshly-started pass to gate on its new deadline "
                + "rather than fetch again immediately"
            Issue.record("\(message)")
            return
        }
        #expect(seconds > 800,
                "the new cycle should be paced ~900s out, not ~60s: got \(seconds)")
    }

    // MARK: - Diagnostic snapshot (Task 17's `squigglectl doctor`/`watch` state line)

    @Test func aFreshEngineReportsAFullBucketAndBothCircuitsClosed() throws {
        let clock = FakeClock()
        let e = engine(clock, [try sym("AAPL")])
        let snapshot = e.diagnosticSnapshot
        #expect(snapshot.tokensAvailable == RateConstants.bucketCapacity)
        #expect(snapshot.networkCircuit == .closed)
        #expect(snapshot.contractCircuit == .closed)
        #expect(snapshot.cooldownRemainingSeconds == 0)
    }

    @Test func theSnapshotReportsAnOpenNetworkCircuitWithoutTrippingTheContractOne() throws {
        let clock = FakeClock()
        let s = try sym("AAPL")
        var e = engine(clock, [s])
        for _ in 0..<RateConstants.circuitFailureThreshold {
            e.record(.transport(.unrecognized), for: s)
        }
        let snapshot = e.diagnosticSnapshot
        let isOpen: Bool
        if case .open = snapshot.networkCircuit { isOpen = true } else { isOpen = false }
        #expect(isOpen, "five consecutive transport failures should open the network circuit")
        #expect(snapshot.contractCircuit == .closed,
                "a network-only failure must not trip the independent contract circuit")
    }
}
