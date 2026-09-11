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

    /// One trading calendar per symbol, and the aggregate the engine actually
    /// consumes.
    ///
    /// The engine takes a *single* `marketState`, so something has to turn N
    /// calendars into one. Keeping only the most recent one — which is what
    /// this loop did before — makes the answer depend on which symbol happened
    /// to be fetched last, and the two failure directions are not symmetric:
    ///
    /// - A crypto symbol fetched last reports `.regular` at 03:00, and every
    ///   equity symbol is then polled as though its exchange were open.
    /// - An equity symbol fetched last reports `.closed` with a 09:30 open,
    ///   and `RefreshPolicy` then puts the **whole loop** to sleep until 09:30
    ///   — including the 24-hour instrument, which had a live price the entire
    ///   time. A ticker that shows a nine-hour-old crypto price is broken in a
    ///   way that a ticker making a few extra requests is not.
    ///
    /// So the aggregate is the *most open* state across the live watchlist,
    /// and the wake is the *earliest* open across it. The loop never sleeps
    /// through a session that some symbol it is watching is actually in.
    ///
    /// The cost of the first direction is real and is paid deliberately: the
    /// nineteen equity symbols do get polled overnight at the continuous
    /// cadence. It is affordable only because `RefreshPolicy.budgetFloor`
    /// exists — it prices a 24-hour instrument directly, so this aggregate is
    /// bounded at the daily budget instead of running to 2,880 requests. Per-
    /// symbol *cadence* would avoid even that, but the engine paces one
    /// round-robin pass against one `cycleDeadline`; giving each symbol its own
    /// would be a redesign of `FeedEngine.next()`, not a change to this loop.
    ///
    /// Per-symbol calendars are still kept rather than aggregated on arrival,
    /// so nothing is lost: removing the crypto symbol restores the equity
    /// answer on the very next tick, with no stale `.regular` left behind.
    struct Calendars {
        private var periods: [Symbol: TradingPeriod] = [:]

        mutating func record(_ period: TradingPeriod, for symbol: Symbol) {
            periods[symbol] = period
        }

        /// Forgets calendars for symbols no longer being polled. Without this
        /// a symbol the engine has marked dead keeps voting: a delisted crypto
        /// ticker that 404s forever would hold the whole watchlist at
        /// `.regular` for the life of the process, which is the original bug
        /// with a longer fuse.
        mutating func retain(_ live: Set<Symbol>) {
            periods = periods.filter { live.contains($0.key) }
        }

        /// `nil` when nothing has reported yet — the caller decides what to
        /// assume before the first successful quote, and that assumption is
        /// not this type's to make.
        func aggregateState(atEpoch epoch: Double) -> MarketState? {
            let states = periods.values.map { $0.state(atEpoch: epoch) }
            guard !states.isEmpty else { return nil }
            return states.max { Self.openness($0) < Self.openness($1) }
        }

        /// The earliest open any watched symbol still has ahead of it. Only
        /// consulted while the aggregate is `.closed`, which by construction
        /// means every symbol is closed, so this is the first one to reopen.
        func earliestSessionOpenEpoch(after epoch: Double) -> Double? {
            periods.values.compactMap { $0.nextSessionOpenEpoch(after: epoch) }.min()
        }

        /// One symbol's own state, unaggregated. Nothing in the loop reads
        /// this; it exists so a test can show that an equity symbol keeps its
        /// own calendar while a crypto symbol drives the aggregate.
        func state(for symbol: Symbol, atEpoch epoch: Double) -> MarketState? {
            periods[symbol]?.state(atEpoch: epoch)
        }

        /// How open a state is. `.pre` outranks `.post` only to keep the
        /// aggregate deterministic when both appear — `RefreshPolicy` stretches
        /// the cycle identically for the two (`RefreshPolicy.swift`, the
        /// `quiet` term), so the choice cannot change what the engine does.
        /// A `switch` with no `default:`, so a fifth `MarketState` fails the
        /// build here rather than silently ranking as something.
        static func openness(_ state: MarketState) -> Int {
            switch state {
            case .closed: return 0
            case .post: return 1
            case .pre: return 2
            case .regular: return 3
            }
        }
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

        // One calendar per symbol, aggregated per tick — see `Calendars`.
        // Kept local to `run()`, not stored on `self`: nothing outside this
        // loop iteration needs it, and a local `var` avoids making this
        // method `mutating` for state no caller will ever read back.
        var calendars = Calendars()
        var fetches = 0

        while maxCycles == nil || fetches < (maxCycles ?? 0) {
            let now = Date().timeIntervalSince1970
            // A symbol the engine has given up on must stop voting on the
            // calendar; `deadSymbols` is the only place that fact lives.
            calendars.retain(Set(symbols).subtracting(engine.deadSymbols))
            let context = EngineContext(
                nowEpoch: now,
                // The CLI has no market calendar of its own; it uses the ones
                // Yahoo already told it about, which is exactly what the app
                // will do. Before the first successful quote it assumes the
                // market is open — one wasted request beats never starting.
                marketState: calendars.aggregateState(atEpoch: now) ?? .regular,
                visibility: .visible,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                nextSessionOpenEpoch: calendars.earliestSessionOpenEpoch(after: now))

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
                        calendars.record(period, for: symbol)
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
                    let wrapped = TickerError.transport(Rendering.transportFault(for: error))
                    engine.record(wrapped, for: symbol)
                    log("\(symbol.raw): \(Rendering.diagnosis(wrapped))")
                }
            }

            // Spec §7's live diagnosis: the running request total, tokens
            // available, both circuit states, and the ladder's remaining
            // cooldown. Free — the loop already holds the engine that knows
            // these, and this makes no request of its own.
            //
            // `fetches` was previously the `maxCycles` bound and nothing else,
            // so the only way to learn what a day cost was to count arrow
            // glyphs in the log — which counts renderings, not requests, and
            // misses every failure. It is reported here, last in the
            // iteration, so the log's final line always carries the total
            // however the run ends.
            log(Rendering.stateLine(engine.diagnosticSnapshot, requests: fetches))
        }
        return 0
    }

    private func log(_ message: String) {
        print(message)
    }
}
