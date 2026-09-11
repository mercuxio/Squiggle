import Foundation
import Testing
@testable import TickerCore

@Test func symbolsAreStoredExactlyAsYahooSpellsThem() throws {
    // Every one of these is a real Yahoo symbol whose punctuation or case is
    // load-bearing. Normalising any of them makes the request 404.
    for raw in ["AAPL", "^GSPC", "BRK-B", "VOD.L", "BTC-USD", "EURUSD=X"] {
        let symbol = try #require(Symbol(raw))
        #expect(symbol.raw == raw)
    }
}

@Test func lowercaseIsNotUppercased() throws {
    // Yahoo does accept "aapl", but round-tripping a symbol through the store
    // must return what the user typed. Upper-casing here would silently
    // rewrite a saved watchlist on first load.
    let symbol = try #require(Symbol("aapl"))
    #expect(symbol.raw == "aapl")
}

@Test func emptyAndWhitespaceOnlySymbolsAreRejected() {
    #expect(Symbol("") == nil)
    #expect(Symbol("   ") == nil)
    #expect(Symbol("\n") == nil)
}

@Test func symbolsWithControlCharactersOrSlashesAreRejected() {
    // Not politeness: these would be pasted straight into a URL path.
    #expect(Symbol("AA\u{0}PL") == nil)
    #expect(Symbol("../../etc/passwd") == nil)
    #expect(Symbol("A A") == nil)
}

@Test func theBareTraversalNamesAreRejectedAndNoOtherDotIs() throws {
    // The initialiser's comment claimed it screened for traversal; the
    // forbidden set had no `.` in it, so `"."` and `".."` were valid symbols.
    // A symbol is interpolated into a request path
    // (`/v8/finance/chart/<symbol>`) and stored in the user's file, and
    // `symbolsWithControlCharactersOrSlashesAreRejected` above only ever
    // caught `"../../etc/passwd"` by its slashes.
    #expect(Symbol(".") == nil)
    #expect(Symbol("..") == nil)

    // And nothing wider than that. A dot inside a symbol is part of the
    // identifier — these are the exchange suffixes Yahoo actually spells —
    // so the fix must not cost a single real instrument.
    for raw in ["VOD.L", "BMW.DE", "0700.HK", "A.B.C", ".L", "X.", "...", "^GSPC",
                "BRK-B", "BTC-USD", "EURUSD=X"] {
        #expect(try #require(Symbol(raw)).raw == raw)
    }
}

@Test func aSymbolRoundTripsThroughJSONAsAPlainString() throws {
    let symbol = try #require(Symbol("^GSPC"))
    let data = try JSONEncoder().encode([symbol])
    #expect(String(decoding: data, as: UTF8.self) == "[\"^GSPC\"]")
    let back = try JSONDecoder().decode([Symbol].self, from: data)
    #expect(back == [symbol])
}
