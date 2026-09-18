import Observation
import TickerCore

/// `TickerCore`'s `Settings`, by a name SwiftUI does not also use. The files
/// that import SwiftUI see two `Settings`, and `TickerCore.Settings` cannot
/// break the tie because the module holds an enum called `TickerCore` too.
/// Declared here because this file imports only the one.
typealias TickerSettings = Settings

/// Everything the Settings window shows, as state SwiftUI can observe.
///
/// The window used to keep this in the fields of an AppKit controller and push
/// it into controls by hand. Now the form reads it and writes it back, and the
/// tests talk to this directly instead of hunting for controls by their text.
///
/// Every edit applies immediately: there is no OK and no Cancel. Spec §4.1
/// requires the effective-interval line to update live beside the choice, and
/// a window that previewed one setting while queueing six others behind a
/// button would be lying about which of them had taken effect.
@MainActor
@Observable
final class SettingsModel {
    private(set) var settings: TickerSettings
    /// The watchlist size the effective-interval line is computed against.
    /// Set by the controller, because the window does not own the watchlist
    /// and the number changes under it.
    var watchlistCount = 0
    private(set) var loginState: LoginItemState = .off
    /// The last refusal, if the last attempt was refused. Describes one
    /// attempt, not a standing condition, so `refreshLoginItem` clears it.
    private(set) var loginFailure: LoginItemFailure?
    let version: String?

    @ObservationIgnored private let launchAtLogin: LaunchAtLogin
    @ObservationIgnored private let onChange: (TickerSettings) -> Void

    init(settings: TickerSettings,
         launchAtLogin: LaunchAtLogin,
         version: String?,
         onChange: @escaping (TickerSettings) -> Void) {
        self.settings = settings
        self.launchAtLogin = launchAtLogin
        self.version = version
        self.onChange = onChange
        refreshLoginItem()
    }

    // MARK: - Settings

    /// Something outside the window changed the document. Not reported back
    /// through `onChange`: the change came from there.
    func apply(_ settings: TickerSettings) {
        self.settings = settings
    }

    /// The one way the form changes a setting, so no control can forget to
    /// report its change.
    func edit(_ change: (inout TickerSettings) -> Void) {
        change(&settings)
        onChange(settings)
    }

    var effectiveInterval: String {
        ErrorText.effectiveInterval(userIntervalSeconds: settings.refreshIntervalSeconds,
                                    watchlistCount: watchlistCount)
    }

    var versionLine: String? { version.map(ErrorText.versionLine) }

    // MARK: - Launch at login (R146)

    var loginNote: String? {
        ErrorText.loginItemNote(for: loginState, failure: loginFailure)
    }

    /// R146: read, never remember. The user can change this in System
    /// Settings while the window is open and nothing tells us, so this runs
    /// every time the window becomes key.
    func refreshLoginItem() {
        loginState = launchAtLogin.read()
        loginFailure = nil
    }

    /// The toggle's setter. The state is read again rather than taken from
    /// the toggle, because the toggle is a report and this is the moment it
    /// is most likely to be out of date.
    func setLaunchAtLogin(_ wanted: Bool) {
        let action = LaunchAtLogin.action(desired: wanted, current: launchAtLogin.read())
        show(launchAtLogin.apply(action))
    }

    func openLoginItems() {
        show(launchAtLogin.apply(.openSystemSettings))
    }

    private func show(_ outcome: LoginItemOutcome) {
        loginState = outcome.state
        loginFailure = outcome.failure
    }
}
