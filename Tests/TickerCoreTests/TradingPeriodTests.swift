import Testing
import Foundation
@testable import TickerCore

private func period(
    pre: (Double, Double)? = (100, 200),
    regular: (Double, Double)? = (200, 300),
    post: (Double, Double)? = (300, 400)
) -> TradingPeriod {
    TradingPeriod(
        pre: pre.map { TradingPeriod.Window(startEpoch: $0.0, endEpoch: $0.1) },
        regular: regular.map { TradingPeriod.Window(startEpoch: $0.0, endEpoch: $0.1) },
        post: post.map { TradingPeriod.Window(startEpoch: $0.0, endEpoch: $0.1) })
}

@Test func stateIsReadFromTheWindowsAndNotFromACalendar() {
    let p = period()
    #expect(p.state(atEpoch: 50) == .closed)
    #expect(p.state(atEpoch: 150) == .pre)
    #expect(p.state(atEpoch: 250) == .regular)
    #expect(p.state(atEpoch: 350) == .post)
    #expect(p.state(atEpoch: 450) == .closed)
}

@Test func windowsAreHalfOpenSoTheBoundaryBelongsToExactlyOneState() {
    let p = period()
    // 200 is regular's start and pre's end. Without a rule, a poll landing
    // exactly on the bell reads as both or neither.
    #expect(p.state(atEpoch: 200) == .regular)
    #expect(p.state(atEpoch: 300) == .post)
    #expect(p.state(atEpoch: 400) == .closed)
}

@Test func cryptoIsNeverClosed() {
    // A 24-hour session arrives as a regular window spanning the whole day.
    // This is the case a hand-maintained holiday table gets wrong.
    let p = period(pre: nil, regular: (0, 86_400), post: nil)
    #expect(p.state(atEpoch: 1) == .regular)
    #expect(p.state(atEpoch: 43_200) == .regular)
    #expect(p.state(atEpoch: 86_399) == .regular)
}

@Test func aPeriodWithNoWindowsAtAllReadsClosedRatherThanCrashing() {
    let p = period(pre: nil, regular: nil, post: nil)
    #expect(p.state(atEpoch: 250) == .closed)
}

@Test func aZeroLengthOrInvertedWindowIsIgnored() {
    // Yahoo has been seen to emit start == end on a holiday.
    let p = period(pre: nil, regular: (200, 200), post: nil)
    #expect(p.state(atEpoch: 200) == .closed)

    let inverted = period(pre: nil, regular: (300, 200), post: nil)
    #expect(inverted.state(atEpoch: 250) == .closed)
}

@Test func regularWinsWhenYahooEmitsOverlappingWindows() {
    // Some venues arrive with real overlap, not just shared boundaries.
    // pre 100-250 and regular 200-350 share [200, 250); regular and
    // post 300-450 share [300, 350). Either overlap must resolve to
    // .regular, not to whichever window happens to be checked first.
    let p = period(pre: (100, 250), regular: (200, 350), post: (300, 450))
    #expect(p.state(atEpoch: 220) == .regular)
    #expect(p.state(atEpoch: 320) == .regular)
}

// Four tests about the next session's open stood here — which of pre and
// regular the wake belonged to, that a `start == end` holiday window could
// not steal it, that an out-of-order payload still yielded the earliest.
// Nothing computes a wake time any more: "forget the market calendar. always
// get the latest quote from yahoo regardless if the market is open or
// closed." `state(atEpoch:)` is what remains, and the tests above cover it.

@Test func theTradingPeriodParsesOutOfARealFixture() throws {
    let parsed = try YahooQuoteDecoding.tradingPeriod(from: Fixture.data("regular-session.json"))
    let regular = try #require(parsed.regular)
    #expect(regular.endEpoch > regular.startEpoch)
    // A US regular session is 6.5 hours. Allow slack for a half-day.
    #expect(regular.endEpoch - regular.startEpoch <= 6.5 * 3600 + 60)
}

@Test func aPayloadWithNoTradingPeriodIsAMissingFieldNotAGuess() throws {
    let json = "{\"chart\":{\"result\":[{\"meta\":{\"regularMarketPrice\":1.0}}],\"error\":null}}"
    #expect(throws: TickerError.self) {
        try YahooQuoteDecoding.tradingPeriod(from: Data(json.utf8))
    }
}
