import Testing
@testable import TickerCore

private func input(
    market: MarketState = .regular,
    visibility: Visibility = .visible,
    lowPower: Bool = false,
    interval: Double = RateConstants.defaultRefreshInterval,
    count: Int = 4,
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

@Test func whenACooldownAndAnOpenCircuitBothApplyTheLongerIsReported() {
    // Both mean "do not fetch", so the number reported must be the one that
    // actually applies — the longer. Reporting the shorter wakes the caller
    // early to be refused again by the other. Asserted in both directions:
    // a fixed order gets one of these right by luck.
    let cooldownIsLonger = RefreshPolicy.decide(input(cooling: true, cooldownRemaining: 1800,
                                                      circuitAllows: false,
                                                      circuitOpenRemaining: 60))
    #expect(cooldownIsLonger == .wait(seconds: 1800))

    let circuitIsLonger = RefreshPolicy.decide(input(cooling: true, cooldownRemaining: 5,
                                                     circuitAllows: false,
                                                     circuitOpenRemaining: 1800))
    #expect(circuitIsLonger == .wait(seconds: 1800))

    // A corrupted cooldown must not shorten a circuit that is genuinely open
    // for half an hour: the sanitised stand-in is a default, not a licence.
    let corruptCooldown = RefreshPolicy.decide(input(cooling: true, cooldownRemaining: .nan,
                                                     circuitAllows: false,
                                                     circuitOpenRemaining: 1800))
    #expect(corruptCooldown == .wait(seconds: 1800))
}

/// "forget the market calendar. always get the latest quote from yahoo
/// regardless if the market is open or closed."
///
/// Five tests and a file-private ceiling constant stood here, each describing
/// some property of the closed-market stand-down: when it woke, how long it
/// could sleep at most, what it did with an unknown open, that a stale open
/// could not make the wait negative. There is no branch left for any of them
/// to describe, and one assertion in their place says what replaced it.
@Test func aClosedMarketIsNoLongerAReasonToRefuse() {
    #expect(RefreshPolicy.decide(input(market: .closed)) == .fetch)
}

/// The cadence still knows about the clock even though the stand-down does
/// not. `.pre` and `.post` stretch the cycle by `quietMultiplier`; `.closed`
/// runs at the ordinary one, because outside every session there is no
/// "quiet" left to distinguish it from. Asserted through `cycleInterval`
/// rather than `decide`, which returns `.fetch` for all four now.
@Test func aShutMarketKeepsTheOrdinaryCadence() {
    let regular = RefreshPolicy.cycleInterval(userIntervalSeconds: 300, watchlistCount: 4,
                                              marketState: .regular, lowPowerMode: false)
    let closed = RefreshPolicy.cycleInterval(userIntervalSeconds: 300, watchlistCount: 4,
                                             marketState: .closed, lowPowerMode: false)
    #expect(closed == regular)
}

@Test func aRefusalNeverReportsASubSecondWait() {
    // A wait of a millisecond, returned by a branch that has just decided not
    // to fetch, is a hot loop in slow motion. The pre-open case that used to
    // open this test — an open sitting a millisecond past the wake lead — no
    // longer exists; a cooldown is the remaining branch that can produce a
    // sub-second remaining, and the sweep further down covers the rest.
    let tinyCooldown = RefreshPolicy.decide(input(cooling: true, cooldownRemaining: 0.25))
    #expect(tinyCooldown == .wait(seconds: RateConstants.minimumWaitSeconds))

    // Too small and corrupt are different failures and keep different
    // answers: a corrupt remaining is not evidence that one second is enough.
    let corrupt = RefreshPolicy.decide(input(cooling: true, cooldownRemaining: .nan))
    #expect(corrupt == .wait(seconds: RateConstants.defaultRefreshInterval))
}

@Test func occlusionStopsFetchingEntirely() {
    // Spec §4.1 and §5.4: hidden behind a notch or another app's menu items,
    // there is nothing to update. This is the single largest saving.
    //
    // The value is pinned, not just the refusal: this branch is the only
    // place `cycleInterval`'s result is observable through `decide`, so an
    // unpinned wait here would let a 1 Hz wake — or a `decide` that ignored
    // Low Power Mode and the market entirely — pass as correct. Task 12's
    // day-long budget simulation is built on exactly this number.
    let cycle = RefreshPolicy.cycleInterval(userIntervalSeconds: RateConstants.defaultRefreshInterval,
                                            watchlistCount: 4,
                                            marketState: .regular,
                                            lowPowerMode: false)
    #expect(RefreshPolicy.decide(input(visibility: .occluded)) == .wait(seconds: cycle))

    // Not `cycle * quietMultiplier`. The multiplier stretches the cadence the
    // user asked for, and the budget floor is then applied to the result — so
    // once the floor is the binding term in regular hours, the quiet cycle is
    // *not* three times the regular one. At these inputs (4 symbols, the 180s
    // default) regular hours run at the floor, `max(180, 120, 288) = 288`,
    // while quiet hours run at `max(180 x 3, 288) = 540`. Both are pinned
    // outright, because deriving one from the other is what hid the difference.
    #expect(cycle == 288)
    let quiet: Double = 540
    #expect(RefreshPolicy.decide(input(visibility: .occluded, lowPower: true))
            == .wait(seconds: quiet))
    #expect(RefreshPolicy.decide(input(market: .pre, visibility: .occluded))
            == .wait(seconds: quiet))
}

@Test func extendedHoursAndLowPowerBothStretchTheCycle() {
    let base = RefreshPolicy.cycleInterval(userIntervalSeconds: 300, watchlistCount: 4,
                                           marketState: .regular, lowPowerMode: false)
    let pre = RefreshPolicy.cycleInterval(userIntervalSeconds: 300, watchlistCount: 4,
                                          marketState: .pre, lowPowerMode: false)
    let post = RefreshPolicy.cycleInterval(userIntervalSeconds: 300, watchlistCount: 4,
                                           marketState: .post, lowPowerMode: false)
    let saving = RefreshPolicy.cycleInterval(userIntervalSeconds: 300, watchlistCount: 4,
                                             marketState: .regular, lowPowerMode: true)
    #expect(pre == base * RateConstants.quietMultiplier)
    // Post-market is the other half of "extended hours" and stretches too.
    #expect(post == base * RateConstants.quietMultiplier)
    #expect(saving == base * RateConstants.quietMultiplier)
}

@Test func theTwoMultipliersDoNotCompound() {
    // Low Power Mode during pre-market should not produce a nine-times
    // interval; the user asked for a slower ticker, not a stopped one.
    let both = RefreshPolicy.cycleInterval(userIntervalSeconds: 300, watchlistCount: 4,
                                           marketState: .pre, lowPowerMode: true)
    #expect(both == 300 * RateConstants.quietMultiplier)
}

@Test func theFloorsRaiseTheCycleForLargeWatchlists() {
    // Spec §4.1: a 60s setting cannot be honoured across 20 symbols, and must
    // not be pretended to be. Two floors say so and the larger one wins: 20 x
    // 30s of spacing is 600s, and the budget floor is 20 x 72s = 1,440s.
    //
    // Both are asserted, and in that order, because the spacing floor alone is
    // what this test used to check — and a 600s cycle on an instrument that
    // never closes is 2,880 requests a day against a 1,200 budget. Passing the
    // weaker floor is not evidence of passing the stronger one.
    let interval = RefreshPolicy.cycleInterval(userIntervalSeconds: 60, watchlistCount: 20,
                                               marketState: .regular, lowPowerMode: false)
    #expect(interval >= 20 * RateConstants.spacingSeconds)
    #expect(interval == RefreshPolicy.budgetFloor(watchlistCount: 20))
    #expect(interval == 1_440)
}

@Test func aWatchlistLargerThanSquiggleSupportsIsCappedNotBelieved() {
    // `maxWatchlistCount` is the largest list the app admits. Without the
    // clamp the floor scales with the number given, and `Int.max` symbols
    // become a cycle of nine trillion years — a hang wearing a cadence's name.
    // The cap is expressed as "behaves exactly as `maxWatchlistCount` does"
    // rather than as one floor's arithmetic, so it keeps holding whichever
    // floor happens to bind. It is 1,440s today, from the budget floor.
    let capped = RefreshPolicy.cycleInterval(userIntervalSeconds: 60,
                                             watchlistCount: RateConstants.maxWatchlistCount,
                                             marketState: .regular, lowPowerMode: false)
    #expect(capped == 1_440)
    let oversized = RefreshPolicy.cycleInterval(userIntervalSeconds: 60, watchlistCount: 100_000,
                                                marketState: .regular, lowPowerMode: false)
    #expect(oversized == capped)

    let extreme = RefreshPolicy.cycleInterval(userIntervalSeconds: 60, watchlistCount: .max,
                                              marketState: .regular, lowPowerMode: false)
    #expect(extreme == capped)
}

@Test func theCycleIsExactlyTheLargestFloorAndNeverShortensAUsersInterval() {
    // The floors are floors: a user who asked for 15 minutes with one symbol
    // gets 15 minutes, not 30 seconds. But `>=` alone was never that claim.
    // `return 86_400` satisfies every `>=` below, at all twenty grid points, so
    // as a pair of lower bounds this test also passed for a policy that fetched
    // once a day — the two `>=` lines are kept for what they say, and the
    // equality is what makes them mean it.
    //
    // So the law is asserted as an equality: the cycle is the largest of the
    // three terms and is not one second more. `max(interval, n x 30s, budget
    // floor)`, with the budget floor as the third term F1(a) added.
    for count in [1, 2, 4, 10, 20] {
        for interval in RateConstants.refreshIntervalChoices {
            let cycle = RefreshPolicy.cycleInterval(userIntervalSeconds: interval,
                                                    watchlistCount: count,
                                                    marketState: .regular,
                                                    lowPowerMode: false)
            let spacingFloor = Double(count) * RateConstants.spacingSeconds
            let budgetFloor = RefreshPolicy.budgetFloor(watchlistCount: count)
            let expected = max(interval, max(spacingFloor, budgetFloor))
            #expect(cycle == expected,
                    "count \(count), interval \(interval) → \(cycle), expected \(expected)")
            #expect(cycle >= interval)
            #expect(cycle >= spacingFloor)
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
    // at 60s takes 1,440s per pass, twenty-four minutes. Measuring against the
    // setting would dim a perfectly healthy large watchlist permanently.
    //
    // This said "ten minutes" until the final review: 600s, the n x 30s spacing
    // floor, which F19 established can never be the binding term on its own.
    // The number below is read from `cycleInterval`, so the assertions were
    // right while the sentence explaining them was wrong — and being spelled in
    // words is what carried it past a numeric sweep looking for digits.
    let cycle = RefreshPolicy.cycleInterval(userIntervalSeconds: 60, watchlistCount: 20,
                                            marketState: .regular, lowPowerMode: false)
    func stale(after elapsed: Double) -> Bool {
        RefreshPolicy.isStale(lastSuccessEpoch: 0, nowEpoch: elapsed,
                              userIntervalSeconds: 60, watchlistCount: 20,
                              marketState: .regular, lowPowerMode: false)
    }
    let justBefore = stale(after: cycle * RateConstants.stalenessMultiplier - 1)
    let atTheBoundary = stale(after: cycle * RateConstants.stalenessMultiplier)
    let justAfter = stale(after: cycle * RateConstants.stalenessMultiplier + 1)
    #expect(!justBefore)
    // Which side of the boundary the strip dims on is a decision, not an
    // accident: exactly three cycles old is still current. Probing only
    // ±1 second leaves `>` and `>=` indistinguishable.
    #expect(!atTheBoundary)
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
    // A timezone change or an NTP correction is not a data fault, and the
    // size of the jump must not turn into a verdict — measuring the magnitude
    // of the age rather than its value would dim the strip hardest for the
    // largest correction.
    for now in [1_000.0, -1_000_000] {
        let stale = RefreshPolicy.isStale(lastSuccessEpoch: 10_000, nowEpoch: now,
                                          userIntervalSeconds: 180, watchlistCount: 4,
                                          marketState: .regular, lowPowerMode: false)
        #expect(!stale, "nowEpoch \(now)")
    }
}

@Test func anAgeThatCannotBeMeasuredDimsTheStrip() {
    // Unknown freshness must dim, because the dimmed strip *is* the "I do not
    // know that this is current" signal. Reporting an unmeasurable age as
    // fresh spends the one signal the strip has on the one case it cannot
    // vouch for.
    for now in [Double.infinity, .nan] {
        let stale = RefreshPolicy.isStale(lastSuccessEpoch: 0, nowEpoch: now,
                                          userIntervalSeconds: 180, watchlistCount: 4,
                                          marketState: .regular, lowPowerMode: false)
        #expect(stale, "nowEpoch \(now)")
    }

    // A corrupt stored timestamp, not a clock correction: an infinite last
    // success is unmeasurable in the other direction and dims too.
    let corruptLastSuccess = RefreshPolicy.isStale(lastSuccessEpoch: .infinity, nowEpoch: 1_000,
                                                   userIntervalSeconds: 180, watchlistCount: 4,
                                                   marketState: .regular, lowPowerMode: false)
    #expect(corruptLastSuccess)

    // The closed-market answer still outranks it: overnight, the last close
    // is the right number however unmeasurable its age.
    let closed = RefreshPolicy.isStale(lastSuccessEpoch: 0, nowEpoch: .nan,
                                       userIntervalSeconds: 180, watchlistCount: 4,
                                       marketState: .closed, lowPowerMode: false)
    #expect(!closed)
}

@Test func anEmptyWatchlistNeverFetches() {
    #expect(RefreshPolicy.decide(input(count: 0)) != .fetch)
}

@Test func aNonsenseIntervalIsClampedRatherThanObeyed() {
    // Defence against a hand-edited settings file. Zero would busy-loop, and
    // `1e308` is no harder to type than `-1` — it is the one input that can
    // make the whole policy non-finite, because a large *finite* interval
    // survives a positivity check and then overflows on the quiet multiplier.
    let offered = RateConstants.offeredRefreshIntervals
    let outsideTheMenu: [Double] = [0, -1, .infinity, -.infinity, .nan,
                                    1e308, .greatestFiniteMagnitude,
                                    offered.upperBound + 1, offered.lowerBound - 1]

    for bad in outsideTheMenu {
        let cycle = RefreshPolicy.cycleInterval(userIntervalSeconds: bad, watchlistCount: 1,
                                                marketState: .regular, lowPowerMode: false)
        #expect(cycle == RateConstants.defaultRefreshInterval, "interval \(bad) → \(cycle)")

        // The stretch is where the overflow lived: a value clamped only at the
        // output would still be reporting `inf` here.
        let stretched = RefreshPolicy.cycleInterval(userIntervalSeconds: bad, watchlistCount: 4,
                                                    marketState: .pre, lowPowerMode: true)
        #expect(stretched == RateConstants.defaultRefreshInterval * RateConstants.quietMultiplier,
                "interval \(bad) → \(stretched)")
    }

    // Every interval Settings can actually produce is obeyed, so the bound
    // rejects corruption and nothing else. A single symbol's budget floor is
    // 72s, which the 60s choice sits under, so the comparison is against the
    // floors rather than against the raw choice — otherwise this would be
    // asserting that the floors do not apply.
    for good in RateConstants.refreshIntervalChoices {
        let cycle = RefreshPolicy.cycleInterval(userIntervalSeconds: good, watchlistCount: 1,
                                                marketState: .regular, lowPowerMode: false)
        let honoured = max(good, max(RateConstants.spacingSeconds,
                                     RefreshPolicy.budgetFloor(watchlistCount: 1)))
        #expect(cycle == honoured, "interval \(good) → \(cycle)")
    }
}

@Test func theIntervalBoundIsDerivedFromTheMenuAndNotWrittenDownTwice() {
    // The bound that rejects a corrupt interval must track the list of
    // intervals Settings offers. Written down separately it would drift, and
    // a bound that drifts from the list it bounds is worse than no bound —
    // it would start rejecting a choice the user can actually pick.
    let lowest = RateConstants.refreshIntervalChoices.min()
    let highest = RateConstants.refreshIntervalChoices.max()
    #expect(RateConstants.offeredRefreshIntervals.lowerBound == lowest)
    #expect(RateConstants.offeredRefreshIntervals.upperBound == highest)
}

@Test func aCorruptIntervalCannotBecomeAnInfiniteWait() {
    // The occluded branch is where a non-finite cycle would reach the caller
    // as a timer that never fires — a silent, permanent hang no error message
    // would ever explain.
    let expected = RateConstants.defaultRefreshInterval * RateConstants.quietMultiplier
    for bad in [1e308, .greatestFiniteMagnitude, .infinity, .nan] {
        let d = RefreshPolicy.decide(input(visibility: .occluded, lowPower: true, interval: bad))
        #expect(d == .wait(seconds: expected), "interval \(bad) → \(d)")
    }
}

@Test func aCorruptIntervalCannotSilenceTheStalenessIndicator() {
    // The same overflow read the other way: `age > inf` is false, so an
    // eleven-day-old quote would report as fresh.
    for bad in [1e308, .greatestFiniteMagnitude, .infinity, .nan] {
        let stale = RefreshPolicy.isStale(lastSuccessEpoch: 0, nowEpoch: 1_000_000,
                                          userIntervalSeconds: bad, watchlistCount: 4,
                                          marketState: .regular, lowPowerMode: true)
        #expect(stale, "interval \(bad)")
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
    // The interval axis was missing, and it is the one axis that can make a
    // decision non-finite: `1e308` passes a positivity check and then
    // overflows on the quiet multiplier.
    let hostileIntervals: [Double] = [RateConstants.defaultRefreshInterval, 900,
                                      1e308, .greatestFiniteMagnitude, .nan]

    for market in [MarketState.pre, .regular, .post, .closed] {
        for visibility in [Visibility.visible, .occluded] {
            for lowPower in [false, true] {
                for count in [0, 1, 20] {
                    for isCoolingDown in [false, true] {
                        for circuitAllows in [false, true] {
                          for interval in hostileIntervals {
                            for remaining in hostileRemainings {
                                let d = RefreshPolicy.decide(input(
                                    market: market, visibility: visibility,
                                    lowPower: lowPower, interval: interval, count: count,
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
                                case .wait(let wait):
                                    #expect(wait.isFinite)
                                    #expect(wait >= 0)
                                    // A refusal owes the caller a real interval. One
                                    // second is the floor: below it the wake buys
                                    // nothing and costs a battery meter.
                                    #expect(wait >= RateConstants.minimumWaitSeconds,
                                            "wait \(wait) for interval \(interval), remaining \(remaining)")
                                    // Zero is only honest when a fetch would in fact
                                    // have been allowed right now — otherwise the
                                    // caller wakes immediately and is refused again.
                                    let fetchWouldBeAllowed = !isCoolingDown && circuitAllows
                                        && count > 0 && visibility == .visible
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
}
