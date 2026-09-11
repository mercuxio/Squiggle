import AppKit

/// Process lifecycle, and nothing else. Everything the user can see belongs to
/// `StatusItemController`; this type exists to own it and to be the one place
/// that knows the app has started.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Task 6 constructs the status item here. Until then the app launches,
        // shows nothing, and keeps running — which is the correct behaviour for
        // an agent with no status item, not a stub.
    }
}
