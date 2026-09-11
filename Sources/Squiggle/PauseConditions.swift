import AppKit
import TickerCore

/// Something the system told us that changes whether the strip should move.
///
/// A named event rather than a raw `Notification`, so the rule ("a locked
/// screen pauses") is testable without standing up a notification centre, and
/// so the four magic strings — the ones nothing but a string literal can name,
/// unlike the compiler-checked `NSWorkspace.*` constants — live in exactly one
/// place (R138).
enum PauseEvent: Equatable, Sendable {
    case screenLocked
    case screenUnlocked
    case screensaverStarted
    case screensaverStopped
    case displaysSlept
    case displaysWoke
    case systemWillSleep
    case systemDidWake
    case occlusionChanged(isVisible: Bool)

    /// Lock and screensaver arrive on the *distributed* centre — they are
    /// broadcast by loginwindow to every process on the machine, not by our
    /// own `NSWorkspace`. This is also why the app must stay un-sandboxed:
    /// a sandboxed process registers successfully and receives nothing.
    ///
    /// These four names are undocumented but have been stable since 10.6.
    /// Being undocumented is exactly why the test asserts them character by
    /// character: nothing else will notice the day one of them changes.
    static let observedDistributedNames = [
        "com.apple.screenIsLocked",
        "com.apple.screenIsUnlocked",
        "com.apple.screensaver.didstart",
        "com.apple.screensaver.didstop",
    ]

    static let observedWorkspaceNames: [Notification.Name] = [
        NSWorkspace.screensDidSleepNotification,
        NSWorkspace.screensDidWakeNotification,
        NSWorkspace.willSleepNotification,
        NSWorkspace.didWakeNotification,
    ]

    init?(distributedName: String) {
        switch distributedName {
        case "com.apple.screenIsLocked": self = .screenLocked
        case "com.apple.screenIsUnlocked": self = .screenUnlocked
        case "com.apple.screensaver.didstart": self = .screensaverStarted
        case "com.apple.screensaver.didstop": self = .screensaverStopped
        default: return nil
        }
    }

    init?(workspaceName: Notification.Name) {
        switch workspaceName {
        case NSWorkspace.screensDidSleepNotification: self = .displaysSlept
        case NSWorkspace.screensDidWakeNotification: self = .displaysWoke
        case NSWorkspace.willSleepNotification: self = .systemWillSleep
        case NSWorkspace.didWakeNotification: self = .systemDidWake
        default: return nil
        }
    }
}

/// Which of spec §5.2's reasons to stop are currently true.
///
/// Flags, not a count. macOS sends `screenIsLocked` more than once in some
/// flows — locking and then letting the screensaver engage on top — and a
/// counter would come out of an unlock still positive, leaving the app
/// permanently paused with no way back short of a relaunch.
///
/// Everything starts false: at launch the app has been told nothing, and
/// assuming the strip is visible costs requests where the opposite assumption
/// would cost a user their prices.
struct PauseConditions: Equatable, Sendable {
    private(set) var screenIsLocked = false
    private(set) var screensaverIsRunning = false
    private(set) var displaysAreAsleep = false
    private(set) var systemIsAsleep = false
    private(set) var statusItemIsOccluded = false

    mutating func apply(_ event: PauseEvent) {
        // No `default:`. A tenth event has to be handled here rather than
        // silently doing nothing, which is the failure mode this whole type
        // exists to make impossible.
        switch event {
        case .screenLocked: screenIsLocked = true
        case .screenUnlocked: screenIsLocked = false
        case .screensaverStarted: screensaverIsRunning = true
        case .screensaverStopped: screensaverIsRunning = false
        case .displaysSlept: displaysAreAsleep = true
        case .displaysWoke: displaysAreAsleep = false
        // Deliberately narrow: waking the machine clears only the machine's
        // own flag. A wake that cleared the lock too would start the marquee
        // running behind the login window, and `screenIsUnlocked` is the
        // event that actually means what that would be claiming.
        case .systemWillSleep: systemIsAsleep = true
        case .systemDidWake: systemIsAsleep = false
        case .occlusionChanged(let isVisible): statusItemIsOccluded = (isVisible == false)
        }
    }

    var isPaused: Bool {
        screenIsLocked || screensaverIsRunning || displaysAreAsleep
            || systemIsAsleep || statusItemIsOccluded
    }

    /// The same state, as the engine reads it. `.occluded` does not mean
    /// "behind the notch" here so much as "nobody can see this" — and
    /// `RefreshPolicy` does the right thing with it either way: no fetch, and
    /// a wait of one cycle rather than an indefinite sleep, so the strip is
    /// current the moment it comes back.
    var visibility: Visibility {
        isPaused ? .occluded : .visible
    }
}
