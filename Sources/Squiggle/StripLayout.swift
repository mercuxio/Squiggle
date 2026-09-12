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
    ///   - rowOneCount: the user's own arrangement, if they have made one —
    ///     see `Store.rowOneCount`. `nil` lets `RowSplitter` balance by width.
    static func build(symbols: [Symbol],
                      quotes: [Symbol: Quote],
                      dead: Set<Symbol>,
                      rows requestedRows: Int,
                      gap: Double,
                      rowOneCount: Int? = nil,
                      locale: Locale = .autoupdatingCurrent,
                      measure: (String) -> Double) -> StripLayout {
        let rowCount = max(1, min(requestedRows, 2))
        // Named `entries`, not `pieces`: a local called `pieces` would shadow
        // the static `pieces(for:…)` it is initialised from, which Swift
        // rejects as a variable used inside its own initial value.
        let entries = symbols.map { pieces(for: $0, quotes: quotes, dead: dead, locale: locale) }

        let buckets = rowBuckets(symbols: symbols, quotes: quotes, dead: dead,
                                 rows: rowCount, gap: gap, rowOneCount: rowOneCount,
                                 locale: locale, measure: measure)

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

    /// Which watchlist indices land in which row, and nothing else.
    ///
    /// Split out of `build` because two surfaces need this answer and only one
    /// of them wants a strip: the dropdown draws a column per row, and a
    /// dropdown that grouped its symbols differently from the menu bar above
    /// it would be worse than no columns at all. Measuring twice in two places
    /// is exactly how those two would drift.
    ///
    /// `RowSplitter` balances by rendered width (spec §5.1) and is the one
    /// place that decision lives — duplicating it here is how the CLI and the
    /// app would end up disagreeing about the same watchlist.
    static func rowBuckets(symbols: [Symbol],
                           quotes: [Symbol: Quote],
                           dead: Set<Symbol>,
                           rows requestedRows: Int,
                           gap: Double,
                           rowOneCount: Int? = nil,
                           locale: Locale = .autoupdatingCurrent,
                           measure: (String) -> Double) -> [[Int]] {
        let entryWidths = symbols.map { symbol -> Double in
            pieces(for: symbol, quotes: quotes, dead: dead, locale: locale)
                .reduce(0.0) { $0 + measure($1.text) } + gap
        }
        return RowSplitter.split(widths: entryWidths,
                                 rows: max(1, min(requestedRows, 2)),
                                 manualRowOneCount: rowOneCount)
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

        let change = Formatting.changeParts(quote, locale: locale)
        let price = Formatting.price(quote.price, locale: locale)

        // Nothing to say about the change: show the price alone rather than a
        // bare glyph or an empty pair of brackets.
        guard !change.glyph.isEmpty || !change.body.isEmpty else {
            return [name, Piece(text: price, role: .label)]
        }

        // The glyph is its own segment so that it, and nothing else, carries
        // `.direction` — the delta and the percentage read as label text in
        // every scheme. The two `isEmpty` guards below are independent on
        // purpose even though no `Quote` can currently trip only one of them:
        // `.unknown` empties both halves at once and is caught by the guard
        // above, so a half-empty pair could only come from a future change to
        // `changeParts`, and emitting a zero-width segment is the failure mode
        // every later stage would have to remember to skip.
        var pieces = [name, Piece(text: price + " ", role: .label)]
        if !change.glyph.isEmpty {
            pieces.append(Piece(text: change.glyph, role: .direction(quote.direction)))
        }
        if !change.body.isEmpty {
            pieces.append(Piece(text: change.body, role: .label))
        }
        return pieces
    }
}
