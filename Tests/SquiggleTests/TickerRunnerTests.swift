import Foundation
import Testing
import TickerCore
@testable import Squiggle

/// The recorded Yahoo bodies from plan 1. Reached by path rather than by
/// resource bundle because `Tests/Fixtures/` is shared by three test targets.
private enum Fixture {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // SquiggleTests
        .deletingLastPathComponent()      // Tests
        .appendingPathComponent("Fixtures/yahoo-2026-09-08")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }
}

/// Hands back canned bytes, or throws a canned error. No network: the project
/// has been rate-limited enough times already, and a test that reaches Yahoo
/// is a test that fails on an aeroplane.
private final class FakeFetcher: QuoteFetching, @unchecked Sendable {
    var body: Data?
    var error: (any Error)?
    private(set) var fetchCount = 0

    func fetch(_ symbol: Symbol) async throws -> Data {
        fetchCount += 1
        if let error { throw error }
        return body ?? Data()
    }
}

private final class FakeClock: MonotonicClock, @unchecked Sendable {
    var nowSeconds: Double = 0
}

@MainActor
@Test func aSuccessfulStepStoresTheQuoteAndStampsTheSuccess() async throws {
    let aapl = try #require(Symbol("AAPL"))
    let fetcher = FakeFetcher()
    fetcher.body = try Fixture.data("regular-session.json")
    let runner = TickerRunner(symbols: [aapl], userIntervalSeconds: 180,
                              fetcher: fetcher, clock: FakeClock())

    _ = await runner.step(nowEpoch: 1_000, visibility: .visible, lowPowerMode: false)

    #expect(runner.quotes[aapl]?.symbol == aapl)
    #expect(runner.lastSuccessEpoch == 1_000)
    #expect(runner.lastError == nil)
}

@MainActor
@Test func aFailedStepKeepsTheOldSuccessStampAndRecordsTheError() async throws {
    // Spec §7's stale state: prices are still shown, dimmed. Clearing the
    // stamp on failure would make a two-minute blip look like a cold start.
    let aapl = try #require(Symbol("AAPL"))
    let fetcher = FakeFetcher()
    fetcher.body = try Fixture.data("regular-session.json")
    let clock = FakeClock()
    let runner = TickerRunner(symbols: [aapl], userIntervalSeconds: 180,
                              fetcher: fetcher, clock: clock)
    // Both epochs below sit inside regular-session.json's recorded regular
    // session (1_788_874_200..<1_788_897_600) on purpose: a nowEpoch outside
    // it makes the aggregate calendar read `.closed` once that period has
    // been recorded, and the engine then sleeps instead of ever fetching
    // again.
    _ = await runner.step(nowEpoch: 1_788_880_000, visibility: .visible, lowPowerMode: false)

    fetcher.error = TickerError.offline
    // Far enough ahead that the pacer's spacing floor has expired.
    clock.nowSeconds = 10_000
    var later = 0.0
    for _ in 0..<40 where runner.lastError == nil {
        later = await runner.step(nowEpoch: 1_788_881_000, visibility: .visible, lowPowerMode: false)
        clock.nowSeconds += max(later, 1)
    }

    #expect(runner.lastError == .offline)
    #expect(runner.lastSuccessEpoch == 1_788_880_000)
    #expect(runner.quotes[aapl] != nil)
}

@MainActor
@Test func theCalendarOutOfTheBodyIsWhatDrivesTheNextContext() async throws {
    // Spec §3.2 and R122: one request yields both the quote and the trading
    // calendar. If the calendar were dropped, every symbol would be polled
    // at the regular cadence around the clock.
    let aapl = try #require(Symbol("AAPL"))
    let fetcher = FakeFetcher()
    fetcher.body = try Fixture.data("overnight-closed.json")
    let runner = TickerRunner(symbols: [aapl], userIntervalSeconds: 180,
                              fetcher: fetcher, clock: FakeClock())

    _ = await runner.step(nowEpoch: 1_000, visibility: .visible, lowPowerMode: false)

    #expect(runner.marketState(atEpoch: 1_000) != nil)
}

@MainActor
@Test func stepNeverThrowsEvenWhenTheFetcherThrowsSomethingUnexpected() async throws {
    // `QuoteFetching` promises `TickerError`, but nothing in the language
    // enforces that across an `async throws` boundary, and an uncaught throw
    // here would take the status item's timer with it.
    struct Surprise: Error {}
    let aapl = try #require(Symbol("AAPL"))
    let fetcher = FakeFetcher()
    fetcher.error = Surprise()
    let clock = FakeClock()
    let runner = TickerRunner(symbols: [aapl], userIntervalSeconds: 180,
                              fetcher: fetcher, clock: clock)

    for _ in 0..<40 where runner.lastError == nil {
        let wait = await runner.step(nowEpoch: 1_000, visibility: .visible, lowPowerMode: false)
        clock.nowSeconds += max(wait, 1)
    }
    #expect(runner.lastError != nil)
}

@MainActor
@Test func anOccludedRunnerStillReportsAWaitRatherThanFetching() async throws {
    // Spec §5.2: occlusion stops the animation. `FeedEngine` also stretches
    // the cadence for it, and the runner must pass the fact through rather
    // than hard-code `.visible` the way the CLI does.
    let aapl = try #require(Symbol("AAPL"))
    let fetcher = FakeFetcher()
    fetcher.body = try Fixture.data("regular-session.json")
    let clock = FakeClock()
    let runner = TickerRunner(symbols: [aapl], userIntervalSeconds: 60,
                              fetcher: fetcher, clock: clock)
    _ = await runner.step(nowEpoch: 1_000, visibility: .occluded, lowPowerMode: false)
    let countAfterFirst = fetcher.fetchCount

    clock.nowSeconds = 100
    _ = await runner.step(nowEpoch: 1_100, visibility: .occluded, lowPowerMode: false)
    #expect(fetcher.fetchCount == countAfterFirst)
}

@MainActor
@Test func replacingTheWatchlistDropsQuotesForSymbolsNoLongerWatched() async throws {
    // Otherwise a symbol removed in the picker keeps its last price in
    // `quotes` and the dropdown quietly shows a row for something the user
    // deleted.
    let aapl = try #require(Symbol("AAPL"))
    let vod = try #require(Symbol("VOD.L"))
    let fetcher = FakeFetcher()
    fetcher.body = try Fixture.data("regular-session.json")
    let runner = TickerRunner(symbols: [aapl], userIntervalSeconds: 180,
                              fetcher: fetcher, clock: FakeClock())
    _ = await runner.step(nowEpoch: 1_000, visibility: .visible, lowPowerMode: false)
    #expect(runner.quotes[aapl] != nil)

    runner.replaceWatchlist([vod])
    #expect(runner.quotes[aapl] == nil)
    #expect(runner.symbols == [vod])
}
