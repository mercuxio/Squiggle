import Foundation
import TickerCore

/// What a segment's colour means, rather than what colour it is (R130).
/// `ColorScheme` (Task 12) resolves one of these to an `NSColor` against the
/// status item button's own appearance — which is why the layout must not
/// hold a colour: the same layout is re-rendered, unchanged, when the menu
/// bar switches between light and dark.
enum ColorRole: Equatable, Sendable {
    case label
    case direction(Direction)
}

/// The whole strip as data: segments, widths, offsets and colour roles, with
/// no pixels and no AppKit. Spec §8.5 tests it at exactly this level.
struct StripLayout: Equatable {
    struct Segment: Equatable {
        let text: String
        let role: ColorRole
        /// Points from the left edge of its row.
        let x: Double
        let width: Double
    }

    struct Row: Equatable {
        let segments: [Segment]
        /// One full pass, trailing gap included. Task 8's animation
        /// translates by exactly this, and a second copy of the row drawn at
        /// `x + contentWidth` tiles it seamlessly.
        let contentWidth: Double
    }

    let rows: [Row]

    var widestRowWidth: Double {
        rows.map(\.contentWidth).max() ?? 0
    }

    /// One entry's worth of text, before it has been placed.
    private struct Piece {
        let text: String
        let role: ColorRole
    }

    /// - Parameters:
    ///   - symbols: the watchlist, in the user's order. Order is the user's,
    ///     not sorted: a watchlist that re-orders itself is unreadable.
    ///   - dead: symbols the engine has given up on (spec §7).
    ///   - gap: points between one entry and the next, and between the last
    ///     entry and the repeat of the first.
    ///   - measure: injected text measurement (R131). The caller binds the
    ///     font; nothing here knows what a font is.
    static func build(symbols: [Symbol],
                      quotes: [Symbol: Quote],
                      dead: Set<Symbol>,
                      rows requestedRows: Int,
                      gap: Double,
                      locale: Locale = .autoupdatingCurrent,
                      measure: (String) -> Double) -> StripLayout {
        let rowCount = max(1, min(requestedRows, 2))
        // Named `entries`, not `pieces`: a local called `pieces` would shadow
        // the static `pieces(for:…)` it is initialised from, which Swift
        // rejects as a variable used inside its own initial value.
        let entries = symbols.map { pieces(for: $0, quotes: quotes, dead: dead, locale: locale) }
        let entryWidths = entries.map { entry in
            entry.reduce(0.0) { $0 + measure($1.text) } + gap
        }

        // `RowSplitter` balances by rendered width (spec §5.1) and is the one
        // place that decision lives — duplicating it here is how the CLI and
        // the app would end up disagreeing about the same watchlist.
        let buckets = RowSplitter.split(widths: entryWidths, rows: rowCount)

        // `RowSplitter` always returns exactly `rowCount` buckets, empty ones
        // included, so an emptied watchlist still yields the rows the renderer
        // indexes unconditionally. No padding needed here — and none written,
        // because unreachable padding would read as a guarantee this function
        // makes rather than one it relies on.
        return StripLayout(rows: buckets.map { indices -> Row in
            var segments: [Segment] = []
            var x = 0.0
            for index in indices {
                for piece in entries[index] {
                    let width = measure(piece.text)
                    segments.append(Segment(text: piece.text, role: piece.role,
                                            x: x, width: width))
                    x += width
                }
                x += gap
            }
            return Row(segments: segments, contentWidth: x)
        })
    }

    /// R127's segment order: `SYMBOL price ▲delta (pct%)`. The currency code
    /// is deliberately absent — it is in the dropdown row instead, where
    /// `GBp` can be read as pence by a human rather than squeezed into a
    /// scrolling strip.
    private static func pieces(for symbol: Symbol,
                               quotes: [Symbol: Quote],
                               dead: Set<Symbol>,
                               locale: Locale) -> [Piece] {
        let name = Piece(text: symbol.raw + " ", role: .label)

        // No quote yet and given-up-on are rendered the same way on purpose:
        // both mean "there is no number for this slot right now", and the
        // difference between them is a sentence in the dropdown footer, not
        // a second glyph in the menu bar.
        guard !dead.contains(symbol), let quote = quotes[symbol] else {
            return [name, Piece(text: Formatting.deadPlaceholder, role: .label)]
        }

        let delta = Formatting.delta(quote.change, locale: locale)
        let percent = Formatting.percent(quote.changePercent, locale: locale)
        let glyph = quote.direction.glyph

        // Nothing to say about the change: show the price alone rather than a
        // bare glyph or an empty pair of brackets.
        guard !delta.isEmpty || !percent.isEmpty else {
            return [name, Piece(text: Formatting.price(quote.price, locale: locale), role: .label)]
        }

        var change = glyph + delta
        if !percent.isEmpty {
            change += change.isEmpty ? "(\(percent))" : " (\(percent))"
        }

        return [
            name,
            Piece(text: Formatting.price(quote.price, locale: locale) + " ", role: .label),
            Piece(text: change, role: .direction(quote.direction)),
        ]
    }
}
