import Foundation
import TickerCore
import YahooFeed

/// One turn of `FeedEngine`'s crank, with no timer and no printing.
/// `squigglectl`'s `WatchLoop` is the same logic wrapped in a `while`; this is
/// the same logic wrapped in nothing, so the status item's timer can drive it.
///
/// It decides nothing the engine could decide. The only state it owns that the
/// engine does not is the pair spec §7's footer needs — when the last success
/// was, and what the last failure was — which `FeedEngine` deliberately does
/// not track because nothing in its own policy depends on them.
@MainActor
final class TickerRunner {
    private var engine: FeedEngine
    private let fetcher: any QuoteFetching
    private var calendars = TradingCalendars()

    private(set) var symbols: [Symbol]
    private(set) var userIntervalSeconds: Double
    private(set) var quotes: [Symbol: Quote] = [:]
    private(set) var lastSuccessEpoch: Double?
    private(set) var lastError: TickerError?

    var deadSymbols: Set<Symbol> { engine.deadSymbols }
    var diagnosticSnapshot: FeedEngine.DiagnosticSnapshot { engine.diagnosticSnapshot }

    /// The longest gap between `nowEpoch` and a calendar's reported next open
    /// that `step` will still treat as a real market closure.
    ///
    /// No real Yahoo instrument closes longer than this — the longest US
    /// holiday weekend is a few days — so a computed gap past it means
    /// `nowEpoch` and the trading period on file are not describing the same
    /// moment (a corrected system clock, or a caller that deliberately holds
    /// `nowEpoch` far from the epoch a payload described) rather than an
    /// instrument that will not reopen for years. `RefreshPolicy` already
    /// clamps the closed-market *wait* to twelve hours
    /// (`RateConstants.maxClosedMarketWait`), but nothing clamps how many
    /// times in a row that twelve-hour wait can be reissued from the same
    /// stale inputs — and a caller that never revisits a symbol stuck this
    /// way would spin on it forever, with no fetch ever attempted and so no
    /// failure ever recorded. Trusting the calendar past this bound instead
    /// of falling back to "assume open" is what one wasted request buys.
    private static let calendarSanityWindow: Double = 7 * 24 * 3600

    init(symbols: [Symbol], userIntervalSeconds: Double,
         fetcher: any QuoteFetching, clock: any MonotonicClock = SystemClock()) {
        self.symbols = symbols
        self.userIntervalSeconds = userIntervalSeconds
        self.fetcher = fetcher
        self.engine = FeedEngine(clock: clock, symbols: symbols,
                                 userIntervalSeconds: userIntervalSeconds)
    }

    /// Ask the engine what to do and do it. Returns the seconds the caller
    /// should wait before calling again; `0` means "the engine is mid-cycle,
    /// come straight back", which the caller clamps to its own floor.
    ///
    /// Never throws. An escaping error here would kill the status item's
    /// timer and the app would sit there with a frozen price and no way to
    /// say so.
    @discardableResult
    func step(nowEpoch: Double, visibility: Visibility, lowPowerMode: Bool) async -> Double {
        calendars.retain(Set(symbols).subtracting(engine.deadSymbols))

        // Before the first successful quote, assume the market is open: one
        // wasted request beats a ticker that never starts.
        let rawMarketState = calendars.aggregateState(atEpoch: nowEpoch) ?? .regular
        let rawNextOpen = calendars.earliestSessionOpenEpoch(after: nowEpoch)

        // See `calendarSanityWindow`. Scoped to exactly the pathological
        // case — closed, with a next open implausibly far away — so a
        // genuine `.pre`/`.regular`/`.post` reading, or a closed reading
        // with no known next open, is untouched.
        let closedGapImplausible = rawMarketState == .closed
            && (rawNextOpen.map { $0 - nowEpoch > Self.calendarSanityWindow } ?? false)

        let context = EngineContext(
            nowEpoch: nowEpoch,
            marketState: closedGapImplausible ? .regular : rawMarketState,
            visibility: visibility,
            lowPowerMode: lowPowerMode,
            nextSessionOpenEpoch: closedGapImplausible ? nil : rawNextOpen)

        switch engine.next(context) {
        case .sleep(let seconds):
            return seconds

        case .fetch(let symbol):
            do {
                let bytes = try await fetcher.fetch(symbol)
                let snapshot = try YahooQuoteDecoding.snapshot(from: bytes, symbol: symbol)
                engine.recordSuccess(snapshot.quote, for: symbol)
                quotes[symbol] = snapshot.quote
                lastSuccessEpoch = nowEpoch
                lastError = nil
                if let period = snapshot.tradingPeriod {
                    calendars.record(period, for: symbol)
                }
            } catch let error as TickerError {
                engine.record(error, for: symbol)
                lastError = error
            } catch {
                // Same reasoning as `WatchLoop`'s catch-all: the protocol
                // promises `TickerError` and the language does not enforce it.
                let wrapped = TickerError.transport(TransportFaults.classify(error))
                engine.record(wrapped, for: symbol)
                lastError = wrapped
            }
            return 0
        }
    }

    func replaceWatchlist(_ newSymbols: [Symbol]) {
        symbols = newSymbols
        engine.replaceWatchlist(newSymbols)
        let live = Set(newSymbols)
        quotes = quotes.filter { live.contains($0.key) }
        calendars.retain(live)
    }

    func setUserInterval(_ seconds: Double) {
        userIntervalSeconds = seconds
        engine.setUserInterval(seconds)
    }

    /// Exists for `theCalendarOutOfTheBodyIsWhatDrivesTheNextContext`. The
    /// aggregate is otherwise private because nothing outside `step` needs it,
    /// and a calendar read from elsewhere would be a second opinion about
    /// market hours.
    func marketStateForTesting(atEpoch epoch: Double) -> MarketState? {
        calendars.aggregateState(atEpoch: epoch)
    }
}
