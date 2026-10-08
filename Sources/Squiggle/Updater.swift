import Foundation
import Sparkle

/// The seam between the Settings form and Sparkle, in the shape
/// `LaunchAtLogin` already uses: a struct of closures with one real
/// implementation, so that exactly one file in the app imports Sparkle and
/// the window never touches it.
///
/// Updates come from the appcast named by `SUFeedURL` in `Resources/Info.plist`
/// and are verified against `SUPublicEDKey` there. Sparkle does the download,
/// the signature check, and the replacement; nothing in Squiggle re-implements
/// any of that.
struct UpdateChecker {
    /// Whether there is anything to check. False when the process has no app
    /// bundle around it — `swift run`, or a test runner — which is both the
    /// case Sparkle cannot work in and the case where showing the controls
    /// would be a lie.
    var isAvailable: Bool
    var automaticallyChecks: () -> Bool
    var setAutomaticallyChecks: (Bool) -> Void
    /// Opens Sparkle's own check-for-updates UI: its progress sheet, its
    /// release notes window, its "you're up to date" alert. Spec §7 bans
    /// alerts the *app* raises about its own state; this is the user asking
    /// a question and getting an answer, which is a different thing.
    var checkNow: () -> Void

    /// What the app uses when it has no bundle, and what the tests get by
    /// default: every control hidden, nothing started, no network.
    ///
    /// `@MainActor` for the same reason `LaunchAtLogin.system` is: the app's
    /// UI is main-actor-only throughout, and that is cheaper than making a
    /// struct of closures `Sendable`.
    @MainActor
    static let unavailable = UpdateChecker(
        isAvailable: false,
        automaticallyChecks: { false },
        setAutomaticallyChecks: { _ in },
        checkNow: {})

    /// The real one. A computed property over a lazy singleton rather than a
    /// `static let` of its own, so that merely *mentioning* this in a default
    /// argument — which `SettingsWindowController`'s initializer does, and
    /// which the tests therefore evaluate — does not start an updater.
    @MainActor
    static var sparkle: UpdateChecker {
        guard let updater = SparkleUpdater.shared else { return .unavailable }
        return UpdateChecker(
            isAvailable: true,
            automaticallyChecks: { updater.automaticallyChecks },
            setAutomaticallyChecks: { updater.automaticallyChecks = $0 },
            checkNow: { updater.checkNow() })
    }

    /// Can Sparkle run here at all? Both halves are required: an `.app` to
    /// replace, and a feed to replace it from. The second is not paranoia —
    /// Sparkle treats a missing `SUFeedURL` as a programming error and says
    /// so on screen, and a build with the key dropped from the plist should
    /// quietly have no updater instead.
    static func canUpdate(_ bundle: Bundle) -> Bool {
        canUpdate(bundled: LaunchAtLogin.isBundledApp(bundle),
                  feedURL: bundle.infoDictionary?["SUFeedURL"] as? String)
    }

    /// The decision itself, with the bundle read already done. Split out for
    /// the same reason `LaunchAtLogin.action(desired:current:)` is: a test can
    /// state all four combinations, where it cannot conjure a `Bundle` whose
    /// path ends in `.app` and whose plist carries a feed.
    static func canUpdate(bundled: Bool, feedURL: String?) -> Bool {
        bundled && feedURL != nil
    }
}

/// Holds the one `SPUStandardUpdaterController` for the life of the process.
///
/// It has to be held: the controller owns the updater, and an updater that
/// goes out of scope stops checking. `shared` is `nil` rather than absent when
/// there is no bundle, which is what keeps `UpdateChecker.unavailable` honest.
@MainActor
private final class SparkleUpdater {
    static let shared: SparkleUpdater? =
        UpdateChecker.canUpdate(.main) ? SparkleUpdater() : nil

    /// `startingUpdater: true` schedules the background check Sparkle's own
    /// `SUEnableAutomaticChecks` key permits. No delegates: Squiggle has no
    /// opinion about which version it is offered, and no UI of its own to
    /// drive — Sparkle's standard user driver is the whole interface.
    private let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkNow() { controller.checkForUpdates(nil) }
}
