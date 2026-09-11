import AppKit
import ServiceManagement

/// What the system will do at the next login, as this app is allowed to see it.
///
/// Four states and not a `Bool`, because two of them are not "off": one is
/// "registered, and the user has switched it off in System Settings", which
/// this app cannot change, and one is "there is no bundle to register", which
/// is what `swift run` gives you.
enum LoginItemState: Equatable, Sendable {
    case on
    case off
    /// Registered, but switched off by the user in System Settings. It will
    /// not launch, and no API here can change that.
    case needsApproval
    /// No bundle — running from `.build`, or a test process.
    case unavailable

    /// R147: `SMAppService.Status` is an imported, non-frozen enum, so Swift
    /// requires the `@unknown default`. It is the opposite of the `default:`
    /// this project bans: every known case is still listed by name, and this
    /// arm catches only values from an SDK that does not exist yet — for which
    /// "disable the control" is the honest answer.
    init(status: SMAppService.Status) {
        switch status {
        case .enabled: self = .on
        case .notRegistered: self = .off
        case .requiresApproval: self = .needsApproval
        case .notFound: self = .unavailable
        @unknown default: self = .unavailable
        }
    }

    /// Ticked only when the app will actually launch. See R146.
    var isOn: Bool { self == .on }

    var isEnabled: Bool { self != .unavailable }

    var showsSystemSettingsButton: Bool { self == .needsApproval }
}

enum LoginItemAction: Equatable {
    case register
    case unregister
    case openSystemSettings
    case nothing
}

/// The seam between the window and `SMAppService`.
///
/// A struct of closures rather than a protocol: there is exactly one real
/// implementation and the tests do not need a fake — every decision worth
/// testing is in `action(desired:current:)`, which is pure. This exists so
/// that the window never touches `SMAppService` directly, which keeps the
/// registration calls in one file next to the reasons they can fail.
struct LaunchAtLogin {
    var read: () -> LoginItemState
    /// Performs the action and returns the state afterwards, read back from
    /// the system rather than assumed from what was asked (spec §6).
    var apply: (LoginItemAction) -> LoginItemState

    @MainActor
    static let system = LaunchAtLogin(
        read: { LoginItemState(status: SMAppService.mainApp.status) },
        apply: { action in
            switch action {
            case .register:
                // Throwing here is not exceptional: an unsigned bundle, a
                // translocated copy running from a quarantined download, or a
                // daemon that is already registered all land here. There is no
                // alert to show (spec §7 allows none), and the state read back
                // below is what the user sees — an unchanged checkbox, which
                // is the truth.
                try? SMAppService.mainApp.register()
            case .unregister:
                try? SMAppService.mainApp.unregister()
            case .openSystemSettings:
                SMAppService.openSystemSettingsLoginItems()
            case .nothing:
                break
            }
            return LoginItemState(status: SMAppService.mainApp.status)
        })

    /// What clicking the checkbox should do, given what the system currently
    /// says. Pure, and the only place the four states turn into calls.
    static func action(desired: Bool, current: LoginItemState) -> LoginItemAction {
        switch current {
        case .unavailable:
            return .nothing
        case .on:
            return desired ? .nothing : .unregister
        case .off:
            return desired ? .register : .nothing
        case .needsApproval:
            // `register()` on an already-registered service throws, and would
            // not clear the user's own switch even if it did not. The only
            // thing that helps is showing them where the switch is.
            return desired ? .openSystemSettings : .unregister
        }
    }
}
