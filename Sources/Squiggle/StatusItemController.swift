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

    init(runner: TickerRunner, settings: Settings) {
        self.runner = runner
        self.settings = settings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = ""
    }

    func start() {
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

    /// Task 8 replaces this with the Core Animation strip. For now the first
    /// row is painted, static, into the button's title — the whole data path
    /// under a user's eye with none of Core Animation in the way.
    private func render() {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let layout = StripLayout.build(
            symbols: runner.symbols, quotes: runner.quotes,
            dead: runner.deadSymbols, rows: 1, gap: 20,
            measure: { ($0 as NSString).size(withAttributes: [.font: font]).width })

        let line = NSMutableAttributedString()
        for segment in layout.rows[0].segments {
            line.append(NSAttributedString(string: segment.text,
                                           attributes: [.font: font,
                                                        .foregroundColor: NSColor.labelColor]))
        }
        button.attributedTitle = line
    }
}
