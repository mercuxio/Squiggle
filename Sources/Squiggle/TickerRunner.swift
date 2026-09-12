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
            // The policy no longer stands down for a shut market, so this
            // only chooses between the ordinary cycle and the pre/post
            // stretch. The fallback stays `.regular` all the same: before the
            // first successful quote there is no calendar to read, and the
            // faster of the two cadences is the one a cold launch wants.
            marketState: calendars.aggregateState(atEpoch: nowEpoch) ?? .regular,
            visibility: visibility,
            lowPowerMode: lowPowerMode)

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

    /// The same symbols, rearranged. Nothing is dropped, so nothing here
    /// filters: `quotes` and `calendars` are keyed by symbol and every key
    /// they hold is still watched.
    ///
    /// See `FeedEngine.reorderWatchlist` for why this does not go through
    /// `replaceWatchlist` — in short, a drag in the dropdown is not the user
    /// asking to retry every dead symbol.
    func reorderWatchlist(_ newOrder: [Symbol]) {
        guard newOrder.count == symbols.count, Set(newOrder) == Set(symbols) else { return }
        symbols = newOrder
        engine.reorderWatchlist(newOrder)
    }

    func setUserInterval(_ seconds: Double) {
        userIntervalSeconds = seconds
        engine.setUserInterval(seconds)
    }

    func requestImmediateCycle() { engine.requestImmediateCycle() }

    /// The aggregate trading state across the live watchlist, as of `epoch`.
    ///
    /// Read by `step` to build its `EngineContext`, and by
    /// `StatusItemController` for the staleness check spec §7 dims the strip
    /// on — `RefreshPolicy.isStale` needs it, because a closed market is never
    /// stale however old the last price is.
    ///
    /// `nil` before any quote has arrived. Both callers then assume `.regular`,
    /// and they must keep assuming the same thing: two different guesses about
    /// market hours in one app is the bug `TradingCalendars` exists to prevent.
    func marketState(atEpoch epoch: Double) -> MarketState? {
        calendars.aggregateState(atEpoch: epoch)
    }
}
