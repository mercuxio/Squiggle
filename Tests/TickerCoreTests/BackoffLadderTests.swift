import Foundation
import Testing
@testable import TickerCore

// NOTE: as in RequestPacerTests.swift, this suite's `#expect(...)` macro
// mis-compiles whenever the checked expression is a direct call to a
// `mutating` method on a `var` — its call-capturing expansion binds the
// receiver as an immutable `$0`, producing "cannot use mutating member on
// immutable value". `BackoffLadder.record(_:)` is exactly that shape, so
// every such call is hoisted into a `let` before the `#expect` rather than
// written inline.

private func ladder(_ clock: FakeClock, _ random: FakeRandom = FakeRandom()) -> BackoffLadder {
    BackoffLadder(clock: clock, random: random)
}

@Test func everyTickerErrorClassifiesIntoExactlyOneFailureKind() throws {
    let symbol = try #require(Symbol("AAPL"))
    #expect(FailureKind(.offline) == .offline)
    #expect(FailureKind(.rateLimited(retryAfterSeconds: nil)) == .rateLimited(retryAfterSeconds: nil))
    #expect(FailureKind(.rateLimited(retryAfterSeconds: 90)) == .rateLimited(retryAfterSeconds: 90))
    #expect(FailureKind(.serverError(status: 503)) == .server)
    #expect(FailureKind(.transport(.urlSession(code: -1001))) == .server)
    #expect(FailureKind(.unauthorized(status: 401)) == .unauthorized)
    // Both ways of saying "this symbol has no data" cost the same. A 404 and
    // a 200 whose `chart.result` is null are one fact reported twice, and
    // `noResult` in the contract group meant the second one stopped the whole
    // watchlist for an hour while the first cost only itself.
    #expect(FailureKind(.symbolNotFound(symbol)) == .deadSymbol)
    #expect(FailureKind(.noResult) == .deadSymbol)
    // The contract faults: a 200 whose *shape* is wrong, which implicates the
    // endpoint and so every symbol. Spec §4.3 gives them their own circuit,
    // and its threshold is 1. This group is deliberately narrower than
    // `TickerError.isContractFault`, which still counts `noResult` — see
    // `Failure.swift` for why the two questions differ.
    #expect(FailureKind(.notJSON) == .contractFault)
    #expect(FailureKind(.missingField(path: "x")) == .contractFault)
    #expect(FailureKind(.nonFiniteNumber(path: "x")) == .contractFault)
    #expect(FailureKind(.emptyBody) == .contractFault)
    #expect(FailureKind(.wrongType(path: "x", expected: "number")) == .contractFault)
    #expect(FailureKind(.negativeValue(path: "x", value: -1)) == .contractFault)
    // These five cannot arise from a fetch at all (a rejected symbol never
    // reaches the network; the other four are storage faults). Mapped to the
    // mildest, shortest, self-correcting rung deliberately: routing an
    // unreachable case into the hour-long contract circuit would turn a
    // local bug into an hour of silence.
    #expect(FailureKind(.invalidSymbol("not a symbol")) == .server)
    #expect(FailureKind(.storeSchemaUnsupported(version: 99)) == .server)
    #expect(FailureKind(.storeVersionUnreadable) == .server)
    let quarantined = URL(fileURLWithPath: "/tmp/squiggle.json.bad-2026-09-08")
    #expect(FailureKind(.storeCorrupt(quarantinedAt: quarantined)) == .server)
    let stuck = URL(fileURLWithPath: "/tmp/squiggle.json")
    #expect(FailureKind(.storeQuarantineFailed(at: stuck)) == .server)
}

@Test func beingOfflineDoesNotAdvanceTheLadder() {
    // Spec §4.3: do not attempt, do not advance. Punishing the user's flaky
    // wifi with a 30-minute cooldown means the ticker is dead long after the
    // network comes back.
    let clock = FakeClock()
    var l = ladder(clock, FakeRandom(position: 1.0))
    for _ in 0..<10 { _ = l.record(.offline) }

    // "Do not attempt" — no cooldown was applied.
    #expect(!l.isCoolingDown())
    #expect(l.cooldownUntilMonotonic == nil)

    // "Do not advance" — the other half of the sentence, and the half a
    // cooldown assertion cannot see. After ten offline cycles the first real
    // failure of each class must still arrive at that class's base, not one
    // rung up. `position: 1.0` means any advance at all would show.
    let firstServer = l.record(.server)
    #expect(firstServer == RateConstants.serverBackoffBase)
    clock.advance(firstServer)
    let firstRateLimit = l.record(.rateLimited(retryAfterSeconds: nil))
    #expect(firstRateLimit == RateConstants.rateLimitBackoffBase)
}

@Test func aDeadSymbolDoesNotAdvanceTheLadderEither() {
    // Same shape as offline: the symbol leaves the rotation, the other
    // nineteen are unaffected, and nothing about the ladder moves.
    let clock = FakeClock()
    var l = ladder(clock, FakeRandom(position: 1.0))
    for _ in 0..<10 { _ = l.record(.deadSymbol) }
    #expect(l.cooldownUntilMonotonic == nil)

    let firstServer = l.record(.server)
    #expect(firstServer == RateConstants.serverBackoffBase)
    clock.advance(firstServer)
    let firstRateLimit = l.record(.rateLimited(retryAfterSeconds: nil))
    #expect(firstRateLimit == RateConstants.rateLimitBackoffBase)
}

@Test func eachFailureClassClimbsItsOwnLadder() {
    // "Decorrelated jitter, per failure class" is the type's headline claim,
    // and a single shared growth field makes it false in the one direction
    // that matters. The realistic sequence is the damaging one: an hour-long
    // circuit expires, the very next cycle hits a transient 503, and instead
    // of the documented thirty-second rung the app goes silent for the full
    // fifteen-minute cap.
    let clock = FakeClock()
    var l = ladder(clock, FakeRandom(position: 1.0))

    let rate1 = l.record(.rateLimited(retryAfterSeconds: nil))
    #expect(rate1 == RateConstants.rateLimitBackoffBase)          // 60
    clock.advance(rate1)

    // A rate limit must not push the server ladder off its own base.
    let server1 = l.record(.server)
    #expect(server1 == RateConstants.serverBackoffBase)           // 30
    clock.advance(server1)

    // Interleaved, each class resumes from where *it* left off.
    let rate2 = l.record(.rateLimited(retryAfterSeconds: nil))
    #expect(rate2 == rate1 * RateConstants.jitterGrowthFactor)    // 180
    clock.advance(rate2)
    let server2 = l.record(.server)
    #expect(server2 == server1 * RateConstants.jitterGrowthFactor) // 90
    clock.advance(server2)

    // The two flat cooldowns are not rungs on anything. They must feed
    // neither ladder's growth.
    let auth = l.record(.unauthorized)
    #expect(auth == RateConstants.unauthorizedCooldown)           // 3600
    clock.advance(auth)
    let contract = l.record(.contractFault)
    #expect(contract == RateConstants.contractFaultCooldown)      // 3600
    clock.advance(contract)

    let server3 = l.record(.server)
    #expect(server3 == server2 * RateConstants.jitterGrowthFactor) // 270
    clock.advance(server3)
    let rate3 = l.record(.rateLimited(retryAfterSeconds: nil))
    #expect(rate3 == rate2 * RateConstants.jitterGrowthFactor)     // 540
}

@Test func aRateLimitStartsAtItsBaseAndGrowsByTheJitterFactor() {
    let clock = FakeClock()
    let random = FakeRandom(position: 1.0)   // always the top of the range
    var l = ladder(clock, random)

    let first = l.record(.rateLimited(retryAfterSeconds: nil))
    #expect(first == RateConstants.rateLimitBackoffBase)

    clock.advance(first)
    let second = l.record(.rateLimited(retryAfterSeconds: nil))
    #expect(second == first * RateConstants.jitterGrowthFactor)
}

@Test func backoffNeverExceedsItsCapHoweverManyFailuresArrive() {
    let clock = FakeClock()
    var l = ladder(clock, FakeRandom(position: 1.0))
    var last: Double = 0
    for _ in 0..<20 {
        last = l.record(.rateLimited(retryAfterSeconds: nil))
        clock.advance(last)
    }
    #expect(last == RateConstants.rateLimitBackoffCap)
}

@Test func backoffNeverFallsBelowItsBase() {
    // Full jitter, never equal jitter — but the low bound is the base, so a
    // random draw can never produce a cooldown shorter than one base period.
    let clock = FakeClock()
    var l = ladder(clock, FakeRandom(position: 0.0))   // always the bottom
    for _ in 0..<10 {
        let wait = l.record(.rateLimited(retryAfterSeconds: nil))
        #expect(wait >= RateConstants.rateLimitBackoffBase)
        clock.advance(wait)
    }
}

@Test func jitterIsDrawnFromTheFullRangeAndNotJustItsEndpoints() throws {
    // Equal jitter would leave the installed base synchronised, which is the
    // failure the jitter exists to prevent — every Squiggle shares one
    // upstream.
    let clock = FakeClock()
    let random = FakeRandom(position: 0.5)
    var l = ladder(clock, random)
    let first = l.record(.rateLimited(retryAfterSeconds: nil))
    #expect(first == RateConstants.rateLimitBackoffBase)
    clock.advance(1000)
    let second = l.record(.rateLimited(retryAfterSeconds: nil))

    let range = try #require(random.calls.last)
    #expect(range.lowerBound == RateConstants.rateLimitBackoffBase)
    #expect(range.upperBound == first * RateConstants.jitterGrowthFactor)

    // A draw from the middle of 60...180 lands at 120: neither endpoint, and
    // nowhere near the cap. Asserting only the endpoints of the range would
    // let a collapsed distribution through.
    #expect(second == 120)
    #expect(second > range.lowerBound)
    #expect(second < range.upperBound)
}

@Test func theRangeHandedToTheRandomizerIsItselfCappedNotJustTheDrawThatComesBack() throws {
    // The distinction is not cosmetic. Clamp only the returned value and a
    // real `SystemRandom` is handed [base, 10^10] and lands on the cap almost
    // surely — the jitter distribution collapses to a constant while every
    // assertion about the returned value still passes, and the whole
    // installed base retries in lockstep again.
    let clock = FakeClock()
    let random = FakeRandom(position: 0.5)
    var l = ladder(clock, random)
    for _ in 0..<20 {
        let wait = l.record(.rateLimited(retryAfterSeconds: nil))
        clock.advance(wait)
    }
    let rateRange = try #require(random.calls.last)
    #expect(rateRange.lowerBound == RateConstants.rateLimitBackoffBase)
    #expect(rateRange.upperBound == RateConstants.rateLimitBackoffCap)

    let serverClock = FakeClock()
    let serverRandom = FakeRandom(position: 0.5)
    var s = ladder(serverClock, serverRandom)
    for _ in 0..<20 {
        let wait = s.record(.server)
        serverClock.advance(wait)
    }
    let serverRange = try #require(serverRandom.calls.last)
    #expect(serverRange.lowerBound == RateConstants.serverBackoffBase)
    #expect(serverRange.upperBound == RateConstants.serverBackoffCap)
}

@Test func aRetryAfterHeaderIsHonouredWhenItIsPresent() {
    let clock = FakeClock()
    var l = ladder(clock)
    let applied = l.record(.rateLimited(retryAfterSeconds: 90))
    #expect(applied == 90)
}

@Test func anAbsurdRetryAfterIsClampedToTheCap() {
    // A header is a hint from a service that is already misbehaving.
    let clock = FakeClock()
    var l = ladder(clock)
    let tooLong = l.record(.rateLimited(retryAfterSeconds: 86_400))
    #expect(tooLong == RateConstants.rateLimitBackoffCap)
    let negative = l.record(.rateLimited(retryAfterSeconds: -5))
    #expect(negative == RateConstants.rateLimitBackoffBase)
}

@Test func serverFailuresUseTheirOwnShorterLadder() {
    let clock = FakeClock()
    var l = ladder(clock, FakeRandom(position: 1.0))
    let first = l.record(.server)
    #expect(first == RateConstants.serverBackoffBase)
    var last: Double = 0
    for _ in 0..<20 { last = l.record(.server); clock.advance(last) }
    #expect(last == RateConstants.serverBackoffCap)
}

@Test func unauthorizedAndContractFaultsBothCoolDownForAnHourImmediately() {
    // Neither is something backoff can fix, so neither climbs a ladder.
    let clock = FakeClock()
    var authLadder = ladder(clock)
    let authDelay = authLadder.record(.unauthorized)
    #expect(authDelay == RateConstants.unauthorizedCooldown)

    var contractLadder = ladder(FakeClock())
    let contractDelay = contractLadder.record(.contractFault)
    #expect(contractDelay == RateConstants.contractFaultCooldown)
}

@Test func aDeadSymbolCoolsDownNothing() {
    // The symbol is dropped from the rotation; the other nineteen are fine.
    let clock = FakeClock()
    var l = ladder(clock)
    let applied = l.record(.deadSymbol)
    #expect(applied == 0)
    #expect(!l.isCoolingDown())
}

@Test func aSuccessResetsTheLadderCompletely() {
    let clock = FakeClock()
    var l = ladder(clock, FakeRandom(position: 1.0))
    for _ in 0..<5 { let w = l.record(.rateLimited(retryAfterSeconds: nil)); clock.advance(w) }
    for _ in 0..<5 { let w = l.record(.server); clock.advance(w) }
    l.recordSuccess()
    #expect(!l.isCoolingDown())
    // Both ladders, not just the one the loop happened to end on. One
    // `recordSuccess()` has to have cleared both growth fields.
    let afterReset = l.record(.rateLimited(retryAfterSeconds: nil))
    #expect(afterReset == RateConstants.rateLimitBackoffBase)
    clock.advance(afterReset)
    let serverAfterReset = l.record(.server)
    #expect(serverAfterReset == RateConstants.serverBackoffBase)
}

@Test func aSuccessClearsACooldownThatIsStillInForce() {
    // The reset must be tested while there is genuinely something to reset.
    // Advancing the clock to the deadline first and *then* calling
    // `recordSuccess()` asserts nothing: the cooldown has already expired on
    // its own, so deleting the clearing line from `recordSuccess()` still
    // leaves every assertion true.
    let clock = FakeClock()
    var l = ladder(clock)
    let wait = l.record(.rateLimited(retryAfterSeconds: 600))
    #expect(wait == 600)

    clock.advance(1)                    // nowhere near the deadline
    #expect(l.isCoolingDown())          // the cooldown is live right now
    #expect(l.secondsRemaining() == 599)

    l.recordSuccess()
    #expect(!l.isCoolingDown())
    #expect(l.cooldownUntilMonotonic == nil)
    #expect(l.secondsRemaining() == 0)
}

@Test func theCooldownDeadlineIsReadableForPersistence() throws {
    // `cooldownUntilMonotonic` is the value the persistence layer writes out.
    // A property that always answers nil loses the circuit across every
    // relaunch, and does so silently.
    let clock = FakeClock(1_000)
    var l = ladder(clock)
    #expect(l.cooldownUntilMonotonic == nil)

    let wait = l.record(.rateLimited(retryAfterSeconds: 600))
    let deadline = try #require(l.cooldownUntilMonotonic)
    #expect(deadline == 1_000 + wait)

    // It tracks the deadline, not merely "some cooldown happened".
    clock.advance(100)
    let unchanged = try #require(l.cooldownUntilMonotonic)
    #expect(unchanged == deadline)
    #expect(l.secondsRemaining() == deadline - clock.nowSeconds)

    let auth = l.record(.unauthorized)
    let authDeadline = try #require(l.cooldownUntilMonotonic)
    #expect(authDeadline == 1_100 + auth)

    l.recordSuccess()
    #expect(l.cooldownUntilMonotonic == nil)
}

@Test func aCooldownExpiresExactlyWhenItSaidItWould() {
    // Half-open, as everywhere else in TickerCore (see TradingPeriodTests):
    // the deadline instant itself is already *out* of the cooldown. Sampling
    // only ±1 ms leaves that convention unpinned, and `FakeClock` can land on
    // the instant exactly — 0 + 120 is exact in binary floating point.
    let clock = FakeClock()
    var l = ladder(clock)
    let wait = l.record(.rateLimited(retryAfterSeconds: 120))
    #expect(wait == 120)
    clock.advance(wait)
    #expect(clock.nowSeconds == 120)
    #expect(l.secondsRemaining() == 0)
    #expect(!l.isCoolingDown())
    clock.advance(0.001)
    #expect(!l.isCoolingDown())

    // And one millisecond earlier, on a clock that has not been nudged twice,
    // it is still in force.
    let justBefore = FakeClock()
    var m = ladder(justBefore)
    let sameWait = m.record(.rateLimited(retryAfterSeconds: 120))
    justBefore.advance(sameWait - 0.001)
    #expect(m.isCoolingDown())
    #expect(m.secondsRemaining() > 0)
}

@Test func aPersistedCooldownSurvivesASimulatedRelaunch() {
    // The reason the deadline is persisted at all: a user who relaunches
    // repeatedly during a 429 would otherwise get the installed base's IP
    // banned (spec §4.3).
    let clock = FakeClock()
    var l = ladder(clock)
    _ = l.record(.rateLimited(retryAfterSeconds: 600))
    let remaining = l.secondsRemaining()
    #expect(remaining > 599)

    // Relaunch: a brand-new ladder on a brand-new monotonic clock.
    let afterRelaunch = FakeClock(0)
    var revived = ladder(afterRelaunch)
    revived.adoptPersistedCooldown(secondsRemaining: remaining)
    #expect(revived.isCoolingDown())
    afterRelaunch.advance(remaining + 1)
    #expect(!revived.isCoolingDown())
}

@Test func secondsRemainingNeverGoesNegativeOnceTheDeadlineHasPassed() {
    // Callers schedule from this interval. A negative one is not "expired",
    // it is a timer in the past, and nothing else in the file ever reads the
    // value after its deadline.
    let clock = FakeClock()
    var l = ladder(clock)
    let wait = l.record(.rateLimited(retryAfterSeconds: 300))
    clock.advance(wait / 2)
    #expect(l.secondsRemaining() == 150)

    clock.advance(wait)                 // 450s in, 150s past the deadline
    #expect(!l.isCoolingDown())
    #expect(l.secondsRemaining() == 0)

    // Far past it, too — the floor is a floor, not an off-by-one.
    clock.advance(RateConstants.maxCooldownSeconds)
    #expect(l.secondsRemaining() == 0)
}

@Test func aPersistedCooldownFromAChangedSystemClockIsClamped() {
    // A wall-clock deadline read back after the user set their date to 2099
    // must not strand the app for a year. The bound is the longest cooldown
    // the ladder itself can produce — clamping to the rate-limit cap instead
    // would silently halve the two hour-long circuits below.
    let clock = FakeClock()
    var l = ladder(clock)
    l.adoptPersistedCooldown(secondsRemaining: 365 * 24 * 3600)
    #expect(l.secondsRemaining() == RateConstants.maxCooldownSeconds)

    var negative = ladder(FakeClock())
    negative.adoptPersistedCooldown(secondsRemaining: -1000)
    #expect(!negative.isCoolingDown())
    #expect(negative.cooldownUntilMonotonic == nil)

    var notANumber = ladder(FakeClock())
    notANumber.adoptPersistedCooldown(secondsRemaining: .nan)
    #expect(!notANumber.isCoolingDown())
    #expect(notANumber.cooldownUntilMonotonic == nil)

    var infinite = ladder(FakeClock())
    infinite.adoptPersistedCooldown(secondsRemaining: .infinity)
    #expect(infinite.secondsRemaining() == RateConstants.maxCooldownSeconds)
}

@Test func aPersistedHourLongCircuitComesBackWhole() {
    // The clamp cannot be shorter than the longest cooldown this same ladder
    // emits, or the restore path silently halves exactly the two circuits
    // that backoff cannot fix — an hour of deliberate silence read back as
    // thirty minutes.
    let clock = FakeClock()
    var l = ladder(clock)
    let applied = l.record(.unauthorized)
    #expect(applied == RateConstants.unauthorizedCooldown)
    let remaining = l.secondsRemaining()
    #expect(remaining == applied)

    let afterRelaunch = FakeClock(0)
    var revived = ladder(afterRelaunch)
    revived.adoptPersistedCooldown(secondsRemaining: remaining)
    #expect(revived.secondsRemaining() == remaining)
    #expect(revived.isCoolingDown())

    var afterContractFault = ladder(FakeClock())
    let contract = afterContractFault.record(.contractFault)
    var revivedContract = ladder(FakeClock())
    revivedContract.adoptPersistedCooldown(secondsRemaining: contract)
    #expect(revivedContract.secondsRemaining() == contract)
}

@Test func aRestoredCooldownRestoresTheLadderItWasClimbing() throws {
    // Persistence exists so that relaunching repeatedly during a 429 does not
    // hand the user a fresh ladder and get the installed base's IP banned
    // (spec §4.3). A restored deadline that quietly resets the growth state
    // defeats the only reason the deadline is written out at all.
    let clock = FakeClock()
    let random = FakeRandom(position: 1.0)
    var l = ladder(clock, random)
    l.adoptPersistedCooldown(secondsRemaining: 200)
    clock.advance(200)
    #expect(!l.isCoolingDown())

    let next = l.record(.rateLimited(retryAfterSeconds: nil))
    #expect(next > RateConstants.rateLimitBackoffBase)
    #expect(next == 200 * RateConstants.jitterGrowthFactor)      // 600, mid-ladder
    let range = try #require(random.calls.last)
    #expect(range.lowerBound == RateConstants.rateLimitBackoffBase)
    #expect(range.upperBound == 600)
}
