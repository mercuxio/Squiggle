import AppKit
import TickerCore

/// An icon button that remembers which symbol it removes.
///
/// `NSMenuItem` had `representedObject` for exactly this; `NSButton` does not,
/// and `tag` is an `Int` — a row index, which would go stale the moment the
/// watchlist changed underneath an open dropdown. The symbol itself cannot.
@MainActor
final class RemoveButton: FooterButton {
    let symbol: Symbol

    init(symbol: Symbol) {
        self.symbol = symbol
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("R133: built in code, not a xib") }
}

/// The dropdown's contents: what `MenuModel` decided, as views.
///
/// The same split as `StripLayout`/`StripRenderer` — the model decides the rows
/// and every word in them, and this turns them into controls. Nothing here
/// formats a price, chooses wording or reads a quote; if a string appears on
/// screen that is not in the model, that is the defect.
///
/// Rebuilt from scratch each time the dropdown opens. Twenty rows of two views
/// is nothing to build, and a view tree that is never mutated in place cannot
/// drift out of step with the watchlist.
@MainActor
final class DropdownView: NSView {
    private enum Metrics {
        /// The same visible inset the footer uses, so the row text, the status
        /// line and the gear all start on one vertical line.
        static let inset: CGFloat = 14
        static let rowSpacing: CGFloat = 2
        static let topPadding: CGFloat = 8
        /// Enough that a two-symbol watchlist does not give a panel narrower
        /// than its own footer.
        static let minWidth: CGFloat = 260
        /// One step down from the system menu size, which is what the rows used
        /// to take. The user asked for smaller detail lines; this is the size
        /// AppKit itself means by "smaller" rather than a number picked to look
        /// right, so it follows the user's text-size setting the way the old
        /// `menuFont(ofSize: 0)` did.
        ///
        /// The status line below the rows is already this size and stays
        /// distinct by colour — it is `.secondaryLabelColor` against the rows'
        /// `.label`, which was always the larger half of that difference.
        static let rowFontSize: CGFloat = NSFont.smallSystemFontSize
        /// The trash icon, matched to the text beside it: "the trash icon to
        /// follow". Stated as the row font size rather than as its own constant
        /// so the two cannot drift apart — an icon a third taller than its row's
        /// text is what made the old 13 look bolted on once the text shrank.
        ///
        /// The footer keeps its own 13pt glyph. That row has no text to match
        /// and is Pitch's styling, which the user asked to copy exactly.
        static let glyph: CGFloat = rowFontSize
        static let hitSlop: CGFloat = 4
        /// What a row spends on everything that is not its text: the leading
        /// inset, the gap the layout keeps between the line and the trash
        /// button, the button, and the trailing inset the button's slop
        /// straddles. Derived from the constraints `quoteRow` activates rather
        /// than written out again, so the two cannot disagree about how wide a
        /// row has to be to show its line whole.
        static let rowChrome: CGFloat =
            inset + rowSpacing * 4 + (glyph + hitSlop * 2) + (inset - hitSlop)
        /// An `NSTextField` draws its string inside a cell that insets it, so a
        /// field given exactly the string's typographic width still truncates
        /// by a hair. Two points a side, the same inset its alignment rect
        /// carries.
        static let measurementSlack: CGFloat = 4
    }

    /// - Parameters:
    ///   - remove: sent by a row's trash button, with the `RemoveButton` as
    ///     sender — the symbol comes off that, not out of an index.
    ///   - command: the footer bar's selector for each command.
    ///   - color: resolves a role exactly as the strip's resolver does, so the
    ///     two surfaces cannot disagree about what green means — or about
    ///     whether the data is stale, which greys both.
    ///
    ///     `NSColor`, not the strip's `CGColor`: the strip is painted into a
    ///     layer under the *menu bar's* appearance, which is why it has to
    ///     resolve through `performAsCurrentDrawingAppearance` first. This view
    ///     is drawn by AppKit inside the panel, which resolves its own
    ///     appearance at draw time.
    ///   - refreshing: non-`nil` while a fetch is under way, saying how to show
    ///     it. Supplied on every rebuild rather than started by the click,
    ///     because the click rebuilds this whole view — an animation attached
    ///     to the button that was pressed would be discarded microseconds
    ///     later, and reopening the panel mid-fetch would show nothing.
    ///   - reordering: present when the rows may be dragged, and carrying the
    ///     row split that decides whether they are drawn in one column or two.
    ///     Absent leaves a static list — which is what this view was before
    ///     the user asked for "2 columns, row 1 and row 2".
    init(model: MenuModel,
         target: AnyObject,
         remove: Selector,
         command: (MenuCommand) -> Selector,
         color: (ColorRole) -> NSColor = { ColorPolicy.color(for: $0, scheme: .monochrome,
                                                             isStale: false) },
         refreshing: RefreshIndicator? = nil,
         reordering: WatchlistColumnsView.Reordering? = nil) {
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.minWidth, height: 0))

        let stack = NSStackView()
        stack.orientation = .vertical
        // `.width` rather than `.leading`: every child is stretched to the
        // stack's width, which is what lets a row put its trash button on the
        // right-hand edge and the footer put quit there.
        stack.alignment = .width
        stack.spacing = Metrics.rowSpacing
        stack.edgeInsets = NSEdgeInsets(top: Metrics.topPadding, left: 0, bottom: 0, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The quote rows leave the stack and become one child of it, because
        // two columns are not something a vertical stack can express and a
        // drag is not something it can survive. Everything else — the status
        // line, the rule, the footer bar — stays exactly where it was.
        let quotes: [MenuModel.QuoteRow] = model.items.compactMap {
            guard case .quote(let row) = $0 else { return nil }
            return row
        }
        let columns = CGFloat(reordering?.rowOneCount == nil ? 1 : 2)
        // The user asked that no symbol's details be truncated, so the column
        // is sized to the widest line the model actually produced rather than
        // to a constant. Measured once, here, off the same attributed string
        // the rows will draw — a second measurement written in terms of "the
        // symbol plus a price plus a change" would be a second place that has
        // to know how `ErrorText.menuRow` spells a line.
        //
        // The labels keep their tail truncation. It is now a backstop for the
        // pathological case rather than the ordinary one.
        let columnWidth = Self.columnWidth(for: quotes, color: color)

        if !quotes.isEmpty {
            var built: [Symbol: NSView] = [:]
            for quote in quotes {
                built[quote.symbol] = Self.quoteRow(quote, target: target, action: remove,
                                                    color: color)
            }
            stack.addArrangedSubview(
                WatchlistColumnsView(symbols: quotes.map(\.symbol), rows: built,
                                     rowHeight: Metrics.glyph + Metrics.hitSlop * 2,
                                     reordering: reordering,
                                     headings: ErrorText.columnHeadings,
                                     textInset: Metrics.inset))
        }

        for item in model.items {
            switch item {
            case .quote:
                continue
            case .footer(let text):
                stack.addArrangedSubview(Self.statusLine(text,
                                                         width: columnWidth * columns))
            }
        }
        // Pitch puts a rule immediately above its footer bar and Squiggle's
        // footer is a copy of Pitch's, so it gets the same rule. It is the only
        // rule in the panel: one above the status line as well read as two
        // stripes across a short menu, and the user asked for "no border above
        // the updated at". This one earns its place — without it the icon row
        // reads as one more entry in the list.
        stack.addArrangedSubview(Self.separator())
        stack.addArrangedSubview(MenuFooterView(target: target, selector: command,
                                                refreshing: refreshing))

        addSubview(stack)
        // One column's worth of width per column, where a column is as wide as
        // the widest row needs. The width is settled before any row is built
        // and does not move while the panel is open: it is a function of the
        // model, so a price gaining a digit only changes it on the next open.
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: columnWidth * columns),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("R133: built in code, not a xib") }

    // MARK: - Pieces

    /// One watchlist row: the model's line on the left, a trash button hard
    /// against the right edge.
    ///
    /// This is the user's item 2. It used to be a submenu with a single
    /// *Remove* item in it — two clicks and a hover delay to undo one mistake,
    /// and a submenu that existed only to hold one command.
    private static func quoteRow(_ quote: MenuModel.QuoteRow,
                                 target: AnyObject, action: Selector,
                                 color: (ColorRole) -> NSColor) -> NSView {
        let row = NSView()
        let symbol = quote.symbol

        let label = NSTextField(labelWithString: quote.title)
        // Still the menu font, because this is still a menu as far as the user
        // is concerned even though AppKit no longer thinks so — but a size down
        // from the system's own menu size, which is what `ofSize: 0` asks for.
        label.font = .menuFont(ofSize: Metrics.rowFontSize)
        label.lineBreakMode = .byTruncatingTail
        label.attributedStringValue = text(quote, font: label.font, color: color)
        // A row now lives in a column of fixed width, so the label has to be
        // the thing that gives when the line is too long. Left at the default,
        // its compression resistance outranks the spacing constraint below it
        // and Auto Layout breaks one at random instead.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let button = RemoveButton(symbol: symbol)
        button.image = LucideIcon.trash2.image(size: Metrics.glyph)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .shadowlessSquare
        button.target = target
        button.action = action
        button.toolTip = ErrorText.removeSymbol(symbol.raw)
        // Naming the symbol, not just "Remove": twenty identically labelled
        // buttons would leave a VoiceOver user counting rows to work out which
        // one they had landed on.
        button.setAccessibilityLabel(ErrorText.removeSymbol(symbol.raw))
        button.contentTintColor = .secondaryLabelColor

        for view in [label, button] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }

        let side = Metrics.glyph + Metrics.hitSlop * 2
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor,
                                           constant: Metrics.inset),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            // The glyph lands `inset` from the edge; the slop straddles it, the
            // same trade the footer makes.
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor,
                                             constant: -(Metrics.inset - Metrics.hitSlop)),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: side),
            button.heightAnchor.constraint(equalToConstant: side),
            // Greater-than-or-equal, so a long row pushes the panel wider
            // rather than sliding the text under the trash button.
            button.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor,
                                            constant: Metrics.rowSpacing * 4),
            row.heightAnchor.constraint(equalToConstant: side),
        ])
        return row
    }

    /// How wide one column has to be for every row to show its line whole.
    ///
    /// `Metrics.minWidth` is still the floor — a two-symbol watchlist should
    /// not give a panel narrower than its own footer — and the widest row sets
    /// everything above it. Rounded up, because a fractional point short is a
    /// truncated line.
    private static func columnWidth(for quotes: [MenuModel.QuoteRow],
                                    color: (ColorRole) -> NSColor) -> CGFloat {
        let font = NSFont.menuFont(ofSize: Metrics.rowFontSize)
        var widest: CGFloat = 0
        for quote in quotes {
            widest = max(widest, text(quote, font: font, color: color).size().width)
        }
        let needed = widest + Metrics.rowChrome + Metrics.measurementSlack
        return max(Metrics.minWidth, needed.rounded(.up))
    }

    /// The row's line, with the direction glyph — and only the glyph — taking
    /// the colour its role earns.
    ///
    /// This is the dropdown catching up with the strip. `StripLayout.pieces`
    /// has emitted the arrow as its own `.direction` segment since Task 7,
    /// which is why one triangle up there is green while the numbers beside it
    /// stay plain; the dropdown flattened the same line to one string and so
    /// painted the whole of it `.label`.
    ///
    /// The range is `MenuModel`'s to decide, not this view's: a view hunting
    /// for "▲" would be a second place that has to know what a glyph looks
    /// like, and it would find one in a symbol named after an arrow.
    ///
    /// The symbol takes a heavier weight than the price and change beside it,
    /// which is the user's ask. Derived from the row's own font rather than
    /// named outright, so it stays the menu face at the row's size and follows
    /// the text-size setting the rest of the row follows; if the descriptor
    /// cannot produce a bold face the row simply keeps one weight throughout,
    /// which is what it looked like before.
    ///
    /// Its range comes from `MenuModel`, on the same principle as the glyph's:
    /// the string's assembler knows where the symbol ends, and a view counting
    /// spaces to find out would be a second place that has to know how the line
    /// is spelled.
    ///
    /// The paragraph style is not decoration. An `NSTextField` truncates via
    /// its cell's `lineBreakMode`, and an attributed string carrying no
    /// paragraph style of its own overrules that with the default — which
    /// wraps. Setting it here keeps the long-row behaviour the plain-string
    /// version had.
    private static func text(_ quote: MenuModel.QuoteRow, font: NSFont?,
                             color: (ColorRole) -> NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let line = NSMutableAttributedString(
            string: quote.title,
            attributes: [.font: font ?? NSFont.menuFont(ofSize: Metrics.rowFontSize),
                         .foregroundColor: color(.label),
                         .paragraphStyle: paragraph])
        let base = font ?? NSFont.menuFont(ofSize: Metrics.rowFontSize)
        if let bold = NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.bold),
                             size: base.pointSize) {
            line.addAttribute(.font, value: bold, range: quote.symbolRange)
        }
        if let glyph = quote.glyph {
            line.addAttribute(.foregroundColor,
                              value: color(.direction(glyph.direction)),
                              range: glyph.range)
        }
        return line
    }

    /// Spec §7's one line of detail — the app's only error surface, and the
    /// thing `MenuModel.Item.footer` means. The bar of icons under it is
    /// `MenuFooterView`; the two are not the same thing.
    ///
    /// - Parameter width: the panel's whole width, every column of it. The
    ///   stack stretches this row that far either way, but a wrapping label
    ///   wraps at `preferredMaxLayoutWidth` and not at the width it was given —
    ///   so a two-column panel used to wrap "Updated…" down the left-hand
    ///   column and leave the right half empty. The user asked for the line to
    ///   span both, which is this one number.
    private static func statusLine(_ text: String, width: CGFloat) -> NSView {
        let row = NSView()
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        // Wrapping, not truncating: a rate-limit sentence with a retry time is
        // longer than a watchlist row, and the half of it that says what to do
        // is at the end.
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = width - Metrics.inset * 2
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor,
                                           constant: Metrics.inset),
            label.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor,
                                            constant: -Metrics.inset),
            label.topAnchor.constraint(equalTo: row.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -4),
        ])
        return row
    }

    /// Pitch's rule: `separatorColor`, the shade AppKit uses between sections
    /// of a menu, which is what "refer to pitch" asks for.
    ///
    /// Drawn as a filled custom box rather than `boxType = .separator`, which
    /// paints the same colour but refuses to be one point tall — it kept a 5pt
    /// frame and drew its hairline somewhere in the middle, so the rule landed
    /// where the constraint asked only by coincidence.
    private static func separator() -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0
        box.fillColor = .separatorColor
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }
}
