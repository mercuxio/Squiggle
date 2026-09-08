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
    #expect(p.nextSessionOpenEpoch(after: 0) == nil)
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

@Test func theNextOpenIsOnlyReportedWhenItIsStillAhead() {
    let p = period()
    // Mid-pre: regular is the next start still ahead. Mid-regular: post is.
    #expect(p.nextSessionOpenEpoch(after: 150) == 200)
    #expect(p.nextSessionOpenEpoch(after: 250) == 300)
    // Past the last start there is nothing left to wake for.
    #expect(p.nextSessionOpenEpoch(after: 350) == nil)
}

@Test func theNextOpenIsThePreOpenAndNotTheRegularOne() {
    // The whole point of `nextSessionOpenEpoch`. Overnight, both pre and
    // regular are ahead; the wake belongs at pre. Returning 200 here is the
    // shipped defect — a Mac left on sleeps from midnight to 09:29 and never
    // polls the 04:00-09:30 session at all, because the closed-market branch
    // put it to sleep past the only chance it had.
    let p = period()
    #expect(p.nextSessionOpenEpoch(after: 50) == 100)
}

@Test func aMalformedSessionIsSkippedRatherThanWokenFor() {
    // A holiday `start == end` pre window must not steal the wake from the
    // real regular open behind it: a window that contains nothing is a window
    // worth waking for nothing.
    let holidayPre = period(pre: (100, 100), regular: (200, 300), post: nil)
    #expect(holidayPre.nextSessionOpenEpoch(after: 50) == 200)

    let invertedPre = period(pre: (150, 100), regular: (200, 300), post: nil)
    #expect(invertedPre.nextSessionOpenEpoch(after: 50) == 200)
}

@Test func anOutOfOrderPayloadStillYieldsTheEarliestOpen() {
    // Nothing guarantees Yahoo orders the windows, and `min` over the futures
    // is the answer whatever order they arrive in — not "whichever field is
    // checked first". Here `post` starts before `pre`.
    let scrambled = period(pre: (900, 1000), regular: (500, 600), post: (300, 400))
    #expect(scrambled.nextSessionOpenEpoch(after: 100) == 300)
}

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
