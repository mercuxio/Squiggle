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
          squigglectl probe <symbol> [--record NAME]

        EXAMPLES
          squigglectl quote AAPL --raw
          squigglectl watch AAPL MSFT --cycles 4
          squigglectl search berkshire hathaway --limit 5
          squigglectl doctor
          squigglectl probe AAPL --record regular-session

        OPTIONS
          --raw        print the response body exactly as received
          --interval N between 60 and 900 seconds between refresh cycles (default 180);
                       out-of-range values are clamped to the nearest bound, not refused
          --cycles N   stop after N fetches instead of running until interrupted
          --limit N    at most N search results (default 10, max 20)
          --record NAME (probe only) capture a fresh fixture as NAME.json instead
                       of diffing against the recorded one; NAME is lowercase
                       letters, digits and hyphens only; refuses if that file
                       already exists for today
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
        case .transport(let fault):
            return "transport error: \(describe(fault))"
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
            // Covers both ways this case arises — a corrupt file that could not
            // be moved aside, and a file that could not be read at all (see
            // `FileWatchlistStore.readIfPresent`). What the user needs from
            // either is the same: the file is unusable and it is still there,
            // so the next launch will hit it again.
            return "store file at \(url.lastPathComponent) is unusable and is still where it was"
        }
    }

    /// The only place `squigglectl` turns a caught `Error` into a
    /// `TransportFault`, and so the only place it decides what a transport
    /// failure is allowed to say about itself.
    ///
    /// A `URLError` contributes its code and nothing else. Everything else
    /// contributes nothing at all: an error this program does not recognise is
    /// an error whose description it cannot vouch for, and `doctor`'s output
    /// has to be safe to paste into a support email (R44). Kept next to
    /// `describe(_ fault:)` below so the two halves of that vocabulary — what
    /// may enter it, and what it may print — cannot drift apart.
    public static func transportFault(for error: any Error) -> TransportFault {
        guard let urlError = error as? URLError else { return .unrecognized }
        return .urlSession(code: urlError.code.rawValue)
    }

    /// The user-facing half of `TransportFault`, and the whole of R44's
    /// guarantee for the transport path.
    ///
    /// The wording for a `URLError` is written here rather than taken from the
    /// error, because neither of the two obvious sources is safe or useful:
    ///
    /// - `error.localizedDescription` reads `NSLocalizedDescription` out of the
    ///   very `userInfo` dictionary that carries the failing URL. It is a
    ///   string the transport layer composed, not one derived from the code,
    ///   so nothing in this package bounds what it may contain — certificate
    ///   failures, for one, name the server they were talking to.
    /// - Rebuilding it from the code alone does not work: measured on this
    ///   machine, `URLError(URLError.Code(rawValue: -1001)).localizedDescription`
    ///   is "The operation couldn't be completed. (NSURLErrorDomain error
    ///   -1001.)" — the generic `NSError` fallback, which says no more than
    ///   printing the number does.
    ///
    /// So the table below is squigglectl's own, which is where every word a
    /// human reads belongs anyway. It answers the question that actually
    /// matters to a support reader — "timed out" versus "cannot find host" —
    /// for the failures this client can produce, and an unlisted code still
    /// arrives with its number. It is an allowlist of codes, not a filter over
    /// a rendered string: a filter would be a blocklist, and a blocklist fails
    /// open on the one shape nobody anticipated, which is the shape that
    /// matters.
    ///
    /// `URLError.Code` is Foundation's, not one of this project's own enums,
    /// so a `default:` is the right shape here — a new URLSession code must
    /// not fail this build.
    private static func describe(_ fault: TransportFault) -> String {
        switch fault {
        case .malformedRequestURL:
            return "bad URL"
        case .nonHTTPResponse:
            return "non-HTTP response"
        case .urlSession(let code):
            return "\(wording(forURLErrorCode: code)) (URLError \(code))"
        case .unrecognized:
            return "an unrecognised failure"
        }
    }

    private static func wording(forURLErrorCode code: Int) -> String {
        switch URLError.Code(rawValue: code) {
        case .timedOut:                     return "the request timed out"
        case .cannotFindHost:               return "the host could not be found"
        case .cannotConnectToHost:          return "the host refused the connection"
        case .networkConnectionLost:        return "the network connection was lost"
        case .dnsLookupFailed:              return "the DNS lookup failed"
        case .notConnectedToInternet:       return "there is no internet connection"
        // `YahooClient` turns off expensive and constrained network access, so
        // this one is reachable on a tethered or metered connection and is not
        // a fault at all — a price is not worth a roaming charge.
        case .dataNotAllowed:               return "this network is not allowed for background data"
        case .internationalRoamingOff:      return "data roaming is off"
        case .secureConnectionFailed:       return "the secure connection failed"
        case .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid: return "the server's certificate was rejected"
        case .badServerResponse:            return "the server's response could not be read"
        case .cancelled:                    return "the request was cancelled"
        default:                            return "the connection failed"
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

    /// `WatchLoop`'s live diagnostic line (spec §7): the requests spent so far,
    /// tokens available, both circuit states, and the ladder's remaining
    /// cooldown. Printed after every event rather than persisted — this state
    /// lives only in the running process's memory, and the store file must
    /// stay safe to email.
    ///
    /// `requests` leads the line, and it is `WatchLoop`'s own fetch counter —
    /// the one the engine's `.fetch` arm increments, so it counts requests
    /// issued and not lines printed. Task 19 Step 4's question is "what did the
    /// day actually cost", and it used to be answered by
    /// `grep -c '▲\|▼\|–'` over the log: that counts *glyphs*, so it missed
    /// every failed request (which prints a diagnosis, not an arrow), counted
    /// nothing at all for a symbol whose direction was `.unknown`, and would
    /// have counted a `–` appearing in any other line. The measurement the
    /// whole design exists to control cannot be a side effect of how prices
    /// happen to render. Because this line is printed last in every loop
    /// iteration, the running total is on the log's final line, and Step 4
    /// reads it there.
    public static func stateLine(_ snapshot: FeedEngine.DiagnosticSnapshot,
                                 requests: Int) -> String {
        let tokens = String(format: "%.1f", snapshot.tokensAvailable)
        let cooldown = Int(snapshot.cooldownRemainingSeconds.rounded(.up))
        return "requests \(requests)  tokens \(tokens)"
            + "  network \(describe(snapshot.networkCircuit))"
            + "  contract \(describe(snapshot.contractCircuit))  cooldown \(cooldown)s"
    }

    private static func describe(_ state: CircuitState) -> String {
        switch state {
        case .closed:   return "closed"
        case .open:     return "open"
        case .halfOpen: return "half-open"
        }
    }

    /// `squigglectl probe`'s diff report. Breaking changes
    /// (`ShapeChange.breaksSquiggle`) are what would actually stop Squiggle
    /// working, so they print first and are marked; everything else follows
    /// under a heading that says plainly it is informational, so a reader
    /// never has to guess which lines demand action.
    ///
    /// Every line here is a JSON key path and a type name — never a value —
    /// so this stays safe to paste into a support email (R44), the same
    /// promise `checkLine(_:detail:)` makes for `doctor`.
    public static func probeReport(breaking: [ShapeChange], informational: [ShapeChange]) -> String {
        guard !breaking.isEmpty || !informational.isEmpty else {
            return "no shape change detected"
        }

        var lines: [String] = []
        if !breaking.isEmpty {
            lines.append("BREAKING — Squiggle depends on these:")
            lines.append(contentsOf: breaking.map { "  [BREAKING] \(describe($0))" })
        }
        if !informational.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("informational — Squiggle does not read these:")
            lines.append(contentsOf: informational.map { "  \(describe($0))" })
        }
        return lines.joined(separator: "\n")
    }

    /// One line per `ShapeChange`. Path and type names only — see
    /// `probeReport(breaking:informational:)`'s own note on R44.
    private static func describe(_ change: ShapeChange) -> String {
        switch change {
        case .missing(let path, let wasType):
            return "missing: \(path) (was \(wasType.rawValue))"
        case .added(let path, let type):
            return "added: \(path) (\(type.rawValue))"
        case .typeChanged(let path, let from, let to):
            return "type changed: \(path) (\(from.rawValue) → \(to.rawValue))"
        }
    }

    /// `probe --record`'s refusal when the named fixture file already
    /// exists for today. `file` is repository-relative (`Tests/Fixtures/
    /// yahoo-<date>/<name>.json`), never an absolute filesystem path, to
    /// keep this safe under R44.
    public static func probeRefusesExistingFixtureFile(_ file: String) -> String {
        "refusing to overwrite \(file) — a fixture is already recorded there; " +
            "a captured fixture is evidence and is never replaced in place"
    }

    /// `probe --record`'s refusal when the fixture corpus is not where the
    /// capture would be written. Names the repository-relative directory it
    /// looked for and nothing about this process's own location — an absolute
    /// path here would be an R44 leak, and printing "I am standing in X" is
    /// also the one thing that tempts a reader into treating a wrong X as a
    /// place to create the tree.
    public static func probeRefusesMissingFixturesRoot() -> String {
        "refusing to record: Tests/Fixtures is not a directory here — " +
            "`--record` writes a live response and must be run from the repository root, " +
            "so that the capture joins the recorded corpus rather than starting a new one"
    }

    /// `probe --record`'s success line. `fileWritten` is repository-relative,
    /// same rule as the refusal above.
    public static func probeRecordedFixture(_ fileWritten: String) -> String {
        "recorded \(fileWritten)"
    }

    /// `probe --record`'s one line appended to `docs/fixture-capture-log.md`.
    /// `record` is the scenario name passed to `--record`, so the logged
    /// command is the one that would actually reproduce this capture.
    /// `fileWritten` is repository-relative and `marketState` is already
    /// `describe(_ state: MarketState)`'s wording — no price, no body
    /// excerpt, no URL, no absolute path, per R44.
    public static func captureLogLine(date: String, symbol: String, record: String,
                                      marketState: String, fileWritten: String) -> String {
        "- \(date): `squigglectl probe \(symbol) --record \(record)` — market state at capture: " +
            "\(marketState); wrote \(fileWritten)"
    }
}
