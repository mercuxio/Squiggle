import AppKit

/// The icon row at the bottom of the dropdown.
///
/// Ported from Pitch's `MenuFooterView` — every metric below is Pitch's, which
/// took them from InOut. Two apps in the same menu bar that look like siblings
/// is worth more than either arrangement on its own merits, and the user asked
/// for this one to "follow exact styling from pitch".
///
/// These are chrome rather than choices in the same list as the watchlist,
/// which is why they are icons in a row instead of rows in the list — and why
/// `MenuModel` stopped emitting them as items when this view appeared.
@MainActor
final class MenuFooterView: NSView {
    private enum Metrics {
        /// Glyph, plus its slop on both sides, plus InOut's 5pt vertical
        /// padding on both sides.
        static let height: CGFloat = 31
        /// InOut pads its footer by 10 and every control carries 4pt of
        /// invisible hit slop inside that, so the *visible* glyph sits 14 from
        /// the edge. Reproduced here as a visible inset, with the slop
        /// subtracted back off when the frames are placed.
        static let visibleInset: CGFloat = 14
        static let spacing: CGFloat = 2
        static let glyph: CGFloat = 13
        static let hitSlop: CGFloat = 4
    }

    /// The four on the left, in the order the user named them.
    static let leadingCommands: [MenuCommand] = [.settings, .addSymbol, .refreshNow, .buyCoffee]
    /// The one on the right. Separate because its position is the whole point:
    /// quit is the only thing here that ends the session, and putting it where
    /// nothing else lives is what keeps a mis-aimed click cheap.
    static let trailingCommand: MenuCommand = .quit

    /// - Parameter selector: what each button sends. A closure rather than five
    ///   parameters so that adding a command is one case in `MenuCommand` and
    ///   one arm in the caller's `switch`, with nothing to forget here.
    init(target: AnyObject, selector: (MenuCommand) -> Selector) {
        // The width is a starting point only — the panel stretches this view to
        // its full width. The height is the one this view insists on, stated as
        // a constraint below.
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: Metrics.height))

        let leading = NSStackView(views: Self.leadingCommands.map {
            Self.button(for: $0, target: target, action: selector($0))
        })
        leading.orientation = .horizontal
        leading.spacing = Metrics.spacing

        let quitButton = Self.button(for: Self.trailingCommand,
                                     target: target,
                                     action: selector(Self.trailingCommand))

        for view in [leading, quitButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.height),
            leading.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Metrics.visibleInset - Metrics.hitSlop),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Pinned to this view's trailing edge, so the panel stretching it to
            // full width is all it takes to push quit out to the right margin —
            // landing that glyph the same 14 from its edge as the gear is from
            // the left.
            quitButton.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -(Metrics.visibleInset - Metrics.hitSlop)),
            quitButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("R133: built in code, not a xib") }

    /// Settings is an SF Symbol; the other four are Lucide.
    ///
    /// That mix is Pitch's, and it is copied rather than "corrected" because it
    /// is what makes the two footers identical — which is what the user asked
    /// for. `gearshape` is also the one glyph in this row that every Mac user
    /// already reads as settings without a tooltip.
    private static func image(for command: MenuCommand) -> NSImage? {
        switch command {
        case .settings:
            return NSImage(systemSymbolName: "gearshape",
                           accessibilityDescription: ErrorText.settings)?
                .withSymbolConfiguration(.init(pointSize: Metrics.glyph, weight: .regular))
        case .addSymbol:
            return LucideIcon.plus.image(size: Metrics.glyph)
        case .refreshNow:
            return LucideIcon.refreshCw.image(size: Metrics.glyph)
        case .buyCoffee:
            return LucideIcon.coffee.image(size: Metrics.glyph)
        case .quit:
            return LucideIcon.logOut.image(size: Metrics.glyph)
        }
    }

    private static func button(
        for command: MenuCommand, target: AnyObject, action: Selector
    ) -> NSButton {
        let button = FooterButton()
        button.image = image(for: command)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .shadowlessSquare
        button.target = target
        button.action = action
        button.toolTip = command.title
        // The icon has no label, so this is the only thing VoiceOver can read.
        button.setAccessibilityLabel(command.title)
        button.contentTintColor = .secondaryLabelColor

        // Glyph plus InOut's 4pt of hit slop on every side: a stroked 13pt icon
        // is a hairline target otherwise.
        let side = Metrics.glyph + Metrics.hitSlop * 2
        button.widthAnchor.constraint(equalToConstant: side).isActive = true
        button.heightAnchor.constraint(equalToConstant: side).isActive = true
        return button
    }
}

/// A borderless icon button that lights up under the pointer.
///
/// An icon that never reacts reads as decoration rather than as a control, and
/// a bordered button here would look nothing like Pitch's footer.
///
/// Not `final`: `RemoveButton` is the same button with a symbol attached, and a
/// row's trash icon has to highlight exactly the way a footer icon does.
class FooterButton: NSButton {
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        contentTintColor = .labelColor
    }

    override func mouseExited(with event: NSEvent) {
        contentTintColor = .secondaryLabelColor
    }
}
