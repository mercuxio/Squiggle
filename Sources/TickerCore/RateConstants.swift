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

    public static let maxWatchlistCount: Int = 20

    /// The refresh intervals offered in Settings (spec §4.1). A fixed menu,
    /// not a slider: the floor sits underneath, and a control that silently
    /// declines to honour what you typed is worse than four honest choices.
    public static let refreshIntervalChoices: [Double] = [60, 180, 300, 900]
    public static let defaultRefreshInterval: Double = 180

    /// Extended-hours and Low Power Mode both stretch the cycle by this.
    public static let quietMultiplier: Double = 3

    /// Wake this long before the open, while closed.
    public static let preOpenWakeLead: Double = 60

    /// The longest a closed market is ever allowed to sleep, even with a
    /// known open far in the future — a holiday close, or a payload whose
    /// open time is simply wrong, must still resolve inside half a day.
    public static let maxClosedMarketWait: Double = 12 * 3600

    /// The poll interval while closed with no known open time at all (a cold
    /// launch into a weekend, before any payload has said when trading
    /// resumes). An hour is slow enough to cost nothing and short enough
    /// that a wrong assumption does not stand for long.
    public static let unknownOpenPollSeconds: Double = 3600

    /// Dim the strip once data is older than this multiple of the interval.
    public static let stalenessMultiplier: Double = 3

    /// Fraction of the interval handed to the OS as timer leeway, so wakeups
    /// coalesce with other system work. A larger battery win than lengthening
    /// the interval.
    public static let timerLeewayFraction: Double = 0.25
}
