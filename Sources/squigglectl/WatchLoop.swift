import Foundation
import TickerCore
import YahooFeed

/// Runs the real engine against the real endpoint, printing one line per
/// event. This is what Task 19's trading-day verification leaves running.
///
/// It deliberately duplicates none of the engine's decisions: it asks,
/// obeys, and reports. If this loop ever grows a rule of its own, that rule
/// belongs in `FeedEngine`, where the tests can reach it.
struct WatchLoop {
    let client: YahooClient
    let store: FileWatchlistStore
    let symbols: [Symbol]
    let intervalSeconds: Double
    let maxCycles: Int?

    /// R56: turns the seconds `FeedEngine` says to sleep into the timer
    /// leeway handed to `Task.sleep(for:tolerance:)`, so the OS can coalesce
    /// this wakeup with other system timers instead of waking the CPU on a
    /// schedule nobody asked for. Squiggle's hardest requirement is
    /// resource efficiency — "it's not time critical" — and tolerance is a
    /// bigger win here than shortening the interval would be.
    ///
    /// A non-private `static func`, not inlined at the call site, so the
    /// value/proportionality relationship is directly testable without
    /// standing up a whole loop or a real clock.
    static func tolerance(forSleep seconds: Double) -> Double {
        max(0, seconds) * RateConstants.timerLeewayFraction
    }

    func run() async -> Int32 {
        let clock = SystemClock()
        var engine = FeedEngine(clock: clock, symbols: symbols,
                                userIntervalSeconds: intervalSeconds)

        // A cooldown that outlived the previous process must outlive this
        // one too, or relaunching becomes a way around a 429 (spec §4.3).
        // A store that fails to load for any other reason (first launch, a
        // quarantined file) is not this loop's problem to diagnose — that is
        // `squigglectl doctor`'s job — so it is silently treated as "nothing
        // persisted" here.
        if let persisted = try? store.load().cooldownUntilEpoch {
            engine.adoptPersistedCooldown(untilEpoch: persisted,
                                          nowEpoch: Date().timeIntervalSince1970)
            log("adopted a persisted cooldown")
        }

        // Updated from whichever fetch last carried a trading calendar.
        // Kept local to `run()`, not stored on `self`: nothing outside this
        // loop iteration needs them, and a local `var` avoids making this
        // method `mutating` for state no caller will ever read back.
        var marketState: MarketState?
        var nextOpen: Double?
        var fetches = 0

        while maxCycles == nil || fetches < (maxCycles ?? 0) {
            let now = Date().timeIntervalSince1970
            let context = EngineContext(
                nowEpoch: now,
                // The CLI has no market calendar of its own; it uses the one
                // Yahoo already told it about, which is exactly what the app
                // will do. Before the first successful quote it assumes the
                // market is open — one wasted request beats never starting.
                marketState: marketState ?? .regular,
                visibility: .visible,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                nextSessionOpenEpoch: nextOpen)

            switch engine.next(context) {
            case .sleep(let seconds):
                log("sleep \(Int(seconds))s")
                try? await Task.sleep(for: .seconds(seconds),
                                      tolerance: .seconds(Self.tolerance(forSleep: seconds)))

            case .fetch(let symbol):
                fetches += 1
                do {
                    // ONE request. The quote and the market calendar both
                    // come out of the same body (spec §3.2); asking a
                    // second endpoint for the calendar would double the
                    // daily budget.
                    let snapshot = try await client.snapshot(for: symbol)
                    engine.recordSuccess(snapshot.quote, for: symbol)
                    log(Rendering.line(snapshot.quote))
                    if let period = snapshot.tradingPeriod {
                        marketState = period.state(atEpoch: now)
                        nextOpen = period.nextSessionOpenEpoch(after: now)
                    }
                } catch let error as TickerError {
                    engine.record(error, for: symbol)
                    log("\(symbol.raw): \(Rendering.diagnosis(error))")
                } catch {
                    // Not a `TickerError` at all — `YahooClient` promises to
                    // throw only that type, but nothing in the language
                    // enforces that promise across an `async throws`
                    // boundary, so this still needs a home rather than a
                    // silently-dropped catch.
                    let wrapped = TickerError.transport(String(describing: error))
                    engine.record(wrapped, for: symbol)
                    log("\(symbol.raw): \(Rendering.diagnosis(wrapped))")
                }
            }
        }
        return 0
    }

    private func log(_ message: String) {
        print(message)
    }
}
