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
    /// One watchlist row: its text, what the trash button acts on, and the one
    /// span of the text that carries colour.
    ///
    /// The strip has had this shape since Task 7 — `StripLayout.pieces` emits
    /// the direction glyph as its own segment so that it, and nothing else,
    /// takes `.direction`. The dropdown showed the same line as one flat
    /// string, which is why its triangle stayed black in every scheme.
    struct QuoteRow: Equatable {
        /// Which characters of `title` are the direction glyph, and which way
        /// it points.
        ///
        /// One optional holding both, rather than two that have to agree: a
        /// direction with no glyph to paint is not a state this row can be in.
        struct Glyph: Equatable {
            /// UTF-16 units, because the only consumer is an
            /// `NSAttributedString` and it measures in those. Located here,
            /// where the string is assembled, rather than searched for in the
            /// view — a view hunting for "▲" is a second place that has to
            /// know what a glyph looks like.
            let range: NSRange
            let direction: Direction
        }

        let title: String
        /// Which characters of `title` are the symbol itself, so the view can
        /// set them a weight heavier than the price and change beside them.
        ///
        /// Decided here for the same reason `Glyph.range` is: `ErrorText`
        /// assembles the line and puts the symbol first, so the span is
        /// arithmetic on a length the assembler already knows. A view working
        /// it out would have to know the delimiter `menuRow` chose, and would
        /// be wrong the day that changes.
        let symbolRange: NSRange
        /// Rides along because the row carries a trash button that needs to
        /// know what it is removing.
        let symbol: Symbol
        /// `nil` when there is no glyph at all: no quote yet, or a symbol the
        /// engine gave up on.
        ///
        /// A flat day is *not* nil — it has an en dash, and it gets a span
        /// carrying `.flat`, exactly as `StripLayout.pieces` gives it a
        /// `.direction(.flat)` segment. Whether that span ends up coloured is
        /// `ColorPolicy`'s ruling ("`.flat` and `.unknown` are never
        /// coloured"), made in one place for both surfaces. Filtering flat out
        /// here would be a second copy of that rule, free to drift.
        let glyph: Glyph?
    }

    enum Item: Equatable {
        case quote(QuoteRow)
        /// Spec §7's one line of detail, and the app's only error surface.
        ///
        /// Named before the footer *bar* existed, and kept: "footer" is the
        /// spec's own word for this line. The row of icons beneath it is
        /// `MenuFooterView`, and the two are not the same thing.
        case footer(String)
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
            .quote(row(for: symbol, quotes: quotes, dead: dead, locale: locale))
        }
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
                            locale: Locale) -> QuoteRow {
        // Same rule as `StripLayout.pieces`, for the same reason: no quote yet
        // and given up on both mean "there is no number for this slot", and
        // which one it is belongs in the footer, not in a second glyph.
        guard !dead.contains(symbol), let quote = quotes[symbol] else {
            let title = ErrorText.menuRow(symbol: symbol.raw,
                                          price: Formatting.deadPlaceholder,
                                          change: "", currency: nil)
            return QuoteRow(title: title, symbolRange: symbolRange(symbol),
                            symbol: symbol, glyph: nil)
        }
        let parts = Formatting.changeParts(quote, locale: locale)
        let change = parts.glyph + parts.body
        let title = ErrorText.menuRow(symbol: symbol.raw,
                                      price: Formatting.price(quote.price, locale: locale),
                                      change: change,
                                      currency: quote.currency)
        return QuoteRow(title: title,
                        symbolRange: symbolRange(symbol),
                        symbol: symbol,
                        glyph: glyph(parts.glyph, in: title, change: change,
                                     direction: quote.direction))
    }

    /// Where the arrow sits in the assembled line.
    ///
    /// `ErrorText.menuRow` puts the change last and `Formatting.changeParts`
    /// puts the glyph first inside it, so the arrow is the first characters of
    /// the final `change` — arithmetic, not a search. Both halves of that are
    /// load-bearing and neither is local to this file, which is why
    /// `theArrowsSpanIsTheArrow` asserts the substring rather than the offset:
    /// if either changes its mind, the test says so instead of the dropdown
    /// colouring a digit.
    /// The symbol is the head of the line — `ErrorText.menuRow` writes it
    /// first in both of its shapes — so its span starts at zero and runs the
    /// symbol's own length. Measured in UTF-16 units, like `Glyph.range`,
    /// because the only consumer is an `NSAttributedString`.
    private static func symbolRange(_ symbol: Symbol) -> NSRange {
        NSRange(location: 0, length: (symbol.raw as NSString).length)
    }

    private static func glyph(_ arrow: String, in title: String, change: String,
                              direction: Direction) -> QuoteRow.Glyph? {
        let arrowLength = (arrow as NSString).length
        guard arrowLength > 0 else { return nil }
        let start = (title as NSString).length - (change as NSString).length
        return QuoteRow.Glyph(range: NSRange(location: start, length: arrowLength),
                              direction: direction)
    }
}
