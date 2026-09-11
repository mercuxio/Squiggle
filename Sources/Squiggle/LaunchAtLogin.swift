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

    /// - Parameter bundled: whether this process has an `.app` to register at
    ///   all. It is a separate argument because no `SMAppService.Status` value
    ///   answers it — see the `.notFound` arm.
    ///
    /// R147: `SMAppService.Status` is an imported, non-frozen enum, so Swift
    /// requires the `@unknown default`. It is the opposite of the `default:`
    /// this project bans: every known case is still listed by name, and this
    /// arm catches only values from an SDK that does not exist yet — for which
    /// "disable the control" is the honest answer.
    init(status: SMAppService.Status, bundled: Bool) {
        guard bundled else {
            self = .unavailable
            return
        }
        switch status {
        case .enabled: self = .on
        case .notRegistered: self = .off
        // `.off`, not `.unavailable`. This arm used to read `.notFound` as
        // "there is no bundle", and that was the defect behind the user's
        // "why is the open at login checkbox disabled?": a correctly signed
        // bundle in /Applications reports `.notFound` until the first
        // successful registration, so the one state where ticking the box
        // would have worked was the state that greyed the box out.
        //
        // Pitch never hit this because it disables its item for
        // `.requiresApproval` only and otherwise just tries.
        case .notFound: self = .off
        case .requiresApproval: self = .needsApproval
        @unknown default: self = .unavailable
        }
    }

    /// Ticked only when the app will actually launch. See R146.
    var isOn: Bool { self == .on }

    var isEnabled: Bool { self != .unavailable }

    var showsSystemSettingsButton: Bool { self == .needsApproval }
}

/// Why a registration attempt did not take, reduced to the two facts that are
/// safe to put on screen.
///
/// Deliberately *not* the error's `localizedDescription`. R44 wants this line
/// pasteable into a support email, and Foundation's descriptions routinely
/// name the file they were about — `/Applications/Squiggle.app`, or worse, a
/// path under the user's home. The domain and code identify the failure
/// exactly as well for anyone who can act on it.
struct LoginItemFailure: Equatable, Sendable {
    let domain: String
    let code: Int

    init(domain: String, code: Int) {
        self.domain = domain
        self.code = code
    }

    /// Every `Error` bridges to `NSError`, so this needs no per-framework
    /// knowledge — and it drops `userInfo` on the floor, which is where the
    /// paths live.
    init(_ error: Error) {
        let bridged = error as NSError
        self.init(domain: bridged.domain, code: bridged.code)
    }
}

/// What `apply` came back with: the state the system reports *now*, plus the
/// reason it is not the state that was asked for, if there is one.
///
/// The two are separate because they answer different questions. The state
/// says what will happen at the next login; the failure says why nothing
/// happened just now. A refusal leaves the state unchanged and perfectly
/// truthful — which is exactly why, before this existed, the app had nothing
/// to show for it.
struct LoginItemOutcome: Equatable, Sendable {
    let state: LoginItemState
    let failure: LoginItemFailure?

    init(_ state: LoginItemState, failure: LoginItemFailure? = nil) {
        self.state = state
        self.failure = failure
    }
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
    var apply: (LoginItemAction) -> LoginItemOutcome

    @MainActor
    static let system = LaunchAtLogin(
        read: { LoginItemState(status: SMAppService.mainApp.status,
                               bundled: isBundledApp(.main)) },
        apply: { action in
            // Throwing here is not exceptional: an unsigned bundle, a
            // translocated copy running from a quarantined download, or a
            // daemon that is already registered all land here.
            //
            // This used to be `try?`, and that was the defect behind the
            // user's "the checkbox doesn't work". A refusal leaves the status
            // exactly where it was, so re-reading it — which spec §6 requires,
            // and which is the honest thing to show — produced a checkbox that
            // silently sprang back with no way for the app, or the user, to
            // learn why. Spec §7 allows no alert, so the reason goes to the
            // note line under the checkbox instead.
            var failure: LoginItemFailure?
            switch action {
            case .register:
                do { try SMAppService.mainApp.register() }
                catch { failure = LoginItemFailure(error) }
            case .unregister:
                do { try SMAppService.mainApp.unregister() }
                catch { failure = LoginItemFailure(error) }
            case .openSystemSettings:
                SMAppService.openSystemSettingsLoginItems()
            case .nothing:
                break
            }
            return LoginItemOutcome(
                LoginItemState(status: SMAppService.mainApp.status,
                               bundled: isBundledApp(.main)),
                failure: failure)
        })

    /// Is there an `.app` here to register?
    ///
    /// The question `SMAppService` cannot answer. `swift run` puts the binary
    /// in `.build` and a test process puts it in an `.xctest`; neither is an
    /// app bundle, and neither can be a login item. Asked of `Bundle` rather
    /// than inferred from a status code, which is what got this wrong before.
    static func isBundledApp(_ bundle: Bundle) -> Bool {
        bundle.bundleURL.pathExtension == "app"
    }

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
