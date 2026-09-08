import Testing
@testable import TickerCore

/// Seconds since the start of an exchange-local day. The absolute date does
/// not matter; only the durations of each session do.
///
/// Internal rather than file-private: `FeedEngineTests` reuses this same
/// session schedule to drive the real `FeedEngine` across a simulated day, so
/// its budget assertion checks the engine against the identical market
/// calendar this file's own sweep uses — not a second, hand-rolled one that
/// could quietly drift from it.
enum Day {
    static let preOpen: Double = 4 * 3600            // 04:00
    static let regularOpen: Double = 9.5 * 3600      // 09:30
    static let regularClose: Double = 16 * 3600      // 16:00
    static let postClose: Double = 20 * 3600         // 20:00
    static let length: Double = 24 * 3600

    /// Which trading calendar the simulated instrument keeps.
    ///
    /// `.equity` is the US listing schedule above. `.continuous` is the one a
    /// budget claim actually has to survive: through the real decoder,
    /// `Tests/Fixtures/`' `crypto.json` and `currency-pair.json` report
    /// `.regular` for 1,439 of a day's 1,440 minutes, so `BTC-USD` or
    /// `EURUSD=X` in a watchlist is a market that never shuts. Both symbols
    /// are on this project's own list of spellings that must round-trip
    /// verbatim, so this calendar is reachable without hand-editing anything.
    /// Modelling only `.equity` was what let the 1,200/day figure stand as an
    /// arithmetic consequence of an eight-hour overnight close rather than as
    /// an enforced property.
    ///
    /// `.closed` is a weekend or a holiday: shut for the whole 24 hours.
    enum Calendar {
        case equity
        case continuous
        case closed
    }

    static func state(atSecondOfDay t: Double, calendar: Calendar = .equity) -> MarketState {
        switch calendar {
        case .continuous: return .regular
        case .closed: return .closed
        case .equity:
            switch t {
            case preOpen..<regularOpen: return .pre
            case regularOpen..<regularClose: return .regular
            case regularClose..<postClose: return .post
            default: return .closed
            }
        }
    }

    /// The next *session* open — pre included — as a second-of-day offset
    /// that may exceed a day. Mirrors
    /// `TradingPeriod.nextSessionOpenEpoch(after:)`: overnight the wake
    /// belongs at 04:00, not at 09:30, or the simulated Mac sleeps through
    /// pre-market exactly as the real one did.
    ///
    /// A `.continuous` instrument is open now, so the next open is now: there
    /// is no closed branch for it to reach.
    static func nextSessionOpen(afterSecondOfDay t: Double,
                                calendar: Calendar = .equity) -> Double {
        if calendar == .continuous { return t }
        if t < preOpen { return preOpen }
        if t < regularOpen { return regularOpen }
        return preOpen + length
    }
}

/// A one-second-tick simulation of Squiggle's actual fetch loop.
///
/// The loop it models is the one `TickerRunner` will implement in plan 2: ask
/// the policy whether to start a cycle, then walk the watchlist one symbol at
/// a time, each request passing through the pacer. Nothing here is
/// hypothetical — if this simulation and the runner ever disagree, the runner
/// is the bug.
///
/// One exception, and it is not a model of anything: `honourPacer: false`
/// bypasses the bucket so a measurement can isolate what the policy alone
/// asks for. No production path has that switch. A simulation run that way is
/// answering a question about the policy, not predicting what Squiggle does.
///
/// Internal rather than file-private: `FeedEngineTests` compares the real
/// `FeedEngine`'s fetch count against this model's prediction for the same
/// configuration, per this file's own doc comment above — "if this
/// simulation and the runner ever disagree, the runner is the bug."
struct DaySimulation {
    var requests = 0
    var cyclesStarted = 0
    /// Increments once per second of refusal, per symbol — not once per
    /// cycle. The brief called this `cyclesRefusedByPacer`; that name claims
    /// a per-cycle count it does not keep, so it is `pacerRefusals` here.
    var pacerRefusals = 0

    /// `honourPacer: false` is a measurement mode, not a model of anything:
    /// it isolates how much the *policy alone* asks for, so that a claim about
    /// the pacer having headroom over the policy is not measuring the pacer on
    /// both sides of its own comparison. Nothing in production has this switch;
    /// the bucket has no bypass.
    static func run(userInterval: Double,
                    watchlistCount: Int,
                    visibility: Visibility = .visible,
                    lowPowerMode: Bool = false,
                    calendar: Day.Calendar = .equity,
                    honourPacer: Bool = true) -> DaySimulation {
        var sim = DaySimulation()
        let clock = FakeClock()
        var pacer = RequestPacer(clock: clock)

        var pendingSymbols = 0
        var nextSymbolDue: Double = 0
        var cycleDeadline: Double = 0

        var t: Double = 0
        while t < Day.length {
            let market = Day.state(atSecondOfDay: t, calendar: calendar)

            if pendingSymbols > 0 {
                if t >= nextSymbolDue {
                    let granted = pacer.take()
                    if granted || !honourPacer {
                        sim.requests += 1
                        pendingSymbols -= 1
                        nextSymbolDue = t + RateConstants.spacingSeconds
                    } else {
                        // The bucket is the final authority. A cycle that
                        // cannot get tokens simply takes longer.
                        sim.pacerRefusals += 1
                        nextSymbolDue = t + 1
                    }
                }
            } else if t >= cycleDeadline {
                let input = RefreshInput(
                    nowMonotonic: t,
                    nowEpoch: t,
                    marketState: market,
                    visibility: visibility,
                    lowPowerMode: lowPowerMode,
                    userIntervalSeconds: userInterval,
                    watchlistCount: watchlistCount,
                    nextSessionOpenEpoch: Day.nextSessionOpen(afterSecondOfDay: t,
                                                              calendar: calendar),
                    isCoolingDown: false,
                    cooldownRemaining: 0,
                    circuitAllows: true,
                    circuitOpenRemaining: 0)

                switch RefreshPolicy.decide(input) {
                case .fetch:
                    sim.cyclesStarted += 1
                    pendingSymbols = watchlistCount
                    nextSymbolDue = t
                    cycleDeadline = t + RefreshPolicy.cycleInterval(
                        userIntervalSeconds: userInterval,
                        watchlistCount: watchlistCount,
                        marketState: market,
                        lowPowerMode: lowPowerMode)
                case .wait(let seconds):
                    // Never advance by zero; that is an infinite loop, and a
                    // test that hangs teaches nothing.
                    cycleDeadline = t + max(1, seconds)
                }
            }

            t += 1
            clock.advance(1)
        }
        return sim
    }
}

/// Spec §4.2: the whole configuration space must fit under this. Read from
/// `RateConstants` rather than written down here, because the policy and the
/// pacer now enforce this same number — a second copy would be free to drift
/// from the one the code obeys.
private let dailyBudget = RateConstants.dailyRequestBudget

@Test func theDailyBudgetHoldsAcrossEveryReachableConfiguration() {
    // Both calendars, because the budget is a claim about the app and not
    // about the US equity session table. `.continuous` is the one that has
    // teeth: with the market never shut, nothing but the policy and the pacer
    // stand between the watchlist and 2,880 requests a day.
    var worst: [Day.Calendar: (interval: Double, count: Int, requests: Int)] = [:]

    for calendar in [Day.Calendar.equity, .continuous] {
        for interval in RateConstants.refreshIntervalChoices {
            for count in [1, 2, 4, 10, 20] {
                let sim = DaySimulation.run(userInterval: interval, watchlistCount: count,
                                            calendar: calendar)
                let overspend = "\(calendar), interval \(interval)s x \(count) symbols -> "
                    + "\(sim.requests) requests"
                #expect(sim.requests <= dailyBudget, "\(overspend)")
                if sim.requests > (worst[calendar]?.requests ?? 0) {
                    worst[calendar] = (interval, count, sim.requests)
                }
            }
        }
    }

    // Fail loudly if either arm of the sweep silently stopped exercising
    // anything. The floors are per-calendar because the two spend very
    // different amounts: an equity day is shut for eight hours and quiet for
    // another nine and a half, so a floor set from the continuous day's
    // spending would be one the equity day walks under while working
    // perfectly.
    //
    // Re-measured at this commit, across the whole grid: the worst equity day
    // is 720 requests (60s, 180s and 300s all tie there at 20 symbols) and the
    // worst continuous day is 1,200 — the budget exactly, reached at eleven of
    // the twenty continuous configurations. That the eleven agree to the
    // request is the budget floor being the binding term rather than the
    // interval: once `budgetFloor` dominates, cost stops depending on what the
    // user chose and lands on the budget itself.
    //
    // (These numbers replace a "505 / 1,180" that this comment recorded a few
    // commits ago and that the sweep had since stopped producing. A comment
    // holding a measurement is worth having only if it is re-taken when the
    // model under it moves; F7 is the same lesson one file over.)
    //
    // The floors sit below those by roughly a session's worth of cycles, which
    // is enough room for a boundary to shift and not enough for a whole
    // session to stop being polled.
    let equity = worst[.equity]?.requests ?? 0
    let continuous = worst[.continuous]?.requests ?? 0
    let equityIdle = "the worst equity day was only \(equity) requests; the simulation is "
        + "not running, or extended hours have stopped being polled"
    let continuousIdle = "the worst continuous day was only \(continuous) requests; a market "
        + "that never closes should be spending close to the whole budget"
    #expect(equity > 400, "\(equityIdle)")
    #expect(continuous > 900, "\(continuousIdle)")
}

@Test func theFloorsMakeCostFlatInWatchlistSize() {
    // Once a floor binds, cost stops tracking watchlist size — a 20-symbol list
    // and a 2-symbol list run at the same underlying rate, and differ only in
    // how much each loses at session boundaries. Both floors scale linearly in
    // the count, so the per-day cost `count / (k x count)` does not contain the
    // count at all. That flatness is what the daily budget rests on, so it is
    // what gets pinned. If some future change makes cost climb with watchlist
    // size again, a floor has stopped doing its job and this fails before the
    // budget does.
    let flooredCounts = [2, 4, 10, 20]
    let counts = flooredCounts.map { DaySimulation.run(userInterval: 60, watchlistCount: $0).requests }
    let lo = counts.min()!, hi = counts.max()!
    // Measured spread is 16 (704 at two and four symbols, 710 at ten, 720 at
    // twenty — boundary loss, not rate). 20 leaves room for a boundary to shift
    // without leaving room for cost to track size again; a cost that tracked
    // size would put twenty symbols ten times above two.
    #expect(hi - lo <= 20, "spread across watchlist sizes was \(lo)...\(hi)")

    // One symbol is the exception, and the *shape* of the exception is the
    // interesting part. It used to be the whole day: with only the 30s floor,
    // one symbol at a 60s setting ran on its interval everywhere and cost
    // exactly half of a floored day. The budget floor is 72s a symbol, above
    // the 60s interval, so the regular session is now floored at one symbol
    // just as it is at twenty and costs the same there.
    //
    // What is left is the quiet sessions: `3 x max(60, 30 x 1)` is 180s, which
    // clears the 72s budget floor, so pre- and post-market alone still run on
    // the user's interval at one symbol. The whole shortfall is therefore one
    // symbol's worth of one quiet day, derived here rather than measured.
    let single = DaySimulation.run(userInterval: 60, watchlistCount: 1).requests
    let quietSeconds = (Day.regularOpen - Day.preOpen) + (Day.postClose - Day.regularClose)
    let quietCycle = 60 * RateConstants.quietMultiplier
    let oneSymbolQuiet = Int(quietSeconds / quietCycle)
    let shortfall = "one symbol cost \(single) against a floored \(lo); the gap is "
        + "\(lo - single) where one quiet day for one symbol is \(oneSymbolQuiet)"
    #expect(lo - single == oneSymbolQuiet, "\(shortfall)")
}

@Test func theDayCostsWhatTheSessionStructurePredicts() {
    // Derived, not observed: regular hours at one request per spacing
    // interval, extended hours at a third of that, nothing overnight. A
    // ceiling taken from the whole 24 hours instead would be 2885 — looser
    // than the budget assertion above, and so unable to fail.
    // Derived from the two per-symbol floors, not from `spacingSeconds` alone.
    // The old derivation used the 30s spacing floor by itself and produced
    // 1,165 — which the sweep, once the budget floor landed, could no longer
    // come within 445 requests of. A ceiling the measurement cannot approach is
    // the same decoration as one it cannot fail, so the tighter floor is the
    // one that has to appear here.
    let budgetPerSymbol = RateConstants.secondsPerDay / Double(RateConstants.dailyRequestBudget)
    let perSymbol = max(RateConstants.spacingSeconds, budgetPerSymbol)
    let quietPerSymbol = max(RateConstants.spacingSeconds * RateConstants.quietMultiplier,
                             budgetPerSymbol)

    // Taken over the counts swept below rather than at any single one: the
    // per-session `ceil` is what a continuous timeline spends crossing a
    // session boundary, and how much that is depends on the count. Twenty
    // symbols is the worst of them, at 725.
    func sessionCeiling(_ count: Int) -> Int {
        func term(_ seconds: Double, _ floorPerSymbol: Double) -> Int {
            Int((seconds / (floorPerSymbol * Double(count))).rounded(.up)) * count
        }
        return term(Day.regularClose - Day.regularOpen, perSymbol)
            + term(Day.regularOpen - Day.preOpen, quietPerSymbol)
            + term(Day.postClose - Day.regularClose, quietPerSymbol)
            + Int(RateConstants.bucketCapacity)
    }
    let ceiling = [1, 2, 4, 10, 20].map(sessionCeiling).max()!

    var worst = 0
    for interval in RateConstants.refreshIntervalChoices {
        for count in [1, 2, 4, 10, 20] {
            let sim = DaySimulation.run(userInterval: interval, watchlistCount: count)
            #expect(sim.requests <= ceiling,
                    "interval \(interval) x \(count) -> \(sim.requests) against \(ceiling)")
            worst = max(worst, sim.requests)
        }
    }
    // The ceiling must stay tighter than the budget or it is decoration.
    #expect(ceiling < dailyBudget, "ceiling \(ceiling) is looser than the budget")

    // And it must stay tight against what the sweep actually spends, or it is
    // decoration in the other direction. Until the pre-market wake was fixed
    // the 220-request pre term was money the harness could not spend: the
    // honest bound on what it ran was ~945 against a measured 938, so 1165
    // read far tighter than it was. Every term is reachable now and the gap is
    // 5 requests — the bucket's opening burst, spent once at 04:00 — with the
    // ceiling at 725 and the sweep's worst day at 720.
    let unreachable = "the ceiling is \(ceiling) but the sweep only spends \(worst); "
        + "a term in it has become unreachable"
    #expect(ceiling - worst <= 10, "\(unreachable)")
}

@Test func anOccludedDayCostsAlmostNothing() {
    // Spec §5.4: the single largest saving Squiggle makes. A user whose
    // Squiggle lives permanently behind the notch should not be paying for it.
    let sim = DaySimulation.run(userInterval: 60, watchlistCount: 20, visibility: .occluded)
    #expect(sim.requests == 0)
}

@Test func aWeekendCostsAlmostNothing() {
    let sim = DaySimulation.run(userInterval: 60, watchlistCount: 20, calendar: .closed)
    #expect(sim.requests == 0)
}

@Test func lowPowerModeStretchesRegularHoursAndLeavesTheQuietOnesAlone() {
    // The old name and its `<= normal / 2` claimed a whole-day saving of the
    // quiet multiplier, which was never what the policy does and is now
    // visibly false: extended hours are *already* stretched by
    // `quietMultiplier`, and `cycleInterval` deliberately does not compound
    // the two. So Low Power Mode buys nothing at all before 09:30 or after
    // 16:00, and the day-level saving is bounded by the regular session alone.
    // Derived here rather than measured-and-pinned, in the same shape as the
    // ceiling above.
    let quietSpacing = RateConstants.spacingSeconds * RateConstants.quietMultiplier
    let extended = Int((Day.regularOpen - Day.preOpen) / quietSpacing)
        + Int((Day.postClose - Day.regularClose) / quietSpacing)
    let regular = Int((Day.regularClose - Day.regularOpen) / RateConstants.spacingSeconds)
    let lowPowerCeiling = extended
        + Int(Double(regular) / RateConstants.quietMultiplier)
        + Int(RateConstants.bucketCapacity)

    let normal = DaySimulation.run(userInterval: 180, watchlistCount: 10)
    let saving = DaySimulation.run(userInterval: 180, watchlistCount: 10, lowPowerMode: true)

    #expect(saving.requests < normal.requests)
    #expect(saving.requests <= lowPowerCeiling,
            "low power cost \(saving.requests) against a derived ceiling of \(lowPowerCeiling)")

    // And the saving must be the regular session's, not something smaller that
    // happens to be under the ceiling. It is no longer two thirds of regular
    // hours, and the reason is worth writing down: at ten symbols the budget
    // floor already holds the regular cycle at 720s, while Low Power stretches
    // `max(180, 10 x 30) = 300` to 900s. The cycle goes 720 -> 900, not 300 ->
    // 900, so the saving is a fifth of regular hours rather than two thirds —
    // 65 requests against the 520 this test used to expect. The floor took most
    // of that saving already and is not going to pay it twice.
    //
    // Derived from the two cycles the policy actually returns, and bounded on
    // both sides: a one-sided `>=` here would be satisfied by a Low Power mode
    // that stopped fetching altogether.
    let regularCycle = RefreshPolicy.cycleInterval(userIntervalSeconds: 180, watchlistCount: 10,
                                                   marketState: .regular, lowPowerMode: false)
    let savingCycle = RefreshPolicy.cycleInterval(userIntervalSeconds: 180, watchlistCount: 10,
                                                  marketState: .regular, lowPowerMode: true)
    let regularSpan = Day.regularClose - Day.regularOpen
    let expectedSaving = Int(regularSpan / regularCycle * 10) - Int(regularSpan / savingCycle * 10)
    let saved = normal.requests - saving.requests
    #expect(saved >= expectedSaving - 10,
            "low power saved only \(saved) of an expected \(expectedSaving)")
    #expect(saved <= expectedSaving + 10,
            "low power saved \(saved), well past the \(expectedSaving) the regular session holds")
}

@Test func aClosedMarketProducesNoBusyLoop() {
    // Asserted against the policy's own decision, not against the simulation.
    // The version this replaces ran a closed day and checked
    // `cyclesStarted == 0`, which could not observe the busy loop it was named
    // for: the simulator's own `max(1, seconds)` clamp neutralises a
    // `.wait(seconds: 0)` before any assertion here could see it, and a closed
    // day starting no cycles is already implied by `aWeekendCostsAlmostNothing`
    // spending no requests.
    //
    // So sweep the closed-market inputs that are actually reachable and
    // require every wait the policy hands back to be one the caller cannot
    // spin on. The `open` offsets are the whole shape of the branch: unknown,
    // stale, exactly now, exactly at the wake lead, a hair past it, and far
    // enough out to hit the half-day cap.
    let now: Double = 1_757_000_000
    let opens: [Double?] = [
        nil,
        now - 86_400,
        now,
        now + RateConstants.preOpenWakeLead,
        now + RateConstants.preOpenWakeLead + 0.001,
        now + RateConstants.preOpenWakeLead + 1,
        now + 3600,
        now + 30 * 86_400,
    ]

    var checked = 0
    for interval in RateConstants.refreshIntervalChoices {
        for count in [0, 1, 4, RateConstants.maxWatchlistCount] {
            for lowPower in [false, true] {
                for visibility in [Visibility.visible, .occluded] {
                    for open in opens {
                        let decision = RefreshPolicy.decide(RefreshInput(
                            nowMonotonic: 0,
                            nowEpoch: now,
                            marketState: .closed,
                            visibility: visibility,
                            lowPowerMode: lowPower,
                            userIntervalSeconds: interval,
                            watchlistCount: count,
                            nextSessionOpenEpoch: open,
                            isCoolingDown: false,
                            cooldownRemaining: 0,
                            circuitAllows: true,
                            circuitOpenRemaining: 0))
                        checked += 1

                        let label = "interval \(interval), count \(count), lowPower \(lowPower), "
                            + "\(visibility), open \(String(describing: open))"
                        let wait = decision.waitSeconds
                        #expect(wait != nil, "\(label) fetched with the market shut")
                        if let wait {
                            #expect(wait >= RateConstants.minimumWaitSeconds,
                                    "\(label) → a \(wait)s wait is a busy loop")
                            #expect(wait.isFinite, "\(label) → a \(wait)s wait never fires")
                        }
                    }
                }
            }
        }
    }
    #expect(checked > 100, "the sweep only checked \(checked) inputs")
}

@Test func thePacerIsNeverTheThingHoldingBackANormalDay() {
    // If the pacer is refusing requests during ordinary operation, the policy
    // is asking for more than the design allows and the two have drifted apart.
    let sim = DaySimulation.run(userInterval: 180, watchlistCount: 4)
    #expect(sim.pacerRefusals == 0,
            "the pacer refused \(sim.pacerRefusals) times on a default day")

    // On its own that pins almost nothing about the pacer. The simulator
    // spaces its own requests at exactly `spacingSeconds`, which is also the
    // bucket's refill period, so the count above stays zero however small the
    // bucket is — it fails when the *spacing* constant moves, which is the
    // simulator's number, not the pacer's. What the claim actually needs is
    // headroom, and both sides of it are measured rather than asserted: the
    // heaviest day the policy can ask for, against what a bucket ticking
    // through the same day actually grants.
    //
    // Demand is measured with the pacer bypassed, and that detail is the
    // whole test. Measured through the pacer, a cut bucket lowers demand and
    // supply together and the comparison survives its own mutation — which is
    // exactly what the first version of this repair did.
    var worstDemand = 0
    for interval in RateConstants.refreshIntervalChoices {
        for count in [1, 2, 4, 10, 20] {
            let sim = DaySimulation.run(userInterval: interval, watchlistCount: count,
                                        honourPacer: false)
            worstDemand = max(worstDemand, sim.requests)
        }
    }

    let clock = FakeClock()
    var pacer = RequestPacer(clock: clock)
    var supply = 0
    for _ in 0..<Int(Day.length) {
        let granted = pacer.take()
        if granted { supply += 1 }
        clock.advance(1)
    }

    // Not "twice over" any more, and the reason is the point of the daily
    // bucket. That bucket refills at exactly the budget, and the policy's own
    // budget floor targets exactly the budget, so demanding 2x headroom would
    // be demanding that the policy spend at most half the allowance it is
    // designed to spend. On a market that never closes the two meet almost
    // exactly: 1,200 asked against 1,220 supplied. The margin visible here is
    // the US equity calendar's overnight, and it is a property of the calendar
    // rather than of the pacer, so it is not what gets asserted.
    #expect(worstDemand <= supply,
            "the worst day asks \(worstDemand); the pacer supplies \(supply) in the same day")

    // The claim the headroom comparison used to stand in for, measured
    // directly: across both calendars and every configuration, the pacer
    // refuses nothing. This assertion had no teeth when the bucket refilled
    // every 30 seconds — the simulator spaces its own requests at exactly
    // `spacingSeconds`, so it could not outrun that bucket however small it
    // was. The daily bucket refills every 72 seconds, on a period the simulator
    // knows nothing about, so a mis-sized one shows up here immediately:
    // building it with `bucketCapacity` (5) instead of one full watchlist pass
    // measured 4,277 refusals at ten symbols and 30,660 at twenty on a
    // continuous day, and turned a cold launch into a 24-minute dribble.
    for calendar in [Day.Calendar.equity, .continuous] {
        for interval in RateConstants.refreshIntervalChoices {
            for count in [1, 2, 4, 10, 20] {
                let swept = DaySimulation.run(userInterval: interval, watchlistCount: count,
                                              calendar: calendar)
                #expect(swept.pacerRefusals == 0,
                        "\(calendar) \(interval)s x \(count) -> \(swept.pacerRefusals) refusals")
            }
        }
    }

    // A day-long count cannot see the burst allowance: over 24 hours the
    // capacity contributes its own size and nothing more, and cutting
    // `bucketCapacity` scales `effectiveSpacingSeconds` by the same factor, so
    // the sustained rate does not move at all. The burst needs its own
    // assertion, and its number comes from what the burst is *for* rather than
    // from the constant it would otherwise be checking against itself: a
    // launch, an unocclusion and a manual refresh, arriving together, must not
    // queue behind three separate 30-second waits.
    var fresh = RequestPacer(clock: FakeClock())
    var burst = 0
    for _ in 0..<10 {
        let granted = fresh.take()
        if !granted { break }
        burst += 1
    }
    let starved = "a cold bucket granted \(burst) back-to-back requests; a launch, an "
        + "unocclusion and a manual refresh cannot all be served"
    #expect(burst >= 3, "\(starved)")
}
