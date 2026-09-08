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
/// owns its own `failures` / `openedAt` / `probeInFlight`, so a flaky
/// connection can never trip the schema alarm and a schema change can never
/// be laundered into "the network is down".
///
/// The half-open state hands out exactly one permit. If it let the whole
/// watchlist through, a still-broken upstream would receive twenty requests
/// as its reward for having been down.
public struct CircuitBreaker {
    private let clock: any MonotonicClock
    private let threshold: Int
    private let openSeconds: Double

    private var failures: Int = 0
    private var openedAt: Double?
    private var probeInFlight = false

    public init(clock: any MonotonicClock, threshold: Int, openSeconds: Double) {
        self.clock = clock
        self.threshold = max(1, threshold)
        self.openSeconds = openSeconds
    }

    public var consecutiveFailures: Int { failures }

    /// `state()` and `secondsRemaining()` are declared `mutating` to match
    /// this type's interface even though neither one writes to `self` today
    /// — they only derive a view from `openedAt` and the clock. Only
    /// `allowsRequest()` actually mutates, by consuming the half-open probe.
    public mutating func state() -> CircuitState {
        guard let openedAt else { return .closed }
        let expiry = openedAt + openSeconds
        // `<` and not `<=`: the breaker is open up to, but not including, its
        // expiry — the same half-open convention used for trading windows.
        return clock.nowSeconds < expiry ? .open(untilMonotonic: expiry) : .halfOpen
    }

    /// How long until this breaker would let a probe through. Zero whenever
    /// it is closed or half-open, so callers can take the maximum across
    /// several breakers without special-casing which ones are shut.
    public mutating func secondsRemaining() -> Double {
        guard case .open(let expiry) = state() else { return 0 }
        return max(0, expiry - clock.nowSeconds)
    }

    /// Decides whether to let a request through, and — while half-open —
    /// consumes the single probe permit as a side effect.
    ///
    /// This is a command, not a query: call it **exactly once per request
    /// decision**. A second call within the same half-open cycle silently
    /// burns the probe and returns `false`, even though nothing failed. That
    /// is deliberate — it is what stops a still-down upstream getting twenty
    /// requests as its reward for the outage — but it also means this method
    /// must never be called speculatively or more than once per cycle.
    public mutating func allowsRequest() -> Bool {
        switch state() {
        case .closed:
            return true
        case .open:
            return false
        case .halfOpen:
            guard !probeInFlight else { return false }
            probeInFlight = true
            return true
        }
    }

    public mutating func recordSuccess() {
        failures = 0
        openedAt = nil
        probeInFlight = false
    }

    public mutating func recordFailure() {
        failures += 1
        probeInFlight = false
        // A failure while half-open (openedAt already set) reopens for the
        // full duration; the outage is not over just because the clock said
        // so.
        if failures >= threshold || openedAt != nil {
            openedAt = clock.nowSeconds
        }
    }

    /// Open immediately, without waiting for the threshold. A 429 is proof
    /// enough on its own.
    public mutating func trip() {
        failures = max(failures, threshold)
        probeInFlight = false
        openedAt = clock.nowSeconds
    }
}
