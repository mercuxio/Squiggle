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
    fileprivate enum Metrics {
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
    /// - Parameter refreshing: non-`nil` while a fetch is under way, and only
    ///   ever applied to `.refreshNow`. The controller owns this state and this
    ///   view is rebuilt from it, rather than the button starting its own
    ///   animation when clicked: clicking rebuilds the dropdown, so the button
    ///   that was pressed no longer exists by the time a fetch is in flight.
    init(target: AnyObject, selector: (MenuCommand) -> Selector,
         refreshing: RefreshIndicator? = nil) {
        // The width is a starting point only — the panel stretches this view to
        // its full width. The height is the one this view insists on, stated as
        // a constraint below.
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: Metrics.height))

        let leading = NSStackView(views: Self.leadingCommands.map {
            Self.button(for: $0, target: target, action: selector($0),
                        // Only the icon that means "fetch" says a fetch is
                        // happening. Deciding it here, once, is what keeps
                        // `button` from having to know which command it is
                        // building beyond picking a glyph.
                        refreshing: $0 == .refreshNow ? refreshing : nil)
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
        for command: MenuCommand, target: AnyObject, action: Selector,
        refreshing: RefreshIndicator? = nil
    ) -> NSButton {
        // `init(frame:)` explicitly: `SpinningFooterButton()` would reach
        // `NSObject.init()` rather than the initializer that installs the spin.
        let button: FooterButton = refreshing == .spin
            ? SpinningFooterButton(frame: .zero)
            : FooterButton()
        // The spinning button strokes its own glyph into a layer it owns, so
        // leaving the cell an image as well would draw two glyphs on top of
        // each other — one turning, one not.
        button.image = refreshing == .spin ? nil : image(for: command)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .shadowlessSquare
        button.target = target
        button.action = action
        button.toolTip = command.title
        // The icon has no label, so this is the only thing VoiceOver can read.
        button.setAccessibilityLabel(command.title)
        // `.tint` is the Reduce Motion substitute and `.spin` brightens too, so
        // in either case the icon reads as the live one — which is the same
        // treatment `FooterButton` gives the icon under the pointer, so it is
        // vocabulary the user has already seen.
        button.contentTintColor = refreshing == nil ? .secondaryLabelColor : .labelColor

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

/// The refresh icon while a fetch is in flight: a spinner, turning.
///
/// The rotation is honest rather than cosmetic. It starts when the click asks
/// for a cycle and stops when the step returns, which is at least
/// `RateConstants.minimumWaitSeconds` plus whatever the network takes — and if
/// the cooldown, a circuit or the token bucket refuses the fetch, it stops
/// almost at once, because the click asks for a refresh and does not grant one.
///
/// A subclass rather than a flag on `FooterButton`, so that the only button
/// that can spin is the one that was built to.
///
/// The glyph is `loader-circle` rather than `refresh-cw`, matching the loader
/// in the user's Athena project ("it should be like the loader animation in the
/// athena project"): a ring with a single gap has no feature except the gap, so
/// its turning reads as turning. Two arrows chasing each other read as the
/// arrows moving instead.
final class SpinningFooterButton: FooterButton {
    /// One turn every `turnSeconds`, forever — "forever" being until the next
    /// rebuild replaces this view with one that is not this class.
    static let turnSeconds: Double = 0.9
    static let animationKey = "squiggle.refresh.spin"

    /// The turning glyph: a layer *we* create, not the view's backing layer.
    ///
    /// That distinction is the whole fix. `transform.rotation.z` turns about a
    /// layer's `anchorPoint`, and a layer-backed `NSView`'s backing layer
    /// anchors at (0, 0) — AppKit's choice, and AppKit's to re-assert whenever
    /// it likes as the view joins a window. Two attempts to move that anchor
    /// point, correcting first `frame` and then `position` for the move, both
    /// held headlessly and both orbited on screen. A sublayer has no such
    /// owner: its `anchorPoint` is (0.5, 0.5) from birth and nothing outside
    /// this class ever touches it, so turning about the middle is what the
    /// layer *is* rather than something corrected back into place each pass.
    let spinner = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        let side = MenuFooterView.Metrics.glyph
        spinner.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        spinner.path = LucideIcon.loaderCircle.cgPath(size: side)
        spinner.lineWidth = LucideIcon.strokeWidth(size: side)
        spinner.lineCap = .round
        spinner.lineJoin = .round
        // A shape layer fills by default, which would blot the ring out.
        spinner.fillColor = nil
        spinner.strokeColor = Self.stroke
        // `position` is written on every layout pass, and a layer's default
        // implicit animation would make the glyph glide to each new centre.
        spinner.actions = ["position": NSNull()]

        // Added here rather than in `layout()` or on move-to-window: the layer
        // carries it from the moment the button exists, so the spin is already
        // running when the panel draws its first frame — and a test can ask the
        // layer whether it is there without a window server.
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        // Negative: positive z-rotation is anticlockwise in a layer's y-up
        // space, and every spinner a Mac user has ever seen turns the other way.
        spin.toValue = -2 * Double.pi
        spin.duration = Self.turnSeconds
        // Linear, and no autoreverse: an eased repeat pulses, which reads as a
        // series of attempts rather than one that is still running.
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        spin.repeatCount = .infinity
        spinner.add(spin, forKey: Self.animationKey)

        layer?.addSublayer(spinner)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("R133: built in code, not a xib") }

    /// Full-strength label colour — the same `refreshing != nil` gives the
    /// other footer icons, because this is the live one while it turns.
    ///
    /// Resolved to a `CGColor` because that is all a layer will take, and
    /// re-read on an appearance change below, because a `CGColor` cannot.
    private static var stroke: CGColor { NSColor.labelColor.cgColor }

    /// Centre the glyph. Its own anchor point does the rest.
    override func layout() {
        super.layout()
        spinner.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        spinner.strokeColor = Self.stroke
    }
}
