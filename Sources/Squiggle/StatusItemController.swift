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

        render()
        scheduleStep(after: 0)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
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

    /// Task 10 replaces this with the notification-driven version (R134).
    /// Until then the status item is always treated as visible, which is the
    /// conservative answer: it costs requests, never correctness.
    private func visibility() -> Visibility { .visible }

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
        tickerView.apply(layout: layout,
                         metrics: metrics,
                         visibleWidth: settings.maxVisibleWidth,
                         pointsPerSecond: settings.scrollPointsPerSecond,
                         color: { _ in NSColor.labelColor.cgColor })
    }
}
