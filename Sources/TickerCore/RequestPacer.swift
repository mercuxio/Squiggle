/// The token bucket every request passes through. There is no bypass.
///
/// This is a safety property rather than a policy: no bug elsewhere in
/// Squiggle — a runaway retry, a UI action wired to the wrong handler, a
/// future feature — can flood Yahoo, because nothing else holds the tokens.
///
/// Capacity is a *burst* allowance; the short-run rate is one request per
/// the current effective spacing — `spacingSeconds` at full capacity, longer
/// once `halveCapacity()` has scaled it back — regardless of how often
/// `take()` is called.
///
/// **Two buckets, two horizons.** The spacing bucket bounds a burst and
/// nothing longer: a steady 30-second cadence never outruns a bucket that
/// refills one token every 30 seconds, so on an instrument that never closes
/// it permits 86,400 / 30 = 2,880 requests a day against a 1,200/day budget.
/// The second bucket refills at the budget spread across a day
/// (`dailySpacingSeconds`, 72 seconds today) and so bounds the day. Both must
/// grant for `take()` to succeed. `RefreshPolicy.budgetFloor` is what keeps
/// the engine inside the budget in normal operation; this bucket is the
/// backstop that holds when something upstream of it is wrong, which is the
/// job this type already claims in the first line of its own documentation.
public struct RequestPacer {
    private let clock: any MonotonicClock
    private var capacity: Double
    private var tokens: Double
    /// The day-horizon bucket. Its burst allowance is one full pass over the
    /// largest watchlist the app admits, so a launch or an unocclusion can
    /// populate the whole strip at the spacing bucket's pace instead of
    /// dribbling one symbol in every 72 seconds — and no larger, because a
    /// bucket seeded with the whole day's budget would let one launch spend
    /// the day in ten hours. That makes this bucket's own bound
    /// `dailyRequestBudget` plus one pass; the day is held at the budget
    /// itself by `RefreshPolicy.budgetFloor`, which is why that is the primary
    /// bound and this is the backstop.
    private var dailyTokens: Double
    private var lastRefill: Double

    /// Seconds to accrue one token in the daily bucket: the budget spread
    /// evenly across the day, 72 seconds today.
    static let dailySpacingSeconds: Double =
        RateConstants.secondsPerDay / Double(RateConstants.dailyRequestBudget)

    /// One full pass over the largest watchlist the app admits — see
    /// `dailyTokens`.
    static let dailyBucketCapacity: Double = Double(RateConstants.maxWatchlistCount)

    public init(clock: any MonotonicClock) {
        self.clock = clock
        self.capacity = RateConstants.bucketCapacity
        self.tokens = RateConstants.bucketCapacity
        self.dailyTokens = Self.dailyBucketCapacity
        self.lastRefill = clock.nowSeconds
    }

    /// How many requests could go out right now — the smaller of the two
    /// buckets, because a request needs a token from each. Reporting only the
    /// spacing bucket would show a full bucket to a diagnostic run at the
    /// moment the daily one is what is refusing.
    public var availableTokens: Double { min(tokens, dailyTokens) }

    /// Multiplicative decrease on a 429 (AIMD, spec §4.3). Never reaches zero:
    /// a capacity of nought is a permanent outage no success could clear.
    /// There is no increase — recovery is a relaunch, which is honest about
    /// the fact that we do not know Yahoo's real limit.
    ///
    /// Only the spacing bucket is halved. The daily bucket is already running
    /// at the budget, which is a rate this project chose rather than one Yahoo
    /// pushed back on; halving it too would make a single 429 cut the day's
    /// allowance in half for the life of the process.
    public mutating func halveCapacity() {
        capacity = max(1, capacity / 2)
        tokens = min(tokens, capacity)
    }

    public mutating func take() -> Bool {
        refill()
        guard tokens >= 1, dailyTokens >= 1 else { return false }
        tokens -= 1
        dailyTokens -= 1
        return true
    }

    public mutating func secondsUntilNextToken() -> Double {
        refill()
        // The longer of the two waits, not the first one that happens to be
        // short: a request needs a token from both buckets, so reporting the
        // spacing bucket's wait while the daily one is empty would wake the
        // caller to be refused again.
        let spacingWait = max(0, 1 - tokens) * effectiveSpacingSeconds
        let dailyWait = max(0, 1 - dailyTokens) * Self.dailySpacingSeconds
        return max(spacingWait, dailyWait)
    }

    /// Seconds to accrue one token at the current capacity. Halving capacity
    /// must also halve the sustained rate — a halved burst allowance that
    /// still refills at the un-throttled rate would leave the long-run rate
    /// to Yahoo untouched by the one signal (a 429) telling us to slow down.
    /// Scales `spacingSeconds` by how far `capacity` has fallen from the
    /// un-throttled `bucketCapacity`.
    private var effectiveSpacingSeconds: Double {
        RateConstants.spacingSeconds * (RateConstants.bucketCapacity / capacity)
    }

    private mutating func refill() {
        let now = clock.nowSeconds
        // Never trust time to move forward. A suspended process, a fake, or a
        // future refactor could hand us a smaller number. The real danger
        // isn't the backward reading itself (that credits nothing — elapsed
        // clamps to zero) but letting lastRefill regress to it: a clock that
        // later returns to where it already was would then look like it
        // travelled forward from the dip, minting tokens for time that never
        // passed. Keeping lastRefill a high-water mark closes that path.
        let elapsed = max(0, now - lastRefill)
        lastRefill = max(lastRefill, now)
        tokens = min(capacity, tokens + elapsed / effectiveSpacingSeconds)
        dailyTokens = min(Self.dailyBucketCapacity,
                          dailyTokens + elapsed / Self.dailySpacingSeconds)
    }
}
