import AppKit

/// Registers for the notifications spec §5.2 cares about and reduces them into
/// a `PauseConditions`, calling back whenever the answer changes.
///
/// Only when it *changes*: macOS is generous with these notifications, and
/// re-applying a pause that is already in effect would reset the animation's
/// captured `timeOffset` and make the strip jump on resume — the exact glitch
/// `speed = 0` exists to avoid.
@MainActor
final class PauseMonitor {
    private(set) var conditions = PauseConditions()
    private let onChange: @MainActor (PauseConditions) -> Void
    private var tokens: [any NSObjectProtocol] = []

    init(onChange: @MainActor @escaping (PauseConditions) -> Void) {
        self.onChange = onChange
    }

    /// `window` is the status item button's window. It is nil until the item
    /// has been placed in the bar, which is why this is a separate call rather
    /// than work done in `init`.
    func start(observing window: NSWindow?) {
        stop()

        for name in PauseEvent.observedDistributedNames {
            let token = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] note in
                guard let event = PauseEvent(distributedName: note.name.rawValue) else { return }
                MainActor.assumeIsolated { self?.handle(event) }
            }
            tokens.append(token)
        }

        for name in PauseEvent.observedWorkspaceNames {
            let token = NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] note in
                guard let event = PauseEvent(workspaceName: note.name) else { return }
                MainActor.assumeIsolated { self?.handle(event) }
            }
            tokens.append(token)
        }

        if let window {
            let token = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main
            ) { [weak self] note in
                let isVisible = (note.object as? NSWindow)?
                    .occlusionState.contains(.visible) ?? true
                MainActor.assumeIsolated {
                    self?.handle(.occlusionChanged(isVisible: isVisible))
                }
            }
            tokens.append(token)
            // The window already has an occlusion state by the time we get
            // here; waiting for it to *change* would leave a status item that
            // launched behind the notch animating until something moved.
            handle(.occlusionChanged(isVisible: window.occlusionState.contains(.visible)))
        }
    }

    func stop() {
        for token in tokens {
            DistributedNotificationCenter.default().removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
        tokens = []
    }

    private func handle(_ event: PauseEvent) {
        let before = conditions
        conditions.apply(event)
        guard conditions != before else { return }
        onChange(conditions)
    }
}
