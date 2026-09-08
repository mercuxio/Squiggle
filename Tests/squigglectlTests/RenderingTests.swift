import Foundation
import Testing
import TickerCore
@testable import squigglectl

/// `Rendering.diagnosis(_:)`'s own doc comment calls it the one place
/// `squigglectl watch` (and eventually `doctor`) translates a `TickerError`
/// into a line a person reads — and that output must be safe to paste into a
/// support email: no absolute filesystem paths.

@Test func aQuarantinedStoreReportsOnlyItsLastPathComponent() throws {
    let url = URL(fileURLWithPath: "/Users/example/Library/Application Support/Squiggle/watchlist.json")
    let text = Rendering.diagnosis(.storeCorrupt(quarantinedAt: url))
    #expect(!text.contains("/"), "leaked an absolute path: \(text)")
    #expect(text.contains("watchlist.json"))
}

/// Finding 3 (fix round 1): `.storeQuarantineFailed` rendered `url.path`
/// verbatim — a full absolute path through the user's home directory —
/// unlike its sibling case `.storeCorrupt` immediately above it, which
/// already redacts to `.lastPathComponent`. Asserted the same way: absence
/// of any `/`, which `url.path` could never pass.
@Test func aStoreThatCouldNotBeQuarantinedReportsOnlyItsLastPathComponent() throws {
    let url = URL(fileURLWithPath: "/Users/example/Library/Application Support/Squiggle/watchlist.json")
    let text = Rendering.diagnosis(.storeQuarantineFailed(at: url))
    #expect(!text.contains("/"), "leaked an absolute path: \(text)")
    #expect(text.contains("watchlist.json"))
}

/// F-1 (fix round 2): `.transport` carried a `String`, and four call sites
/// across two modules filled it with `String(describing: error)`. `URLError`'s
/// description prints its `userInfo`, which is where URLSession puts the
/// failing URL — query string and all, under both `NSErrorFailingURLKey` and
/// `NSErrorFailingURLStringKey`. `doctor` printed that line verbatim, and a
/// timeout is the single most common way this app fails, so it is the line a
/// user is most likely to paste into a support email.
///
/// Asserted the way the two path cases above are: on characters the leak
/// cannot avoid. `?` and `=` are better witnesses than the URL itself — they
/// catch any query string, not only the one this test happens to build.
@Test func aTimedOutRequestReportsItsCodeAndNoURL() throws {
    let url = try #require(URL(string:
        "https://query1.finance.yahoo.com/v1/finance/search?q=apple&quotesCount=20"))
    let underlying = URLError(.timedOut, userInfo: [
        NSURLErrorFailingURLErrorKey: url,
        // Spelled out rather than via `NSURLErrorFailingURLStringErrorKey`,
        // which is deprecated as of macOS 15.4 but is still the key URLSession
        // populates and still the second copy of the URL in the dictionary.
        "NSErrorFailingURLStringKey": url.absoluteString,
        NSLocalizedDescriptionKey: "The request timed out.",
    ])
    let text = Rendering.diagnosis(.transport(Rendering.transportFault(for: underlying)))
    #expect(!text.contains("?"), "leaked a query string: \(text)")
    #expect(!text.contains("="), "leaked a query string: \(text)")
    #expect(!text.contains("/"), "leaked a URL: \(text)")
    #expect(!text.contains("yahoo"), "leaked a host: \(text)")
    // Still worth reading: a support reader needs "timed out" rather than
    // "cannot find host", and the number identifies the code exactly.
    #expect(text.contains("timed out"))
    #expect(text.contains("-1001"))
}

/// The companion to the case above: an error this program does not recognise
/// contributes nothing but the fact that it happened. Nothing here is known to
/// be safe to print, so nothing is.
@Test func anUnrecognisedTransportFailureSaysSoAndNothingElse() {
    struct Chatty: Error, CustomStringConvertible {
        var description: String { "/Users/example/secret?token=abc123" }
    }
    let text = Rendering.diagnosis(.transport(Rendering.transportFault(for: Chatty())))
    #expect(!text.contains("/"), "leaked a path: \(text)")
    #expect(!text.contains("token"), "leaked a credential: \(text)")
}

/// An unlisted `URLError` code must still arrive with its number rather than
/// being dropped: the wording table is an allowlist of codes, not of errors.
@Test func anUnlistedURLErrorCodeStillReportsItsNumber() {
    let text = Rendering.diagnosis(.transport(.urlSession(code: -1234)))
    #expect(text.contains("-1234"))
}

/// F-6: `Rendering.render(_:)` for search results had no tests at all.
@Test func renderingNoSearchResultsSaysSo() {
    #expect(Rendering.render([]) == "no matches")
}

@Test func renderingOneSearchResultShowsSymbolNameAndExchange() throws {
    let symbol = try #require(Symbol("AAPL"))
    let result = SearchResult(symbol: symbol, name: "Apple Inc.", exchange: "NASDAQ", kind: "EQUITY")
    #expect(Rendering.render([result]) == "AAPL  Apple Inc.  (NASDAQ)")
}

@Test func renderingOmitsTheExchangeSuffixWhenExchangeIsEmpty() throws {
    let symbol = try #require(Symbol("XYZ"))
    let result = SearchResult(symbol: symbol, name: "Some Co", exchange: "", kind: "")
    #expect(Rendering.render([result]) == "XYZ  Some Co")
}

@Test func renderingPadsSymbolsToTheWidestOneAndJoinsWithNewlines() throws {
    let v = try #require(Symbol("V"))
    let aapl = try #require(Symbol("AAPL"))
    let results = [
        SearchResult(symbol: v, name: "Vee Corp", exchange: "", kind: ""),
        SearchResult(symbol: aapl, name: "Apple Inc.", exchange: "NASDAQ", kind: "EQUITY"),
    ]
    // "V" is padded out to the width of "AAPL" (4) before the two-space
    // separator, so the names line up in a monospaced terminal.
    #expect(Rendering.render(results) == "V     Vee Corp\nAAPL  Apple Inc.  (NASDAQ)")
}

@Test func everyCheckHasWordingAndNoneIsBlank() {
    // A check that prints an empty label looks like a rendering bug to the
    // one person least able to diagnose it.
    for id in CheckID.allCases {
        #expect(!Rendering.describe(id).isEmpty)
    }
}

@Test func theFourStatusesReadDifferently() {
    let marks = [CheckStatus.ok, .degraded, .broken, .skipped].map(Rendering.mark)
    #expect(Set(marks).count == 4)
}

// MARK: - probe (Task 18)

@Test func probeReportWithNoChangesSaysSo() {
    #expect(Rendering.probeReport(breaking: [], informational: []) == "no shape change detected")
}

@Test func probeReportListsBreakingChangesUnderTheirOwnHeadingAndMarksEachLine() {
    let breaking: [ShapeChange] = [
        .missing(path: "chart.result[].meta.regularMarketPrice", wasType: .number),
    ]
    let text = Rendering.probeReport(breaking: breaking, informational: [])
    #expect(text.contains("BREAKING"))
    #expect(text.contains("[BREAKING]"))
    #expect(text.contains("chart.result[].meta.regularMarketPrice"))
    #expect(text.contains("(was number)"))
    #expect(!text.contains("informational"))
}

@Test func probeReportListsInformationalChangesUnderTheirOwnHeading() {
    let informational: [ShapeChange] = [
        .added(path: "chart.result[].meta.gmtoffset", type: .number),
    ]
    let text = Rendering.probeReport(breaking: [], informational: informational)
    #expect(text.contains("informational"))
    #expect(text.contains("added: chart.result[].meta.gmtoffset (number)"))
    #expect(!text.contains("BREAKING"))
}

/// Both sections appear together, breaking first, separated by a blank line
/// — so a reader scanning top-down sees the changes that matter before the
/// ones that don't.
@Test func probeReportPutsBreakingChangesBeforeInformationalOnes() throws {
    let breaking: [ShapeChange] = [
        .missing(path: "chart.result[].meta.regularMarketPrice", wasType: .number),
    ]
    let informational: [ShapeChange] = [
        .added(path: "chart.result[].meta.gmtoffset", type: .number),
    ]
    let text = Rendering.probeReport(breaking: breaking, informational: informational)
    let breakingRange = try #require(text.range(of: "BREAKING"))
    let informationalRange = try #require(text.range(of: "informational"))
    #expect(breakingRange.lowerBound < informationalRange.lowerBound)
}

/// R44: every `ShapeChange` line is a JSON key path and a type name, never a
/// value — so a report built from arbitrary paths must never contain a `/`,
/// a `?`, or a `=`, the same witnesses `aTimedOutRequestReportsItsCodeAndNoURL`
/// uses above for the transport path.
@Test func probeReportLinesCarryNoPathsOrQueryStrings() {
    let changes: [ShapeChange] = [
        .missing(path: "chart.result[].meta.regularMarketPrice", wasType: .number),
        .added(path: "chart.result[].meta.gmtoffset", type: .number),
        .typeChanged(path: "chart.result[].meta.currency", from: .string, to: .number),
    ]
    let text = Rendering.probeReport(breaking: [changes[0]], informational: [changes[1], changes[2]])
    #expect(!text.contains("/"), "leaked a path or URL: \(text)")
    #expect(!text.contains("?"), "leaked a query string: \(text)")
    #expect(!text.contains("="), "leaked a query string: \(text)")
}

@Test func probeRefusesExistingFixtureFileNamesTheFileAndExplainsWhy() {
    let text = Rendering.probeRefusesExistingFixtureFile("Tests/Fixtures/yahoo-2026-09-08/regular-session.json")
    #expect(text.contains("Tests/Fixtures/yahoo-2026-09-08/regular-session.json"))
    #expect(text.contains("already recorded"))
}

@Test func probeRecordedFixtureNamesTheFileWritten() {
    let text = Rendering.probeRecordedFixture("Tests/Fixtures/yahoo-2026-09-09/regular-session.json")
    #expect(text.contains("Tests/Fixtures/yahoo-2026-09-09/regular-session.json"))
}

@Test func captureLogLineIsAMarkdownBulletCarryingDateSymbolRecordStateAndFile() {
    let text = Rendering.captureLogLine(date: "2026-09-09", symbol: "AAPL", record: "regular-session",
                                        marketState: "regular session",
                                        fileWritten: "Tests/Fixtures/yahoo-2026-09-09/regular-session.json")
    #expect(text.hasPrefix("- 2026-09-09:"))
    #expect(text.contains("AAPL"))
    #expect(text.contains("--record regular-session"))
    #expect(text.contains("regular session"))
    #expect(text.contains("Tests/Fixtures/yahoo-2026-09-09/regular-session.json"))
}

/// R44 also governs the line `probe --record` appends to
/// `docs/fixture-capture-log.md` — ruling for this task is explicit that this
/// log line is covered by the same rule as every other `squigglectl` output.
/// `fileWritten` here stands in for what could be an absolute path if a
/// caller ever passed one by mistake; the rendering itself adds nothing that
/// could turn a clean repository-relative path into an unsafe line, so this
/// only needs to confirm no extra `?`/`=` machinery sneaks in.
@Test func captureLogLineAddsNoQueryStringOrExtraPunctuation() {
    let text = Rendering.captureLogLine(date: "2026-09-09", symbol: "AAPL", record: "regular-session",
                                        marketState: "closed",
                                        fileWritten: "Tests/Fixtures/yahoo-2026-09-09/regular-session.json")
    #expect(!text.contains("?"))
    #expect(!text.contains("="))
}

