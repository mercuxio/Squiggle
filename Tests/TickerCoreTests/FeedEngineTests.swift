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
            e.record(.transport("boom"), for: s)
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
            e.record(.transport("boom"), for: s)
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
    @Test func theCycleGateKeepsFeedEngineUnderBudgetAndInStepWithTheDaySimulation() throws {
        let interval: Double = 60
        let count = 10

        let actual = try driveFeedEngine(userInterval: interval, watchlistCount: count)
        let predicted = DaySimulation.run(userInterval: interval, watchlistCount: count).requests

        #expect(actual < 1_200, "\(actual) requests exceeds the 1,200/day budget")

        // Not an exact match: `DaySimulation` paces individual within-cycle
        // fetches by an explicit per-symbol `nextSymbolDue`, while
        // `FeedEngine` paces them through the shared token bucket's burst
        // allowance, so a handful of requests can land on either side of a
        // session boundary. The tolerance is a small fraction of the
        // prediction, not a number picked to make this pass.
        let drift = abs(actual - predicted)
        let tolerance = max(20, predicted / 10)
        #expect(drift <= tolerance,
                "engine fetched \(actual); the cycleDeadline model predicts \(predicted)")
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
            e.record(.transport("boom"), for: s)
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
}
