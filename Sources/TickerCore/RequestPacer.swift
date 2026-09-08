/// The token bucket every request passes through. There is no bypass.
///
/// This is a safety property rather than a policy: no bug elsewhere in
/// Squiggle — a runaway retry, a UI action wired to the wrong handler, a
/// future feature — can flood Yahoo, because nothing else holds the tokens.
///
/// Capacity is a *burst* allowance; the long-run rate is one request per
/// `spacingSeconds` regardless of how often `take()` is called.
public struct RequestPacer {
    private let clock: any MonotonicClock
    private var capacity: Double
    private var tokens: Double
    private var lastRefill: Double

    public init(clock: any MonotonicClock) {
        self.clock = clock
        self.capacity = RateConstants.bucketCapacity
        self.tokens = RateConstants.bucketCapacity
        self.lastRefill = clock.nowSeconds
    }

    public var availableTokens: Double { tokens }

    /// Multiplicative decrease on a 429 (AIMD, spec §4.3). Never reaches zero:
    /// a capacity of nought is a permanent outage no success could clear.
    /// There is no increase — recovery is a relaunch, which is honest about
    /// the fact that we do not know Yahoo's real limit.
    public mutating func halveCapacity() {
        capacity = max(1, capacity / 2)
        tokens = min(tokens, capacity)
    }

    public mutating func take() -> Bool {
        refill()
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }

    public mutating func secondsUntilNextToken() -> Double {
        refill()
        guard tokens < 1 else { return 0 }
        return (1 - tokens) * effectiveSpacingSeconds
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
        // future refactor could hand us a smaller number, and minting tokens
        // from it would break the only guarantee this type makes.
        let elapsed = max(0, now - lastRefill)
        lastRefill = now
        tokens = min(capacity, tokens + elapsed / effectiveSpacingSeconds)
    }
}
