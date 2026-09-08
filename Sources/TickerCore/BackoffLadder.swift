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

    /// Growth state, one field per ladder. Sharing a single field would make
    /// "per failure class" a lie in the one direction that matters: an
    /// hour-long unauthorized or contract circuit would hand the very next
    /// transient 503 the fifteen-minute cap instead of the documented
    /// thirty-second base.
    private var previousRateLimitDelay: Double = 0
    private var previousServerDelay: Double = 0
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
        previousRateLimitDelay = 0
        previousServerDelay = 0
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
                                 cap: RateConstants.rateLimitBackoffCap,
                                 previous: previousRateLimitDelay)
            }
            previousRateLimitDelay = delay

        case .server:
            delay = jittered(base: RateConstants.serverBackoffBase,
                             cap: RateConstants.serverBackoffCap,
                             previous: previousServerDelay)
            previousServerDelay = delay

        case .unauthorized:
            // Flat, not a rung. Neither cooldown climbs, so neither may feed
            // a ladder it is not part of.
            delay = RateConstants.unauthorizedCooldown

        case .contractFault:
            delay = RateConstants.contractFaultCooldown
        }

        cooldownUntil = clock.nowSeconds + delay
        return delay
    }

    /// Restore a cooldown that outlived the process (spec §4.3, the single
    /// documented wall-clock exception). Clamped on the way in to the longest
    /// cooldown this type can itself produce, so a system clock change cannot
    /// strand the app for a year — and so a persisted hour-long circuit is not
    /// silently halved on the way back in. NaN and negatives fail the `> 0`
    /// guard and clear the cooldown outright.
    public mutating func adoptPersistedCooldown(secondsRemaining: Double) {
        let clamped = min(secondsRemaining, RateConstants.maxCooldownSeconds)
        guard clamped > 0 else {
            cooldownUntil = nil
            return
        }
        cooldownUntil = clock.nowSeconds + clamped
        // Persistence exists so that relaunching during a 429 does not hand
        // the user a fresh ladder (spec §4.3) — resetting the growth state
        // here would defeat the only reason the deadline is written out. The
        // class that produced the deadline is not recorded, so only the
        // rate-limit ladder is seeded: it is the one persistence protects,
        // and it is seeded no higher than its own cap.
        previousRateLimitDelay = min(clamped, RateConstants.rateLimitBackoffCap)
    }

    private func jittered(base: Double, cap: Double, previous: Double) -> Double {
        // The cap is applied once, to the range handed to the randomizer, and
        // not to the draw that comes back. Capping the draw instead would let
        // a real RNG draw from [base, ∞) and land on the cap almost surely —
        // a jitter distribution collapsed to a constant, which is precisely
        // the thundering herd this type exists to break up.
        //
        // `previous == 0` is the initial state, not a signal to skip the draw.
        // It used to be read as one: `max(base, 0 * growth)` is `base`, so the
        // guard below returned `base` and the randomizer was never called at
        // all. The first delay after a 429 was exactly 60.0 seconds in every
        // copy of Squiggle ever shipped — and the first retry is the one
        // moment jitter matters most, because it is precisely when the whole
        // installed base has just been synchronised by the same upstream
        // event. Seeding from `base` gives the first draw the same
        // `base...base x growth` range every later one gets.
        let seed = previous > 0 ? previous : base
        let upper = min(cap, max(base, seed * RateConstants.jitterGrowthFactor))
        // Still reachable, and still right: a cap at or below the base leaves
        // no range to draw from. Degenerate constants, not a first failure.
        guard upper > base else { return base }
        return random.double(in: base...upper)
    }
}
