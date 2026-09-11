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
/// only needs to confirm no extra query-string machinery sneaks in.
///
/// A bare `=` is not itself that witness — `EURUSD=X` is a real symbol (see
/// the ground rules' verbatim-symbols list) and `captureLogLine` embeds
/// `symbol` in the command it renders, so a blanket `!text.contains("=")`
/// would fail on a scenario this function must handle correctly. `?` is what
/// a query string actually starts with, and nothing here ever embeds a URL
/// for one to hide in, so it is the witness that can tell the two apart.
@Test func captureLogLineAddsNoQueryStringOrExtraPunctuation() {
    let text = Rendering.captureLogLine(date: "2026-09-09", symbol: "AAPL", record: "regular-session",
                                        marketState: "closed",
                                        fileWritten: "Tests/Fixtures/yahoo-2026-09-09/regular-session.json")
    #expect(!text.contains("?"), "leaked a query string: \(text)")

    // The witness above must still hold for a symbol that legitimately
    // contains "=" — proving this isn't just a repeat of the AAPL case with
    // a weaker check.
    let withEqualsInSymbol = Rendering.captureLogLine(
        date: "2026-09-09", symbol: "EURUSD=X", record: "regular-session",
        marketState: "closed", fileWritten: "Tests/Fixtures/yahoo-2026-09-09/regular-session.json")
    #expect(withEqualsInSymbol.contains("EURUSD=X"))
    #expect(!withEqualsInSymbol.contains("?"), "leaked a query string: \(withEqualsInSymbol)")
}


// MARK: - F16: the number Task 19 Step 4 reads

/// Repository paths, for the two tests below. `#filePath` is the only fixed
/// point a test has — the same technique `Fixture` and `TickerCoreSource` use.
private enum RepositoryFile {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // squigglectlTests
        .deletingLastPathComponent()      // Tests
        .deletingLastPathComponent()      // repository root

    static func text(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

/// F16. Task 19 Step 4 asks what a real trading day cost, and the number it
/// reads now comes from `stateLine`. So the field has to be the argument and
/// not a constant, and it has to lead the line, because Step 4 reads it off
/// the log's last line by eye.
@Test func theStateLineReportsTheRequestCountItWasGivenAndLeadsWithIt() throws {
    let symbol = try #require(Symbol("AAPL"))
    let engine = FeedEngine(clock: SystemClock(), symbols: [symbol],
                            userIntervalSeconds: RateConstants.defaultRefreshInterval)
    let snapshot = engine.diagnosticSnapshot

    let fresh = Rendering.stateLine(snapshot, requests: 0)
    let spent = Rendering.stateLine(snapshot, requests: 1147)

    #expect(fresh.hasPrefix("requests 0 "))
    #expect(spent.hasPrefix("requests 1147 "))

    // The count is the parameter and nothing else: two different arguments
    // must not render the same line — which a hard-coded field, or one wired
    // to something else on the snapshot, would.
    #expect(fresh != spent)

    // And it is the only thing that differs. Step 4 reads one field off a line
    // that also carries tokens, both circuits and the cooldown; if the request
    // count perturbed any of those, the line would be reporting the counter
    // twice under different names.
    #expect(fresh.dropFirst("requests 0".count) == spent.dropFirst("requests 1147".count))
}

/// F16, the other half — and the half a test of `stateLine` alone cannot
/// reach. `WatchLoop.run()` builds a real `YahooClient`, so the loop itself
/// cannot be run in a test without opening a socket (R76), which leaves three
/// claims Step 4 depends on unwitnessed:
///
/// 1. the number is `fetches`, the counter the engine's `.fetch` arm
///    increments — a count of requests issued, not of lines printed;
/// 2. the state line is printed *last* in the iteration, which is the only
///    reason `tail -n 1` finds the total however the run ends; and
/// 3. Step 4 actually reads it, rather than going back to counting glyphs.
///
/// So they are checked against the source text, which is the same move
/// `PurityTests` makes for the import rule: a claim that lives only in prose
/// is the defect signature this review keeps finding. Comments are stripped
/// first, because both files discuss the old `grep -c` in prose.
@Test func theTradingDayCountIsTheFetchCounterPrintedLastAndReadFromTheLastLine() throws {
    let raw = try RepositoryFile.text("Sources/squigglectl/WatchLoop.swift")
    let source = raw.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.components(separatedBy: "//").first ?? "" }
        .joined(separator: "\n")

    let call = "log(Rendering.stateLine(engine.diagnosticSnapshot, requests: fetches))"
    let callRange = try #require(source.range(of: call))
    let loopStart = try #require(source.range(of: "while maxCycles"))
    // The first `return 0` *after* the loop starts is the loop's exit — the
    // earlier one in the file belongs to `Calendars.openness(.closed)`.
    let loopEnd = try #require(source.range(of: "return 0",
                                            range: loopStart.upperBound..<source.endIndex))

    // Inside the loop, not before it and not after it.
    #expect(loopStart.upperBound < callRange.lowerBound)
    #expect(callRange.upperBound < loopEnd.lowerBound)

    // Last thing the iteration prints. `tail -n 1` is only the total if
    // nothing else can be printed after it — a `log` moved below this line
    // would leave Step 4 reading a price.
    let afterTheCall = source[callRange.upperBound..<loopEnd.lowerBound]
    #expect(!afterTheCall.contains("log("), "something prints after the state line")

    // And the counter counts the request. `fetches += 1` sits in the `.fetch`
    // arm, ahead of the call that issues it, so a request that throws is
    // still counted — which is exactly what the glyph count missed.
    let fetchArm = try #require(source.range(of: "case .fetch"))
    let request = try #require(source.range(of: "client.snapshot(for: symbol)"))
    let increment = try #require(source.range(of: "fetches += 1"))
    #expect(fetchArm.upperBound < increment.lowerBound)
    #expect(increment.upperBound < request.lowerBound)
    #expect(source.components(separatedBy: "fetches += 1").count == 2,
            "the request counter is incremented in more than one place")

    // Step 4's own instruction. The prose above it explains the glyph count
    // it replaced, so the check is on the fenced commands the step tells a
    // human to run, not on its prose: exactly one, and it reads the last line.
    let plan = try RepositoryFile.text("docs/plans/2026-09-08-tickercore-and-cli.md")
    let stepStart = try #require(plan.range(of: "**Step 4: Count what it actually cost**"))
    let stepEnd = try #require(plan.range(of: "**Step 5: Write the log**"))
    let step = plan[stepStart.upperBound..<stepEnd.lowerBound]

    let fenced = step.components(separatedBy: "```")
        .enumerated().filter { $0.offset % 2 == 1 }.map { $0.element }
    #expect(fenced.count == 1, "Step 4 runs \(fenced.count) commands, not one")
    let command = try #require(fenced.first)
    #expect(command.contains("tail -n 1 docs/trading-day-$(date +%F).log"))
    #expect(!command.contains("grep"), "Step 4 is counting glyphs again: \(command)")

    // And the figure it tells a human to compare the count against is the
    // budget constant, not a number typed into prose that is free to drift
    // away from it. The plan writes it grouped, so the expectation groups it
    // the same way — a budget that stopped being four digits would fail here,
    // which is the right outcome: the step's two sentences would both need
    // rereading anyway.
    let budget = RateConstants.dailyRequestBudget
    let grouped = "\(budget / 1000),\(String(format: "%03d", budget % 1000))"
    #expect(step.contains("Expected: **under \(grouped)**"))
    #expect(step.contains("exceeds \(grouped)"))
}
