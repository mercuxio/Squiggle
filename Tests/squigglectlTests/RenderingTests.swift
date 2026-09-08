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

