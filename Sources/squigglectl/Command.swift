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

        /// Every verb calls this before it treats what is left as its own
        /// arguments. Three things were wrong with the four hand-written
        /// copies it replaces.
        ///
        /// `watch` had no sweep at all, so `squigglectl watch --raw AAPL`
        /// parsed as a watchlist of two symbols — `--raw` and `AAPL` — because
        /// `Symbol`'s forbidden set has no hyphen in it, and then failed
        /// against Yahoo as a bad symbol rather than as the unknown flag it is.
        ///
        /// The other four tested `hasPrefix("--")`, so a single-hyphen `-x`
        /// walked through every one of them and became a symbol or a search
        /// word. `hasPrefix("-")` is the test, and it is safe precisely because
        /// `takeValue` has already removed each known flag *and the token after
        /// it* by the time this runs: `--interval -5` and `--cycles -1` reach
        /// their own error messages, which say what is wrong with the number,
        /// rather than being reported here as unknown flags.
        ///
        /// And having one copy is itself the point — the missing sweep in
        /// `watch` is what four separate copies of a rule look like after
        /// someone adds a fifth verb.
        func rejectUnknownFlags() throws {
            if let unknownFlag = rest.first(where: { $0.hasPrefix("-") }) {
                throw ParseError("unknown flag: \(unknownFlag)")
            }
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
            // the symbol. A token still starting with a hyphen is not a symbol
            // that slipped through — it's a flag this verb doesn't know, and
            // reporting it as an unusable symbol would misdiagnose the
            // mistake (R64 removed `--json` from this parser but nothing
            // rejected it, so it silently became the symbol).
            try rejectUnknownFlags()
            guard let symbol = rest.first else {
                throw ParseError("quote needs a symbol, e.g. `squigglectl quote AAPL`")
            }
            // One symbol, and `rest.first` used to take it and drop the rest in
            // silence: `squigglectl quote AAPL MSFT` quoted AAPL and said
            // nothing about MSFT, so the answer on screen was right for a
            // question the user did not ask. Reported separately from the flag
            // case above, the way `doctor` already separates them — calling
            // `MSFT` an unknown flag would misdiagnose it.
            if rest.count > 1 {
                throw ParseError("quote takes one symbol, got: \(rest[1])")
            }
            return .quote(symbol: symbol, raw: raw)

        case "watch":
            var intervalSeconds = RateConstants.defaultRefreshInterval
            if let intervalText = try takeValue("--interval") {
                guard let parsed = Double(intervalText), parsed.isFinite else {
                    throw ParseError("--interval needs a number of seconds, got \(intervalText)")
                }
                // Clamped, not rejected: a stray "30" or "7200" on the
                // command line runs at the nearest end of
                // `RateConstants.offeredRefreshIntervals` rather than failing.
                //
                // This is deliberately *not* what `Settings.init(from:)` does
                // with the same out-of-range number in a hand-edited store
                // file, and a comment here used to claim it was. That decoder
                // replaces an unoffered interval with
                // `RateConstants.defaultRefreshInterval` — 7200 becomes 180,
                // not 900. The two differ because the inputs differ: a store
                // file is persisted state that the app will re-save, so
                // snapping it to a nearby value would write a number the user
                // never chose back to their disk, while an interval typed on
                // the command line lives for one run and clamping it does what
                // the operator plainly meant. `theCommandLineClampAndTheStoreDecoderDisagreeOnPurpose`
                // pins both halves against each other.
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

            // `watch` is the verb that had no sweep at all. It matters most
            // here: every other verb would have failed loudly on a stray flag
            // one step later, while this one turned it into a symbol and
            // fetched it every cycle for as long as the loop ran.
            try rejectUnknownFlags()

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

            // Reject a stray flag before it can join the query text below.
            // Multi-word queries are the normal case, so anything left in
            // `rest` is ordinarily meant to become part of the search text —
            // but a token starting with a hyphen is a mistyped or unsupported
            // flag, not a word to search for.
            try rejectUnknownFlags()

            // Multi-word queries are the normal case ("berkshire hathaway"),
            // so join the leftovers rather than demanding the user quote them.
            let query = rest.joined(separator: " ")
            guard !query.isEmpty else {
                throw ParseError("search needs something to search for, e.g. `squigglectl search apple`")
            }

            return .search(query: query, limit: limit)

        case "doctor":
            // No flags of its own yet — any flag here is a mistake, not a
            // token to silently ignore. Same rule as `quote` and `search`.
            try rejectUnknownFlags()
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
                //
                // A leading `-` is rejected separately from the character
                // set below: a hyphen is legal elsewhere in the name
                // (`regular-session`, `crypto-while-equities-closed`), so
                // the character set alone would wave a value like `--raw`
                // straight through. `takeValue` has already stripped
                // `--record` and the token after it from `rest` by the time
                // this check runs, so that token never reaches the
                // unknown-flag sweep below to be caught there instead — this
                // is the only place a stray flag consumed as `--record`'s
                // value gets rejected.
                let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
                guard !name.isEmpty, !name.hasPrefix("-"), name.allSatisfy(allowed.contains) else {
                    throw ParseError(
                        "--record needs a name of lowercase letters, digits and hyphens only, " +
                        "and must not begin with -, got \(name)")
                }
            }
            // Same rule as `quote`, `search` and `doctor`: a stray flag this
            // verb doesn't know must not be silently swallowed or mistaken for
            // the symbol — for whatever flag reaches this sweep.
            // `takeValue("--record")` above already removed `--record` and the
            // single token after it, so a stray flag given as that token never
            // gets here; the guard above is what catches it.
            try rejectUnknownFlags()
            guard let symbol = rest.first else {
                throw ParseError("probe needs a symbol, e.g. `squigglectl probe AAPL`")
            }
            // One symbol, for the same reason `quote` takes one: a probe of
            // `AAPL MSFT` made exactly one request and reported on it as
            // though the second symbol had never been typed.
            if rest.count > 1 {
                throw ParseError("probe takes one symbol, got: \(rest[1])")
            }
            return .probe(symbol: symbol, record: record)

        default:
            throw ParseError("unknown command: \(subcommand)")
        }
    }
}
