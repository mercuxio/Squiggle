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
    case quote(symbol: String, raw: Bool, json: Bool)
    /// `symbols` empty means none were given on the command line; the caller
    /// (`main.swift`) falls back to the watchlist on disk. `parse` itself
    /// touches no filesystem — see the type's own doc comment — so that
    /// fallback cannot live here.
    case watch(symbols: [Symbol], intervalSeconds: Double, maxCycles: Int?)

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
            let json = takeFlag("--json")
            guard let symbol = rest.first else {
                throw ParseError("quote needs a symbol, e.g. `squigglectl quote AAPL`")
            }
            return .quote(symbol: symbol, raw: raw, json: json)

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

        default:
            throw ParseError("unknown command: \(subcommand)")
        }
    }
}
