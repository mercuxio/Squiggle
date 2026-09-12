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

    // MARK: - Offline

    @Test func aWifiDropAdvancesNeitherCircuitNorTheLadder() throws {
        // F4. `Failure.swift` documents `.offline` as "the path monitor says
        // there is no network. Do not attempt, do not advance the ladder."
        // `record` did the opposite twice over: `.offline` shared an arm with
        // `.server` and `.unauthorized` calling `networkCircuit.recordFailure()`,
        // and then fell through to `ladder.record(kind)`. Five of them reached
        // the threshold, so a brief Wi-Fi drop silenced the app for thirty
        // minutes *after the network came back* — using a circuit meant to
        // protect Yahoo from us to punish the user for their own router.
        //
        // Ten, not five: the threshold is five, so ten is unambiguously past
        // it and the assertion cannot pass by having merely not yet arrived.
        let clock = FakeClock()
        let one = try sym("AAPL")
        var e = engine(clock, [one, try sym("MSFT")])
        for _ in 0..<10 { e.record(.offline, for: one) }

        let snapshot = e.diagnosticSnapshot
        #expect(snapshot.networkCircuit == .closed)
        #expect(snapshot.contractCircuit == .closed)
        // Honest about what this one detects: the ladder half of F4 was never
        // real. `BackoffLadder.record` has always had its own `.offline` arm
        // returning 0, so this assertion passed before the fix too. It is kept
        // because it is the only place the *composed* rule is stated, and it
        // is falsifiable — measured, not assumed: removing the early return
        // above *and* folding `.offline` into the ladder's `.server` arm gives
        // 900.0 here. A single-site regression at either end still leaves it
        // green, which is exactly why the circuit assertion above is the one
        // that carries F4.
        #expect(snapshot.cooldownRemainingSeconds == 0,
                "the ladder advanced to \(snapshot.cooldownRemainingSeconds)s on a network we never touched")

        // And the point of all three: the very next cycle is allowed. There is
        // no path-monitor edge to resume on — `TickerCore` takes no `Network`
        // dependency and the app layer that would own `NWPathMonitor` does not
        // exist — so retrying on the next cycle is the whole recovery story.
        let action = e.next(openMarket())
        #expect(action == .fetch(one))
    }

    @Test func anOpenCircuitCostsNoTokensBecauseTheTokenIsNeverTaken() throws {
        // F5 was raised as a hypothesis: `pacer.take()` sits above the two
        // `allowsRequest()` calls, so an open circuit was thought to burn one
        // token per wake with no request made. Measured, it does not, and this
        // test is the measurement rather than a claim.
        //
        // `RefreshPolicy.decide` is consulted *first* and is handed both
        // `circuitAllows` and `isCoolingDown`, so an open circuit returns
        // `.wait` and `next()` returns before it reaches the bucket at all.
        // The take below the policy is the last word on *when*, not the first.
        //
        // Two gates, not one, which is why a single mutation leaves this test
        // green: setting `circuitAllows: true` is masked by the ladder cooldown
        // that every one of these scenarios also carries. Falsified by removing
        // both — `circuitAllows: true` and the `isCoolingDown || !circuitAllows`
        // branch in `decide` — which reads 4.0 tokens here instead of 5.0.
        //
        // And 4.0, not 0.0, is the second half of the answer: even in that
        // world the engine loses exactly one token in five wakes, not one per
        // wake, because a 30-second bucket refills across a 60-second sleep.
        // The hypothesis needs both the gates gone *and* a sleep shorter than
        // the spacing interval; an open circuit sleeps for half an hour.
        let a = try sym("AAPL")

        // Network circuit fully open.
        let c1 = FakeClock()
        var e1 = engine(c1, [a, try sym("MSFT")])
        for _ in 0..<RateConstants.circuitFailureThreshold {
            e1.record(.serverError(status: 500), for: a)
        }
        #expect(e1.diagnosticSnapshot.networkCircuit == .open(untilMonotonic: RateConstants.circuitOpenSeconds))
        for _ in 0..<5 {
            _ = e1.next(openMarket())
            c1.advance(60)
        }
        #expect(e1.diagnosticSnapshot.tokensAvailable == RateConstants.bucketCapacity,
                "five wakes under an open network circuit spent tokens")

        // Contract circuit open, network circuit closed — the other half, so a
        // fix that only threaded one of the two cannot pass.
        let c2 = FakeClock()
        var e2 = engine(c2, [a, try sym("MSFT")])
        e2.record(.missingField(path: "regularMarketPrice"), for: a)
        #expect(e2.diagnosticSnapshot.networkCircuit == .closed)
        for _ in 0..<5 {
            _ = e2.next(openMarket())
            c2.advance(60)
        }
        #expect(e2.diagnosticSnapshot.tokensAvailable == RateConstants.bucketCapacity,
                "five wakes under an open contract circuit spent tokens")

        // The case that looks most like the hypothesis and still is not it:
        // the network circuit has aged into half-open, so `wouldAllowRequest()`
        // grants, while the contract circuit still refuses. The conjunction at
        // the policy is what saves the token — and, because the query is a
        // query, the half-open probe permit is not spent either (R57).
        let c3 = FakeClock()
        var e3 = engine(c3, [a, try sym("MSFT")])
        for _ in 0..<RateConstants.circuitFailureThreshold {
            e3.record(.serverError(status: 500), for: a)
        }
        e3.record(.missingField(path: "x"), for: a)
        c3.advance(RateConstants.circuitOpenSeconds + 1)
        #expect(e3.diagnosticSnapshot.networkCircuit == .halfOpen)
        for _ in 0..<6 {
            _ = e3.next(openMarket())
            c3.advance(60)
        }
        #expect(e3.diagnosticSnapshot.tokensAvailable == RateConstants.bucketCapacity,
                "a half-open network circuit and an open contract circuit spent tokens")
        #expect(e3.diagnosticSnapshot.networkCircuit == .halfOpen,
                "the probe permit was spent on a decision that never fetched")
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
    /// What one simulated day cost, and what the engine concluded about the
    /// watchlist while paying for it. `dead` is the part F2 turns on: a fault
    /// that implicates one symbol must leave exactly one symbol dead.
    private struct Drive {
        let fetches: Int
        let dead: Set<Symbol>
        /// Fetches that were not the misbehaving symbol — what the other
        /// nineteen actually got, which is the number the user sees.
        let healthyFetches: Int
    }

    /// `failing` names one symbol whose every fetch returns `error` instead of
    /// a quote; the rest succeed. `nil` is the control.
    private func driveFeedEngine(userInterval: Double, watchlistCount: Int,
                                 failing: Symbol? = nil,
                                 with error: TickerError = .noResult) throws -> Drive {
        let clock = FakeClock()
        let symbols = try (1...watchlistCount).map { try sym("SYM\($0)") }
        var e = engine(clock, symbols, interval: userInterval)

        var fetches = 0
        var healthy = 0
        var t: Double = 0
        while t < Day.length {
            let market = Day.state(atSecondOfDay: t)
            let context = EngineContext(
                nowEpoch: t, marketState: market, visibility: .visible, lowPowerMode: false,
                nextSessionOpenEpoch: Day.nextSessionOpen(afterSecondOfDay: t))

            switch e.next(context) {
            case .fetch(let s):
                fetches += 1
                if s == failing {
                    e.record(error, for: s)
                } else {
                    healthy += 1
                    e.recordSuccess(stubQuote(s), for: s)
                }
            case .sleep(let seconds):
                let step = max(1, seconds)
                t += step
                clock.advance(step)
            }
        }
        return Drive(fetches: fetches, dead: e.deadSymbols, healthyFetches: healthy)
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
    /// `DaySimulation` oracle is **`count` itself**, at every one of the
    /// twenty configurations. So that is the bound, rather than the flat 20
    /// that used to stand here.
    ///
    /// F7. The comment above already said "equals the watchlist count itself"
    /// and then asserted a constant: at `count: 1` the drift is 1 and the test
    /// tolerated 20, so twenty spurious requests a day passed a test whose own
    /// prose said the answer was one. A bound calibrated to the worst case is
    /// blind at the cheapest case, which is exactly where a proportional defect
    /// is smallest and easiest to ship.
    ///
    /// Re-measured after F1 changed the day model, drift by interval x count:
    ///
    ///        count:    1    2    4   10   20
    ///        60        1    2    4   10    0
    ///        180       1    2    4   10    0
    ///        300       1    2    4   10    0
    ///        900       1    2    4   10   15
    ///
    /// The three zeroes at count 20 are F1(a)'s budget floor doing its job:
    /// 60, 180 and 300 all clamp to the same 720-request day, so the engine
    /// and the oracle agree exactly. 900/20 is the only point with any slack
    /// (15 of a permitted 20), because there the interval and not the floor is
    /// what binds.
    ///
    /// The tightness earns its keep. Shortening the cycle deadline by one
    /// spacing interval — a plausible off-by-one — leaves **nine** of these
    /// twenty configurations under a flat 20, including 900/1 at drift 2 and
    /// 900/2 at drift 4. Against `count`, five of those nine fail.
    @Test func theCycleGateKeepsFeedEngineUnderBudgetAndInStepWithTheDaySimulation() throws {
        for interval in RateConstants.refreshIntervalChoices {
            for count in [1, 2, 4, 10, 20] {
                let actual = try driveFeedEngine(userInterval: interval, watchlistCount: count).fetches
                let predicted = DaySimulation.run(userInterval: interval,
                                                   watchlistCount: count).requests

                // The constant, not a literal 1_200: F1(a) moved this number
                // into `RateConstants` precisely so the figure the tests check
                // and the figure `RefreshPolicy.budgetFloor` obeys cannot drift
                // apart.
                let over = "interval \(interval) x \(count): \(actual) exceeds the "
                    + "\(RateConstants.dailyRequestBudget)/day budget"
                #expect(actual < RateConstants.dailyRequestBudget, "\(over)")

                // Not an exact match: `DaySimulation` paces individual
                // within-cycle fetches by an explicit per-symbol
                // `nextSymbolDue`, while `FeedEngine` paces them through the
                // shared token bucket's burst allowance, so a handful of
                // requests can land on either side of a session boundary.
                let drift = abs(actual - predicted)
                let message = "interval \(interval) x \(count): engine fetched \(actual); "
                    + "the cycleDeadline model predicts \(predicted) (drift \(drift))"
                #expect(drift <= count, "\(message)")
            }
        }
    }

    // MARK: - F2: a null result implicates one symbol, not the endpoint

    /// One symbol in twenty returns HTTP 200 with `chart.result: null` all day.
    ///
    /// That body used to classify as `.contractFault`, whose circuit has a
    /// threshold of **1** and a one-hour cooldown, so the first bad payload
    /// stopped every symbol for an hour, every hour, forever — and marked
    /// nothing dead, so nothing ever recovered. Measured across this exact
    /// day, twenty symbols at 180s:
    ///
    ///                       total   healthy   dead
    ///     control (all ok)    720       720      0
    ///     before              283       268      0
    ///     after               722       721      1
    ///
    /// The nineteen innocent symbols lost 63% of their refreshes to one
    /// stranger's payload. The same symbol returning 404 cost only itself,
    /// which is the asymmetry F2 removes: a 404 and a 200-with-null are one
    /// fact — *this symbol has no data* — reported two ways.
    ///
    /// The "after" total sits slightly *above* the control because the dead
    /// symbol leaves the live watchlist, and a nineteen-symbol cycle is
    /// shorter than a twenty-symbol one under both of `cycleInterval`'s
    /// floors. Nineteen symbols refreshing at a nineteen-symbol cadence is
    /// the correct outcome, not an overshoot.
    @Test func oneSymbolReturningANullResultDoesNotSilenceTheOtherNineteen() throws {
        let bad = try sym("SYM3")
        let count = 20

        for interval in RateConstants.refreshIntervalChoices {
            let control = try driveFeedEngine(userInterval: interval, watchlistCount: count)
            let hurt = try driveFeedEngine(userInterval: interval, watchlistCount: count,
                                           failing: bad, with: .noResult)

            // Only that symbol, and it by name. `dead.count == 1` alone would
            // pass if the engine killed the wrong one.
            #expect(hurt.dead == [bad],
                    "interval \(interval): dead set was \(hurt.dead.map(\.raw).sorted())")

            // The nineteen keep refreshing. The bound is the control less one
            // symbol's worth of a cycle, which is what losing the twentieth
            // symbol legitimately costs; a threshold-1 circuit lands hundreds
            // of requests below it.
            let floor = control.fetches - count
            let message = "interval \(interval): the healthy nineteen got "
                + "\(hurt.healthyFetches) fetches against a \(control.fetches) control"
            #expect(hurt.healthyFetches >= floor, "\(message)")
        }
    }

    /// The contrast that makes the case above mean something: a genuinely
    /// malformed *shape* must still stop everything. `.missingField` says the
    /// endpoint changed, every symbol will fail identically, and one is enough.
    /// Without this, moving `noResult` out of the contract group would be
    /// indistinguishable from disabling the contract circuit.
    @Test func aMalformedShapeStillStopsEverythingAfterOneResponse() throws {
        let bad = try sym("SYM3")
        let hurt = try driveFeedEngine(userInterval: 180, watchlistCount: 20, failing: bad,
                                       with: .missingField(path: "chart.result[0].meta"))
        #expect(hurt.dead.isEmpty, "a shape fault must not be blamed on one symbol")
        let control = try driveFeedEngine(userInterval: 180, watchlistCount: 20)
        #expect(hurt.fetches < control.fetches / 2,
                "the contract circuit did not stop the day: \(hurt.fetches) of \(control.fetches)")
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

    // MARK: - Refresh now

    @Test func refreshNowRetiresTheCycleDeadline() throws {
        let clock = FakeClock()
        let one = try sym("AAPL")
        var e = engine(clock, [one])
        // A fresh engine fetches twice before it is holding a deadline at all:
        // the first call runs with `cursor == 0` and never reaches the deadline
        // block, and the second is the one that sets it.
        _ = e.next(openMarket())
        _ = e.next(openMarket())
        clock.advance(60)

        let waiting = e.next(openMarket())
        let isWaiting: Bool
        if case .sleep = waiting { isWaiting = true } else { isWaiting = false }
        #expect(isWaiting, "a 180s cycle 60s in should still be waiting, got \(waiting)")

        e.requestImmediateCycle()
        #expect(e.next(openMarket()) == .fetch(one))
    }

    /// The user's report: "the refresh also doesn't seem to work. the refresh
    /// should force the refresh to immediate regardless of the refresh
    /// settings." Reported on a Saturday, which is the whole story: with the
    /// market closed, `RefreshPolicy.decide` returns `.wait` *before* `next()`
    /// ever reaches the cycle deadline that `requestImmediateCycle` clears, so
    /// the click cleared a variable nothing on that path reads and the app
    /// slept until Monday's open.
    @Test func refreshNowFetchesEvenWithTheMarketClosed() throws {
        let clock = FakeClock()
        let one = try sym("AAPL")
        var e = engine(clock, [one])
        let closed = EngineContext(nowEpoch: 1_757_000_000, marketState: .closed,
                                   visibility: .visible, lowPowerMode: false,
                                   nextSessionOpenEpoch: 1_757_000_000 + 172_800)

        let asleep = e.next(closed)
        let isWaiting: Bool
        if case .sleep = asleep { isWaiting = true } else { isWaiting = false }
        #expect(isWaiting, "a closed market should rest, got \(asleep)")

        e.requestImmediateCycle()
        #expect(e.next(closed) == .fetch(one))
    }

    /// The same rule for the other schedule gate. An occluded strip is a
    /// reason not to spend a request on its own, and not a reason to ignore a
    /// button the user just pressed — the dropdown they pressed it in is
    /// exactly what covers the strip.
    @Test func refreshNowFetchesEvenWhileOccluded() throws {
        let clock = FakeClock()
        let one = try sym("AAPL")
        var e = engine(clock, [one])
        let hidden = EngineContext(nowEpoch: 1_757_000_000, marketState: .regular,
                                   visibility: .occluded, lowPowerMode: false,
                                   nextSessionOpenEpoch: nil)

        let asleep = e.next(hidden)
        let isWaiting: Bool
        if case .sleep = asleep { isWaiting = true } else { isWaiting = false }
        #expect(isWaiting, "an occluded strip should rest, got \(asleep)")

        e.requestImmediateCycle()
        #expect(e.next(hidden) == .fetch(one))
    }

    /// One click, one pass over the whole watchlist — and then the ordinary
    /// schedule again. The request has to outlive the first symbol or a
    /// three-symbol watchlist would refresh only its first row; it has to die
    /// at the end of the pass or a single click would keep a closed market
    /// fetching forever.
    @Test func refreshNowCoversEverySymbolAndThenStops() throws {
        let clock = FakeClock()
        let watched = [try sym("AAPL"), try sym("MSFT"), try sym("^GSPC")]
        var e = engine(clock, watched)
        let closed = EngineContext(nowEpoch: 1_757_000_000, marketState: .closed,
                                   visibility: .visible, lowPowerMode: false,
                                   nextSessionOpenEpoch: 1_757_000_000 + 172_800)

        e.requestImmediateCycle()
        var fetched: [Symbol] = []
        for _ in watched {
            let action = e.next(closed)
            guard case .fetch(let symbol) = action else {
                Issue.record("the requested pass stopped early at \(action)")
                break
            }
            fetched.append(symbol)
            // The bucket refills a token every 30 seconds and is the last word
            // on *when*; this test is about the gates above it.
            clock.advance(RateConstants.spacingSeconds)
        }
        // As a set: the pass starts wherever the cursor is and wraps, so the
        // claim is that it covers every symbol, not that it begins at the top.
        #expect(Set(fetched) == Set(watched))
        #expect(fetched.count == watched.count)

        let after = e.next(closed)
        let isWaiting: Bool
        if case .sleep = after { isWaiting = true } else { isWaiting = false }
        #expect(isWaiting, "the closed market went back to sleep? got \(after)")
    }

    /// The user's second report, one message after the first: "also adding a
    /// symbol should retrieve its value immediately." The controller already
    /// asks for a cycle the moment the watchlist changes, so what was missing
    /// is *where* that cycle starts — appended last, a new symbol was fetched
    /// last, one 30-second token behind every symbol that already had a price.
    @Test func aNewlyAddedSymbolIsTheNextThingFetched() throws {
        let clock = FakeClock()
        let old = [try sym("AAPL"), try sym("MSFT")]
        var e = engine(clock, old)
        for symbol in old {
            _ = e.next(openMarket())
            e.recordSuccess(Quote(symbol: symbol, shortName: nil, price: 1,
                                  previousClose: nil, currency: "USD", asOfEpoch: nil),
                            for: symbol)
            clock.advance(RateConstants.spacingSeconds)
        }

        let added = try sym("^GSPC")
        e.replaceWatchlist(old + [added])
        e.requestImmediateCycle()
        #expect(e.next(openMarket()) == .fetch(added))
    }

    @Test func refreshNowCannotWalkPastACooldown() throws {
        // Spec §4.3 and §7 together: the item still takes a token, so it must
        // not become a way around a 429 by clicking it enough times.
        let clock = FakeClock()
        let one = try sym("AAPL")
        var e = engine(clock, [one])
        e.record(.rateLimited(retryAfterSeconds: nil), for: one)

        e.requestImmediateCycle()
        let action = e.next(openMarket())
        let isWaiting: Bool
        if case .sleep = action { isWaiting = true } else { isWaiting = false }
        #expect(isWaiting, "the cooldown let a fetch through: \(action)")
    }

    // MARK: - Dragging a row in the dropdown

    @Test func reorderingCarriesTheCursorWithItsSymbolRatherThanItsIndex() throws {
        // A drag rearranges the two menu-bar rows; it is not a statement about
        // which symbol is next. Leaving the raw index behind would silently
        // skip whichever symbol the drag pushed past the cursor — the user
        // would see one quote go stale for a whole cycle for no visible
        // reason.
        let clock = FakeClock()
        let a = try sym("AAPL")
        let b = try sym("MSFT")
        let c = try sym("NVDA")
        var e = engine(clock, [a, b, c])

        guard case .fetch(let first) = e.next(openMarket()) else {
            Issue.record("expected the first fetch to go out")
            return
        }
        #expect(first == a)
        e.recordSuccess(stubQuote(a), for: a)
        clock.advance(RateConstants.spacingSeconds)

        // The cursor is parked on MSFT. After the drag MSFT sits at index 0,
        // where the old index 1 now holds NVDA.
        e.reorderWatchlist([b, c, a])
        guard case .fetch(let second) = e.next(openMarket()) else {
            Issue.record("expected a fetch after the reorder")
            return
        }
        #expect(second == b, "the cursor followed its index instead of its symbol")
    }

    @Test func reorderingDoesNotReviveADeadSymbolTheWayReplacingDoes() throws {
        // `replaceWatchlist` clears `dead` because editing the watchlist is the
        // user saying "try again". Dragging a row says nothing of the kind, so
        // a symbol Yahoo has no such ticker for must stay out of the rotation.
        let clock = FakeClock()
        let gone = try sym("GONE")
        let kept = try sym("AAPL")
        var e = engine(clock, [gone, kept])
        e.record(.symbolNotFound(gone), for: gone)
        let wasDead = e.deadSymbols.contains(gone)
        #expect(wasDead)

        e.reorderWatchlist([kept, gone])
        let stillDead = e.deadSymbols.contains(gone)
        #expect(stillDead, "a drag cleared the dead set and put a 404 back in the rotation")
    }

    @Test func reorderingDoesNotOverrideTheCycleGateTheWayAnEditDoes() throws {
        // Zeroing `cycleDeadline` is `replaceWatchlist`'s way of letting a
        // newly added symbol be fetched at once. A drag adds nothing, so it
        // must not buy a free pass round the cadence the user configured.
        let clock = FakeClock()
        let a = try sym("AAPL")
        let b = try sym("MSFT")
        var e = engine(clock, [a, b], interval: 900)

        // Four fetches, not two: `cycleDeadline` starts at zero, so it is the
        // *second* pass that is gated by it — the first wrap is what arms it.
        for _ in 0..<4 {
            guard case .fetch(let s) = e.next(openMarket()) else {
                Issue.record("expected the first two passes to complete")
                return
            }
            e.recordSuccess(stubQuote(s), for: s)
            clock.advance(RateConstants.spacingSeconds)
        }

        e.reorderWatchlist([b, a])
        let action = e.next(openMarket())
        let isWaiting: Bool
        if case .sleep = action { isWaiting = true } else { isWaiting = false }
        #expect(isWaiting, "the drag started a new cycle early: \(action)")
    }

    @Test func aReorderThatIsNotAPermutationIsIgnoredEntirely() throws {
        // The guard exists because the caller is a view: a dropped row that
        // gained or lost a symbol would otherwise let the watchlist the engine
        // fetches drift away from the watchlist the store holds.
        let clock = FakeClock()
        let a = try sym("AAPL")
        let b = try sym("MSFT")
        var e = engine(clock, [a, b])

        e.reorderWatchlist([b])
        e.reorderWatchlist([b, a, try sym("NVDA")])
        e.reorderWatchlist([b, b])

        guard case .fetch(let first) = e.next(openMarket()) else {
            Issue.record("expected a fetch")
            return
        }
        #expect(first == a, "a malformed reorder was applied anyway")
    }
}
