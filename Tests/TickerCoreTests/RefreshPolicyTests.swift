import Testing
@testable import TickerCore

private func input(
    market: MarketState = .regular,
    visibility: Visibility = .visible,
    lowPower: Bool = false,
    interval: Double = RateConstants.defaultRefreshInterval,
    count: Int = 4,
    nextOpen: Double? = nil,
    cooling: Bool = false,
    cooldownRemaining: Double = 0,
    circuitAllows: Bool = true,
    circuitOpenRemaining: Double = 0
) -> RefreshInput {
    RefreshInput(nowMonotonic: 0,
                 nowEpoch: 1_757_000_000,
                 marketState: market,
                 visibility: visibility,
                 lowPowerMode: lowPower,
                 userIntervalSeconds: interval,
                 watchlistCount: count,
                 nextRegularOpenEpoch: nextOpen,
                 isCoolingDown: cooling,
                 cooldownRemaining: cooldownRemaining,
                 circuitAllows: circuitAllows,
                 circuitOpenRemaining: circuitOpenRemaining)
}

@Test func theHappyPathFetches() {
    #expect(RefreshPolicy.decide(input()) == .fetch)
}

@Test func anActiveCooldownOutranksEverything() {
    let d = RefreshPolicy.decide(input(cooling: true, cooldownRemaining: 412))
    #expect(d == .wait(seconds: 412))
}

@Test func anOpenCircuitOutranksAVisibleMarketOpenWatchlist() {
    let d = RefreshPolicy.decide(input(circuitAllows: false, circuitOpenRemaining: 900))
    #expect(d == .wait(seconds: 900))
}

@Test func aCooldownIsPreferredOverAnOpenCircuitWhenBothApply() {
    // Order matters only for the number reported; both mean "do not fetch".
    // Pin it so the reported wait is never the shorter of the two, which
    // would have the caller wake up early and be refused again.
    let d = RefreshPolicy.decide(input(cooling: true, cooldownRemaining: 1800,
                                       circuitAllows: false, circuitOpenRemaining: 60))
    let wait = d.waitSeconds ?? 0
    #expect(wait >= 1800)
}

@Test func aClosedMarketWaitsUntilShortlyBeforeTheNextOpen() {
    // Spec §4.1: while closed, one wake a minute before the open, not a
    // 15-minute poll that learns nothing 96 times a night.
    let now: Double = 1_757_000_000
    let open = now + 8 * 3600
    let d = RefreshPolicy.decide(input(market: .closed, nextOpen: open))
    let wait = d.waitSeconds ?? 0
    #expect(wait > 7 * 3600)
    #expect(wait <= 8 * 3600 - RateConstants.preOpenWakeLead + 1)
}

@Test func aClosedMarketWithNoKnownOpenFallsBackToASlowPoll() {
    // The open time comes from the last payload. On a cold launch into a
    // weekend there may be none, and a nil must not become an infinite sleep.
    let d = RefreshPolicy.decide(input(market: .closed, nextOpen: nil))
    let wait = d.waitSeconds ?? 0
    #expect(wait > 0)
    #expect(wait <= 3600, "a fallback poll of \(wait)s is a hang, not a poll")
}

@Test func aStaleNextOpenInThePastDoesNotProduceANegativeWait() {
    let now: Double = 1_757_000_000
    let d = RefreshPolicy.decide(input(market: .closed, nextOpen: now - 5000))
    let wait = d.waitSeconds ?? -1
    #expect(wait >= 0)
}

@Test func occlusionStopsFetchingEntirely() {
    // Spec §4.1 and §5.4: hidden behind a notch or another app's menu items,
    // there is nothing to update. This is the single largest saving.
    let d = RefreshPolicy.decide(input(visibility: .occluded))
    #expect(d != .fetch)
}

@Test func extendedHoursAndLowPowerBothStretchTheCycle() {
    let base = RefreshPolicy.cycleInterval(userIntervalSeconds: 300, watchlistCount: 4,
                                           marketState: .regular, lowPowerMode: false)
    let pre = RefreshPolicy.cycleInterval(userIntervalSeconds: 300, watchlistCount: 4,
                                          marketState: .pre, lowPowerMode: false)
    let saving = RefreshPolicy.cycleInterval(userIntervalSeconds: 300, watchlistCount: 4,
                                             marketState: .regular, lowPowerMode: true)
    #expect(pre == base * RateConstants.quietMultiplier)
    #expect(saving == base * RateConstants.quietMultiplier)
}

@Test func theTwoMultipliersDoNotCompound() {
    // Low Power Mode during pre-market should not produce a nine-times
    // interval; the user asked for a slower ticker, not a stopped one.
    let both = RefreshPolicy.cycleInterval(userIntervalSeconds: 300, watchlistCount: 4,
                                           marketState: .pre, lowPowerMode: true)
    #expect(both == 300 * RateConstants.quietMultiplier)
}

@Test func theSpacingFloorRaisesTheCycleForLargeWatchlists() {
    // Spec §4.1: cycleInterval = max(userInterval, n × spacing). With 20
    // symbols the floor is 600s, so a 60s setting cannot be honoured — and
    // must not be pretended to be.
    let interval = RefreshPolicy.cycleInterval(userIntervalSeconds: 60, watchlistCount: 20,
                                               marketState: .regular, lowPowerMode: false)
    #expect(interval == 20 * RateConstants.spacingSeconds)
}

@Test func theSpacingFloorNeverShortensAUsersChosenInterval() {
    // The floor is a floor. A user who asked for 15 minutes with one symbol
    // gets 15 minutes, not 30 seconds.
    for count in [1, 2, 4, 10, 20] {
        for interval in RateConstants.refreshIntervalChoices {
            let cycle = RefreshPolicy.cycleInterval(userIntervalSeconds: interval,
                                                    watchlistCount: count,
                                                    marketState: .regular,
                                                    lowPowerMode: false)
            #expect(cycle >= interval, "count \(count), interval \(interval) → \(cycle)")
            #expect(cycle >= Double(count) * RateConstants.spacingSeconds)
        }
    }
}

@Test func aFreshQuoteIsNotStale() {
    // Spec §7: the strip dims past three cycles. Below that it must not,
    // because a ticker that dims during normal operation teaches the user to
    // ignore the one signal it has.
    let stale = RefreshPolicy.isStale(lastSuccessEpoch: 1_000, nowEpoch: 1_100,
                                      userIntervalSeconds: 180, watchlistCount: 4,
                                      marketState: .regular, lowPowerMode: false)
    #expect(!stale)
}

@Test func stalenessIsThreeCyclesAndNotThreeUserIntervals() {
    // The cycle, not the setting, is the real cadence — a 20-symbol watchlist
    // at 60s takes ten minutes per pass. Measuring against the setting would
    // dim a perfectly healthy large watchlist permanently.
    let cycle = RefreshPolicy.cycleInterval(userIntervalSeconds: 60, watchlistCount: 20,
                                            marketState: .regular, lowPowerMode: false)
    func stale(after elapsed: Double) -> Bool {
        RefreshPolicy.isStale(lastSuccessEpoch: 0, nowEpoch: elapsed,
                              userIntervalSeconds: 60, watchlistCount: 20,
                              marketState: .regular, lowPowerMode: false)
    }
    let justBefore = stale(after: cycle * RateConstants.stalenessMultiplier - 1)
    let justAfter = stale(after: cycle * RateConstants.stalenessMultiplier + 1)
    #expect(!justBefore)
    #expect(justAfter)
}

@Test func aQuoteThatNeverArrivedIsStale() {
    // No successful fetch yet is exactly the state the dimmed strip is for.
    let stale = RefreshPolicy.isStale(lastSuccessEpoch: nil, nowEpoch: 5_000,
                                      userIntervalSeconds: 180, watchlistCount: 4,
                                      marketState: .regular, lowPowerMode: false)
    #expect(stale)
}

@Test func aClosedMarketDoesNotDimTheStrip() {
    // Overnight the last close is the correct number, however old it is.
    // Dimming it every night would make the signal meaningless by morning.
    let stale = RefreshPolicy.isStale(lastSuccessEpoch: 0, nowEpoch: 40 * 3600,
                                      userIntervalSeconds: 180, watchlistCount: 4,
                                      marketState: .closed, lowPowerMode: false)
    #expect(!stale)
}

@Test func aClockThatJumpedBackwardsDoesNotDimTheStrip() {
    let stale = RefreshPolicy.isStale(lastSuccessEpoch: 10_000, nowEpoch: 1_000,
                                      userIntervalSeconds: 180, watchlistCount: 4,
                                      marketState: .regular, lowPowerMode: false)
    #expect(!stale)
}

@Test func anEmptyWatchlistNeverFetches() {
    #expect(RefreshPolicy.decide(input(count: 0)) != .fetch)
}

@Test func aNonsenseIntervalIsClampedRatherThanObeyed() {
    // Defence against a hand-edited settings file. Zero would busy-loop.
    for bad in [0.0, -1, .infinity, .nan] {
        let cycle = RefreshPolicy.cycleInterval(userIntervalSeconds: bad, watchlistCount: 1,
                                                marketState: .regular, lowPowerMode: false)
        #expect(cycle.isFinite)
        #expect(cycle >= RateConstants.spacingSeconds)
    }
}

// R27: the brief's sweep never varied `cooldownRemaining` or
// `circuitOpenRemaining`, so it could not see either R25 failure, and it
// skipped its assertions entirely on every `.fetch` iteration (`if let wait =
// d.waitSeconds` is simply false there). This version sweeps hostile
// remainings crossed with both gating flags, and asserts the real invariant
// on every iteration, `.fetch` included: the decision is either `.fetch`, or
// a `.wait` whose seconds are finite, non-negative, and — this is the part a
// bare finite/non-negative check cannot catch — not zero unless a fetch
// would in fact have been allowed. A `.wait(seconds: 0)` while cooling down
// or circuit-closed-for-a-reason is a hot loop wearing a passing test.
@Test func everyDecisionIsFiniteAndNonNegative() {
    let hostileRemainings: [Double] = [0, -1, .infinity, -.infinity, .nan, 412]

    for market in [MarketState.pre, .regular, .post, .closed] {
        for visibility in [Visibility.visible, .occluded] {
            for lowPower in [false, true] {
                for count in [0, 1, 20] {
                    for isCoolingDown in [false, true] {
                        for circuitAllows in [false, true] {
                            for remaining in hostileRemainings {
                                let d = RefreshPolicy.decide(input(
                                    market: market, visibility: visibility,
                                    lowPower: lowPower, count: count,
                                    cooling: isCoolingDown, cooldownRemaining: remaining,
                                    circuitAllows: circuitAllows, circuitOpenRemaining: remaining))

                                switch d {
                                case .fetch:
                                    // A fetch is only ever a valid answer when nothing
                                    // is actively refusing it.
                                    #expect(!isCoolingDown)
                                    #expect(circuitAllows)
                                    #expect(count > 0)
                                    #expect(visibility == .visible)
                                    #expect(market != .closed)
                                case .wait(let wait):
                                    #expect(wait.isFinite)
                                    #expect(wait >= 0)
                                    // Zero is only honest when a fetch would in fact
                                    // have been allowed right now — otherwise the
                                    // caller wakes immediately and is refused again.
                                    let fetchWouldBeAllowed = !isCoolingDown && circuitAllows
                                        && count > 0 && visibility == .visible && market != .closed
                                    if wait == 0 {
                                        #expect(fetchWouldBeAllowed)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
