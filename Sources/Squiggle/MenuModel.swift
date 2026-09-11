import Foundation
import TickerCore

/// One button in the dropdown's footer bar.
///
/// *Remove* is not here: it lives in a symbol's own row, where it has a symbol
/// to act on. A command in this enum needs no argument, which is what lets
/// `StatusItemController` map it to a selector with a `switch` and no
/// `default:` — and what lets `MenuFooterView` lay them out as five identical
/// icon buttons differing only in glyph and action.
enum MenuCommand: Equatable, Sendable, CaseIterable {
    case addSymbol
    case refreshNow
    case settings
    case buyCoffee
    case quit

    /// All wording lives in `ErrorText` (spec §7). This property exists so the
    /// menu never spells a title itself and a test can say so.
    var title: String {
        switch self {
        case .addSymbol: return ErrorText.addSymbol
        case .refreshNow: return ErrorText.refreshNow
        case .settings: return ErrorText.settings
        case .buyCoffee: return ErrorText.buyCoffee
        case .quit: return ErrorText.quit
        }
    }
}

/// What the dropdown says, as a value.
///
/// The same split as `StripLayout` and `StripRenderer`: this decides the rows
/// and the wording, and `DropdownView` turns it into views. The reason is the
/// same too — every rule worth testing is in here, and none
/// of it needs a status bar, a window server or a run loop to exercise.
struct MenuModel: Equatable {
    enum Item: Equatable {
        /// One watchlist row. The symbol rides along because the row carries a
        /// trash button that needs to know what it is removing.
        case quote(title: String, symbol: Symbol)
        /// Spec §7's one line of detail, and the app's only error surface.
        ///
        /// Named before the footer *bar* existed, and kept: "footer" is the
        /// spec's own word for this line. The row of icons beneath it is
        /// `MenuFooterView`, and the two are not the same thing.
        case footer(String)
        case separator
    }

    let items: [Item]

    static func build(symbols: [Symbol],
                      quotes: [Symbol: Quote],
                      dead: Set<Symbol>,
                      lastSuccessEpoch: Double?,
                      lastError: TickerError?,
                      storeFault: TickerError?,
                      nowEpoch: Double,
                      nextStepEpoch: Double?,
                      locale: Locale = .autoupdatingCurrent) -> MenuModel {
        var items: [Item] = symbols.map { symbol in
            .quote(title: row(for: symbol, quotes: quotes, dead: dead, locale: locale),
                   symbol: symbol)
        }
        if !items.isEmpty { items.append(.separator) }

        // R139: the transient fault outranks the permanent one, because the
        // permanent one gets every other minute of the session to be read in.
        let footer = ErrorText.footer(
            lastSuccessAgoSeconds: lastSuccessEpoch.map { nowEpoch - $0 },
            lastError: lastError ?? storeFault,
            retryInSeconds: nextStepEpoch.map { max(0, $0 - nowEpoch) })
        // The list ends here. The four commands that used to follow are now the
        // footer bar, which is chrome rather than another entry in the same
        // list of things — and, being a view, is the only way to put one of
        // them on the right-hand edge.
        items.append(.footer(footer))
        return MenuModel(items: items)
    }

    private static func row(for symbol: Symbol,
                            quotes: [Symbol: Quote],
                            dead: Set<Symbol>,
                            locale: Locale) -> String {
        // Same rule as `StripLayout.pieces`, for the same reason: no quote yet
        // and given up on both mean "there is no number for this slot", and
        // which one it is belongs in the footer, not in a second glyph.
        guard !dead.contains(symbol), let quote = quotes[symbol] else {
            return ErrorText.menuRow(symbol: symbol.raw,
                                     price: Formatting.deadPlaceholder,
                                     change: "", currency: nil)
        }
        return ErrorText.menuRow(symbol: symbol.raw,
                                 price: Formatting.price(quote.price, locale: locale),
                                 change: Formatting.change(quote, locale: locale),
                                 currency: quote.currency)
    }
}
