import Foundation
import TickerCore
import Testing
@testable import Squiggle

// R151's rule, tested where it lives: in `RefreshPolicy`, against the same
// arguments `StatusItemController.isStale(atEpoch:)` passes it.
//
// The controller itself needs a status bar and a run loop, so the assertion
// here is on the predicate rather than on the call — and that is the right
// place for it anyway, because the ruling is that the catch-up and the dim
// share one predicate. A test of the controller could show the catch-up
// firing; only this one shows the two agreeing.

private func wakeStale(agoSeconds: Double, symbols: Int,
                       marketState: MarketState = .regular) -> Bool {
    RefreshPolicy.isStale(lastSuccessEpoch: 10_000 - agoSeconds,
                          nowEpoch: 10_000,
                          userIntervalSeconds: RateConstants.defaultRefreshInterval,
                          watchlistCount: symbols,
                          marketState: marketState,
                          lowPowerMode: false)
}

// A lid closed over lunch. The strip is dimmed, so the catch-up fires.
// an hour asleep leaves a one-symbol strip stale
@Test func anHourIsStaleAtOneSymbol() {
    #expect(wakeStale(agoSeconds: 3_600, symbols: 1))
}

// The unlock-ten-seconds-later case `applyPause`'s old comment worried about.
// Nothing is dimmed, so nothing is fetched. Negated with `!`, never
// `== false`: `#expect(x == false)` passes whatever `x` is (`ExpectMacroTests`).
// a brief lock leaves nothing stale
@Test func tenSecondsIsNotStale() {
    #expect(!wakeStale(agoSeconds: 10, symbols: 1))
    #expect(!wakeStale(agoSeconds: 10, symbols: RateConstants.maxWatchlistCount))
}

// Three cycles, not three intervals. At twenty symbols the cycle floors at
// 1,440s, so the threshold is 72 minutes there and nine at one symbol — which
// is why the controller must never compute an age of its own.
// the threshold is three cycles, so it moves with the watchlist
@Test func theThresholdScalesWithTheWatchlist() {
    #expect(wakeStale(agoSeconds: 1_800, symbols: 1))
    #expect(!wakeStale(agoSeconds: 1_800, symbols: RateConstants.maxWatchlistCount))
    #expect(wakeStale(agoSeconds: 5_000, symbols: RateConstants.maxWatchlistCount))
}

// Overnight, the last close is the right number however old it is — so a
// machine woken at 03:00 fetches nothing.
// a closed market is never stale, however long the sleep
@Test func aClosedMarketWakesQuietly() {
    #expect(!wakeStale(agoSeconds: 50_000, symbols: 5, marketState: .closed))
}

// The R151 guard. Nothing has ever succeeded, so `isStale` says yes and the
// controller must still not ask for a cycle — the ordinary schedule is already
// retrying as fast as the ladder allows.
// never having succeeded is stale, and is the case the guard catches
@Test func nothingFetchedYetIsStale() {
    let never = RefreshPolicy.isStale(lastSuccessEpoch: nil,
                                      nowEpoch: 10_000,
                                      userIntervalSeconds: RateConstants.defaultRefreshInterval,
                                      watchlistCount: 1,
                                      marketState: .regular,
                                      lowPowerMode: false)
    #expect(never)
}
