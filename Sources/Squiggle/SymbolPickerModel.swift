import Foundation
import TickerCore

/// Every search the window issues, so a slow old one cannot overwrite a fast
/// new one (R148).
///
/// Its own type rather than an `Int` on the window, because the rule is worth
/// a name and the race is worth a test: out-of-order responses reproduce by
/// hand perhaps one time in fifty, and never on a fast connection.
struct SearchSession {
    private var current = 0

    mutating func begin() -> Int {
        current += 1
        return current
    }

    func accepts(_ generation: Int) -> Bool { generation == current }
}

/// What the picker shows, given what the search returned.
///
/// Pure, so the whole of the picker's behaviour can be tested without a
/// window, a run loop, or a network — which is also why `SymbolPickerWindow`
/// takes its search as a closure rather than a client.
struct SymbolPickerModel: Equatable {
    enum Row: Equatable {
        case result(SearchResult, isAdded: Bool)
        /// Spec §9 step 8: the typed text, tried as a symbol. Verbatim (R149).
        case literal(Symbol)
    }

    let rows: [Row]
    /// The one line under the list. `nil` when the list speaks for itself.
    let message: String?
    /// The watchlist is at `RateConstants.maxWatchlistCount`; nothing can be
    /// added until something is removed.
    let isFull: Bool

    static func build(query: String,
                      results: [SearchResult],
                      error: TickerError?,
                      watchlist: [Symbol]) -> SymbolPickerModel {
        let full = watchlist.count >= RateConstants.maxWatchlistCount

        // Nothing typed is not a query, is not a symbol, and is not an error.
        guard !query.isEmpty else {
            return SymbolPickerModel(rows: [], message: full ? ErrorText.watchlistFull : nil,
                                     isFull: full)
        }

        if results.isEmpty {
            // R149: exactly what was typed. The trimming happened to the
            // query inside `searchResults`, and reaching here means that
            // trimmed query matched nothing.
            //
            // `Symbol.init?` is failable, and that failure is the whole
            // validation step: text with a space in it is not offered as a
            // symbol, because it cannot be one.
            let candidate = Symbol(query)
            let rows: [Row] = candidate.map { [Row.literal($0)] } ?? []
            let message: String?
            if full {
                message = ErrorText.watchlistFull
            } else if let error {
                // Not "no matches" — the search never ran to completion, and
                // saying otherwise would send the user hunting for a typo.
                message = ErrorText.message(for: error)
            } else {
                message = candidate == nil ? ErrorText.notASymbol : ErrorText.noMatches
            }
            return SymbolPickerModel(rows: rows, message: message, isFull: full)
        }

        let watched = Set(watchlist)
        let rows = results.map { Row.result($0, isAdded: watched.contains($0.symbol)) }
        return SymbolPickerModel(rows: rows,
                                 message: full ? ErrorText.watchlistFull : nil,
                                 isFull: full)
    }
}
