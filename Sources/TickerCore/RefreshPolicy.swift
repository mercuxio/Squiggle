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
    /// The next **session** open — the earliest of pre, regular and post that
    /// is still ahead — and not the next *regular* open.
    ///
    /// The distinction is load-bearing, which is why the field is named for
    /// it. The closed-market branch below sleeps until this instant minus
    /// `preOpenWakeLead`, and that is the only wake a closed Mac gets. Pass
    /// the regular open and Squiggle sleeps from midnight to 09:29, silently
    /// skipping the whole 04:00-09:30 pre-market session for everyone whose
    /// Mac was closed-market when the wake was scheduled — which is everyone
    /// who leaves it on overnight. `TradingPeriod.nextSessionOpenEpoch(after:)`
    /// computes the right value; callers should not compute their own.
    public var nextSessionOpenEpoch: Double?
    public var isCoolingDown: Bool
    public var cooldownRemaining: Double
    public var circuitAllows: Bool
    public var circuitOpenRemaining: Double
    /// The user pressed *Refresh Now*. It retires the **schedule** — the
    /// market calendar, the occlusion check, the cycle interval — and nothing
    /// else. The cooldown and both circuits are checked above it and the token
    /// bucket below it, so this is a request for a refresh, not a grant of
    /// one. Defaulted so that every ordinary caller keeps saying nothing.
    public var userRequested: Bool

    public init(nowMonotonic: Double, nowEpoch: Double, marketState: MarketState,
                visibility: Visibility, lowPowerMode: Bool, userIntervalSeconds: Double,
                watchlistCount: Int, nextSessionOpenEpoch: Double?, isCoolingDown: Bool,
                cooldownRemaining: Double, circuitAllows: Bool, circuitOpenRemaining: Double,
                userRequested: Bool = false) {
        self.nowMonotonic = nowMonotonic
        self.nowEpoch = nowEpoch
        self.marketState = marketState
        self.visibility = visibility
        self.lowPowerMode = lowPowerMode
        self.userIntervalSeconds = userIntervalSeconds
        self.watchlistCount = watchlistCount
        self.nextSessionOpenEpoch = nextSessionOpenEpoch
        self.isCoolingDown = isCoolingDown
        self.cooldownRemaining = cooldownRemaining
        self.circuitAllows = circuitAllows
        self.circuitOpenRemaining = circuitOpenRemaining
        self.userRequested = userRequested
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

    /// The interval `cycleInterval` will actually honour for a stored setting.
    ///
    /// A hand-edited settings file can contain anything at all, and an interval
    /// outside the menu Settings offers is corrupt in exactly the way `0`, `-1`
    /// and NaN are — so it is replaced by the default rather than clamped. Its
    /// own function because `Diagnosis.pacerThrottlesSettings` has to compare
    /// against the same number: a second copy of this rule there would be free
    /// to drift, and the whole point of that comparison is to say which of two
    /// numbers is larger.
    public static func honouredInterval(_ userIntervalSeconds: Double) -> Double {
        RateConstants.offeredRefreshIntervals.contains(userIntervalSeconds)
            ? userIntervalSeconds
            : RateConstants.defaultRefreshInterval
    }

    /// The watchlist size this type will reason about: at least one symbol,
    /// never more than the app admits. Its own function because both
    /// `cycleInterval` and `budgetFloor` need the same clamp, and `Int.max`
    /// symbols becoming a cycle of nine trillion years is a hang wearing a
    /// cadence's name.
    private static func clampedCount(_ watchlistCount: Int) -> Int {
        max(1, min(watchlistCount, RateConstants.maxWatchlistCount))
    }

    /// The shortest cycle that keeps a full pass over `watchlistCount` symbols
    /// inside `RateConstants.dailyRequestBudget` on an instrument that never
    /// closes.
    ///
    /// One pass costs `count` requests, so a day of passes at cycle `c` costs
    /// `count × 86_400 / c`; requiring that to stay under the budget gives
    /// `c >= count × 86_400 / budget`. At 20 symbols that is 1,440 seconds, at
    /// 5 symbols 360, at one symbol 72.
    ///
    /// This exists because the budget was, until it did, an arithmetic
    /// consequence of the US equity calendar rather than a property anything
    /// enforced: the 30-second spacing floor bounds a burst and cannot bound a
    /// day, and a `BTC-USD` or `EURUSD=X` in the watchlist is a market that
    /// never shuts. Deriving the bound from the budget itself rather than from
    /// market hours is the point — a market-hours heuristic is what produced
    /// the overshoot.
    ///
    /// Its own function, like `honouredInterval`, so `Diagnosis` and the tests
    /// can name the same number the policy obeys instead of re-deriving it.
    public static func budgetFloor(watchlistCount: Int) -> Double {
        Double(clampedCount(watchlistCount)) * RateConstants.secondsPerDay
            / Double(RateConstants.dailyRequestBudget)
    }

    /// How long one full pass over the watchlist should take.
    ///
    /// `max(max(userInterval, n × spacing) × quiet, budget floor)` — the 30s
    /// floor between requests means a 20-symbol watchlist needs ten minutes per
    /// pass whatever the user chose, and the budget floor (`budgetFloor` above)
    /// means it needs twenty-four. Squiggle honours both floors and reports the
    /// real cadence rather than pretending to obey a setting it cannot. See the
    /// body for why the budget floor sits outside the quiet multiplier rather
    /// than inside it.
    public static func cycleInterval(userIntervalSeconds: Double,
                                     watchlistCount: Int,
                                     marketState: MarketState,
                                     lowPowerMode: Bool) -> Double {
        // A hand-edited settings file can contain anything at all, and this
        // function has to be total over "anything". Rejected at the input
        // rather than clamped at the output: `1e308 × quietMultiplier` is
        // `inf`, and a clamped product would leave this function reporting a
        // cadence while silently having rewritten the setting it claims to
        // honour. See `honouredInterval` above for the rule itself.
        let requested = honouredInterval(userIntervalSeconds)

        let count = clampedCount(watchlistCount)
        let spacingFloor = Double(count) * RateConstants.spacingSeconds
        let base = max(requested, spacingFloor)

        // Extended hours and Low Power Mode each stretch the cycle. They do
        // not compound: the user asked for a slower ticker, not a stopped one.
        let quiet = marketState == .pre || marketState == .post || lowPowerMode
        let cadence = quiet ? base * RateConstants.quietMultiplier : base

        // The budget floor is applied *after* the stretch, not folded into
        // `base` above, and the difference is not cosmetic: `max(a, f) × k` and
        // `max(a × k, f)` differ by a factor of `k` whenever the floor is the
        // binding term. The multiplier stretches the cadence the user asked
        // for; the budget floor is a lower bound on the cycle itself, and it is
        // already sufficient on its own — a cycle at the floor spends exactly
        // the budget over a day that never closes, so tripling it in quiet
        // hours would buy a third of the budget nobody asked to save at the
        // cost of a ticker three times staler. It also went blind: at twenty
        // symbols in Low Power the folded form produced a 4,320-second cycle,
        // which the closed-market fallback below then adopted, breaking
        // `theUnknownOpenFallbackNeverGoesBlindForAnHour`. This is the shortest
        // cycle that honours both the stretch and the budget.
        return max(cadence, budgetFloor(watchlistCount: count))
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
        // An age that cannot be measured is not an age this function can
        // vouch for, and the dimmed strip *is* the "I do not know that this is
        // current" signal — so a NaN or infinite age dims rather than
        // reassures. No `age > 0` companion here: a clock correction makes the
        // age negative, which the comparison below already answers `false`
        // without help, and a guard that changes no result while naming one is
        // a guard taking credit for work it does not do.
        guard age.isFinite else { return true }

        let cycle = cycleInterval(userIntervalSeconds: userIntervalSeconds,
                                  watchlistCount: watchlistCount,
                                  marketState: marketState,
                                  lowPowerMode: lowPowerMode)
        return age > cycle * RateConstants.stalenessMultiplier
    }

    public static func decide(_ input: RefreshInput) -> RefreshDecision {
        // A cooldown and an open circuit both mean "do not fetch", and when
        // both are live the longer of the two is the one that actually
        // applies. So the reported wait is the maximum of the live reasons,
        // not whichever reason happens to be tested first: reporting the
        // shorter would wake the caller early to be refused again by the
        // other. A reason that is not live contributes nothing, and every
        // live one is at least `minimumWaitSeconds`, so `0` cannot win.
        if input.isCoolingDown || !input.circuitAllows {
            let cooldown = input.isCoolingDown ? sanitizedWait(input.cooldownRemaining) : 0
            let circuit = input.circuitAllows ? 0 : sanitizedWait(input.circuitOpenRemaining)
            return .wait(seconds: max(cooldown, circuit))
        }

        guard input.watchlistCount > 0 else {
            return .wait(seconds: sanitizedWait(RateConstants.defaultRefreshInterval))
        }

        // Below the safety gates and above every schedule gate — which is the
        // whole of what *Refresh Now* means. The user's words: "the refresh
        // should force the refresh to immediate regardless of the refresh
        // settings", and the settings are exactly what lies below: the market
        // calendar, the occlusion check and the cycle interval. The cooldown
        // and the circuits are not settings, so they stay above.
        //
        // It goes after the watchlist guard rather than before it because an
        // empty watchlist has nothing to fetch — there is no symbol to return
        // and `next()` would only come straight back here.
        if input.userRequested { return .fetch }

        let cycle = cycleInterval(userIntervalSeconds: input.userIntervalSeconds,
                                  watchlistCount: input.watchlistCount,
                                  marketState: input.marketState,
                                  lowPowerMode: input.lowPowerMode)

        if input.visibility == .occluded {
            // Do not fetch, but do not sleep forever either: the strip must be
            // current the moment it reappears, and unocclusion wakes us anyway.
            return .wait(seconds: sanitizedWait(cycle))
        }

        if input.marketState == .closed {
            guard let open = input.nextSessionOpenEpoch else {
                // No payload has told us when the market opens — a cold launch
                // into a weekend. Fall back to a slow poll rather than sleeping
                // indefinitely; a nil must never become a hang.
                //
                // No hourly ceiling is written here. The slowest cycle the
                // interval menu can produce is 45 minutes, so a `min` against
                // an hour would be a bound that never binds — a guard taking
                // credit for work the interval table already does. The ceiling
                // is a requirement on this branch rather than an input to it,
                // so it lives in `theUnknownOpenFallbackNeverGoesBlindForAnHour`,
                // which sweeps the whole menu and fails the day a slower
                // choice is added.
                return .wait(seconds: sanitizedWait(
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

    /// Turns a proposed "seconds until it is worth asking again" into a wait
    /// this type will stand behind. **Every** `.wait` `decide()` returns is
    /// built here, so no branch can drift out of the invariant.
    ///
    /// `max(0, remaining)` looks sufficient and is not, in two directions at
    /// once. `max(0, Double.nan) == 0`, because Swift's `max` is effectively
    /// `y >= x ? y : x` and every comparison against NaN is false — so a
    /// corrupted remaining becomes "ask now" while the condition that produced
    /// it is still refusing, and the caller spins. And
    /// `max(0, Double.infinity) == .infinity`: a timer that never fires.
    ///
    /// The invariant is `CircuitBreaker`'s, kept here too: a reported wait
    /// must never be one the caller can spin on. Every site that reaches this
    /// helper is one where `decide()` has already committed to *not*
    /// fetching, so zero is not an honest answer — and neither is a
    /// millisecond. The two failures get different answers: a value that is
    /// corrupt gets the default interval, a value that is merely too small
    /// gets the floor.
    private static func sanitizedWait(_ remaining: Double) -> Double {
        guard remaining.isFinite, remaining > 0 else {
            return RateConstants.defaultRefreshInterval
        }
        return max(remaining, RateConstants.minimumWaitSeconds)
    }
}
