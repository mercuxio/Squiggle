import Testing
import TickerCore
@testable import squigglectl

// R56: `WatchLoop.tolerance(forSleep:)` is the one place
// `RateConstants.timerLeewayFraction` (0.25) is actually consumed. Before
// this task it was a dead constant — mutating its value broke zero tests.
// These two assertions are why it no longer is.

@Test func toleranceIsAQuarterOfAThreeMinuteSleep() throws {
    // A concrete literal, not `180 * RateConstants.timerLeewayFraction`: an
    // expected value derived from the constant under test would pass for
    // every possible value of that constant, which proves nothing about
    // 0.25 specifically.
    #expect(WatchLoop.tolerance(forSleep: 180) == 45)
}

@Test func toleranceScalesWithTheLengthOfTheSleepAcrossSeveralIntervals() throws {
    // Three more fixed points, independently hand-computed at a quarter of
    // each interval, so the whole relationship is pinned rather than just
    // the one value above.
    #expect(WatchLoop.tolerance(forSleep: 60) == 15)
    #expect(WatchLoop.tolerance(forSleep: 300) == 75)
    #expect(WatchLoop.tolerance(forSleep: 900) == 225)
}

@Test func toleranceNeverGoesNegativeForANegativeSleep() throws {
    // Defensive: `next()` already floors every sleep it reports at
    // `RateConstants.minimumWaitSeconds`, so this should be unreachable in
    // practice, but `tolerance(forSleep:)` has no business handing
    // `Task.sleep` a negative duration if it ever is called with one.
    #expect(WatchLoop.tolerance(forSleep: -30) == 0)
}
