import Foundation
import Testing
@testable import TickerCore

/// Task 15 controller ruling R66: `Tests/Fixtures/yahoo-2026-09-08/search-apple.json`
/// was never captured — six attempts on 2026-09-08 all hit Yahoo's 429. This
/// reads a hand-written stand-in from `Tests/Fixtures/synthetic/` instead (see
/// that directory's README). Repoint this at `Fixtures/yahoo-2026-09-08/` once
/// a real capture lands.
private func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // TickerCoreTests
        .deletingLastPathComponent()      // Tests
        .appendingPathComponent("Fixtures/synthetic/\(name)")
    return try Data(contentsOf: url)
}

private let appleFixtureName = "search-apple-SYNTHETIC.json"

@Test func theAppleSearchFixtureDecodesToUsableResults() throws {
    let results = try YahooSearchDecoding.results(from: fixture(appleFixtureName), limit: 10)
    #expect(!results.isEmpty)
    let apple = try #require(results.first { $0.symbol.raw == "AAPL" })
    #expect(apple.name.contains("Apple"))
    #expect(!apple.exchange.isEmpty)
}

@Test func theLimitIsHonouredExactly() throws {
    // R68: the fixture carries more rows than the limit, so `<= 3` (which
    // also passes on zero results) would not have caught a decoder that
    // dropped everything. Assert the exact count.
    let results = try YahooSearchDecoding.results(from: fixture(appleFixtureName), limit: 3)
    #expect(results.count == 3)
}

@Test func aZeroOrNegativeLimitReturnsNothingRatherThanEverything() throws {
    #expect(try YahooSearchDecoding.results(from: fixture(appleFixtureName), limit: 0).isEmpty)
    #expect(try YahooSearchDecoding.results(from: fixture(appleFixtureName), limit: -1).isEmpty)
}

@Test func resultOrderFromTheFixtureIsPreservedExactly() throws {
    // F-6: renamed from `resultOrderFromYahooIsPreservedExactly` — this pins
    // the hand-written synthetic fixture's row order, not anything Yahoo
    // actually sent (see the file's own README), so the name should not
    // claim otherwise.
    //
    // R69: the fixture's rows are ordered neither alphabetically by symbol
    // (AAPL.MX and 3007.HK would sort elsewhere) nor by name (APPLE INC /
    // Apple Hospitality / Apple Inc. would reorder under either
    // case-sensitive or case-insensitive comparison). A decoder that resorts
    // the rows in any of those ways fails this exact-sequence assertion,
    // which the original prefix-vs-prefix comparison could not have caught.
    let all = try YahooSearchDecoding.results(from: fixture(appleFixtureName), limit: 50)
    #expect(all.map(\.symbol.raw) == ["AAPL", "APLE", "AAPL.MX", "APRU", "3007.HK", "aAPL-wt"])
}

@Test func aSymbolWithSignificantCaseSurvivesDecodingByteForByte() throws {
    // F-6: a witness for "never upper-case, trim or normalise a symbol" —
    // the fixture's `aAPL-wt` row has mixed case that a `.uppercased()` (or
    // any other normalisation) slipped into the decoder would silently
    // rewrite. Assert survival, not just presence: finding a row named
    // "case-significance witness" but reading its symbol as `AAPL-WT` would
    // mean this test still passed by accident.
    let all = try YahooSearchDecoding.results(from: fixture(appleFixtureName), limit: 50)
    let witness = try #require(all.first { $0.name.contains("case-significance witness") })
    #expect(witness.symbol.raw == "aAPL-wt")
}

@Test func aLowerLimitReturnsAPrefixOfTheUnlimitedResults() throws {
    // The property the original test actually exercised: truncating to a
    // smaller limit does not change the order of the rows that remain.
    let all = try YahooSearchDecoding.results(from: fixture(appleFixtureName), limit: 50)
    let firstThree = try YahooSearchDecoding.results(from: fixture(appleFixtureName), limit: 3)
    #expect(Array(all.prefix(3)) == firstThree)
}

@Test func aQueryWithNoMatchesIsAnEmptyListAndNotAnError() throws {
    // Spec §7: an empty result is a normal outcome the picker shows as
    // "no matches", not a failure the user has to interpret.
    let json = Data(#"{"quotes":[],"news":[]}"#.utf8)
    #expect(try YahooSearchDecoding.results(from: json, limit: 10).isEmpty)
}

@Test func aMissingQuotesArrayIsTreatedAsNoMatches() throws {
    #expect(try YahooSearchDecoding.results(from: Data("{}".utf8), limit: 10).isEmpty)
}

@Test func entriesWithoutAUsableSymbolAreSkippedNotFatal() throws {
    // Yahoo's search index carries non-tradeable rows — indices, currencies,
    // and occasionally entries with no symbol at all. One bad row must not
    // cost the user the other nine good ones.
    let json = Data("""
    {"quotes":[
      {"shortname":"No symbol here","exchDisp":"NASDAQ"},
      {"symbol":"","shortname":"Empty","exchDisp":"NASDAQ"},
      {"symbol":"bad/symbol","shortname":"Slashes","exchDisp":"NASDAQ"},
      {"symbol":"MSFT","shortname":"Microsoft Corporation","exchDisp":"NASDAQ","quoteType":"EQUITY"}
    ]}
    """.utf8)
    let results = try YahooSearchDecoding.results(from: json, limit: 10)
    #expect(results.map(\.symbol.raw) == ["MSFT"])
}

@Test func longnameIsUsedWhenShortnameIsAbsent() throws {
    let json = Data("""
    {"quotes":[{"symbol":"BRK-B","longname":"Berkshire Hathaway Inc. New","exchDisp":"NYSE"}]}
    """.utf8)
    let results = try YahooSearchDecoding.results(from: json, limit: 10)
    #expect(results.first?.name == "Berkshire Hathaway Inc. New")
}

@Test func aResultWithNoNameAtAllFallsBackToItsSymbol() throws {
    // Better a row reading "XYZ  —  NASDAQ" than a blank line the user
    // cannot tell apart from a rendering bug.
    let json = Data(#"{"quotes":[{"symbol":"XYZ","exchDisp":"NASDAQ"}]}"#.utf8)
    #expect(try YahooSearchDecoding.results(from: json, limit: 10).first?.name == "XYZ")
}

@Test func missingExchangeAndKindDegradeToEmptyStringsRatherThanFailing() throws {
    let json = Data(#"{"quotes":[{"symbol":"XYZ","shortname":"Some Co"}]}"#.utf8)
    let result = try #require(try YahooSearchDecoding.results(from: json, limit: 10).first)
    #expect(result.exchange.isEmpty)
    #expect(result.kind.isEmpty)
}

@Test func searchDecodingRejectsNonJsonWithTheSameErrorAsQuoteDecoding() throws {
    // Consistency matters: `doctor` (Task 17) classifies faults by error case,
    // and a search failure that reported something different would be
    // diagnosed wrongly.
    #expect(throws: TickerError.notJSON) {
        try YahooSearchDecoding.results(from: Data("<html>429</html>".utf8), limit: 10)
    }
}

/// F-1: the search and quote decoders must answer the *same* error case for
/// zero bytes, not merely "search happens to throw `.emptyBody`" — a check
/// that would still pass if the quote decoder's behaviour later drifted. So
/// this pins the two against each other, not each against a hardcoded case.
@Test func emptyBodyProducesTheSameErrorCaseAsTheQuoteDecoder() throws {
    let aapl = try #require(Symbol("AAPL"))

    var searchError: TickerError?
    do {
        _ = try YahooSearchDecoding.results(from: Data(), limit: 10)
    } catch let error as TickerError {
        searchError = error
    }

    var quoteError: TickerError?
    do {
        _ = try YahooQuoteDecoding.quote(from: Data(), symbol: aapl)
    } catch let error as TickerError {
        quoteError = error
    }

    let search = try #require(searchError)
    let quote = try #require(quoteError)
    #expect(search == quote)
    #expect(search == TickerError.emptyBody)
}

@Test func searchDecodingSurvivesEveryTruncationOfTheFixture() throws {
    // A connection cut mid-body must throw, never crash. Same shape as
    // `everyTruncatedPrefixOfEveryFixtureThrowsRatherThanTraps` in
    // `TruncationTests.swift`, which is the template this follows: every
    // truncation either throws a `TickerError` or succeeds, and never crashes
    // or throws anything else.
    //
    // Succeeding on a prefix is expected, not a failure to record. This
    // decoder is deliberately lenient — a body cut before `quotes` decodes to
    // an empty list rather than faulting — so a great many prefixes here
    // legitimately return `[]`.
    //
    // Every length is sampled. Task 6 thins to every 17th byte past the first
    // 512 because its fixtures are large; this one is under 1KB and the whole
    // sweep runs in 0.007s, so there is nothing to thin.
    let data = try fixture(appleFixtureName)
    for length in 0..<data.count {
        do {
            _ = try YahooSearchDecoding.results(from: Data(data.prefix(length)), limit: 10)
        } catch is TickerError {
            // Expected: a truncated body is a contract fault, not a crash.
        } catch {
            Issue.record("prefix length \(length) threw an untyped error: \(error)")
        }
    }
}
