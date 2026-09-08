import Testing
import Foundation
@testable import TickerCore

/// Rewrite one key path in a JSON object tree.
/// Returns nil when the path does not exist in this fixture.
private func mutate(
    _ data: Data,
    at path: [String],
    to replacement: Any?
) throws -> Data? {
    guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }

    func rewrite(_ container: Any, _ remaining: ArraySlice<String>) -> Any? {
        guard let key = remaining.first else { return nil }
        if var dictionary = container as? [String: Any] {
            guard dictionary.keys.contains(key) else { return nil }
            if remaining.count == 1 {
                if let replacement { dictionary[key] = replacement }
                else { dictionary.removeValue(forKey: key) }
                return dictionary
            }
            guard let child = rewrite(dictionary[key]!, remaining.dropFirst()) else { return nil }
            dictionary[key] = child
            return dictionary
        }
        if var array = container as? [Any], let index = Int(key), array.indices.contains(index) {
            if remaining.count == 1 {
                if let replacement { array[index] = replacement } else { array.remove(at: index) }
                return array
            }
            guard let child = rewrite(array[index], remaining.dropFirst()) else { return nil }
            array[index] = child
            return array
        }
        return nil
    }

    guard let rewritten = rewrite(root, path[...]) as? [String: Any] else { return nil }
    root = rewritten
    return try JSONSerialization.data(withJSONObject: root)
}

/// Every field the decoder reads, by path from the document root.
///
/// Not `private`: Task 18 cross-checks this against `ShapeDigest.readPaths`,
/// which spells the same fact differently. Change one and that test tells you
/// to change the other.
let readFields: [[String]] = [
    ["chart"],
    ["chart", "result"],
    ["chart", "result", "0"],
    ["chart", "result", "0", "meta"],
    ["chart", "result", "0", "meta", "regularMarketPrice"],
    ["chart", "result", "0", "meta", "chartPreviousClose"],
    ["chart", "result", "0", "meta", "previousClose"],
    ["chart", "result", "0", "meta", "shortName"],
    ["chart", "result", "0", "meta", "currency"],
    ["chart", "result", "0", "meta", "exchangeTimezoneName"],
    ["chart", "result", "0", "meta", "regularMarketTime"],
    ["chart", "result", "0", "meta", "currentTradingPeriod"],
]

/// The shapes an upstream change actually takes.
private nonisolated(unsafe) let mutations: [(name: String, value: Any?)] = [
    ("missing", nil),
    ("null", NSNull()),
    ("wrong-type-string", "banana"),
    ("wrong-type-object", ["unexpected": 1]),
    ("wrong-type-array", [1, 2, 3]),
    ("nan", "NaN"),
    ("infinity", "inf"),
    ("negative", -1),
    ("zero", 0),
    ("huge", 1e308),
]

@Test func everyMutationOfEveryReadFieldIsHandledOrRejected() throws {
    let symbol = try #require(Symbol("AAPL"))
    let original = try Fixture.data("regular-session.json")
    var exercised = 0

    for field in readFields {
        for mutation in mutations {
            guard let mutated = try mutate(original, at: field, to: mutation.value) else {
                continue  // this fixture does not carry that path; nothing to test
            }
            exercised += 1
            let label = "\(field.joined(separator: ".")) → \(mutation.name)"

            do {
                let quote = try YahooQuoteDecoding.quote(from: mutated, symbol: symbol)
                // Parsing is allowed to succeed — but only into a quote that is
                // internally honest. This is the assertion that catches a
                // plausible-but-wrong number.
                #expect(quote.price.isFinite, "\(label): non-finite price survived")
                #expect(quote.price >= 0, "\(label): negative price survived")
                if let percent = quote.changePercent {
                    #expect(percent.isFinite, "\(label): non-finite change percent survived")
                }
                if quote.change == nil {
                    #expect(quote.direction == .unknown,
                            "\(label): a direction was claimed with no change to justify it")
                }
                if mutation.name == "zero", field.last == "chartPreviousClose" {
                    #expect(quote.direction == .unknown, "\(label): divided by a zero close")
                }
            } catch is TickerError {
                // A typed error is the other acceptable outcome.
            } catch {
                Issue.record("\(label): threw an untyped \(type(of: error)): \(error)")
            }
        }
    }

    // If the fixture stops carrying these paths, the loop above silently tests
    // nothing. Pin the fact that it did real work.
    #expect(exercised > 40, "only \(exercised) mutations were exercised")
}

@Test func aMutatedPriceNeverSilentlyBecomesZero() throws {
    let symbol = try #require(Symbol("AAPL"))
    let original = try Fixture.data("regular-session.json")
    let path = ["chart", "result", "0", "meta", "regularMarketPrice"]

    for mutation in [("missing", nil as Any?), ("null", NSNull()), ("wrong-type", "banana")] {
        let mutated = try #require(try mutate(original, at: path, to: mutation.1))
        #expect(throws: TickerError.self, "\(mutation.0) price should throw") {
            try YahooQuoteDecoding.quote(from: mutated, symbol: symbol)
        }
    }
}
