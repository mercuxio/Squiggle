import Foundation
import TickerCore

/// Every string a human reads from this tool. `TickerCore` has none — its own
/// doc comment on `TickerError` says wording lives in the caller, and this is
/// that caller.
public enum Rendering {
    public static let usage = """
        squigglectl — diagnostics for Squiggle

        USAGE
          squigglectl quote <symbol> [--raw]
          squigglectl watch [SYMBOL...] [--interval N] [--cycles N]
          squigglectl search <QUERY...> [--limit N]

        EXAMPLES
          squigglectl quote AAPL --raw
          squigglectl watch AAPL MSFT --cycles 4
          squigglectl search berkshire hathaway --limit 5

        OPTIONS
          --raw        print the response body exactly as received
          --interval N between 60 and 900 seconds between refresh cycles (default 180);
                       out-of-range values are clamped to the nearest bound, not refused
          --cycles N   stop after N fetches instead of running until interrupted
          --limit N    at most N search results (default 10, max 20)
        """

    /// One line per quote, for `squigglectl watch`'s running log.
    public static func line(_ quote: Quote) -> String {
        var text = "\(quote.symbol.raw)  \(quote.price)"
        if let currency = quote.currency {
            text += " \(currency)"
        }
        if let changePercent = quote.changePercent {
            let glyph = quote.direction.glyph
            let sign = changePercent > 0 ? "+" : ""
            text += "  \(glyph) \(sign)\(String(format: "%.2f", changePercent))%"
        }
        return text
    }

    /// One line per search result, for `squigglectl search`'s output.
    public static func render(_ results: [SearchResult]) -> String {
        guard !results.isEmpty else { return "no matches" }
        // Pad to the widest symbol so the names line up. The picker in plan 2
        // uses a real table; this is the terminal's version of the same idea.
        let width = results.map(\.symbol.raw.count).max() ?? 0
        return results.map { result in
            let padded = result.symbol.raw.padding(toLength: width, withPad: " ", startingAt: 0)
            let suffix = result.exchange.isEmpty ? "" : "  (\(result.exchange))"
            return "\(padded)  \(result.name)\(suffix)"
        }.joined(separator: "\n")
    }

    /// Turns a failure into a line a person reads. `TickerError` itself
    /// carries no such wording by design, so this is the one place
    /// `squigglectl watch` (and eventually `doctor`) does that translation.
    public static func diagnosis(_ error: TickerError) -> String {
        switch error {
        case .invalidSymbol(let raw):
            return "not a usable symbol: \(raw)"
        case .offline:
            return "offline"
        case .transport(let detail):
            return "transport error: \(detail)"
        case .rateLimited(let retryAfterSeconds):
            if let retryAfterSeconds {
                return "rate limited, retry after \(Int(retryAfterSeconds))s"
            }
            return "rate limited"
        case .serverError(let status):
            return "server error (\(status))"
        case .unauthorized(let status):
            return "unauthorized (\(status))"
        case .symbolNotFound(let symbol):
            return "\(symbol.raw): not found"
        case .emptyBody:
            return "empty response body"
        case .notJSON:
            return "response was not JSON"
        case .noResult:
            return "no result in the response"
        case .missingField(let path):
            return "missing field: \(path)"
        case .wrongType(let path, let expected):
            return "wrong type at \(path), expected \(expected)"
        case .nonFiniteNumber(let path):
            return "non-finite number at \(path)"
        case .negativeValue(let path, let value):
            return "negative value at \(path): \(value)"
        case .storeSchemaUnsupported(let version):
            return "store schema \(version) is not supported by this version"
        case .storeVersionUnreadable:
            return "store schema version could not be read"
        case .storeCorrupt(let quarantinedAt):
            return "store file was corrupt; moved aside to \(quarantinedAt.lastPathComponent)"
        case .storeQuarantineFailed(let url):
            return "store file at \(url.lastPathComponent) is corrupt and could not be moved aside"
        }
    }
}
