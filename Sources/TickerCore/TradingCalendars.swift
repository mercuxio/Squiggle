import Foundation

/// One trading calendar per symbol, and the aggregate the engine actually
/// consumes.
///
/// The engine takes a *single* `marketState`, so something has to turn N
/// calendars into one. Keeping only the most recent one makes the answer
/// depend on which symbol happened to be fetched last, and the two failure
/// directions are not symmetric:
///
/// - A crypto symbol fetched last reports `.regular` at 03:00, and every
///   equity symbol is then polled as though its exchange were open.
/// - An equity symbol fetched last reports `.closed` with a 09:30 open, and
///   `RefreshPolicy` then puts the **whole loop** to sleep until 09:30 —
///   including the 24-hour instrument, which had a live price the entire time.
///   A ticker that shows a nine-hour-old crypto price is broken in a way that
///   a ticker making a few extra requests is not.
///
/// So the aggregate is the *most open* state across the live watchlist, and
/// the wake is the *earliest* open across it. The caller never sleeps through
/// a session that some symbol it is watching is actually in.
///
/// The cost of the first direction is real and is paid deliberately: the
/// nineteen equity symbols do get polled overnight at the continuous cadence.
/// It is affordable only because `RefreshPolicy.budgetFloor` exists — it
/// prices a 24-hour instrument directly, so this aggregate is bounded at the
/// daily budget instead of running to 2,880 requests. Per-symbol *cadence*
/// would avoid even that, but `FeedEngine` paces one round-robin pass against
/// one `cycleDeadline`; giving each symbol its own would be a redesign of
/// `FeedEngine.next()`, not a change to its callers.
///
/// Per-symbol calendars are still kept rather than aggregated on arrival, so
/// nothing is lost: removing the crypto symbol restores the equity answer on
/// the very next tick, with no stale `.regular` left behind.
///
/// Lives in `TickerCore` by ruling R121: `squigglectl watch` and the app's
/// `TickerRunner` both have to build an `EngineContext`, and this is the only
/// thing that knows how.
public struct TradingCalendars: Sendable {
    private var periods: [Symbol: TradingPeriod] = [:]

    public init() {}

    public mutating func record(_ period: TradingPeriod, for symbol: Symbol) {
        periods[symbol] = period
    }

    /// Forgets calendars for symbols no longer being polled. Without this a
    /// symbol the engine has marked dead keeps voting: a delisted crypto
    /// ticker that 404s forever would hold the whole watchlist at `.regular`
    /// for the life of the process, which is the original bug with a longer
    /// fuse.
    public mutating func retain(_ live: Set<Symbol>) {
        periods = periods.filter { live.contains($0.key) }
    }

    /// `nil` when nothing has reported yet — the caller decides what to assume
    /// before the first successful quote, and that assumption is not this
    /// type's to make.
    public func aggregateState(atEpoch epoch: Double) -> MarketState? {
        let states = periods.values.map { $0.state(atEpoch: epoch) }
        guard !states.isEmpty else { return nil }
        return states.max { Self.openness($0) < Self.openness($1) }
    }

    /// The earliest open any watched symbol still has ahead of it. Only
    /// consulted while the aggregate is `.closed`, which by construction means
    /// every symbol is closed, so this is the first one to reopen.
    public func earliestSessionOpenEpoch(after epoch: Double) -> Double? {
        periods.values.compactMap { $0.nextSessionOpenEpoch(after: epoch) }.min()
    }

    /// One symbol's own state, unaggregated. Nothing in the app reads this; it
    /// exists so a test can show that an equity symbol keeps its own calendar
    /// while a crypto symbol drives the aggregate.
    public func state(for symbol: Symbol, atEpoch epoch: Double) -> MarketState? {
        periods[symbol]?.state(atEpoch: epoch)
    }

    /// How open a state is. `.pre` outranks `.post` only to keep the aggregate
    /// deterministic when both appear — `RefreshPolicy` stretches the cycle
    /// identically for the two (`RefreshPolicy.swift`, the `quiet` term), so
    /// the choice cannot change what the engine does. A `switch` with no
    /// `default:`, so a fifth `MarketState` fails the build here rather than
    /// silently ranking as something.
    public static func openness(_ state: MarketState) -> Int {
        switch state {
        case .closed: return 0
        case .post: return 1
        case .pre: return 2
        case .regular: return 3
        }
    }
}
