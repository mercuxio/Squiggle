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

// MARK: - Per-symbol trading calendars (F1(c))
//
// The engine consumes one `MarketState`, so N calendars have to become one.
// This loop used to keep whichever arrived last, which made the answer depend
// on round-robin position. These fix the aggregate in both directions.

/// 03:00 on a day whose equity session runs 04:00 pre / 09:30 regular /
/// 16:00 post / 20:00 close. Epoch zero is midnight; the numbers are hours so
/// the windows read as a trading day rather than as arithmetic.
private let hour: Double = 3600
private let threeAM = 3 * hour

private func equityDay(openingAt offsetHours: Double = 0) -> TradingPeriod {
    TradingPeriod(
        pre: .init(startEpoch: (4 + offsetHours) * hour, endEpoch: (9.5 + offsetHours) * hour),
        regular: .init(startEpoch: (9.5 + offsetHours) * hour, endEpoch: (16 + offsetHours) * hour),
        post: .init(startEpoch: (16 + offsetHours) * hour, endEpoch: (20 + offsetHours) * hour))
}

/// Crypto: one regular session covering the whole day, no pre and no post.
/// This is the shape `TradingPeriod` already documents as falling out for free.
private let twentyFourHourDay = TradingPeriod(
    pre: nil, regular: .init(startEpoch: 0, endEpoch: 24 * hour), post: nil)

private func equitySymbols(_ n: Int) throws -> [Symbol] {
    try (0..<n).map { try #require(Symbol("EQ\($0)")) }
}

@Test func nineteenEquitySymbolsDoNotInheritOneTwentyFourHourCalendar() throws {
    // The charge's case exactly: one crypto symbol, nineteen equity symbols,
    // 03:00. Each equity symbol must still know its own exchange is shut.
    let crypto = try #require(Symbol("BTC-USD"))
    let equities = try equitySymbols(19)

    var calendars = WatchLoop.Calendars()
    calendars.record(twentyFourHourDay, for: crypto)
    for symbol in equities { calendars.record(equityDay(), for: symbol) }

    for symbol in equities {
        let own = calendars.state(for: symbol, atEpoch: threeAM)
        #expect(own == .closed,
                "\(symbol.raw) took the crypto calendar: \(String(describing: own))")
    }
    // And the crypto symbol keeps its own too — the collapse ran both ways.
    #expect(calendars.state(for: crypto, atEpoch: threeAM) == .regular)
}

@Test func oneClosedEquitySymbolCannotPutATwentyFourHourSymbolToSleep() throws {
    // The expensive direction of the old bug. At 03:00 an equity symbol
    // reports `.closed` with a 04:00 open; if that wins, `RefreshPolicy` sleeps
    // the entire loop — crypto included — for an hour, and a 24-hour
    // instrument goes dark while it is trading.
    let crypto = try #require(Symbol("BTC-USD"))
    let equity = try #require(Symbol("AAPL"))

    var equityLast = WatchLoop.Calendars()
    equityLast.record(twentyFourHourDay, for: crypto)
    equityLast.record(equityDay(), for: equity)
    #expect(equityLast.aggregateState(atEpoch: threeAM) == .regular,
            "the equity calendar won because it arrived second")

    // Same two symbols, opposite arrival order. An aggregate that depends on
    // round-robin position is the defect, so both orders are asserted.
    var cryptoLast = WatchLoop.Calendars()
    cryptoLast.record(equityDay(), for: equity)
    cryptoLast.record(twentyFourHourDay, for: crypto)
    #expect(cryptoLast.aggregateState(atEpoch: threeAM) == .regular)
}

@Test func theAggregateIsClosedOnlyWhenEveryWatchedSymbolIsClosed() throws {
    // Most-open must not mean never-closed: with nothing open the loop still
    // has to reach `RefreshPolicy`'s closed-market branch and sleep until the
    // open, or the overnight saving in spec §4.2's cost table disappears.
    let equities = try equitySymbols(3)
    var calendars = WatchLoop.Calendars()
    for symbol in equities { calendars.record(equityDay(), for: symbol) }
    #expect(calendars.aggregateState(atEpoch: threeAM) == .closed)
}

@Test func theWakeIsTheEarliestOpenAcrossTheWatchlistNotWhicheverArrivedLast() throws {
    // Two exchanges, opens three hours apart. Waking for the later one sleeps
    // straight through the earlier symbol's whole pre-market session.
    let early = try #require(Symbol("EARLY"))
    let late = try #require(Symbol("LATE"))
    var calendars = WatchLoop.Calendars()
    calendars.record(equityDay(openingAt: 3), for: late)
    calendars.record(equityDay(), for: early)

    let wake = calendars.earliestSessionOpenEpoch(after: threeAM)
    #expect(wake == 4 * hour, "woke at \(String(describing: wake)) rather than 04:00")
}

@Test func aSymbolTheEngineGaveUpOnStopsVotingOnTheCalendar() throws {
    // A delisted 24-hour ticker that fails forever would otherwise hold the
    // whole watchlist at `.regular` for the life of the process — the original
    // bug with a longer fuse, and one no successful fetch can ever clear.
    let dead = try #require(Symbol("DEAD-USD"))
    let equity = try #require(Symbol("AAPL"))
    var calendars = WatchLoop.Calendars()
    calendars.record(twentyFourHourDay, for: dead)
    calendars.record(equityDay(), for: equity)
    #expect(calendars.aggregateState(atEpoch: threeAM) == .regular)

    calendars.retain([equity])
    #expect(calendars.aggregateState(atEpoch: threeAM) == .closed,
            "the dead symbol was still voting")
    #expect(calendars.state(for: dead, atEpoch: threeAM) == nil)
}

@Test func anEmptyCalendarSetDeclinesToGuess() {
    // Before the first successful quote there is no calendar. `nil` is not
    // `.closed`: reporting `.closed` here would sleep the loop until an open
    // it has never been told about, and the loop's own comment says one wasted
    // request beats never starting.
    let calendars = WatchLoop.Calendars()
    #expect(calendars.aggregateState(atEpoch: threeAM) == nil)
    #expect(calendars.earliestSessionOpenEpoch(after: threeAM) == nil)
}

@Test func opennessRanksEveryStateAndRegularOutranksThemAll() {
    // The ordering the aggregate is built on, asserted directly so a reordering
    // shows up here rather than as a cost regression three tests away.
    let closed = WatchLoop.Calendars.openness(.closed)
    let post = WatchLoop.Calendars.openness(.post)
    let pre = WatchLoop.Calendars.openness(.pre)
    let regular = WatchLoop.Calendars.openness(.regular)
    #expect(closed < post)
    #expect(post < pre)
    #expect(pre < regular)
}
