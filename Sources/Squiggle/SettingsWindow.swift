import AppKit
import SwiftUI
import TickerCore

/// Spec build-order step 7, including launch-at-login (Task 14).
///
/// An AppKit window around a SwiftUI grouped form, the same arrangement
/// Sniffcast uses, so the two apps' settings look alike. The window stays
/// AppKit because the app is AppKit: it is opened from the dropdown, closed by
/// Escape, and kept alive between openings by this controller.
///
/// The state lives in `SettingsModel`; this class only owns the window and
/// passes the outside world's changes in.
@MainActor
final class SettingsWindowController: NSWindowController {
    let model: SettingsModel

    /// The watchlist size the effective-interval line is computed against.
    /// `StatusItemController.openSettings` seeds it, and `add` and
    /// `removeSymbol` push every later change. Spec §4.1 put this line here to
    /// stop the app quoting a cadence it will not keep, which it would do the
    /// moment the count moved without it.
    var watchlistCount: Int {
        get { model.watchlistCount }
        set { model.watchlistCount = newValue }
    }

    /// - Parameter version: what to print at the foot of the window, or `nil`
    ///   to print nothing. An argument rather than a direct read of
    ///   `Bundle.main`, because under `swift test` the main bundle is the test
    ///   runner: a window that asked the bundle itself could only be tested
    ///   against whatever version the test harness happens to carry.
    /// - Parameter onChange: called with the edited settings after every
    ///   change. The controller re-renders immediately and persists on a short
    ///   delay — see `StatusItemController.settingsChanged`.
    init(settings: TickerSettings,
         launchAtLogin: LaunchAtLogin = .system,
         version: String? = AppVersion.current,
         onChange: @escaping (TickerSettings) -> Void) {
        model = SettingsModel(settings: settings,
                              launchAtLogin: launchAtLogin,
                              version: version,
                              onChange: onChange)

        let hosting = NSHostingController(rootView: SettingsView(model: model))
        // The form decides the window's size, and a note appearing under the
        // login toggle grows it rather than being clipped.
        hosting.sizingOptions = .preferredContentSize
        let window = EscapeClosingWindow(contentViewController: hosting)
        // No `.resizable`: the form has one correct size.
        window.styleMask = [.titled, .closable]
        window.title = ErrorText.settingsTitle
        // The window is closed and reopened from the menu, not destroyed —
        // `NSWindowController` would otherwise release it out from under the
        // controller that is still holding this object.
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowBecameKey),
            name: NSWindow.didBecomeKeyNotification, object: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not a xib") }

    /// Push a settings value into the form. Called whenever something outside
    /// the window changes the document.
    func apply(_ settings: TickerSettings) {
        model.apply(settings)
    }

    /// R146: the user can change Login Items in System Settings while this
    /// window is open, so the state is read again whenever it comes forward.
    @objc private func windowBecameKey() { model.refreshLoginItem() }
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
