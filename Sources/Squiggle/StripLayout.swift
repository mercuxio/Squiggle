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
    /// The interpunct between one entry and the next. Its own role rather
    /// than `.label`, because it is punctuation and not content: it is drawn
    /// quieter than the numbers it divides, and a scheme that wanted to drop
    /// it entirely could do so here without touching the layout.
    case separator
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
        /// Drawn in the heavier of the strip's two weights. The symbol takes
        /// it and the numbers beside it do not, which is the same emphasis
        /// the dropdown gives its rows.
        let emphasized: Bool

        /// Spelled out rather than left to the memberwise initialiser so the
        /// weight can default: every caller that predates the emphasis, tests
        /// included, means "the ordinary weight" and should not have to say so.
        init(text: String, role: ColorRole, x: Double, width: Double,
             emphasized: Bool = false) {
            self.text = text
            self.role = role
            self.x = x
            self.width = width
            self.emphasized = emphasized
        }
    }

    struct Row: Equatable {
        let segments: [Segment]
        /// One full pass, trailing gap included. Task 8's animation
        /// translates by exactly this, and a second copy of the row drawn at
        /// `x + contentWidth` tiles it seamlessly.
        let contentWidth: Double

        /// The same row measured for type a fraction of the size.
        ///
        /// Multiplication rather than re-measurement, and that is an
        /// assumption worth naming: a glyph's advance in a scalable font is
        /// linear in point size, so a row set at 8pt is a row set at 12pt
        /// times two thirds. Re-measuring would be exact, but the measurement
        /// closure belongs to the caller that built the layout (R131) and is
        /// long gone by the time a renderer discovers the row does not fit.
        ///
        /// Used only by Flip, whose cards shrink to fit the status item
        /// instead of scrolling — see `StripRenderer.cardShrink`.
        func scaled(by factor: Double) -> Row {
            Row(segments: segments.map {
                    Segment(text: $0.text, role: $0.role,
                            x: $0.x * factor, width: $0.width * factor,
                            emphasized: $0.emphasized)
                },
                contentWidth: contentWidth * factor)
        }
    }

    let rows: [Row]

    /// What divides one entry from the next: U+00B7, the interpunct. A middle
    /// dot rather than a bullet or a pipe because it sits on the x-height's
    /// midline and takes almost no width — the strip gains a reading aid
    /// without gaining a lap.
    static let separatorText = "\u{00B7}"

    var widestRowWidth: Double {
        rows.map(\.contentWidth).max() ?? 0
    }

    /// One entry's worth of text, before it has been placed.
    private struct Piece {
        let text: String
        let role: ColorRole
        /// See `Segment.emphasized`. Carried from here so that the one place
        /// that decides what a strip entry is made of is also the one place
        /// that decides which part of it is the name.
        var emphasized: Bool = false
    }

    /// - Parameters:
    ///   - symbols: the watchlist, in the user's order. Order is the user's,
    ///     not sorted: a watchlist that re-orders itself is unreadable.
    ///   - dead: symbols the engine has given up on (spec §7).
    ///   - gap: points between one entry and the next, and between the last
    ///     entry and the repeat of the first.
    ///   - measure: injected text measurement (R131). The caller binds the
    ///     fonts — both of them; nothing here knows what a font is. The flag
    ///     is `Segment.emphasized`: a heavier weight measures wider, and a
    ///     measurement taken at the wrong weight would put every segment to
    ///     its right at the wrong `x` and give the row the wrong
    ///     `contentWidth`, which is the marquee's lap and its tiling seam.
    ///   - rowOneCount: the user's own arrangement, if they have made one —
    ///     see `Store.rowOneCount`. `nil` lets `RowSplitter` balance by width.
    static func build(symbols: [Symbol],
                      quotes: [Symbol: Quote],
                      dead: Set<Symbol>,
                      rows requestedRows: Int,
                      gap: Double,
                      rowOneCount: Int? = nil,
                      locale: Locale = .autoupdatingCurrent,
                      measure: (String, Bool) -> Double) -> StripLayout {
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
                    let width = measure(piece.text, piece.emphasized)
                    segments.append(Segment(text: piece.text, role: piece.role,
                                            x: x, width: width,
                                            emphasized: piece.emphasized))
                    x += width
                }
                // The interpunct is centred *inside* the gap rather than
                // added to it, so `contentWidth` — and with it the lap, the
                // tiling seam and the scroll duration — is exactly what it
                // was before the separator existed. Emitted after every
                // entry, the last one included: in a scrolling row the
                // trailing gap is the join to the repeat of the first entry,
                // so that gap divides two entries like any other. A row that
                // does not scroll has nothing after it, and `rowLayer` drops
                // the dangling dot when it draws a single untiled copy.
                let separatorWidth = measure(separatorText, false)
                if separatorWidth < gap {
                    segments.append(Segment(text: separatorText, role: .separator,
                                            x: x + (gap - separatorWidth) / 2,
                                            width: separatorWidth))
                }
                x += gap
            }
            return Row(segments: segments, contentWidth: x)
        })
    }

    /// One card per watchlist entry, for Flip.
    ///
    /// A `StripLayout` again, rather than a type of its own: a card is a row
    /// of exactly one entry, and reusing `Row` means `StripRenderer` builds a
    /// card out of the same text layers it builds a strip out of, with the
    /// same emphasis and the same measurement. A parallel `Card` type would
    /// be the second place that `SYMBOL price ▲delta (pct%)` is assembled,
    /// and the two would drift the first time the format changed.
    ///
    /// No gap and no tiling: a card has nothing beside it to be spaced from
    /// and nothing to wrap into, so `contentWidth` is the text's own width —
    /// which is also what tells the view whether the card overflows the
    /// window.
    static func cards(symbols: [Symbol],
                      quotes: [Symbol: Quote],
                      dead: Set<Symbol>,
                      locale: Locale = .autoupdatingCurrent,
                      measure: (String, Bool) -> Double) -> StripLayout {
        StripLayout(rows: symbols.map { symbol in
            var segments: [Segment] = []
            var x = 0.0
            for piece in pieces(for: symbol, quotes: quotes, dead: dead, locale: locale) {
                let width = measure(piece.text, piece.emphasized)
                segments.append(Segment(text: piece.text, role: piece.role,
                                        x: x, width: width,
                                        emphasized: piece.emphasized))
                x += width
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
                           measure: (String, Bool) -> Double) -> [[Int]] {
        let entryWidths = symbols.map { symbol -> Double in
            pieces(for: symbol, quotes: quotes, dead: dead, locale: locale)
                .reduce(0.0) { $0 + measure($1.text, $1.emphasized) } + gap
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
        // The name is the one piece drawn heavy — the same split the
        // dropdown makes between a row's symbol and its numbers.
        let name = Piece(text: symbol.raw + " ", role: .label, emphasized: true)

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
