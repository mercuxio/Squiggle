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
    #expect(FailureKind(.transport("timeout")) == .server)
    #expect(FailureKind(.unauthorized(status: 401)) == .unauthorized)
    #expect(FailureKind(.symbolNotFound(symbol)) == .deadSymbol)
    // Every contract fault, one kind. Spec §4.3 gives them their own circuit.
    #expect(FailureKind(.notJSON) == .contractFault)
    #expect(FailureKind(.noResult) == .contractFault)
    #expect(FailureKind(.missingField(path: "x")) == .contractFault)
    #expect(FailureKind(.nonFiniteNumber(path: "x")) == .contractFault)
    // The remaining contract faults from `TickerError.isContractFault`.
    #expect(FailureKind(.emptyBody) == .contractFault)
    #expect(FailureKind(.wrongType(path: "x", expected: "number")) == .contractFault)
    #expect(FailureKind(.negativeValue(path: "x", value: -1)) == .contractFault)
    // These three cannot arise from a fetch at all (a rejected symbol never
    // reaches the network; the other two are storage faults). Mapped to the
    // mildest, shortest, self-correcting rung deliberately: routing an
    // unreachable case into the hour-long contract circuit would turn a
    // local bug into an hour of silence.
    #expect(FailureKind(.invalidSymbol("not a symbol")) == .server)
    #expect(FailureKind(.storeSchemaUnsupported(version: 99)) == .server)
    #expect(FailureKind(.storeCorrupt(quarantinedAt: "2026-09-08")) == .server)
}

@Test func beingOfflineDoesNotAdvanceTheLadder() {
    // Spec §4.3: do not attempt, do not advance. Punishing the user's flaky
    // wifi with a 30-minute cooldown means the ticker is dead long after the
    // network comes back.
    let clock = FakeClock()
    var l = ladder(clock)
    for _ in 0..<10 { _ = l.record(.offline) }
    #expect(!l.isCoolingDown())
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
    _ = l.record(.rateLimited(retryAfterSeconds: nil))
    clock.advance(1000)
    _ = l.record(.rateLimited(retryAfterSeconds: nil))

    let range = try #require(random.calls.last)
    #expect(range.lowerBound == RateConstants.rateLimitBackoffBase)
    #expect(range.upperBound > range.lowerBound)
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
    l.recordSuccess()
    #expect(!l.isCoolingDown())
    let afterReset = l.record(.rateLimited(retryAfterSeconds: nil))
    #expect(afterReset == RateConstants.rateLimitBackoffBase)
}

@Test func aCooldownExpiresExactlyWhenItSaidItWould() {
    let clock = FakeClock()
    var l = ladder(clock)
    let wait = l.record(.rateLimited(retryAfterSeconds: 120))
    clock.advance(wait - 0.001)
    #expect(l.isCoolingDown())
    clock.advance(0.002)
    #expect(!l.isCoolingDown())
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

@Test func aPersistedCooldownFromAChangedSystemClockIsClamped() {
    // A wall-clock deadline read back after the user set their date to 2099
    // must not strand the app for a year.
    let clock = FakeClock()
    var l = ladder(clock)
    l.adoptPersistedCooldown(secondsRemaining: 365 * 24 * 3600)
    #expect(l.secondsRemaining() <= RateConstants.rateLimitBackoffCap)

    var negative = ladder(FakeClock())
    negative.adoptPersistedCooldown(secondsRemaining: -1000)
    #expect(!negative.isCoolingDown())
}
