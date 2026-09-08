import Foundation
import Testing
import TickerCore
@testable import squigglectl

// F-5 (fix round 2): `evaluateTradingPeriods` and `classifyStoreError` were
// `private static`, so the only way to reach either was to run `DoctorRun.run()`
// — which opens two network connections. Both are pure functions of their
// argument, and neither had a single test. Widening them to the target's own
// scope (not `public`: nothing outside `squigglectl` has any business calling
// them) is what makes the behaviour below assertable without a request.
//
// `DoctorRun.run()` itself is still untested here. It reaches its client
// through a concrete `YahooClient` rather than an abstraction, so exercising it
// means talking to Yahoo; that restructuring is explicitly out of scope for
// this round.

// MARK: - evaluateTradingPeriods

/// Windows built relative to the wall clock, because `evaluateTradingPeriods`
/// reads `Date()` itself. `offsets` are seconds from now.
private func window(_ from: Double, _ to: Double) -> TradingPeriod.Window {
    let now = Date().timeIntervalSince1970
    return TradingPeriod.Window(startEpoch: now + from, endEpoch: now + to)
}

@Test func aResponseWithNoTradingCalendarIsDegradedRatherThanSilent() {
    let (absent, absentDetail) = DoctorRun.evaluateTradingPeriods(nil)
    #expect(absent == .degraded)
    #expect(absentDetail == "no trading calendar in this response")

    // Present but empty is the same condition wearing a different shape: a
    // `TradingPeriod` whose three windows are all nil says nothing at all.
    let empty = TradingPeriod(pre: nil, regular: nil, post: nil)
    let (emptyStatus, emptyDetail) = DoctorRun.evaluateTradingPeriods(empty)
    #expect(emptyStatus == .degraded)
    #expect(emptyDetail == "no trading calendar in this response")
}

@Test func aDegenerateOrInvertedWindowIsReportedAsInconsistent() {
    // Yahoo emits `start == end` on some holidays, and `Window.contains`
    // answers false for every epoch when it does — a window that contains
    // nothing is not a calendar this check can vouch for.
    let degenerate = TradingPeriod(pre: nil, regular: window(0, 0), post: nil)
    let (degenerateStatus, degenerateDetail) = DoctorRun.evaluateTradingPeriods(degenerate)
    #expect(degenerateStatus == .degraded)
    #expect(degenerateDetail == "trading calendar windows are inconsistent")

    let inverted = TradingPeriod(pre: nil, regular: window(3_600, -3_600), post: nil)
    let (invertedStatus, _) = DoctorRun.evaluateTradingPeriods(inverted)
    #expect(invertedStatus == .degraded)
}

@Test func sessionsOutOfChronologicalOrderAreReportedAsInconsistent() {
    // Pre-market running past the opening bell is not a schedule any venue
    // keeps; it means the payload's fields were mismatched.
    let overlapping = TradingPeriod(pre: window(-7_200, 1_800),
                                    regular: window(-3_600, 3_600),
                                    post: window(3_600, 7_200))
    let (status, detail) = DoctorRun.evaluateTradingPeriods(overlapping)
    #expect(status == .degraded)
    #expect(detail == "trading calendar windows are inconsistent")
}

@Test func sessionsThatTouchExactlyAreAcceptedBecauseWindowsAreHalfOpen() {
    // `Window.contains` is `[start, end)`, so pre ending at the same instant
    // regular begins is the *normal* shape of a trading day, not an overlap:
    // the opening bell belongs to exactly one session. Rejecting it would
    // report every ordinary day as inconsistent.
    let touching = TradingPeriod(pre: window(-7_200, -3_600),
                                 regular: window(-3_600, 3_600),
                                 post: window(3_600, 7_200))
    let (status, _) = DoctorRun.evaluateTradingPeriods(touching)
    #expect(status == .ok)
}

@Test func aConsistentCalendarReportsWhichSessionIsRunningNow() {
    let inRegular = TradingPeriod(pre: window(-7_200, -3_600),
                                  regular: window(-3_600, 3_600),
                                  post: window(3_600, 7_200))
    let (regularStatus, regularDetail) = DoctorRun.evaluateTradingPeriods(inRegular)
    #expect(regularStatus == .ok)
    #expect(regularDetail == Rendering.describe(.regular))

    let inPre = TradingPeriod(pre: window(-1_800, 1_800),
                              regular: window(1_800, 9_000),
                              post: window(9_000, 12_600))
    let (preStatus, preDetail) = DoctorRun.evaluateTradingPeriods(inPre)
    #expect(preStatus == .ok)
    #expect(preDetail == Rendering.describe(.pre))

    let inPost = TradingPeriod(pre: window(-12_600, -9_000),
                               regular: window(-9_000, -1_800),
                               post: window(-1_800, 1_800))
    let (postStatus, postDetail) = DoctorRun.evaluateTradingPeriods(inPost)
    #expect(postStatus == .ok)
    #expect(postDetail == Rendering.describe(.post))
}

@Test func aCalendarWhoseSessionsHaveAllPassedIsHealthyAndClosed() {
    // The check asks whether the calendar is coherent, not whether the market
    // happens to be open. Reporting an evening run as degraded would teach the
    // user to ignore the line.
    let allPast = TradingPeriod(pre: window(-25_200, -21_600),
                                regular: window(-21_600, -14_400),
                                post: window(-14_400, -7_200))
    let (status, detail) = DoctorRun.evaluateTradingPeriods(allPast)
    #expect(status == .ok)
    #expect(detail == Rendering.describe(.closed))
}

@Test func aCalendarWithOnlyOneSessionIsStillJudgedOnItsOwn() {
    // Crypto and some venues report a single window. One window cannot be out
    // of order with anything, so the only question left is whether it is
    // degenerate.
    let onlyRegular = TradingPeriod(pre: nil, regular: window(-3_600, 3_600), post: nil)
    let (status, detail) = DoctorRun.evaluateTradingPeriods(onlyRegular)
    #expect(status == .ok)
    #expect(detail == Rendering.describe(.regular))
}

// MARK: - classifyStoreError

@Test func anUnreadableSchemaBlamesTheSchemaAndNotTheFile() {
    // The bytes were read and parsed; it is the version inside them this build
    // cannot honour. Marking `storeFile` broken here would send the user
    // looking for disk trouble that does not exist.
    let unsupported = DoctorRun.classifyStoreError(.storeSchemaUnsupported(version: 99))
    #expect(unsupported.file == .ok)
    #expect(unsupported.schema == .degraded)

    let unreadable = DoctorRun.classifyStoreError(.storeVersionUnreadable)
    #expect(unreadable.file == .ok)
    #expect(unreadable.schema == .degraded)
}

@Test func aCorruptFileSkipsTheSchemaCheckItMadeUnanswerable() {
    // Nothing parsed, so there is no schema to have an opinion about. Skipped
    // rather than degraded: `Diagnosis.overall` ignores skips, and reporting
    // both lines as degraded would double-count one fault.
    let quarantined = URL(fileURLWithPath: "/Users/example/Library/Application Support/Squiggle/watchlist.json.bad-1")
    let corrupt = DoctorRun.classifyStoreError(.storeCorrupt(quarantinedAt: quarantined))
    #expect(corrupt.file == .degraded)
    #expect(corrupt.schema == .skipped)

    let stuck = DoctorRun.classifyStoreError(.storeQuarantineFailed(at: quarantined))
    #expect(stuck.file == .degraded)
    #expect(stuck.schema == .skipped)
}

@Test func aStoreFaultCarryingAPathPrintsTheNameAndNotTheLocation() {
    // R44: `doctor`'s output has to be safe to paste into a support email, and
    // a store path contains the user's account name. Both store errors that
    // carry a URL are checked here, because both are rendered by `DoctorRun`'s
    // store branch and either one leaking would be the same disclosure.
    let quarantined = URL(fileURLWithPath: "/Users/example/Library/Application Support/Squiggle/watchlist.json.bad-1")
    for error in [TickerError.storeCorrupt(quarantinedAt: quarantined),
                  TickerError.storeQuarantineFailed(at: quarantined)] {
        let rendered = Rendering.diagnosis(error)
        #expect(rendered.contains("watchlist.json.bad-1"))
        #expect(!rendered.contains("/"))
        #expect(!rendered.contains("example"))
    }
}

@Test func aFaultTheStoreCannotProduceIsStillClassifiedRatherThanCrashing() {
    // `FileWatchlistStore.load()` never throws a feed error, but the switch is
    // exhaustive rather than defaulted so a new `TickerError` case fails this
    // build. The arm still has to give a usable answer if one ever arrives:
    // the file line borrows `Diagnosis`'s own classification and the schema
    // line, which nothing has learned anything about, is skipped.
    let transport = DoctorRun.classifyStoreError(.transport(.urlSession(code: -1001)))
    #expect(transport.file == Diagnosis.status(for: .transport(.urlSession(code: -1001))))
    #expect(transport.schema == .skipped)

    let unauthorized = DoctorRun.classifyStoreError(.unauthorized(status: 401))
    #expect(unauthorized.file == .broken)
    #expect(unauthorized.schema == .skipped)
}
