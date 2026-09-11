import Foundation

/// A Yahoo ticker symbol, exactly as Yahoo spells it.
///
/// Deliberately not normalised. `^GSPC`, `BRK-B`, `VOD.L`, `BTC-USD` and
/// `EURUSD=X` all carry punctuation that is part of the identifier, and
/// upper-casing a user's stored watchlist on load rewrites their file for no
/// benefit. The initialiser rejects only what cannot be a symbol at all.
public struct Symbol: Hashable, Sendable, Comparable {
    public let raw: String

    public init?(_ raw: String) {
        guard !raw.isEmpty, raw.count <= 32 else { return nil }
        // Anything that would need percent-encoding in a URL path segment, or
        // that could traverse it, is not a symbol.
        //
        // Traversal was the half of that sentence the code did not do. The
        // forbidden set below has no `.`, so `Symbol(".")` and `Symbol("..")`
        // were valid symbols, and a symbol is interpolated straight into a
        // request path — `YahooClient` builds `/v8/finance/chart/\(symbol.raw)`
        // — as well as being stored in the user's file. `"../../etc/passwd"` was
        // only ever rejected for its slashes.
        //
        // Rejected as whole strings and nothing more: a `.` inside a symbol is
        // part of the identifier for every exchange suffix Yahoo uses (`VOD.L`,
        // `BMW.DE`), and screening the character in general would reject real
        // instruments to fix a defect that only the two bare forms can cause.
        guard raw != ".", raw != ".." else { return nil }
        let forbidden = CharacterSet.whitespacesAndNewlines
            .union(.controlCharacters)
            .union(CharacterSet(charactersIn: "/?#%&+ "))
        guard raw.rangeOfCharacter(from: forbidden) == nil else { return nil }
        self.raw = raw
    }

    public static func < (lhs: Symbol, rhs: Symbol) -> Bool { lhs.raw < rhs.raw }
}

extension Symbol: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let symbol = Symbol(raw) else {
            throw TickerError.invalidSymbol(raw)
        }
        self = symbol
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}
