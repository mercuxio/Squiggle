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

@Test func aSymbolRoundTripsThroughJSONAsAPlainString() throws {
    let symbol = try #require(Symbol("^GSPC"))
    let data = try JSONEncoder().encode([symbol])
    #expect(String(decoding: data, as: UTF8.self) == "[\"^GSPC\"]")
    let back = try JSONDecoder().decode([Symbol].self, from: data)
    #expect(back == [symbol])
}
