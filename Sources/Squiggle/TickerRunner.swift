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
        let context = EngineContext(
            nowEpoch: nowEpoch,
            // Before the first successful quote, assume the market is open:
            // one wasted request beats a ticker that never starts.
            marketState: calendars.aggregateState(atEpoch: nowEpoch) ?? .regular,
            visibility: visibility,
            lowPowerMode: lowPowerMode,
            nextSessionOpenEpoch: calendars.earliestSessionOpenEpoch(after: nowEpoch))

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
