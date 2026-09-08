import Testing
import TickerCore
@testable import squigglectl

@Test func quoteTakesASymbolAndOptionalRawFlag() throws {
    let parsed = try Command.parse(["quote", "AAPL"])
    #expect(parsed == .quote(symbol: "AAPL", raw: false, json: false))

    let rawForm = try Command.parse(["quote", "^GSPC", "--raw"])
    #expect(rawForm == .quote(symbol: "^GSPC", raw: true, json: false))
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
