import Foundation

/// A number as Yahoo variously spells it.
///
/// Observed 2026-09-08: the same payload carries bare numbers
/// (`regularMarketPrice`), numeric strings, and `{raw:, fmt:}` objects
/// depending on the field and the endpoint. `fmt` is a localised display
/// string — "1.23B" — and is never read.
///
/// Everything else throws. There is deliberately no fallback to zero: a field
/// that quietly becomes 0 produces a plausible wrong price, which is the one
/// failure mode this app must not have.
public struct LenientDouble: Decodable, Sendable, Equatable {
    public let value: Double

    private enum ObjectKeys: String, CodingKey { case raw }

    public init(from decoder: Decoder) throws {
        let path = decoder.codingPath.map(\.stringValue).joined(separator: ".")

        if let single = try? decoder.singleValueContainer(), !single.decodeNil() {
            if let number = try? single.decode(Double.self) {
                try LenientDouble.requireFinite(number, path: path)
                self.value = number
                return
            }
            if let text = try? single.decode(String.self) {
                guard let number = Double(text) else {
                    throw TickerError.wrongType(path: path, expected: "number")
                }
                try LenientDouble.requireFinite(number, path: path)
                self.value = number
                return
            }
        }

        let object = try decoder.container(keyedBy: ObjectKeys.self)
        let nested = try object.decode(LenientDouble.self, forKey: .raw)
        self.value = nested.value
    }

    private static func requireFinite(_ number: Double, path: String) throws {
        guard number.isFinite else { throw TickerError.nonFiniteNumber(path: path) }
    }
}
