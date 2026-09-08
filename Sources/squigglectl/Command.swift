import TickerCore

public struct ParseError: Error, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Hand-rolled on purpose. `squigglectl` is the diagnostic path — the thing
/// you reach for when the app is misbehaving — so it takes no dependency that
/// could itself be the problem.
public enum Command: Equatable {
    case help
    case quote(symbol: String, raw: Bool)
    /// `symbols` empty means none were given on the command line; the caller
    /// (`main.swift`) falls back to the watchlist on disk. `parse` itself
    /// touches no filesystem — see the type's own doc comment — so that
    /// fallback cannot live here.
    case watch(symbols: [Symbol], intervalSeconds: Double, maxCycles: Int?)
    /// `limit` is already clamped to `1...20` by the time this case exists —
    /// `parse` is the only place that enforces the cap, so nothing downstream
    /// has to re-check it.
    case search(query: String, limit: Int)
    /// One pass, at most two network requests, no flags. See
    /// `Sources/squigglectl/DoctorRun.swift`.
    case doctor
    /// One request either way. Without `--record`, diffs the response
    /// against the recorded shape and reports what moved. With
    /// `--record NAME`, captures a fresh fixture named `NAME.json` instead —
    /// see `Sources/squigglectl/ProbeRun.swift`. `record` is `nil` when the
    /// flag is absent; the operator names the scenario because the tool
    /// cannot know it from the payload alone.
    case probe(symbol: String, record: String?)

    public static func parse(_ arguments: [String]) throws -> Command {
        guard let subcommand = arguments.first else { return .help }
        var rest = Array(arguments.dropFirst())

        func takeFlag(_ name: String) -> Bool {
            guard let index = rest.firstIndex(of: name) else { return false }
            rest.remove(at: index)
            return true
        }

        /// Removes `name` and the token after it, and returns that token.
        /// A flag given with nothing following it is a parse error, not a
        /// silently-ignored flag.
        func takeValue(_ name: String) throws -> String? {
            guard let index = rest.firstIndex(of: name) else { return nil }
            guard index + 1 < rest.count else {
                throw ParseError("\(name) needs a value")
            }
            let value = rest[index + 1]
            rest.removeSubrange(index...(index + 1))
            return value
        }

        switch subcommand {
        case "help", "--help", "-h":
            return .help

        case "quote":
            let raw = takeFlag("--raw")
            // Whatever is left after removing recognised flags is meant to be
            // the symbol. A token still starting with `--` is not a symbol
            // that slipped through — it's a flag this verb doesn't know, and
            // reporting it as an unusable symbol would misdiagnose the
            // mistake (R64 removed `--json` from this parser but nothing
            // rejected it, so it silently became the symbol).
            if let unknownFlag = rest.first(where: { $0.hasPrefix("--") }) {
                throw ParseError("unknown flag: \(unknownFlag)")
            }
            guard let symbol = rest.first else {
                throw ParseError("quote needs a symbol, e.g. `squigglectl quote AAPL`")
            }
            return .quote(symbol: symbol, raw: raw)

        case "watch":
            var intervalSeconds = RateConstants.defaultRefreshInterval
            if let intervalText = try takeValue("--interval") {
                guard let parsed = Double(intervalText), parsed.isFinite else {
                    throw ParseError("--interval needs a number of seconds, got \(intervalText)")
                }
                // Clamped, not rejected: a stray "30" or "7200" on the
                // command line should run at the nearest honoured value, the
                // same rule `Settings` applies to a hand-edited store file —
                // see RateConstants.offeredRefreshIntervals.
                let range = RateConstants.offeredRefreshIntervals
                intervalSeconds = min(max(parsed, range.lowerBound), range.upperBound)
            }

            var maxCycles: Int?
            if let cyclesText = try takeValue("--cycles") {
                guard let parsed = Int(cyclesText), parsed > 0 else {
                    throw ParseError("--cycles needs a positive whole number, got \(cyclesText)")
                }
                maxCycles = parsed
            }

            var symbols: [Symbol] = []
            for token in rest {
                guard let symbol = Symbol(token) else {
                    throw ParseError("not a usable symbol: \(token)")
                }
                symbols.append(symbol)
            }

            return .watch(symbols: symbols, intervalSeconds: intervalSeconds, maxCycles: maxCycles)

        case "search":
            var limit = 10
            if let limitText = try takeValue("--limit") {
                guard let parsed = Int(limitText), parsed > 0 else {
                    throw ParseError("--limit needs a positive whole number, got \(limitText)")
                }
                // Capped, not rejected: a request for thousands of rows
                // becomes a request for the cap instead of failing outright —
                // one command must not turn into a large request against the
                // same daily budget as everything else.
                limit = min(parsed, RateConstants.maxSearchResultCount)
            }

            // Reject a stray `--flag` before it can join the query text below.
            // Multi-word queries are the normal case, so anything left in
            // `rest` is ordinarily meant to become part of the search text —
            // but a token starting with `--` is a mistyped or unsupported
            // flag, not a word to search for.
            if let unknownFlag = rest.first(where: { $0.hasPrefix("--") }) {
                throw ParseError("unknown flag: \(unknownFlag)")
            }

            // Multi-word queries are the normal case ("berkshire hathaway"),
            // so join the leftovers rather than demanding the user quote them.
            let query = rest.joined(separator: " ")
            guard !query.isEmpty else {
                throw ParseError("search needs something to search for, e.g. `squigglectl search apple`")
            }

            return .search(query: query, limit: limit)

        case "doctor":
            // No flags of its own yet — any `--flag` here is a mistake, not a
            // token to silently ignore. Same rule as `quote` and `search`.
            if let unknownFlag = rest.first(where: { $0.hasPrefix("--") }) {
                throw ParseError("unknown flag: \(unknownFlag)")
            }
            // And nothing positional either. `doctor` used to discard whatever
            // survived the flag check above, so `squigglectl doctor AAPL` ran
            // the same eight checks and gave no hint that the symbol had been
            // ignored — a user who meant `quote AAPL` got a clean bill of
            // health for a question they never asked.
            //
            // Reported separately from the flag case rather than folded into
            // it: telling someone that `AAPL` is an unknown flag misdiagnoses
            // the mistake, and a misdiagnosis is worse than silence.
            if let leftover = rest.first {
                throw ParseError("doctor takes no arguments, got: \(leftover)")
            }
            return .doctor

        case "probe":
            // `--record` takes the fixture's scenario name, not a bare flag
            // — `takeValue` already throws `ParseError("--record needs a
            // value")` when it's given with nothing after it.
            let record = try takeValue("--record")
            if let name = record {
                // The name becomes a path component
                // (`Tests/Fixtures/yahoo-<date>/<name>.json`), so it is
                // restricted to what's safe there — lowercase letters,
                // digits and hyphens. Rejected outright rather than
                // sanitised: a rejected name is a typo the operator should
                // see, not one silently rewritten into something else.
                let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
                guard !name.isEmpty, name.allSatisfy(allowed.contains) else {
                    throw ParseError(
                        "--record needs a name of lowercase letters, digits and hyphens only, got \(name)")
                }
            }
            // Same rule as `quote`, `search` and `doctor`: a stray `--flag`
            // this verb doesn't know must not be silently swallowed or
            // mistaken for the symbol.
            if let unknownFlag = rest.first(where: { $0.hasPrefix("--") }) {
                throw ParseError("unknown flag: \(unknownFlag)")
            }
            guard let symbol = rest.first else {
                throw ParseError("probe needs a symbol, e.g. `squigglectl probe AAPL`")
            }
            return .probe(symbol: symbol, record: record)

        default:
            throw ParseError("unknown command: \(subcommand)")
        }
    }
}
