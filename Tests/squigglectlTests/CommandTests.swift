import Testing
import TickerCore
@testable import squigglectl

@Test func quoteTakesASymbolAndOptionalRawFlag() throws {
    let parsed = try Command.parse(["quote", "AAPL"])
    #expect(parsed == .quote(symbol: "AAPL", raw: false))

    let rawForm = try Command.parse(["quote", "^GSPC", "--raw"])
    #expect(rawForm == .quote(symbol: "^GSPC", raw: true))
}

@Test func quoteWithoutASymbolIsAParseError() {
    #expect(throws: ParseError.self) { try Command.parse(["quote"]) }
}

@Test func anUnknownSubcommandIsAParseError() {
    #expect(throws: ParseError.self) { try Command.parse(["frobnicate"]) }
}

@Test func noArgumentsPrintsHelpRatherThanFailing() throws {
    let parsed = try Command.parse([])
    #expect(parsed == .help)
}

@Test func watchTakesSymbolsAndDefaultsIntervalAndCycles() throws {
    let aapl = try #require(Symbol("AAPL"))
    let msft = try #require(Symbol("MSFT"))
    let parsed = try Command.parse(["watch", "AAPL", "MSFT"])
    #expect(parsed == .watch(symbols: [aapl, msft],
                             intervalSeconds: RateConstants.defaultRefreshInterval,
                             maxCycles: nil))
}

@Test func watchWithNoSymbolsParsesToAnEmptyListForMainToFallBackOn() throws {
    // `Command.parse` touches no filesystem (see its own doc comment), so an
    // empty watchlist-fallback list is `main.swift`'s job, not this parser's.
    // This just confirms parsing bare `watch` doesn't fail outright.
    let parsed = try Command.parse(["watch"])
    #expect(parsed == .watch(symbols: [], intervalSeconds: RateConstants.defaultRefreshInterval,
                             maxCycles: nil))
}

@Test func watchClampsAnIntervalBelowTheOfferedRangeUpToTheMinimum() throws {
    let aapl = try #require(Symbol("AAPL"))
    let parsed = try Command.parse(["watch", "AAPL", "--interval", "10"])
    #expect(parsed == .watch(symbols: [aapl], intervalSeconds: 60, maxCycles: nil))
}

@Test func watchClampsAnIntervalAboveTheOfferedRangeDownToTheMaximum() throws {
    let aapl = try #require(Symbol("AAPL"))
    let parsed = try Command.parse(["watch", "AAPL", "--interval", "7200"])
    #expect(parsed == .watch(symbols: [aapl], intervalSeconds: 900, maxCycles: nil))
}

@Test func watchRejectsANonNumericInterval() {
    #expect(throws: ParseError.self) {
        try Command.parse(["watch", "AAPL", "--interval", "soon"])
    }
}

@Test func watchParsesAPositiveCycleCount() throws {
    let aapl = try #require(Symbol("AAPL"))
    let parsed = try Command.parse(["watch", "AAPL", "--cycles", "4"])
    #expect(parsed == .watch(symbols: [aapl], intervalSeconds: RateConstants.defaultRefreshInterval,
                             maxCycles: 4))
}

@Test func watchRejectsAZeroOrNegativeCycleCount() {
    #expect(throws: ParseError.self) { try Command.parse(["watch", "AAPL", "--cycles", "0"]) }
    #expect(throws: ParseError.self) { try Command.parse(["watch", "AAPL", "--cycles", "-1"]) }
}

@Test func watchRejectsANonNumericCycleCount() {
    #expect(throws: ParseError.self) {
        try Command.parse(["watch", "AAPL", "--cycles", "soon"])
    }
}

@Test func watchRejectsATokenThatIsNotAUsableSymbol() {
    // A "/" cannot appear in a symbol (Symbol.init rejects it — it's a URL
    // path separator), so this is deliberately not a mistyped ticker.
    #expect(throws: ParseError.self) { try Command.parse(["watch", "AA/PL"]) }
}

@Test func searchTakesAMultiWordQueryWithoutQuoting() throws {
    let parsed = try Command.parse(["search", "berkshire", "hathaway"])
    #expect(parsed == .search(query: "berkshire hathaway", limit: 10))
}

@Test func searchAcceptsALimitAnywhereInTheArguments() throws {
    let leading = try Command.parse(["search", "--limit", "3", "apple"])
    #expect(leading == .search(query: "apple", limit: 3))

    let trailing = try Command.parse(["search", "apple", "--limit", "3"])
    #expect(trailing == .search(query: "apple", limit: 3))
}

@Test func theLimitIsCappedSoOneCommandCannotBecomeALargeRequest() throws {
    let parsed = try Command.parse(["search", "apple", "--limit", "5000"])
    #expect(parsed == .search(query: "apple", limit: RateConstants.maxSearchResultCount))
}

@Test func aNonNumericOrZeroLimitIsRejectedWithAMessage() {
    #expect(throws: ParseError.self) { try Command.parse(["search", "apple", "--limit", "lots"]) }
    #expect(throws: ParseError.self) { try Command.parse(["search", "apple", "--limit", "0"]) }
    #expect(throws: ParseError.self) { try Command.parse(["search", "apple", "--limit"]) }
}

@Test func searchWithNothingToSearchForIsRejected() {
    #expect(throws: ParseError.self) { try Command.parse(["search"]) }
    #expect(throws: ParseError.self) { try Command.parse(["search", "--limit", "5"]) }
}

/// F-5: `quote --json AAPL` used to silently treat `--json` as the symbol
/// (R64 removed the flag from the parser but nothing rejected it). An
/// unrecognised `--flag` is a user error, wherever it appears.
@Test func quoteRejectsAnUnknownFlagRatherThanTreatingItAsTheSymbol() {
    #expect(throws: ParseError.self) { try Command.parse(["quote", "--json", "AAPL"]) }
    #expect(throws: ParseError.self) { try Command.parse(["quote", "AAPL", "--json"]) }
}

/// F-5: an unrecognised `--flag` used to silently join the search query
/// instead of being reported as a mistake.
@Test func searchRejectsAnUnknownFlagRatherThanJoiningItIntoTheQuery() {
    #expect(throws: ParseError.self) { try Command.parse(["search", "--bogus", "apple"]) }
    #expect(throws: ParseError.self) { try Command.parse(["search", "apple", "--bogus"]) }
}

@Test func usageMentionsEveryVerbTheToolAccepts() {
    // A verb that works but is undocumented is a verb nobody uses.
    for verb in ["quote", "watch", "search"] {
        #expect(Rendering.usage.contains("squigglectl \(verb)"))
    }
}
