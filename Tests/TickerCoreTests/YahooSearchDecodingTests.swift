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
    // R68: the fixture carries five rows, strictly more than the limit, so
    // `<= 3` (which also passes on zero results) would not have caught a
    // decoder that dropped everything. Assert the exact count.
    let results = try YahooSearchDecoding.results(from: fixture(appleFixtureName), limit: 3)
    #expect(results.count == 3)
}

@Test func aZeroOrNegativeLimitReturnsNothingRatherThanEverything() throws {
    #expect(try YahooSearchDecoding.results(from: fixture(appleFixtureName), limit: 0).isEmpty)
    #expect(try YahooSearchDecoding.results(from: fixture(appleFixtureName), limit: -1).isEmpty)
}

@Test func resultOrderFromYahooIsPreservedExactly() throws {
    // R69: the synthetic fixture's rows are ordered neither alphabetically by
    // symbol (AAPL.MX and 3007.HK would sort elsewhere) nor by name (APPLE
    // INC / Apple Hospitality / Apple Inc. would reorder under either
    // case-sensitive or case-insensitive comparison). A decoder that resorts
    // the rows in any of those ways fails this exact-sequence assertion,
    // which the original prefix-vs-prefix comparison could not have caught.
    let all = try YahooSearchDecoding.results(from: fixture(appleFixtureName), limit: 50)
    #expect(all.map(\.symbol.raw) == ["AAPL", "APLE", "AAPL.MX", "APRU", "3007.HK"])
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

@Test func searchDecodingSurvivesEveryTruncationOfTheFixture() throws {
    // Same fuzz as Task 6: a connection cut mid-body must throw, never crash.
    let data = try fixture(appleFixtureName)
    for length in stride(from: 0, to: data.count, by: 7) {
        _ = try? YahooSearchDecoding.results(from: Data(data.prefix(length)), limit: 10)
    }
}
