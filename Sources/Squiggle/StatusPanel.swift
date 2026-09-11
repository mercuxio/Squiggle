import AppKit

/// The dropdown itself: a borderless panel that hangs under the status item.
///
/// Ported from Pitch's `StatusPanel`. This replaces the `NSMenu` Squiggle used
/// to hang off `statusItem.menu`, and the reason is the user's punch list, not
/// taste: `NSMenu` cannot right-align anything. A trash icon on the right of a
/// row and a quit icon on the right of a footer are both impossible in a menu
/// and both trivial in a view, so the menu had to go.
///
/// What is lost with it is worth naming, because it is not nothing: keyboard
/// type-select, menu-key navigation, and AppKit's own dismissal. The last one
/// is rebuilt below; the other two are the price of the layout the user asked
/// for.
@MainActor
final class StatusPanel: NSPanel {
    private enum Metrics {
        static let corner: CGFloat = 10
        /// The drop below the menu bar, matching what AppKit gives a real menu.
        static let gap: CGFloat = 6
        static let screenMargin: CGFloat = 8
    }

    private var outsideClicks: Any?
    private var keys: Any?
    /// The status item this panel is hanging under. Weak: the status bar owns
    /// its button, and a panel that outlived it would be holding a corpse.
    private weak var anchor: NSStatusBarButton?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            // `.nonactivatingPanel` is what stops clicking a row from pulling
            // the app forward and shuffling the user's window order — the same
            // thing a real menu does.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        isFloatingPanel = true
        level = .popUpMenu
        // Closed and reopened all session long; releasing on close would free
        // it out from under the controller still holding it.
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        animationBehavior = .utilityWindow

        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        // Both of the next two are needed, and they round different things.
        // The layer radius rounds what the effect view *draws*; the mask tells
        // the window server what shape to blur *behind* it. With only the
        // layer, square corners of blurred desktop stick out past the rounded
        // fill.
        background.maskImage = Self.roundedMask(radius: Metrics.corner)
        background.wantsLayer = true
        background.layer?.cornerRadius = Metrics.corner
        background.layer?.masksToBounds = true
        contentView = background
    }

    /// A nine-part stretchable rounded rectangle. `capInsets` keeps the corners
    /// at their drawn size however far the middle is stretched, so one small
    /// image masks a panel of any height.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// Borderless panels refuse key by default, which would leave the Escape
    /// monitor as the only way out and the search field in the picker dead.
    override var canBecomeKey: Bool { true }

    /// Swap in freshly built content and resize to fit it.
    ///
    /// The top-left corner is captured first and restored afterwards: the panel
    /// hangs *down* from the status item, so growing it by one row must move
    /// the bottom edge, not the top. Without this, adding a symbol while the
    /// dropdown is open walks it up over the menu bar.
    func setContent(_ view: NSView) {
        guard let background = contentView else { return }
        let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
        background.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            view.topAnchor.constraint(equalTo: background.topAnchor),
            view.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        background.layoutSubtreeIfNeeded()
        setContentSize(view.fittingSize)
        if isVisible { setFrameTopLeftPoint(topLeft) }
    }

    var isShowing: Bool { isVisible }

    func show(under button: NSStatusBarButton, quit: @escaping () -> Void) {
        guard let buttonWindow = button.window else { return }
        self.anchor = button
        let frame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        setFrameTopLeftPoint(origin(under: frame, on: buttonWindow.screen))
        // An `LSUIElement` app is never frontmost on its own, and without this
        // the panel opens behind whatever the user was working in.
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        startWatching(quit: quit)
    }

    override func close() {
        stopWatching()
        super.close()
    }

    /// Centred under the status item, then pulled back onto the screen it is
    /// on. A status item near the right edge of a small display would otherwise
    /// put half the panel past the edge.
    private func origin(under anchor: NSRect, on screen: NSScreen?) -> NSPoint {
        let width = frame.width
        var x = anchor.midX - width / 2
        let y = anchor.minY - Metrics.gap
        if let visible = screen?.visibleFrame {
            let leftmost = visible.minX + Metrics.screenMargin
            let rightmost = visible.maxX - Metrics.screenMargin - width
            // The inner `max` matters when the panel is wider than the screen:
            // `min(max(x, left), right)` with right < left would pin it to the
            // right and push its left edge off instead.
            x = min(max(x, leftmost), max(leftmost, rightmost))
        }
        return NSPoint(x: x, y: y)
    }

    /// Dismissal, which AppKit used to do for us.
    private func startWatching(quit: @escaping () -> Void) {
        stopWatching()
        // Deliberately *global*: a local monitor would also see clicks inside
        // this app's own windows — the settings window, the symbol picker — and
        // close the panel out from under them. The status item itself is
        // excluded below so this does not race the button's own toggle, which
        // would close and immediately reopen.
        outsideClicks = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                guard let self, !self.anchorFrame().contains(location) else { return }
                self.close()
            }
        }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Classified out here rather than inside `assumeIsolated`, which can
            // only hand back a `Sendable` value — and an `NSEvent` is not one.
            let isEscape = event.keyCode == 53
            let isQuit =
                event.modifierFlags.contains(.command)
                && event.charactersIgnoringModifiers?.lowercased() == "q"
            guard isEscape || isQuit else { return event }
            MainActor.assumeIsolated {
                if isEscape { self?.close() } else { quit() }
            }
            return nil
        }
    }

    private func anchorFrame() -> NSRect {
        guard let anchor, let window = anchor.window else { return .zero }
        return window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    }

    private func stopWatching() {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        if let keys { NSEvent.removeMonitor(keys) }
        outsideClicks = nil
        keys = nil
    }
}
