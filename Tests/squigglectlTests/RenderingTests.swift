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
