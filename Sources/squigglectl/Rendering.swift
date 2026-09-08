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
          squigglectl doctor

        EXAMPLES
          squigglectl quote AAPL --raw
          squigglectl watch AAPL MSFT --cycles 4
          squigglectl search berkshire hathaway --limit 5
          squigglectl doctor

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

    /// Which check produced a result, in words. `CheckID` itself is only a
    /// code — `TickerCore` vends no user-facing strings — so this is the one
    /// place that code becomes a label a person reads.
    public static func describe(_ id: CheckID) -> String {
        switch id {
        case .quoteEndpoint:  return "quote endpoint"
        case .searchEndpoint: return "search endpoint"
        case .tradingPeriods: return "trading calendar"
        case .storeFile:      return "settings file"
        case .storeSchema:    return "settings file version"
        case .setAsideFiles:  return "earlier unreadable settings files"
        case .cooldown:       return "backoff"
        case .budget:         return "daily request estimate"
        }
    }

    /// A short mark for `doctor`'s per-line status, e.g. `"[ok]  quote
    /// endpoint"`. The four must read differently at a glance — that is what
    /// `RenderingTests.theFourStatusesReadDifferently` pins.
    public static func mark(_ status: CheckStatus) -> String {
        switch status {
        case .ok:       return "ok"
        case .degraded: return "warn"
        case .broken:   return "FAIL"
        case .skipped:  return "skip"
        }
    }

    /// One line of `doctor`'s output: a mark, the check's label, and an
    /// optional detail. Every detail reaching this function must already be
    /// safe to paste into a support email (R44) — no quote values, no file
    /// contents, no URLs with query strings, no absolute filesystem paths —
    /// which is why `DoctorRun` only ever passes it text built from
    /// `Rendering.diagnosis(_:)` or another already-redacted source.
    public static func checkLine(_ check: Check, detail: String? = nil) -> String {
        let head = "[\(mark(check.status))]  \(describe(check.id))"
        guard let detail, !detail.isEmpty else { return head }
        return "\(head) — \(detail)"
    }

    /// The market session `doctor`'s trading-calendar check resolved, if any.
    public static func describe(_ state: MarketState) -> String {
        switch state {
        case .pre:     return "pre-market"
        case .regular: return "regular session"
        case .post:    return "post-market"
        case .closed:  return "closed"
        }
    }

    /// `WatchLoop`'s live diagnostic line (spec §7): tokens available, both
    /// circuit states, and the ladder's remaining cooldown. Printed after
    /// every event rather than persisted — this state lives only in the
    /// running process's memory, and the store file must stay safe to email.
    public static func stateLine(_ snapshot: FeedEngine.DiagnosticSnapshot) -> String {
        let tokens = String(format: "%.1f", snapshot.tokensAvailable)
        let cooldown = Int(snapshot.cooldownRemainingSeconds.rounded(.up))
        return "tokens \(tokens)  network \(describe(snapshot.networkCircuit))"
            + "  contract \(describe(snapshot.contractCircuit))  cooldown \(cooldown)s"
    }

    private static func describe(_ state: CircuitState) -> String {
        switch state {
        case .closed:   return "closed"
        case .open:     return "open"
        case .halfOpen: return "half-open"
        }
    }
}
