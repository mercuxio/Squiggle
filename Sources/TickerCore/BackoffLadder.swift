/// Decorrelated jitter, per failure class.
///
/// `min(cap, random(base, previous × growth))` — **full** jitter, never equal
/// jitter, because the whole installed base shares one upstream. Equal jitter
/// keeps everyone's retries in lockstep, which is the thundering herd the
/// jitter exists to break up.
///
/// There is no per-request retry anywhere in Squiggle. The next cycle is the
/// retry, and this type decides when that cycle may run.
public struct BackoffLadder {
    private let clock: any MonotonicClock
    private let random: any Randomizing

    private var previousDelay: Double = 0
    private var cooldownUntil: Double?

    public init(clock: any MonotonicClock, random: any Randomizing = SystemRandom()) {
        self.clock = clock
        self.random = random
    }

    public var cooldownUntilMonotonic: Double? { cooldownUntil }

    public func isCoolingDown() -> Bool {
        guard let cooldownUntil else { return false }
        return clock.nowSeconds < cooldownUntil
    }

    public func secondsRemaining() -> Double {
        guard let cooldownUntil else { return 0 }
        return max(0, cooldownUntil - clock.nowSeconds)
    }

    public mutating func recordSuccess() {
        previousDelay = 0
        cooldownUntil = nil
    }

    /// Applies the cooldown for this failure and returns its length in seconds.
    @discardableResult
    public mutating func record(_ kind: FailureKind) -> Double {
        let delay: Double

        switch kind {
        case .offline, .deadSymbol:
            // Neither is a reason to stop asking about everything else.
            return 0

        case .rateLimited(let retryAfter):
            if let retryAfter {
                // A hint from a service that is already misbehaving: honour it,
                // but inside our own bounds.
                delay = min(RateConstants.rateLimitBackoffCap,
                            max(RateConstants.rateLimitBackoffBase, retryAfter))
            } else {
                delay = jittered(base: RateConstants.rateLimitBackoffBase,
                                 cap: RateConstants.rateLimitBackoffCap)
            }

        case .server:
            delay = jittered(base: RateConstants.serverBackoffBase,
                             cap: RateConstants.serverBackoffCap)

        case .unauthorized:
            delay = RateConstants.unauthorizedCooldown

        case .contractFault:
            delay = RateConstants.contractFaultCooldown
        }

        previousDelay = delay
        cooldownUntil = clock.nowSeconds + delay
        return delay
    }

    /// Restore a cooldown that outlived the process (spec §4.3, the single
    /// documented wall-clock exception). Clamped on the way in, so a system
    /// clock change cannot strand the app for a year.
    public mutating func adoptPersistedCooldown(secondsRemaining: Double) {
        let clamped = min(max(0, secondsRemaining), RateConstants.rateLimitBackoffCap)
        guard clamped > 0 else {
            cooldownUntil = nil
            return
        }
        cooldownUntil = clock.nowSeconds + clamped
        previousDelay = clamped
    }

    private func jittered(base: Double, cap: Double) -> Double {
        let upper = max(base, min(cap, previousDelay * RateConstants.jitterGrowthFactor))
        guard upper > base else { return base }
        return min(cap, random.double(in: base...upper))
    }
}
