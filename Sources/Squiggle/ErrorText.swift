import Foundation
import TickerCore

/// Every user-facing string in the app (spec §7). `TickerCore` emits typed
/// errors and carries no words; this is where they become sentences.
///
/// The rule the wording follows is spec §7's: name the user's move, not the
/// diagnosis. "Yahoo is rate-limiting Squiggle" tells someone to wait; "HTTP
/// 429" tells them to search the web. The one thing this file must never do is
/// print a value out of the error payload that is not the user's own input —
/// paths, statuses and field names belong in `squigglectl doctor`, whose
/// output is meant to be pasted into an email, not read in a menu bar.
enum ErrorText {
    // MARK: - Menu titles

    static let refreshNow = "Refresh Now"
    static let settings = "Settings…"
    static let addSymbol = "Add Symbol…"
    static let removeSymbol = "Remove"
    static let quit = "Quit Squiggle"

    // MARK: - The footer line

    /// The one line at the foot of the dropdown (spec §7). There is no other
    /// error surface in the app: no alerts, no notifications, no badge.
    static func footer(lastSuccessAgoSeconds: Double?,
                       lastError: TickerError?,
                       retryInSeconds: Double?) -> String {
        guard let lastError else {
            let updated = freshness(lastSuccessAgoSeconds)
            guard let retryInSeconds else { return updated }
            return updated + " — retrying in " + duration(retryInSeconds)
        }
        let sentence = message(for: lastError)
        guard waitingHelps(lastError), let retryInSeconds else { return sentence }
        return sentence + " Retrying in " + duration(retryInSeconds) + "."
    }

    /// One dropdown row. The currency code is rendered **verbatim** — a London
    /// listing reports `GBp`, meaning pence, and upper-casing it would claim
    /// the price was in pounds and be wrong by a factor of 100.
    static func menuRow(symbol: String, price: String,
                        change: String, currency: String?) -> String {
        let money = currency.map { "\(price) \($0)" } ?? price
        return change.isEmpty ? "\(symbol)  \(money)" : "\(symbol)  \(money)  \(change)"
    }

    // MARK: - Wording

    /// Exhaustive over `TickerError`, with no `default:`: a nineteenth case
    /// must fail the build here rather than reach a user as an empty line.
    private static func message(for error: TickerError) -> String {
        switch error {
        case .offline:
            return "No network connection."
        case .rateLimited:
            return "Yahoo is rate-limiting Squiggle."
        case .serverError, .transport:
            return "Yahoo isn't responding."
        case .unauthorized:
            // Spec §3.1: the whole premise is that this endpoint needs no
            // credentials. If it starts to, waiting will not fix it and
            // Squiggle will not start holding a cookie.
            return "Yahoo now wants a sign-in that Squiggle doesn't do."
        case .invalidSymbol(let raw):
            // Echoing the user's own typed text back is sanctioned; it is the
            // only way to say which of twenty symbols is the problem.
            return "Squiggle can't read the symbol “\(raw)”."
        case .symbolNotFound(let symbol):
            return "Yahoo doesn't know “\(symbol.raw)”."
        case .emptyBody, .notJSON, .noResult, .missingField,
             .wrongType, .nonFiniteNumber, .negativeValue:
            // Every contract fault gets the same sentence on purpose. The user
            // can do exactly one thing about any of them, and which JSON key
            // path moved is a question for `squigglectl doctor`.
            return "Yahoo changed what it sends. Squiggle needs an update."
        case .storeSchemaUnsupported:
            return "Your watchlist was written by a newer Squiggle."
        case .storeVersionUnreadable, .storeCorrupt:
            return "Your watchlist couldn't be read, so Squiggle set it aside and started fresh."
        case .storeQuarantineFailed:
            return "Your watchlist couldn't be read and couldn't be set aside, so Squiggle isn't saving changes."
        }
    }

    /// Whether a retry is worth telling the user about. A contract fault, a
    /// credential demand or an unreadable file will look identical in four
    /// minutes, and promising otherwise is the one way a footer line can lie.
    private static func waitingHelps(_ error: TickerError) -> Bool {
        switch error {
        case .transport, .rateLimited, .serverError,
             .symbolNotFound, .invalidSymbol:
            return true
        case .offline, .unauthorized, .emptyBody, .notJSON, .noResult, .missingField,
             .wrongType, .nonFiniteNumber, .negativeValue,
             .storeSchemaUnsupported, .storeVersionUnreadable,
             .storeCorrupt, .storeQuarantineFailed:
            return false
        }
    }

    private static func freshness(_ agoSeconds: Double?) -> String {
        guard let agoSeconds, agoSeconds.isFinite else { return "Updating…" }
        if agoSeconds < 60 { return "Updated just now" }
        return "Updated \(minutes(agoSeconds)) min ago"
    }

    /// R129: the rounding is a wording decision, so it lives here rather than
    /// in `Formatting`. "under a minute" instead of "0 min" — a countdown that
    /// reaches zero and stays there reads as a stuck app.
    private static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 60 else { return "under a minute" }
        return "\(minutes(seconds)) min"
    }

    private static func minutes(_ seconds: Double) -> Int {
        max(1, Int((seconds / 60).rounded()))
    }
}
