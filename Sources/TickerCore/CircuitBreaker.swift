public enum CircuitState: Equatable, Sendable {
    case closed
    case open(untilMonotonic: Double)
    /// One probe is in flight, or one is available to be taken.
    case halfOpen
}

/// A circuit breaker with a single-probe half-open state.
///
/// Squiggle runs two of these (spec §4.3), configured differently and kept
/// deliberately independent:
///
/// - the **network** circuit: five consecutive failed cycles, open 30 minutes;
/// - the **contract** circuit: one parse failure, open one hour.
///
/// Independence is structural, not a discipline to remember: each instance
/// owns its own `failures` / `openedAt` / `probeIssuedAt`, so a flaky
/// connection can never trip the schema alarm and a schema change can never
/// be laundered into "the network is down".
///
/// The half-open state hands out exactly one permit. If it let the whole
/// watchlist through, a still-broken upstream would receive twenty requests
/// as its reward for having been down.
///
/// One invariant runs through the whole type: **`secondsRemaining()` is never
/// zero at a moment when `allowsRequest()` would refuse.** Zero means "ask
/// now"; a caller told to ask now and then refused has nothing left to sleep
/// on, and spins. On a menu bar app that lives in a battery meter, a hot loop
/// is the worst failure this type can produce — worse than staying open too
/// long, and far worse than one extra request.
public struct CircuitBreaker {
    private let clock: any MonotonicClock
    private let threshold: Int
    private let openSeconds: Double

    private var failures: Int = 0
    private var openedAt: Double?

    /// When the outstanding half-open probe was issued, if one is out.
    ///
    /// An instant and not a flag: a bare `probeInFlight` is a latch with no
    /// way out. A probe that is granted and never resolved — the process
    /// suspended, the app quit mid-request, a caller that simply forgets to
    /// report — leaves the breaker half-open, refusing every request, for
    /// the rest of the process's life. With an instant the probe can be
    /// presumed lost after `RateConstants.probeTimeoutSeconds` and reissued.
    private var probeIssuedAt: Double?

    public init(clock: any MonotonicClock, threshold: Int, openSeconds: Double) {
        self.clock = clock
        // No clamp on `threshold`. `recordFailure()` compares it only after
        // counting the failure, so the left-hand side is at least 1 at every
        // comparison and a threshold of zero or less already behaves exactly
        // as one. A `max(1, threshold)` here would guard against nothing
        // while claiming in its own name to guard against something.
        self.threshold = threshold
        self.openSeconds = openSeconds
    }

    /// Failures actually recorded since the last success.
    ///
    /// `trip()` deliberately does not touch it: one 429 is one piece of bad
    /// news, and reporting five failures that never happened would make this
    /// a latch wearing a count's name.
    public var consecutiveFailures: Int { failures }

    public func state() -> CircuitState {
        state(at: clock.nowSeconds)
    }

    private func state(at now: Double) -> CircuitState {
        guard let openedAt else { return .closed }
        let expiry = openedAt + openSeconds
        // `<` and not `<=`: the breaker is open up to, but not including, its
        // expiry — the same half-open convention used for trading windows.
        return now < expiry ? .open(untilMonotonic: expiry) : .halfOpen
    }

    /// How long the caller should wait before asking again. Zero means "ask
    /// now", and is only ever answered when asking now would in fact be
    /// allowed — see the invariant on the type. While half-open with a probe
    /// still outstanding the answer is the remaining life of that probe, not
    /// zero: the breaker is refusing, and it owes the caller an interval.
    public func secondsRemaining() -> Double {
        // One read of the clock, shared by the state decision and the
        // arithmetic below. Two separate reads of a real `SystemClock` can
        // straddle a tick, which was the only thing that ever made a
        // `max(0, …)` floor here defensible; with a single read every
        // subtraction below is positive by construction, so there is no floor
        // to keep.
        let now = clock.nowSeconds
        switch state(at: now) {
        case .closed:
            return 0
        case .open(let expiry):
            return expiry - now
        case .halfOpen:
            guard let age = probeAge(at: now),
                  age < RateConstants.probeTimeoutSeconds else { return 0 }
            return RateConstants.probeTimeoutSeconds - age
        }
    }

    /// Decides whether to let a request through, and — while half-open —
    /// issues the single probe permit as a side effect.
    ///
    /// This is a command, not a query: call it **exactly once per request
    /// decision**, and then **report the outcome** with `recordSuccess()` or
    /// `recordFailure()`. Reporting is the load-bearing half of the contract.
    /// The first call issues the probe; every later call within the same
    /// half-open cycle merely observes that it is already out and returns
    /// `false`, which is what stops a still-down upstream getting twenty
    /// requests as its reward for the outage.
    ///
    /// A probe whose outcome is never reported is not fatal, but it is not
    /// free either: the breaker refuses for `RateConstants.probeTimeoutSeconds`
    /// from the moment the probe was issued, then presumes it lost and issues
    /// a fresh one.
    public mutating func allowsRequest() -> Bool {
        let now = clock.nowSeconds
        guard wouldAllow(at: now) else { return false }
        if case .halfOpen = state(at: now) {
            probeIssuedAt = now
        }
        return true
    }

    /// Whether `allowsRequest()` would return `true` right now, **without**
    /// issuing the half-open probe permit.
    ///
    /// A query, not a command: callers that must decide something — what to
    /// do next, how long to sleep — *before* they know whether they are
    /// actually about to make the request ask this instead of
    /// `allowsRequest()`. Only the caller that is about to make the request,
    /// at the last moment before it does, calls `allowsRequest()` itself.
    /// Deciding with the command and never following through spends the one
    /// half-open probe on a request that never happened, and leaves the
    /// breaker refusing everyone else for `probeTimeoutSeconds` for nothing.
    public func wouldAllowRequest() -> Bool {
        wouldAllow(at: clock.nowSeconds)
    }

    /// The logic shared by `allowsRequest()` and `wouldAllowRequest()`: what
    /// the answer would be at a given instant, with no side effect. Given the
    /// same `now`, `state(at:)` and `probeAge(at:)` are pure functions of it
    /// and the breaker's own fields, so calling this once for the query and
    /// once more for the command produces no drift between the two calls.
    private func wouldAllow(at now: Double) -> Bool {
        switch state(at: now) {
        case .closed:
            return true
        case .open:
            return false
        case .halfOpen:
            if let age = probeAge(at: now), age < RateConstants.probeTimeoutSeconds {
                return false
            }
            return true
        }
    }

    public mutating func recordSuccess() {
        failures = 0
        openedAt = nil
        // Deliberately no `probeIssuedAt = nil`. The token is released in
        // `open(at:)`, where a new episode begins, which is the only moment
        // it can be read: a closed breaker never consults it, and every route
        // back to half-open passes through `open(at:)` first. One release in
        // one place beats three assignments in three places to forget.
    }

    public mutating func recordFailure() {
        // Read the state — and the clock — *before* recording, because what
        // the breaker was when the request went out is what decides whether
        // the deadline moves.
        let now = clock.nowSeconds
        let observed = state(at: now)
        failures += 1

        switch observed {
        case .halfOpen:
            // A failed probe reopens for the full duration; the outage is not
            // over just because the clock said so. This case, not the failure
            // count, is what carries the reopen — after `trip()` the count can
            // be as low as one.
            open(at: now)
        case .open:
            // A failure recorded while open belongs to a request the breaker
            // had already refused, or to a caller that never asked. Restarting
            // the timer for it would let a stream of stale reports multiply
            // the outage without bound and make `.open(untilMonotonic:)` a
            // deadline the type does not keep.
            break
        case .closed:
            if failures >= threshold { open(at: now) }
        }
    }

    /// Open immediately, without waiting for the threshold. A 429 is proof
    /// enough on its own. The failure count is left alone — this is one piece
    /// of bad news, not five.
    public mutating func trip() {
        open(at: clock.nowSeconds)
    }

    /// Begins an open episode.
    ///
    /// The probe belongs to the episode that issued it, so a new episode
    /// starts with the token released. A token carried across would refuse
    /// the next cycle's probe for a whole `probeTimeoutSeconds` — a
    /// self-inflicted outage on a breaker that was ready to test the water.
    private mutating func open(at now: Double) {
        openedAt = now
        probeIssuedAt = nil
    }

    /// How long the outstanding probe has been out, or `nil` if none is.
    private func probeAge(at now: Double) -> Double? {
        probeIssuedAt.map { now - $0 }
    }
}
