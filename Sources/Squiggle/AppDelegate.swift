import AppKit
import TickerCore
import YahooFeed

/// Process lifecycle, and nothing else. Everything the user can see belongs to
/// `StatusItemController`; this type exists to own it and to be the one place
/// that knows the app has started.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = FileWatchlistStore(url: FileWatchlistStore.defaultURL(applicationName: "Squiggle"))
        // A store that will not load is not a reason to refuse to launch: an
        // empty watchlist is a usable app with an empty strip, and spec §7
        // puts the explanation in the dropdown footer rather than an alert.
        // Task 11 carries the fault into that footer; this keeps the launch.
        let loaded = try? store.load()
        let settings = loaded?.settings ?? Settings()
        let symbols = loaded?.symbols ?? []

        let runner = TickerRunner(symbols: symbols,
                                  userIntervalSeconds: settings.refreshIntervalSeconds,
                                  fetcher: YahooClient())
        let controller = StatusItemController(runner: runner, settings: settings)
        self.controller = controller
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}
