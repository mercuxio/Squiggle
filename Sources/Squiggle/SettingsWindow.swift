import AppKit
import TickerCore

/// Spec build-order step 7, minus launch-at-login (Task 14).
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
    /// The watchlist size the effective-interval line is computed against.
    /// Set by the controller, because the window does not own the watchlist
    /// and the number changes under it when Task 15 adds a symbol.
    var watchlistCount = 0 { didSet { refreshEffectiveLabel() } }

    init(settings: Settings, onChange: @escaping (Settings) -> Void) {
        self.settings = settings
        self.onChange = onChange

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 0),
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
        apply(settings)
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

        let grid = NSGridView(views: [
            [label(ErrorText.rowsLabel), rowsControl],
            [label(ErrorText.intervalLabel), intervalPopUp],
            [NSGridCell.emptyContentView, effectiveLabel],
            [label(ErrorText.schemeLabel), schemePopUp],
            [label(ErrorText.motionLabel), motionControl],
            [label(ErrorText.widthLabel), widthSlider],
            [label(ErrorText.speedLabel), speedSlider],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 220
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false

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
}
