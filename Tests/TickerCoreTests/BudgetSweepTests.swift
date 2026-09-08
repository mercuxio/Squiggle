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

    /// The next 09:30, as a second-of-day offset that may exceed a day.
    static func nextRegularOpen(afterSecondOfDay t: Double) -> Double {
        t < regularOpen ? regularOpen : regularOpen + length
    }
}

/// A one-second-tick simulation of Squiggle's actual fetch loop.
///
/// The loop it models is the one `TickerRunner` will implement in plan 2: ask
/// the policy whether to start a cycle, then walk the watchlist one symbol at
/// a time, each request passing through the pacer. Nothing here is
/// hypothetical — if this simulation and the runner ever disagree, the runner
/// is the bug.
private struct DaySimulation {
    var requests = 0
    var cyclesStarted = 0
    /// Increments once per second of refusal, per symbol — not once per
    /// cycle. The brief called this `cyclesRefusedByPacer`; that name claims
    /// a per-cycle count it does not keep, so it is `pacerRefusals` here.
    var pacerRefusals = 0

    static func run(userInterval: Double,
                    watchlistCount: Int,
                    visibility: Visibility = .visible,
                    lowPowerMode: Bool = false,
                    marketOverride: MarketState? = nil) -> DaySimulation {
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
                    if pacer.take() {
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
                    nextRegularOpenEpoch: Day.nextRegularOpen(afterSecondOfDay: t),
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

    // Fail loudly if the sweep silently stopped exercising anything.
    #expect(worst.requests > 400,
            "the worst case was only \(worst.requests) requests; the simulation is not running")
}

@Test func theSpacingFloorMakesCostFlatInWatchlistSize() {
    // Once the 30s floor binds, cost stops tracking watchlist size — a
    // 20-symbol list and a 2-symbol list run at the same underlying rate,
    // and differ only in how much each loses at session boundaries. That
    // flatness is what the daily budget rests on, so it is what gets pinned.
    // If some future change makes cost climb with watchlist size again, the
    // floor has stopped doing its job and this fails before the budget does.
    let flooredCounts = [2, 4, 10, 20]   // count x 30s >= 60s, so the floor binds
    let counts = flooredCounts.map { DaySimulation.run(userInterval: 60, watchlistCount: $0).requests }
    let lo = counts.min()!, hi = counts.max()!
    #expect(hi - lo <= 25, "spread across watchlist sizes was \(lo)...\(hi)")

    // One symbol is the exception and must stay it: below the floor the
    // user's 60s interval is what binds, so it costs half as much.
    let single = DaySimulation.run(userInterval: 60, watchlistCount: 1).requests
    #expect(single < lo / 2 + 25, "one symbol cost \(single) against a floored \(lo)")
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

    for interval in RateConstants.refreshIntervalChoices {
        for count in [1, 2, 4, 10, 20] {
            let sim = DaySimulation.run(userInterval: interval, watchlistCount: count)
            #expect(sim.requests <= ceiling,
                    "interval \(interval) x \(count) -> \(sim.requests) against \(ceiling)")
        }
    }
    // The ceiling must stay tighter than the budget or it is decoration.
    #expect(ceiling < dailyBudget, "ceiling \(ceiling) is looser than the budget")
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

@Test func lowPowerModeCutsTheDayByRoughlyTheQuietMultiplier() {
    let normal = DaySimulation.run(userInterval: 180, watchlistCount: 10)
    let saving = DaySimulation.run(userInterval: 180, watchlistCount: 10, lowPowerMode: true)
    #expect(saving.requests < normal.requests)
    #expect(Double(saving.requests) <= Double(normal.requests) / 2)
}

@Test func aClosedMarketProducesNoBusyLoop() {
    // A wait of zero would spin the simulation for 86,400 iterations and, in
    // the real runner, spin a timer. Assert the cycle count is sane.
    let sim = DaySimulation.run(userInterval: 60, watchlistCount: 1, marketOverride: .closed)
    #expect(sim.cyclesStarted == 0)
}

@Test func thePacerIsNeverTheThingHoldingBackANormalDay() {
    // If the pacer is refusing requests during ordinary operation, the policy
    // is asking for more than the design allows and the two have drifted apart.
    let sim = DaySimulation.run(userInterval: 180, watchlistCount: 4)
    #expect(sim.pacerRefusals == 0,
            "the pacer refused \(sim.pacerRefusals) times on a default day")
}
