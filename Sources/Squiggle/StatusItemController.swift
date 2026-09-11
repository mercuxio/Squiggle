import AppKit
import TickerCore

/// The `NSStatusItem`, and the one real timer in the app (spec §2.2).
///
/// The timer is a one-shot, rescheduled after every step rather than a
/// repeating one: the interval `FeedEngine` asks for changes with the market
/// state, Low Power Mode, and the ladder's cooldown, so a repeating timer
/// would be answering a question that had already changed.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let runner: TickerRunner
    private var settings: Settings
    private var timer: Timer?
    private let tickerView = TickerView()
    // Retained by `NotificationCenter` until removed, same as `timer` is
    // retained by the run loop until invalidated — `stop()` tears both down
    // for the same reason.
    private var reduceMotionObserver: NSObjectProtocol?
    private var pauseMonitor: PauseMonitor?
    private var pauseConditions = PauseConditions()

    init(runner: TickerRunner, settings: Settings) {
        self.runner = runner
        self.settings = settings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = ""
    }

    func start() {
        guard let button = statusItem.button else { return }
        // The button keeps its click handling (the dropdown, Task 11); the
        // view only draws. Replacing the button with a custom view would give
        // up the highlight and the menu behaviour, which is a poor trade for
        // one subview.
        //
        // `init` already cleared `title`; this clears the attributed one Task
        // 6's `render()` was setting, because an empty view over a stale
        // title shows the title.
        button.attributedTitle = NSAttributedString(string: "")
        tickerView.frame = button.bounds
        tickerView.autoresizingMask = [.width, .height]
        button.addSubview(tickerView)

        // Reduce Motion can be toggled while Squiggle is running, and a user
        // who turns it on because a marquee is making them ill should not have
        // to quit the app to be rid of it.
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.render() }
            }

        let monitor = PauseMonitor { [weak self] conditions in
            self?.applyPause(conditions)
        }
        monitor.start(observing: button.window)
        pauseMonitor = monitor

        render()
        scheduleStep(after: 0)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let reduceMotionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(reduceMotionObserver)
        }
        reduceMotionObserver = nil
        pauseMonitor?.stop()
        pauseMonitor = nil
    }

    /// Spec §5.2: pausing is `speed = 0` with the offset captured, never a
    /// removal — removing and re-adding makes the strip jump.
    ///
    /// The refresh side needs nothing here. `visibility()` reads
    /// `pauseConditions` on the next scheduled step, and forcing a step now
    /// would turn every unlock into an unscheduled request.
    private func applyPause(_ conditions: PauseConditions) {
        pauseConditions = conditions
        if conditions.isPaused {
            tickerView.pause()
        } else {
            tickerView.resume()
        }
    }

    private func scheduleStep(after seconds: Double) {
        timer?.invalidate()
        let delay = max(seconds, RateConstants.minimumWaitSeconds)
        let fired = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            // `Timer`'s block is not main-actor-isolated, so hop explicitly
            // rather than annotating the closure and hoping.
            Task { @MainActor in await self?.stepOnce() }
        }
        // R56: let the OS coalesce this wakeup with other system timers. The
        // app is explicitly not time-critical, and tolerance buys more
        // battery than any interval choice does.
        fired.tolerance = delay * RateConstants.timerLeewayFraction
        timer = fired
        RunLoop.main.add(fired, forMode: .common)
    }

    private func stepOnce() async {
        let wait = await runner.step(nowEpoch: Date().timeIntervalSince1970,
                                     visibility: visibility(),
                                     lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
        render()
        scheduleStep(after: wait)
    }

    /// R134: reads the state `PauseMonitor` maintains rather than polling
    /// anything itself. `pauseConditions` is updated only when it changes, so
    /// this is always the answer as of the most recent notification, not a
    /// snapshot taken here.
    private func visibility() -> Visibility { pauseConditions.visibility }

    private func render() {
        let metrics = StripRenderer.metrics(rows: settings.rows,
                                            barHeight: Double(NSStatusBar.system.thickness))
        // R131: the closure binds the font, so `StripLayout` never sees one.
        let font = metrics.font
        let measure: (String) -> Double = { text in
            Double((text as NSString).size(withAttributes: [.font: font]).width)
        }
        let layout = StripLayout.build(symbols: runner.symbols,
                                       quotes: runner.quotes,
                                       dead: runner.deadSymbols,
                                       rows: metrics.rowCount,
                                       gap: 20,
                                       measure: measure)
        // Spec §5.1: a *fixed*-width status item. Task 6 created it
        // `variableLength` because a button sized to its title was the honest
        // thing while a title was what it drew; a marquee needs a window that
        // does not resize itself to the content it is meant to clip.
        statusItem.length = settings.maxVisibleWidth
        // R136: Monochrome is the default scheme, so this is the app's real
        // default appearance rather than a placeholder. Task 12 replaces the
        // closure, not the call.
        let requested = MotionMode(setting: settings.motionMode)
        let mode = MotionPolicy.effective(
            requested: requested,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        tickerView.apply(layout: layout,
                         metrics: metrics,
                         visibleWidth: settings.maxVisibleWidth,
                         mode: mode,
                         pointsPerSecond: settings.scrollPointsPerSecond,
                         color: { _ in NSColor.labelColor.cgColor })
    }
}
