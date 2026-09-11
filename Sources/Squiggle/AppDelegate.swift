import AppKit
import TickerCore
import YahooFeed

/// Process lifecycle, and nothing else. Everything the user can see belongs to
/// `StatusItemController`; this type exists to own it and to be the one place
/// that knows the app has started.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let url = FileWatchlistStore.defaultURL(applicationName: "Squiggle")
        let store = FileWatchlistStore(url: url)

        // A store that will not load is not a reason to refuse to launch: an
        // empty watchlist is a usable app with an empty strip. Task 6 dropped
        // the fault on the floor with a `try?` and a note saying this task
        // would pick it up; this is that. Spec §7 puts it in the dropdown
        // footer, and nowhere else — no alert, no notification.
        var document = Store()
        var storeFault: TickerError?
        do {
            document = try store.load()
        } catch let error as TickerError {
            storeFault = error
        } catch {
            storeFault = .storeQuarantineFailed(at: url)
        }

        let runner = TickerRunner(symbols: document.symbols,
                                  userIntervalSeconds: document.settings.refreshIntervalSeconds,
                                  fetcher: YahooClient())
        let controller = StatusItemController(runner: runner, store: store, storeURL: url,
                                              document: document, storeFault: storeFault)
        self.controller = controller
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}
