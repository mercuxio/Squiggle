import Testing
import Foundation
@testable import TickerCore

@Test func everyTruncatedPrefixOfEveryFixtureThrowsRatherThanTraps() throws {
    // A crashing menu bar agent cannot be recovered without Terminal. A
    // truncated body is what a dropped connection mid-response looks like, and
    // it must be a typed error every single time.
    let symbol = try #require(Symbol("AAPL"))
    let names = ["regular-session.json", "index.json", "etf.json",
                 "currency-pair.json", "crypto.json", "non-usd-listing.json"]

    for name in names {
        let full = try Fixture.data(name)
        #expect(full.count > 100, "\(name) is suspiciously small")

        // Every prefix, thinned to keep the suite fast on large bodies: every
        // byte for the first 512, then every 17th. 17 is coprime with any
        // plausible token length, so the sampling does not align with the
        // payload's structure and skip a whole class of boundary.
        var lengths = Array(0..<min(512, full.count))
        lengths += stride(from: 512, to: full.count, by: 17)

        for length in lengths {
            let prefix = full.prefix(length)
            do {
                _ = try YahooQuoteDecoding.quote(from: Data(prefix), symbol: symbol)
                // Succeeding on a prefix is fine and even likely for a body
                // whose trailing fields are all optional.
            } catch is TickerError {
                // Expected.
            } catch {
                Issue.record("\(name) truncated to \(length): untyped \(type(of: error))")
            }
        }
    }
}

@Test func aTruncatedBodyNeverProducesAQuoteWithADishonestNumber() throws {
    let symbol = try #require(Symbol("AAPL"))
    let full = try Fixture.data("regular-session.json")

    for length in stride(from: 0, to: full.count, by: 7) {
        guard let quote = try? YahooQuoteDecoding.quote(
            from: Data(full.prefix(length)), symbol: symbol) else { continue }
        #expect(quote.price.isFinite && quote.price >= 0,
                "truncation to \(length) produced price \(quote.price)")
        if let percent = quote.changePercent {
            #expect(percent.isFinite, "truncation to \(length) produced \(percent)%")
        }
    }
}
