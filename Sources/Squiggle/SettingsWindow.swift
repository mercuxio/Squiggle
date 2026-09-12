import AppKit
import TickerCore

/// Spec build-order step 7, including launch-at-login (Task 14).
///
/// Built in code (R133). Seven controls do not justify a second UI framework
/// in a menu bar utility, and a storyboard is a file no test can read.
///
/// Every control applies immediately: there is no OK and no Cancel. Spec §4.1
/// requires the effective-interval line to update live beside the choice, and
/// a window that previewed one setting while queueing six others behind a
/// button would be lying about which of them had taken effect.
@MainActor
final class SettingsWindowController: NSWindowController {
    /// Called with the edited settings after every change. The controller
    /// re-renders immediately and persists on a short delay — see
    /// `StatusItemController.settingsChanged`.
    private let onChange: (Settings) -> Void
    private var settings: Settings

    private let rowsControl = NSSegmentedControl()
    private let intervalPopUp = NSPopUpButton()
    private let schemePopUp = NSPopUpButton()
    private let motionControl = NSSegmentedControl()
    private let widthSlider = NSSlider()
    private let speedSlider = NSSlider()
    private let effectiveLabel = NSTextField(labelWithString: "")
    private let launchAtLogin: LaunchAtLogin
    private let version: String?
    private let loginCheckbox = NSButton(checkboxWithTitle: ErrorText.launchAtLoginLabel,
                                         target: nil, action: nil)
    private let loginNote = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    /// "Open at Login" at one end, the version at the other. A stack rather
    /// than two grid cells because the grid has two columns and column 0 is
    /// the labels: a version placed there would sit to the *left* of the
    /// checkbox, not the right of the window.
    private let loginRow = NSStackView()

    /// The width of the grid's control column, and so the width any note in it
    /// has to wrap inside. Named because two places have to agree on it.
    private static let columnWidth: CGFloat = 240
    private let loginSettingsButton = NSButton(title: ErrorText.openLoginItems,
                                               target: nil, action: nil)
    /// The watchlist size the effective-interval line is computed against.
    /// Set by the controller, because the window does not own the watchlist
    /// and the number changes under it: `StatusItemController.openSettings`
    /// seeds it, and `add` and `removeSymbol` push every later change. Spec
    /// §4.1 put this line here to stop the app quoting a cadence it will not
    /// keep, which it would do the moment the count moved without it.
    var watchlistCount = 0 { didSet { refreshEffectiveLabel() } }

    /// Grid row indices, named because three separate things index into the
    /// same list — padding, the merged divider, and the rows that come and go
    /// — and a bare `7` in any of them silently moves when a row is added.
    private enum Row {
        static let effective = 2
        static let divider = 7
        static let note = 9
        static let loginButton = 10
    }

    /// Hiding a *view* leaves its row's height behind; hiding the row is what
    /// closes the gap. Held because `show(_:)` needs them long after the grid
    /// has gone out of scope.
    private var noteRow: NSGridRow?
    private var loginButtonRow: NSGridRow?

    /// - Parameter version: what to print at the foot of the window, or `nil`
    ///   to print nothing. An argument rather than a direct read of
    ///   `Bundle.main`, because under `swift test` the main bundle is the test
    ///   runner: a window that asked the bundle itself could only be tested
    ///   against whatever version the test harness happens to carry.
    init(settings: Settings,
         launchAtLogin: LaunchAtLogin = .system,
         version: String? = AppVersion.current,
         onChange: @escaping (Settings) -> Void) {
        self.settings = settings
        self.launchAtLogin = launchAtLogin
        self.version = version
        self.onChange = onChange

        let window = EscapeClosingWindow(
            // Zero on both axes: Auto Layout sizes this window from the grid.
            // A width typed here is a width the grid has to absorb, and it
            // absorbs it in the one column that is free to grow — column 0,
            // which is `.trailing`, so the slack lands to the *left* of every
            // label. The user's report ("too much empty space on the left")
            // was 57pt of exactly that, measured between the 20pt margin and
            // the word "Refresh".
            contentRect: NSRect(x: 0, y: 0, width: 0, height: 0),
            // No `.resizable`: an `NSGridView` of six rows has one correct
            // size and dragging its corner can only spoil it.
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = ErrorText.settingsTitle
        // The window is closed and reopened from the menu, not destroyed —
        // `NSWindowController` would otherwise release it out from under the
        // controller that is still holding this object.
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = makeContentView()
        window.center()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowBecameKey),
            name: NSWindow.didBecomeKeyNotification, object: window)
        apply(settings)
        refreshLoginItem()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("R133: built in code, not a xib") }

    /// Push a settings value into the controls. Called at init and whenever
    /// something outside the window changes the document.
    func apply(_ settings: Settings) {
        self.settings = settings
        rowsControl.selectedSegment = SettingsForm.rows.index(of: settings.rows)
        intervalPopUp.selectItem(at:
            SettingsForm.interval.index(of: settings.refreshIntervalSeconds))
        schemePopUp.selectItem(at: SettingsForm.scheme.index(of: settings.colorScheme))
        motionControl.selectedSegment = SettingsForm.motion.index(of: settings.motionMode)
        widthSlider.doubleValue = settings.maxVisibleWidth
        speedSlider.doubleValue = settings.scrollPointsPerSecond
        refreshEffectiveLabel()
    }

    // MARK: - Layout

    private func makeContentView() -> NSView {
        rowsControl.segmentCount = SettingsForm.rows.titles.count
        rowsControl.segmentStyle = .rounded
        rowsControl.trackingMode = .selectOne
        for (index, title) in SettingsForm.rows.titles.enumerated() {
            rowsControl.setLabel(title, forSegment: index)
        }
        rowsControl.target = self
        rowsControl.action = #selector(controlChanged)

        motionControl.segmentCount = SettingsForm.motion.titles.count
        motionControl.segmentStyle = .rounded
        motionControl.trackingMode = .selectOne
        for (index, title) in SettingsForm.motion.titles.enumerated() {
            motionControl.setLabel(title, forSegment: index)
        }
        motionControl.target = self
        motionControl.action = #selector(controlChanged)

        for (popUp, titles) in [(intervalPopUp, SettingsForm.interval.titles),
                                (schemePopUp, SettingsForm.scheme.titles)] {
            popUp.removeAllItems()
            popUp.addItems(withTitles: titles)
            popUp.target = self
            popUp.action = #selector(controlChanged)
        }

        for (slider, range) in [(widthSlider, Settings.widthRange),
                                (speedSlider, Settings.speedRange)] {
            // R143: the decoder's clamps, not numbers typed again here.
            slider.minValue = range.lowerBound
            slider.maxValue = range.upperBound
            // Continuous so the strip previews as the handle moves. The write
            // to disk is coalesced by the controller, not by this.
            slider.isContinuous = true
            slider.target = self
            slider.action = #selector(controlChanged)
        }

        effectiveLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        effectiveLabel.textColor = .secondaryLabelColor

        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginCheckboxChanged)
        loginNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        loginNote.textColor = .secondaryLabelColor
        // The user's report: "Available when Squiggle is running from an app
        // bundle." arrived as "…running from ar". A `labelWithString:` field is
        // single-line and truncating, and column 1 is pinned to `columnWidth` —
        // so every note longer than that lost the half that says what to do.
        // These four together are what makes it grow downwards instead.
        loginNote.maximumNumberOfLines = 0
        loginNote.lineBreakMode = .byWordWrapping
        loginNote.cell?.wraps = true
        loginNote.preferredMaxLayoutWidth = Self.columnWidth
        loginSettingsButton.target = self
        loginSettingsButton.action = #selector(openLoginItems)
        loginSettingsButton.bezelStyle = .inline

        let divider = NSBox()
        divider.boxType = .separator

        versionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        versionLabel.textColor = .secondaryLabelColor
        if let version {
            versionLabel.stringValue = ErrorText.versionLine(version)
        }

        // Gravity areas rather than a spacer view: `.leading` hugs the left of
        // whatever width the stack is given and `.trailing` hugs the right, so
        // the two ends stay put without a third view standing between them
        // pretending to be space.
        loginRow.orientation = .horizontal
        // Baselines, not centres: the version is small-system-size and the
        // checkbox is not, and two different type sizes centred against each
        // other read as one of them sitting slightly low.
        loginRow.alignment = .firstBaseline
        loginRow.addView(loginCheckbox, in: .leading)
        loginRow.addView(versionLabel, in: .trailing)

        let grid = NSGridView(views: [
            [label(ErrorText.rowsLabel), rowsControl],
            [label(ErrorText.intervalLabel), intervalPopUp],
            [NSGridCell.emptyContentView, effectiveLabel],
            [label(ErrorText.schemeLabel), schemePopUp],
            [label(ErrorText.motionLabel), motionControl],
            [label(ErrorText.widthLabel), widthSlider],
            [label(ErrorText.speedLabel), speedSlider],
            [divider, NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, loginRow],
            [NSGridCell.emptyContentView, loginNote],
            [NSGridCell.emptyContentView, loginSettingsButton],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = Self.columnWidth
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false

        // One right edge for the whole column. Left to themselves the popups
        // stop wherever their longest title happens to end — 150pt and 127pt,
        // against sliders that run the full 240 — and the ragged edge between
        // them is most of what reads as unfinished.
        grid.column(at: 1).xPlacement = .fill
        // Except for the controls that have a correct size of their own: a
        // two-segment picker or a checkbox stretched across 240pt looks
        // stretched, not aligned.
        for natural in [rowsControl, motionControl] as [NSView] {
            grid.cell(for: natural)?.xPlacement = .leading
        }
        // `loginRow` keeps column 1's default `.fill`: the checkbox stays
        // left because its gravity area says so, and the version needs the
        // column's full width to sit against its right edge.
        grid.cell(for: loginSettingsButton)?.xPlacement = .leading

        // The divider is a rule, not a cell of content: it spans both columns.
        grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2),
                        verticalRange: NSRange(location: Row.divider, length: 1))
        grid.cell(atColumnIndex: 0, rowIndex: Row.divider).xPlacement = .fill

        // Captions belong to the control above them, so they sit closer to it
        // than the 10pt that separates one setting from the next. The divider
        // gets the opposite treatment — the login group is a separate subject.
        grid.row(at: Row.effective).topPadding = -6
        grid.row(at: Row.note).topPadding = -6
        grid.row(at: Row.loginButton).topPadding = -2
        grid.row(at: Row.divider).topPadding = 6
        grid.row(at: Row.divider).bottomPadding = 6

        noteRow = grid.row(at: Row.note)
        loginButtonRow = grid.row(at: Row.loginButton)

        let container = NSView()
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            container.trailingAnchor.constraint(equalTo: grid.trailingAnchor, constant: 20),
            container.bottomAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
        ])
        return container
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    // MARK: - Changes

    /// One action for all six controls. Reading every control on every change
    /// rather than switching on the sender means a control that is wired up
    /// but forgotten here does nothing visible, instead of writing a stale
    /// value over a fresh one.
    @objc private func controlChanged() {
        settings.rows = SettingsForm.rows.value(at: rowsControl.selectedSegment)
        settings.refreshIntervalSeconds =
            SettingsForm.interval.value(at: intervalPopUp.indexOfSelectedItem)
        settings.colorScheme = SettingsForm.scheme.value(at: schemePopUp.indexOfSelectedItem)
        settings.motionMode = SettingsForm.motion.value(at: motionControl.selectedSegment)
        settings.maxVisibleWidth = widthSlider.doubleValue
        settings.scrollPointsPerSecond = speedSlider.doubleValue
        refreshEffectiveLabel()
        onChange(settings)
    }

    private func refreshEffectiveLabel() {
        effectiveLabel.stringValue = ErrorText.effectiveInterval(
            userIntervalSeconds: settings.refreshIntervalSeconds,
            watchlistCount: watchlistCount)
    }

    // MARK: - Launch at login

    /// R146: read, never remember. The user can change this in System
    /// Settings while the window is open and nothing tells us.
    private func refreshLoginItem() {
        // `read()` cannot fail, and it is also the moment any earlier refusal
        // stops being news — the note describes one attempt, not a standing
        // condition.
        show(LoginItemOutcome(launchAtLogin.read()))
    }

    /// The seam the window tests reach for. `windowBecameKey` is the real
    /// trigger, and there is no way to make a test window become key without
    /// a running event loop, so the notification's one line of work is what
    /// gets called directly instead.
    func refreshLoginItemForTesting() { refreshLoginItem() }

    private func show(_ outcome: LoginItemOutcome) {
        let state = outcome.state
        loginCheckbox.state = state.isOn ? .on : .off
        loginCheckbox.isEnabled = state.isEnabled
        let note = ErrorText.loginItemNote(for: state, failure: outcome.failure)
        loginNote.stringValue = note ?? ""
        loginNote.isHidden = note == nil
        noteRow?.isHidden = note == nil
        loginSettingsButton.isHidden = !state.showsSystemSettingsButton
        loginButtonRow?.isHidden = !state.showsSystemSettingsButton
        // The window is not resizable, so nothing else will take the height
        // those rows just gave back.
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    @objc private func loginCheckboxChanged() {
        // The state is re-read rather than taken from the checkbox, because
        // the checkbox is a report and this is the moment it is most likely
        // to be out of date.
        let current = launchAtLogin.read()
        let wanted = loginCheckbox.state == .on
        show(launchAtLogin.apply(LaunchAtLogin.action(desired: wanted, current: current)))
    }

    @objc private func openLoginItems() {
        show(launchAtLogin.apply(.openSystemSettings))
    }

    @objc private func windowBecameKey() { refreshLoginItem() }
}

/// A window Escape closes.
///
/// `NSPanel` does this for nothing — which is why the dropdown already
/// dismisses on Escape — but a plain `NSWindow` inherits `NSResponder`'s
/// `cancelOperation(_:)`, which passes the key along and ends at a beep. The
/// settings window is a modeless dialog with nothing to commit: every control
/// writes through the moment it changes, so there is no "cancel" for Escape to
/// mean other than "put this away", and that is what the close button means
/// too.
///
/// `performClose` rather than `close` for exactly that reason: it is the close
/// button's own code path — delegate consulted, title bar flashed — so the two
/// ways out of this window cannot drift apart.
///
/// Escape inside a text field never reaches here. The field editor takes it
/// first and uses it to abandon the edit, which is the behaviour every other
/// Mac app has and not something to take away.
final class EscapeClosingWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

/// Where the app's own version number comes from.
///
/// `CFBundleShortVersionString` is the user-facing one — `1.0.0` — as against
/// `CFBundleVersion`, which is a build counter nobody wants read aloud. `nil`
/// when Squiggle is run as a bare executable with no bundle around it, which
/// `main.swift` already allows for and which has no version to report.
enum AppVersion {
    static var current: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }
}
