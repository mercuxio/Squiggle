import Testing
@testable import TickerCore

/// The spec's numbers, written out a second time.
///
/// Every other test in this suite derives its expectation from the constant
/// it is checking — `clock.advance(RateConstants.circuitOpenSeconds - 1)` and
/// so on. That is correct: those tests are about behaviour at a boundary, and
/// they should keep working if the boundary legitimately moves. But it leaves
/// the *values* asserted nowhere. A mutation sweep on 2026-09-08 changed
/// eleven of the seventeen literals in `RateConstants.swift` to arbitrary
/// values with the whole suite still green, `circuitOpenSeconds` among them.
///
/// So this file is, deliberately, a change-detector test — normally a smell,
/// here the entire point. These are safety properties, not preferences: they
/// were chosen by a spec written after Yahoo returned 429 for over an hour on
/// 2026-09-08 (§3.2), and the failure mode they guard against is a number
/// quietly becoming a different number. A number can only be checked against
/// drift if it exists in two independent places. This is the second place.
///
/// If one of these fails, do not adjust the constant to match the test or the
/// test to match the constant. Go and read the spec section cited beside it,
/// and change both together only if the spec changed.
///
/// Two constants are deliberately absent: `probeTimeoutSeconds` and
/// `minimumWaitSeconds` are implementation choices with no literal anywhere in
/// the spec. Asserting that one of those equals itself, with the expected
/// value sourced from nothing but the code it is checking, would be exactly
/// the vacuity this file exists to answer.

@Test func requestSpacingMatchesTheSpec() {
    // §4.1: `spacing = 30s  // between any two requests, ever`
    //
    // Held at 30 rather than lowered, and the reason is in `RateConstants`:
    // below 25 the quiet multiplier stops binding, the whole day runs at the
    // budget floor, and the day goes over 1,200. Pinned above 24 here too, so
    // a future edit meets the arithmetic rather than a bare literal.
    #expect(RateConstants.spacingSeconds == 30)
    #expect(RateConstants.spacingSeconds * RateConstants.quietMultiplier
        > RateConstants.secondsPerDay / Double(RateConstants.dailyRequestBudget))
}

@Test func theRefreshMenuMatchesTheSpec() {
    // §4.1: "1, 3 (default), 5, or 15 minutes."
    #expect(RateConstants.refreshIntervalChoices == [60, 180, 300, 900])
    #expect(RateConstants.defaultRefreshInterval == 180)
}

@Test func theQuietMultiplierMatchesTheSpec() {
    // §4.1 table: pre/post = `cycleInterval x 3`; Low Power Mode = `x 3`.
    #expect(RateConstants.quietMultiplier == 3)
}

// §4.1's Closed row — "one wake scheduled at `regular.start - 60s`" — was
// pinned here, and the user has since overruled that row of the spec:
// "forget the market calendar. always get the latest quote from yahoo
// regardless if the market is open or closed." There is no wake lead and no
// half-day ceiling left to pin. What the spec still governs for a shut market
// is the cadence, and `RefreshPolicyTests` asserts that: the ordinary one,
// not the quiet one.

@Test func theWatchlistCapMatchesTheSpec() {
    // §4.2: "Watchlist capped at 20 symbols."
    #expect(RateConstants.maxWatchlistCount == 20)
}

@Test func theTimerLeewayFractionMatchesTheSpec() {
    // §4.2: "`leeway = 0.25 x interval` so macOS coalesces the wakeup".
    // Nothing consumes this constant yet — `FeedEngine` (Task 16) will be its
    // first reader. Pinned now so the value cannot drift in the interval
    // between being written down and being used.
    #expect(RateConstants.timerLeewayFraction == 0.25)
}

@Test func theBucketCapacityMatchesTheSpec() {
    // §4.3 wrote "Capacity 5, refill 1 per 30s"; the same amendment raises the
    // capacity to one full watchlist so a cold launch fills both rows at once.
    // It cannot raise the burst past 20 whatever is written here: `take()`
    // needs a daily-bucket token too, and that bucket holds
    // `maxWatchlistCount`.
    #expect(RateConstants.bucketCapacity == 20)
    #expect(RateConstants.bucketCapacity == Double(RateConstants.maxWatchlistCount))
}

@Test func theRateLimitLadderMatchesTheSpec() {
    // §4.3, 429: "decorrelated jitter from 60s, cap 30 min."
    #expect(RateConstants.rateLimitBackoffBase == 60)
    #expect(RateConstants.rateLimitBackoffCap == 30 * 60)
}

@Test func theServerLadderMatchesTheSpec() {
    // §4.3, 5xx/timeout: "Decorrelated jitter from 30s, cap 15 min."
    #expect(RateConstants.serverBackoffBase == 30)
    #expect(RateConstants.serverBackoffCap == 15 * 60)
}

@Test func theJitterGrowthFactorMatchesTheSpec() {
    // §4.3: "`min(cap, random(base, previous x 3))`".
    #expect(RateConstants.jitterGrowthFactor == 3)
}

@Test func theUnauthorizedCooldownMatchesTheSpec() {
    // §4.3, 401/403: "1-hour cooldown; backoff cannot fix it."
    #expect(RateConstants.unauthorizedCooldown == 60 * 60)
}

@Test func theContractFaultCooldownMatchesTheSpec() {
    // §4.3, 200 with unparseable body: "Separate 1-hour circuit".
    #expect(RateConstants.contractFaultCooldown == 60 * 60)
}

@Test func theCircuitBreakerMatchesTheSpec() {
    // §4.3: "five consecutive failed cycles opens the circuit for 30
    // minutes, then one half-open probe of a single symbol."
    #expect(RateConstants.circuitFailureThreshold == 5)
    #expect(RateConstants.circuitOpenSeconds == 30 * 60)
}

@Test func theStalenessThresholdMatchesTheSpec() {
    // §5 state table: "Stale (> 3 x interval) | Whole strip dims".
    #expect(RateConstants.stalenessMultiplier == 3)
}
