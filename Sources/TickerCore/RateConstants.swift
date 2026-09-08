/// Every rate and timeout in Squiggle, in one table.
///
/// **Borrowed and unverified.** No authoritative published Yahoo rate limit
/// exists; the `360/hr` figure circulating in `yfinance` issues traces to
/// YQL-era documentation, not to current policy. These values are chosen to
/// sit an order of magnitude below any plausible limit, and to arrive evenly
/// spaced rather than in the bursts that actually trigger a 429.
///
/// The one hard datum (observed 2026-09-08): a 429 from
/// `query1.finance.yahoo.com` is IP-scoped, took only a few dozen requests
/// over eight minutes to trip, and persisted for over an hour. Being slow is
/// far cheaper than being blocked.
public enum RateConstants {
    /// The floor between any two requests, ever. A safety property.
    public static let spacingSeconds: Double = 30

    /// Burst allowance: a launch, an unocclusion and a manual refresh should
    /// not each wait 30 seconds. Does not raise the long-run rate.
    public static let bucketCapacity: Double = 5

    /// Decorrelated jitter: min(cap, random(base, previous × growth)).
    public static let jitterGrowthFactor: Double = 3

    public static let rateLimitBackoffBase: Double = 60
    public static let rateLimitBackoffCap: Double = 30 * 60

    public static let serverBackoffBase: Double = 30
    public static let serverBackoffCap: Double = 15 * 60

    /// Backoff cannot fix a broken authentication assumption.
    public static let unauthorizedCooldown: Double = 60 * 60

    /// A 200 with an unparseable body is a contract fault, not a network
    /// fault. Retrying a parse failure faster buys nothing.
    public static let contractFaultCooldown: Double = 60 * 60

    /// The longest cooldown `BackoffLadder` can legitimately produce, and so
    /// the only defensible clamp for a deadline read back from disk. Derived,
    /// not written down twice: a bound that drifts from the constants it
    /// bounds is worse than no bound.
    /// Every cooldown-producing constant appears here, including
    /// `serverBackoffCap` which is not the maximum today — the point is that
    /// raising any one of them cannot leave this bound behind.
    public static let maxCooldownSeconds: Double = max(
        max(rateLimitBackoffCap, serverBackoffCap),
        max(unauthorizedCooldown, contractFaultCooldown)
    )

    public static let circuitFailureThreshold: Int = 5
    public static let circuitOpenSeconds: Double = 30 * 60

    /// How long a half-open probe may stay unresolved before it is presumed
    /// lost and reissued. Four times `YahooClient`'s 15-second request
    /// timeout: a probe still outstanding after a minute cannot be in flight,
    /// and a probe that is never reissued wedges the breaker permanently.
    public static let probeTimeoutSeconds: Double = 60

    /// Spec §4.2: the whole configuration space must fit under this, on every
    /// calendar and not only on one that shuts for eight hours a night.
    ///
    /// A constant here rather than a literal in `BudgetSweepTests` because
    /// `RefreshPolicy.budgetFloor` and `RequestPacer`'s daily bucket both
    /// enforce it: the number the tests check against and the number the code
    /// obeys have to be the same number, or the test is checking a second copy
    /// that is free to drift.
    public static let dailyRequestBudget: Int = 1_200

    /// The span the budget is a budget *over*. Written once so the two places
    /// that divide by it cannot disagree about how long a day is.
    public static let secondsPerDay: Double = 24 * 3600

    public static let maxWatchlistCount: Int = 20

    /// The largest `quotesCount` a search request ever asks Yahoo for, and
    /// the cap `squigglectl search --limit` clamps to. Both happen to be 20
    /// today, but this is deliberately its own constant rather than a reuse
    /// of `maxWatchlistCount` above: one bounds how many rows a single search
    /// request returns, the other how many symbols a user may watch, and
    /// binding them together would make raising one silently move the other —
    /// the same conflation already logged twice for
    /// `spacingSeconds`-vs-interval-bound.
    public static let maxSearchResultCount: Int = 20

    /// The refresh intervals offered in Settings (spec §4.1). A fixed menu,
    /// not a slider: the floor sits underneath, and a control that silently
    /// declines to honour what you typed is worse than four honest choices.
    public static let refreshIntervalChoices: [Double] = [60, 180, 300, 900]
    public static let defaultRefreshInterval: Double = 180

    /// The span a stored refresh interval can legitimately fall in, and so the
    /// only defensible bound on one read back from disk. Derived from the menu
    /// rather than written down twice, for the same reason `maxCooldownSeconds`
    /// is derived: a bound that drifts from the list it bounds is worse than no
    /// bound. Adding a choice widens this automatically.
    public static let offeredRefreshIntervals: ClosedRange<Double> =
        (refreshIntervalChoices.min() ?? defaultRefreshInterval) ...
        (refreshIntervalChoices.max() ?? defaultRefreshInterval)

    /// The shortest wait any policy will report. A decision *not* to fetch is
    /// not worth waking a millisecond later to re-take; `FeedEngine` applies
    /// the same floor to the sleeps it derives.
    public static let minimumWaitSeconds: Double = 1

    /// Extended-hours and Low Power Mode both stretch the cycle by this.
    public static let quietMultiplier: Double = 3

    /// Wake this long before the open, while closed.
    public static let preOpenWakeLead: Double = 60

    /// The longest a closed market is ever allowed to sleep, even with a
    /// known open far in the future — a holiday close, or a payload whose
    /// open time is simply wrong, must still resolve inside half a day.
    public static let maxClosedMarketWait: Double = 12 * 3600

    /// Dim the strip once data is older than this multiple of the interval.
    public static let stalenessMultiplier: Double = 3

    /// Fraction of the interval handed to the OS as timer leeway, so wakeups
    /// coalesce with other system work. A larger battery win than lengthening
    /// the interval.
    public static let timerLeewayFraction: Double = 0.25
}
