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

@Test func aNonUSDListingKeepsItsOwnCurrencyExactlyAsSpelled() throws {
    let symbol = try #require(Symbol("VOD.L"))
    let quote = try YahooQuoteDecoding.quote(from: Fixture.data("non-usd-listing.json"), symbol: symbol)

    // The assertion is the *case*, not merely the difference. This fixture's
    // currency is `GBp` — pence, one hundredth of `GBP` — so upper-casing it
    // does not tidy a string, it multiplies the displayed unit by a hundred.
    // The rule this project states is that a currency code is never
    // upper-cased and never validated against ISO 4217; `GBp` is the reason
    // the rule exists and this is the only test that witnesses it.
    //
    // It used to read `quote.currency != "USD"`, which a decoder ending in
    // `.uppercased()` passes with "GBP" — and nothing else in the suite would
    // have noticed either, since every other currency assertion is against
    // "USD", which is its own upper-casing.
    #expect(quote.currency == "GBp")
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
    // `text/html`, not JSON. A parser that assumes a JSON body on error
    // throws the wrong error — and the wrong error means the wrong backoff
    // ladder.
    //
    // This file is the *reconstruction*, 17 bytes, with the trailing CRLF
    // stripped. The 19-byte figure a comment here used to quote belongs to
    // `429-body-live.txt`, the bytes Yahoo actually sent, which
    // `theLiveRateLimitBodyDecodesTheSameWayAsTheReconstruction` below loads
    // and pins. Both sizes are asserted rather than described, because the
    // whole point of keeping two files is that they differ.
    #expect(try Fixture.data("429-body.html").count == 17)
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

@Test func theUnauthorizedBodyIsAContractFaultAndNotAClassification() throws {
    // `401-body.json` had no test at all, while its marker file claimed its
    // "only job is to prove the parser classifies a 401 body as
    // `unauthorized`". The parser cannot do that and never could: nothing in
    // this body says 401. `TickerError.unauthorized(status:)` is raised by
    // `YahooClient` from the HTTP status line, before a byte of the body is
    // decoded, and it carries the status *number* — which only the response
    // knows.
    //
    // What the fixture does witness is why that ordering is not an
    // implementation detail. Handed to the decoder, this body is well-formed
    // JSON with no `chart` key, so it comes back as a contract fault — and a
    // contract fault opens a circuit whose threshold is 1 and whose cooldown
    // is an hour, on the theory that the endpoint's shape has changed for
    // every symbol at once. A 401 is not a shape change; it is a credential
    // problem that backoff cannot fix. Decoding first would file one as the
    // other.
    let data = try Fixture.data("401-body.json")

    // Well-formed JSON, so `.notJSON` is not what is being witnessed here.
    #expect(throws: Never.self) {
        try JSONSerialization.jsonObject(with: data)
    }

    let symbol = try #require(Symbol("AAPL"))
    var caughtError: TickerError?
    do {
        _ = try YahooQuoteDecoding.quote(from: data, symbol: symbol)
    } catch let error as TickerError {
        caughtError = error
    }
    let error = try #require(caughtError)
    #expect(error == .missingField(path: "chart"))
    #expect(error.isContractFault)
    #expect(FailureKind(error) == .contractFault)

    // And the classification it must *not* collide with. `unauthorized`
    // carries a status; a decoder has no status to carry.
    #expect(FailureKind(error) != .unauthorized)
}

@Test func anEmptyBodyIsItsOwnError() throws {
    let symbol = try #require(Symbol("AAPL"))
    #expect(throws: TickerError.emptyBody) {
        try YahooQuoteDecoding.quote(from: Data(), symbol: symbol)
    }
}

@Test func oneBodyYieldsBothTheQuoteAndTheCalendar() throws {
    // Spec §3.2: asking a second endpoint for the calendar would double the
    // app's share of the daily budget. R122 moved this decode into the core so
    // the app gets it without depending on `YahooClient`.
    let data = try Fixture.data("regular-session.json")
    let symbol = try #require(Symbol("AAPL"))

    let snapshot = try YahooQuoteDecoding.snapshot(from: data, symbol: symbol)
    #expect(snapshot.quote.symbol == symbol)
    #expect(snapshot.tradingPeriod != nil)
}

@Test func aBodyWithNoUsableCalendarStillYieldsItsQuote() throws {
    // The calendar is a bonus fact the body happens to carry, not a promise.
    // An instrument whose `tradingPeriods` Yahoo has not sent this session must
    // not cost the user a perfectly good price.
    let data = try Fixture.data("crypto.json")
    let symbol = try #require(Symbol("BTC-USD"))

    let snapshot = try YahooQuoteDecoding.snapshot(from: data, symbol: symbol)
    #expect(snapshot.quote.price > 0)
}
