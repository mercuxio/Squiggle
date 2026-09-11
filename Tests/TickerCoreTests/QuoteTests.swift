import Foundation
import Testing
@testable import TickerCore

/// `Quote`'s derived fields — `change`, `changePercent` and `direction` — are
/// computed once in the initialiser so that no call site can reintroduce the
/// division. That makes the initialiser the only place the rule can be stated,
/// and the only place it can be broken.

@Test func aPreviousCloseThatIsNotPositiveIsNotABaseToMeasureAgainst() {
    // The guard read `base != 0`, which is the zero half of the rule and not
    // the sign half. A negative base divides perfectly well and produces a
    // percentage pointing the opposite way from the change it came from.
    let symbol = Symbol("AAPL")!
    for base in [-5.0, -0.01, 0.0, -1_000.0] {
        let quote = Quote(symbol: symbol, shortName: nil, price: 10, previousClose: base,
                          currency: "USD", asOfEpoch: nil)
        #expect(quote.direction == .unknown, "previousClose \(base) was treated as a base")
        #expect(quote.change == nil)
        #expect(quote.changePercent == nil)
        // The price itself is never in doubt — an unusable base costs the
        // comparison, not the quote.
        #expect(quote.price == 10)
    }
}

@Test func aChangeAndItsPercentageAlwaysPointTheSameWay() {
    // The property the sign guard exists to preserve, swept rather than
    // asserted at one point: with `price: 10, previousClose: -5` the delta is
    // +15 and `direction` is `.up`, while `delta / base * 100` is -300, so the
    // renderer produced "▲ -300.00%" — two numbers that contradict each other
    // on the same line.
    let symbol = Symbol("AAPL")!
    for base in [0.01, 1, 5, 10, 250.75, 1_000] as [Double] {
        for price in [0, 0.5, 10, 999.5] as [Double] {
            let quote = Quote(symbol: symbol, shortName: nil, price: price, previousClose: base,
                              currency: "USD", asOfEpoch: nil)
            let label = "price \(price) against base \(base)"
            guard let change = quote.change, let percent = quote.changePercent else {
                Issue.record("\(label): a usable base produced no comparison")
                continue
            }
            #expect(change.sign == percent.sign, "\(label): \(change) vs \(percent)%")
            switch quote.direction {
            case .up: #expect(percent > 0, "\(label): ▲ on \(percent)%")
            case .down: #expect(percent < 0, "\(label): ▼ on \(percent)%")
            case .flat: #expect(percent == 0, "\(label): flat on \(percent)%")
            case .unknown: Issue.record("\(label): a usable base yielded no direction")
            }
        }
    }
}

@Test func aNegativePreviousCloseArrivesFromTheWireAndNotOnlyFromThisTest() throws {
    // Reachability, so the guard above is not defending against a case only a
    // test can construct. The decoder rejects a negative *price*
    // (`TickerError.negativeValue`) and has never checked the base, so a body
    // carrying `chartPreviousClose: -5` parses and reaches `Quote`.
    let json = """
        {"chart":{"result":[{"meta":{
          "regularMarketPrice":10.0,
          "chartPreviousClose":-5.0,
          "currency":"USD",
          "symbol":"NEW"
        }}],"error":null}}
        """
    let quote = try YahooQuoteDecoding.quote(from: Data(json.utf8),
                                             symbol: try #require(Symbol("NEW")))
    #expect(quote.previousClose == -5)
    #expect(quote.direction == .unknown)
    #expect(quote.changePercent == nil)
}
