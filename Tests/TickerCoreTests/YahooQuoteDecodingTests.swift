import Testing
import Foundation
@testable import TickerCore

enum Fixture {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // TickerCoreTests
        .deletingLastPathComponent()      // Tests
        .appendingPathComponent("Fixtures/yahoo-2026-09-08")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }
}

@Test func theRegularSessionFixtureParses() throws {
    let symbol = try #require(Symbol("AAPL"))
    let quote = try YahooQuoteDecoding.quote(from: Fixture.data("regular-session.json"), symbol: symbol)

    #expect(quote.symbol == symbol)
    #expect(quote.price > 0)
    #expect(quote.currency == "USD")
    #expect(quote.shortName != nil)
    // Direction must agree with the arithmetic, whichever way the day went.
    let change = try #require(quote.change)
    switch quote.direction {
    case .up:      #expect(change > 0)
    case .down:    #expect(change < 0)
    case .flat:    #expect(change == 0)
    case .unknown: Issue.record("a regular-session fixture should have a previous close")
    }
}

@Test func everyCapturedInstrumentKindParses() throws {
    // Indices, ETFs, currency pairs, crypto and a non-USD listing all come
    // back through the same endpoint. If any of them needed special handling,
    // this is where it would show up.
    for (name, raw) in [
        ("index.json", "^GSPC"),
        ("etf.json", "SPY"),
        ("currency-pair.json", "EURUSD=X"),
        ("crypto.json", "BTC-USD"),
        ("non-usd-listing.json", "VOD.L"),
    ] {
        let symbol = try #require(Symbol(raw))
        let quote = try YahooQuoteDecoding.quote(from: Fixture.data(name), symbol: symbol)
        #expect(quote.price > 0, "\(raw) produced no price")
    }
}

@Test func aNonUSDListingKeepsItsOwnCurrency() throws {
    let symbol = try #require(Symbol("VOD.L"))
    let quote = try YahooQuoteDecoding.quote(from: Fixture.data("non-usd-listing.json"), symbol: symbol)
    #expect(quote.currency != "USD")
}

@Test func aZeroPreviousCloseYieldsUnknownRatherThanInfinity() throws {
    // The newly-listed case. Dividing by zero here would render "+Inf%" in a
    // 10pt slot in the menu bar (spec §5.3).
    let json = """
        {"chart":{"result":[{"meta":{
          "regularMarketPrice":42.0,
          "chartPreviousClose":0,
          "currency":"USD",
          "symbol":"NEW"
        }}],"error":null}}
        """
    let symbol = try #require(Symbol("NEW"))
    let quote = try YahooQuoteDecoding.quote(from: Data(json.utf8), symbol: symbol)
    #expect(quote.direction == .unknown)
    #expect(quote.changePercent == nil)
    #expect(quote.price == 42.0)
}

@Test func aMissingPreviousCloseYieldsUnknownButKeepsThePrice() throws {
    let json = """
        {"chart":{"result":[{"meta":{"regularMarketPrice":42.0,"currency":"USD"}}],"error":null}}
        """
    let symbol = try #require(Symbol("NEW"))
    let quote = try YahooQuoteDecoding.quote(from: Data(json.utf8), symbol: symbol)
    #expect(quote.direction == .unknown)
    #expect(quote.change == nil)
    #expect(quote.price == 42.0)
}

@Test func aMissingPriceIsAnErrorAndNeverAZero() throws {
    // `regularMarketPrice` decodes as REQUIRED. A price defaulting to 0 is the
    // exact class of silent wrong answer spec §8.2 names.
    let json = """
        {"chart":{"result":[{"meta":{"chartPreviousClose":10.0,"currency":"USD"}}],"error":null}}
        """
    let symbol = try #require(Symbol("AAPL"))
    #expect(throws: TickerError.self) {
        try YahooQuoteDecoding.quote(from: Data(json.utf8), symbol: symbol)
    }
}

@Test func anEmptyResultArrayIsNoResultNotACrash() throws {
    let json = "{\"chart\":{\"result\":[],\"error\":null}}"
    let symbol = try #require(Symbol("AAPL"))
    #expect(throws: TickerError.noResult) {
        try YahooQuoteDecoding.quote(from: Data(json.utf8), symbol: symbol)
    }
}

@Test func theRateLimitBodyIsNotMistakenForJSON() throws {
    // Observed 2026-09-08: `text/html`, 19 bytes, not JSON. A parser that
    // assumes a JSON body on error throws the wrong error — and the wrong
    // error means the wrong backoff ladder.
    let symbol = try #require(Symbol("AAPL"))
    var caughtError: TickerError?
    do {
        try YahooQuoteDecoding.quote(from: try Fixture.data("429-body.html"), symbol: symbol)
    } catch let error as TickerError {
        caughtError = error
    }
    let error = try #require(caughtError)
    #expect(error == .notJSON)
}

@Test func theLiveRateLimitBodyDecodesTheSameWayAsTheReconstruction() throws {
    // Captured live 2026-09-08 on the fourth 429 of the day. The
    // reconstruction in `429-body.html` strips the trailing CRLF; this file
    // is the bytes Yahoo actually sent, terminator and all. Both must reach
    // `.notJSON` — a decoder that trims whitespace before deciding "is this
    // JSON?" would pass on one and could still surprise us on the other.
    let symbol = try #require(Symbol("AAPL"))
    let live = try Fixture.data("429-body-live.txt")
    #expect(live.count == 19)
    var caughtError: TickerError?
    do {
        try YahooQuoteDecoding.quote(from: live, symbol: symbol)
    } catch let error as TickerError {
        caughtError = error
    }
    let error = try #require(caughtError)
    #expect(error == .notJSON)
}

@Test func anEmptyBodyIsItsOwnError() throws {
    let symbol = try #require(Symbol("AAPL"))
    #expect(throws: TickerError.emptyBody) {
        try YahooQuoteDecoding.quote(from: Data(), symbol: symbol)
    }
}
