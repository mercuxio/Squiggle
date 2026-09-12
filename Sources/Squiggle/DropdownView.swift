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
        static let glyph: CGFloat = 13
        static let hitSlop: CGFloat = 4
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
    init(model: MenuModel,
         target: AnyObject,
         remove: Selector,
         command: (MenuCommand) -> Selector,
         color: (ColorRole) -> NSColor = { ColorPolicy.color(for: $0, scheme: .monochrome,
                                                             isStale: false) },
         refreshing: RefreshIndicator? = nil) {
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

        for item in model.items {
            switch item {
            case .quote(let row):
                stack.addArrangedSubview(
                    Self.quoteRow(row, target: target, action: remove, color: color))
            case .footer(let text):
                stack.addArrangedSubview(Self.statusLine(text))
            case .separator:
                stack.addArrangedSubview(Self.separator())
            }
        }
        stack.addArrangedSubview(MenuFooterView(target: target, selector: command,
                                                refreshing: refreshing))

        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: Metrics.minWidth),
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
        // The menu font, because this is still a menu as far as the user is
        // concerned even though AppKit no longer thinks so. Size 0 means "the
        // system's own menu size", whatever the user has set.
        label.font = .menuFont(ofSize: 0)
        label.lineBreakMode = .byTruncatingTail
        label.attributedStringValue = text(quote, font: label.font, color: color)

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
            attributes: [.font: font ?? NSFont.menuFont(ofSize: 0),
                         .foregroundColor: color(.label),
                         .paragraphStyle: paragraph])
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
    private static func statusLine(_ text: String) -> NSView {
        let row = NSView()
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        // Wrapping, not truncating: a rate-limit sentence with a retry time is
        // longer than a watchlist row, and the half of it that says what to do
        // is at the end.
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = Metrics.minWidth - Metrics.inset * 2
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

    private static func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }
}
