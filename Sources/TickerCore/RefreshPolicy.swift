public enum Visibility: Sendable {
    case visible
    /// Behind the notch, or pushed off by another app's menu items. There is
    /// nothing to update, and this is the single largest saving Squiggle makes.
    case occluded
}

public struct RefreshInput: Sendable {
    public var nowMonotonic: Double
    /// Wall-clock seconds, passed in as a number. `TickerCore` never reads a
    /// clock; trading periods are epochs from the payload, so comparing them
    /// requires one — as a parameter, not a dependency.
    public var nowEpoch: Double
    public var marketState: MarketState
    public var visibility: Visibility
    public var lowPowerMode: Bool
    public var userIntervalSeconds: Double
    public var watchlistCount: Int
    public var nextRegularOpenEpoch: Double?
    public var isCoolingDown: Bool
    public var cooldownRemaining: Double
    public var circuitAllows: Bool
    public var circuitOpenRemaining: Double

    public init(nowMonotonic: Double, nowEpoch: Double, marketState: MarketState,
                visibility: Visibility, lowPowerMode: Bool, userIntervalSeconds: Double,
                watchlistCount: Int, nextRegularOpenEpoch: Double?, isCoolingDown: Bool,
                cooldownRemaining: Double, circuitAllows: Bool, circuitOpenRemaining: Double) {
        self.nowMonotonic = nowMonotonic
        self.nowEpoch = nowEpoch
        self.marketState = marketState
        self.visibility = visibility
        self.lowPowerMode = lowPowerMode
        self.userIntervalSeconds = userIntervalSeconds
        self.watchlistCount = watchlistCount
        self.nextRegularOpenEpoch = nextRegularOpenEpoch
        self.isCoolingDown = isCoolingDown
        self.cooldownRemaining = cooldownRemaining
        self.circuitAllows = circuitAllows
        self.circuitOpenRemaining = circuitOpenRemaining
    }
}

public enum RefreshDecision: Equatable, Sendable {
    case fetch
    case wait(seconds: Double)

    public var waitSeconds: Double? {
        if case .wait(let s) = self { return s }
        return nil
    }
}

/// Should we fetch, and if not, for how long should we not?
///
/// A pure function, deliberately: it reads no clock and performs no I/O, so
/// the whole day-long budget simulation in the test suite is a loop over this
/// one call. A policy you cannot simulate is a policy you are guessing about.
public enum RefreshPolicy {

    /// How long one full pass over the watchlist should take.
    ///
    /// `max(userInterval, n × spacing)` — the 30s floor between requests means
    /// a 20-symbol watchlist needs ten minutes per pass whatever the user
    /// chose. Squiggle honours the floor and reports the real cadence rather
    /// than pretending to obey a setting it cannot.
    public static func cycleInterval(userIntervalSeconds: Double,
                                     watchlistCount: Int,
                                     marketState: MarketState,
                                     lowPowerMode: Bool) -> Double {
        // A hand-edited settings file can contain anything at all.
        let requested = userIntervalSeconds.isFinite && userIntervalSeconds > 0
            ? userIntervalSeconds
            : RateConstants.defaultRefreshInterval

        let count = max(1, min(watchlistCount, RateConstants.maxWatchlistCount))
        let floor = Double(count) * RateConstants.spacingSeconds
        let base = max(requested, floor)

        // Extended hours and Low Power Mode each stretch the cycle. They do
        // not compound: the user asked for a slower ticker, not a stopped one.
        let quiet = marketState == .pre || marketState == .post || lowPowerMode
        return quiet ? base * RateConstants.quietMultiplier : base
    }

    /// Whether the strip should dim (spec §7). Measured against the cycle
    /// rather than the user's setting, because the cycle is the cadence that
    /// actually applies once the 30s floor binds.
    ///
    /// `nil` means nothing has ever arrived, which is stale by definition.
    public static func isStale(lastSuccessEpoch: Double?,
                               nowEpoch: Double,
                               userIntervalSeconds: Double,
                               watchlistCount: Int,
                               marketState: MarketState,
                               lowPowerMode: Bool) -> Bool {
        // While the market is shut, the last close is the right number no
        // matter how old it is. Dimming overnight would spend the signal on
        // the one case that is never a fault.
        guard marketState != .closed else { return false }
        guard let lastSuccessEpoch else { return true }

        let age = nowEpoch - lastSuccessEpoch
        // A clock correction can make this negative. Treat that as fresh: the
        // alternative is dimming the strip because the user changed timezone.
        guard age.isFinite, age > 0 else { return false }

        let cycle = cycleInterval(userIntervalSeconds: userIntervalSeconds,
                                  watchlistCount: watchlistCount,
                                  marketState: marketState,
                                  lowPowerMode: lowPowerMode)
        return age > cycle * RateConstants.stalenessMultiplier
    }

    public static func decide(_ input: RefreshInput) -> RefreshDecision {
        // Ordered by how long each reason lasts, longest first, so the wait we
        // report is the wait that actually applies. Reporting the shorter of
        // two live reasons would wake the caller early to be refused again.

        if input.isCoolingDown {
            return .wait(seconds: sanitizedWait(input.cooldownRemaining))
        }

        if !input.circuitAllows {
            return .wait(seconds: sanitizedWait(input.circuitOpenRemaining))
        }

        guard input.watchlistCount > 0 else {
            return .wait(seconds: RateConstants.defaultRefreshInterval)
        }

        let cycle = cycleInterval(userIntervalSeconds: input.userIntervalSeconds,
                                  watchlistCount: input.watchlistCount,
                                  marketState: input.marketState,
                                  lowPowerMode: input.lowPowerMode)

        if input.visibility == .occluded {
            // Do not fetch, but do not sleep forever either: the strip must be
            // current the moment it reappears, and unocclusion wakes us anyway.
            return .wait(seconds: cycle)
        }

        if input.marketState == .closed {
            guard let open = input.nextRegularOpenEpoch else {
                // No payload has told us when the market opens — a cold launch
                // into a weekend. Fall back to a slow poll rather than sleeping
                // indefinitely; a nil must never become a hang.
                return .wait(seconds: min(RateConstants.unknownOpenPollSeconds,
                                          max(cycle, RateConstants.defaultRefreshInterval)))
            }
            let untilOpen = open - input.nowEpoch - RateConstants.preOpenWakeLead
            // A stale open time from a payload older than the session it
            // described would otherwise produce a negative wait; clamp through
            // the same helper used above rather than a bare `max(0, …)`.
            return .wait(seconds: sanitizedWait(min(untilOpen, RateConstants.maxClosedMarketWait)))
        }

        return .fetch
    }

    /// Turns a caller-reported "seconds remaining" into a wait this type will
    /// actually stand behind. Called at every site in `decide()` that turns a
    /// caller-supplied remaining into a `.wait`, so the three sites cannot
    /// drift apart.
    ///
    /// `max(0, remaining)` looks sufficient and is not, in two directions at
    /// once:
    ///
    /// - `max(0, Double.nan) == 0`, because Swift's `max` is effectively
    ///   `y >= x ? y : x` and *every* comparison against NaN is false. A
    ///   corrupted remaining would silently become "ask now" while the
    ///   condition that produced it — `isCoolingDown`, an open circuit — is
    ///   still true. The caller wakes immediately, is refused again, and
    ///   spins: a hot loop in an app that lives in a battery meter.
    /// - `max(0, Double.infinity) == .infinity` — a timer that never fires: a
    ///   silent, permanent hang no error message would ever explain.
    ///
    /// A third case is less obvious than either: a remaining that is exactly
    /// zero, or has gone negative, while the flag that produced it still says
    /// "blocked" (an expired-but-not-yet-refreshed `BackoffLadder` cooldown,
    /// a `nextRegularOpenEpoch` that is stale) is not corrupted in the
    /// NaN/Infinity sense, but reporting it verbatim breaks the same
    /// invariant `CircuitBreaker` states on itself: **a reported wait of zero
    /// must mean asking now is genuinely allowed.** Every call site in
    /// `decide()` that reaches this helper is one where `decide()` has
    /// already committed to *not* returning `.fetch` — so zero is never the
    /// honest answer there, corrupted or not.
    ///
    /// So: a remaining that is not finite, or not strictly positive, is
    /// treated the same way — the default refresh interval, never `0`, never
    /// infinity.
    private static func sanitizedWait(_ remaining: Double) -> Double {
        guard remaining.isFinite, remaining > 0 else {
            return RateConstants.defaultRefreshInterval
        }
        return remaining
    }
}
