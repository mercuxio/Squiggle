import Testing
@testable import TickerCore

/// Seconds since the start of an exchange-local day. The absolute date does
/// not matter; only the durations of each session do.
private enum Day {
    static let preOpen: Double = 4 * 3600            // 04:00
    static let regularOpen: Double = 9.5 * 3600      // 09:30
    static let regularClose: Double = 16 * 3600      // 16:00
    static let postClose: Double = 20 * 3600         // 20:00
    static let length: Double = 24 * 3600

    static func state(atSecondOfDay t: Double) -> MarketState {
        switch t {
        case preOpen..<regularOpen: return .pre
        case regularOpen..<regularClose: return .regular
        case regularClose..<postClose: return .post
        default: return .closed
        }
    }

    /// The next *session* open — pre included — as a second-of-day offset
    /// that may exceed a day. Mirrors
    /// `TradingPeriod.nextSessionOpenEpoch(after:)`: overnight the wake
    /// belongs at 04:00, not at 09:30, or the simulated Mac sleeps through
    /// pre-market exactly as the real one did.
    static func nextSessionOpen(afterSecondOfDay t: Double) -> Double {
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
private struct DaySimulation {
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
                    marketOverride: MarketState? = nil,
                    honourPacer: Bool = true) -> DaySimulation {
        var sim = DaySimulation()
        let clock = FakeClock()
        var pacer = RequestPacer(clock: clock)

        var pendingSymbols = 0
        var nextSymbolDue: Double = 0
        var cycleDeadline: Double = 0

        var t: Double = 0
        while t < Day.length {
            let market = marketOverride ?? Day.state(atSecondOfDay: t)

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
                    nextSessionOpenEpoch: Day.nextSessionOpen(afterSecondOfDay: t),
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

/// Spec §4.2: the whole configuration space must fit under this.
private let dailyBudget = 1_200

@Test func theDailyBudgetHoldsAcrossEveryReachableConfiguration() {
    var worst = (interval: 0.0, count: 0, requests: 0)

    for interval in RateConstants.refreshIntervalChoices {
        for count in [1, 2, 4, 10, 20] {
            let sim = DaySimulation.run(userInterval: interval, watchlistCount: count)
            #expect(sim.requests <= dailyBudget,
                    "interval \(interval)s x \(count) symbols -> \(sim.requests) requests")
            if sim.requests > worst.requests {
                worst = (interval, count, sim.requests)
            }
        }
    }

    // Fail loudly if the sweep silently stopped exercising anything. The
    // floor is 1,000 rather than a token 400 because it now has a second job:
    // the shipped defect this file exposed — waking at the regular open and
    // sleeping through pre-market — measured 938 here, and a sanity floor
    // that a known regression walks under is not a sanity floor.
    let notRunning = "the worst case was only \(worst.requests) requests; the simulation is "
        + "not running, or extended hours have stopped being polled"
    #expect(worst.requests > 1_000, "\(notRunning)")
}

@Test func theSpacingFloorMakesCostFlatInWatchlistSize() {
    // Once the 30s floor binds, cost stops tracking watchlist size — a
    // 20-symbol list and a 2-symbol list run at the same underlying rate,
    // and differ only in how much each loses at session boundaries. That
    // flatness is what the daily budget rests on, so it is what gets pinned.
    // If some future change makes cost climb with watchlist size again, the
    // floor has stopped doing its job and this fails before the budget does.
    // count x 30s >= 60s. At two symbols the floor exactly meets the 60s
    // interval rather than overriding it; above two it is the floor that sets
    // the cadence. Either way the interval has stopped being what decides.
    let flooredCounts = [2, 4, 10, 20]
    let counts = flooredCounts.map { DaySimulation.run(userInterval: 60, watchlistCount: $0).requests }
    let lo = counts.min()!, hi = counts.max()!
    // Measured spread is 4 (1156 at two and four symbols, 1160 at ten and
    // twenty — the difference is boundary loss, not rate). 10 leaves room for
    // a boundary to shift without leaving room for cost to track size again.
    #expect(hi - lo <= 10, "spread across watchlist sizes was \(lo)...\(hi)")

    // One symbol is the exception and must stay it: below the floor the
    // user's 60s interval is what binds, so one request per 60s against the
    // floored one per 30s — exactly half, by construction rather than by
    // measurement, so it is pinned exactly.
    let single = DaySimulation.run(userInterval: 60, watchlistCount: 1).requests
    #expect(single * 2 <= lo, "one symbol cost \(single) against a floored \(lo)")
}

@Test func theDayCostsWhatTheSessionStructurePredicts() {
    // Derived, not observed: regular hours at one request per spacing
    // interval, extended hours at a third of that, nothing overnight. A
    // ceiling taken from the whole 24 hours instead would be 2885 — looser
    // than the budget assertion above, and so unable to fail.
    let quietSpacing = RateConstants.spacingSeconds * RateConstants.quietMultiplier
    let ceiling = Int((Day.regularClose - Day.regularOpen) / RateConstants.spacingSeconds)
        + Int((Day.regularOpen - Day.preOpen) / quietSpacing)
        + Int((Day.postClose - Day.regularClose) / quietSpacing)
        + Int(RateConstants.bucketCapacity)

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
    // read far tighter than it was. Now every term is reachable and the gap is
    // 5 requests — the bucket's opening burst, spent once at 04:00.
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
    let sim = DaySimulation.run(userInterval: 60, watchlistCount: 20, marketOverride: .closed)
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

    // And the saving must be the regular session's, not something smaller
    // that happens to be under the ceiling: two thirds of regular hours.
    let expectedSaving = regular - Int(Double(regular) / RateConstants.quietMultiplier)
    #expect(normal.requests - saving.requests >= expectedSaving - 10,
            "low power saved only \(normal.requests - saving.requests) of an expected \(expectedSaving)")
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

    // Twice over, so this fails on a halved refill rate rather than only at
    // the moment supply and demand exactly collide.
    #expect(worstDemand * 2 <= supply,
            "the worst day asks \(worstDemand); the pacer supplies \(supply) in the same day")

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
