import Testing
@testable import TickerCore

// NOTE: as in BackoffLadderTests.swift, this suite's `#expect(...)` macro
// mis-compiles whenever the checked expression is a direct call to a
// `mutating` method on a `var` — its call-capturing expansion binds the
// receiver as an immutable `$0`, producing "cannot use mutating member on
// immutable value". `allowsRequest()`, `state()` and `secondsRemaining()`
// are all `mutating`, so every such call is hoisted into its own `let`
// before the `#expect` that checks it — one `let` per original call site,
// in the original order, since `allowsRequest()` has a side effect (it
// consumes the half-open probe) and collapsing two calls into one binding
// would silently change what is being tested.

private func networkBreaker(_ clock: FakeClock) -> CircuitBreaker {
    CircuitBreaker(clock: clock,
                   threshold: RateConstants.circuitFailureThreshold,
                   openSeconds: RateConstants.circuitOpenSeconds)
}

@Test func aFreshBreakerIsClosedAndAllowsRequests() {
    var b = networkBreaker(FakeClock())
    let state = b.state()
    #expect(state == .closed)
    let allowed = b.allowsRequest()
    #expect(allowed)
}

@Test func theBreakerTripsOnTheThresholdFailureAndNotBefore() {
    let clock = FakeClock()
    var b = networkBreaker(clock)
    for _ in 0..<(RateConstants.circuitFailureThreshold - 1) {
        b.recordFailure()
        let allowed = b.allowsRequest()
        #expect(allowed, "tripped early at \(b.consecutiveFailures) failures")
    }
    b.recordFailure()
    let allowed = b.allowsRequest()
    #expect(!allowed)
}

@Test func oneSuccessAnywhereInTheRunResetsTheCount() {
    // "Consecutive" is the whole point: an outage that alternates
    // success/failure is a working connection, not a dead one.
    let clock = FakeClock()
    var b = networkBreaker(clock)
    for _ in 0..<20 {
        for _ in 0..<(RateConstants.circuitFailureThreshold - 1) { b.recordFailure() }
        b.recordSuccess()
    }
    #expect(b.consecutiveFailures == 0)
    let allowed = b.allowsRequest()
    #expect(allowed)
}

@Test func anOpenBreakerStaysOpenForItsFullDurationThenGoesHalfOpen() {
    let clock = FakeClock()
    var b = networkBreaker(clock)
    for _ in 0..<RateConstants.circuitFailureThreshold { b.recordFailure() }

    clock.advance(RateConstants.circuitOpenSeconds - 1)
    let stillBlocked = b.allowsRequest()
    #expect(!stillBlocked)
    let stateBeforeExpiry = b.state()
    #expect(stateBeforeExpiry == .open(untilMonotonic: RateConstants.circuitOpenSeconds))

    clock.advance(2)
    let stateAfterExpiry = b.state()
    #expect(stateAfterExpiry == .halfOpen)
    let probe = b.allowsRequest()
    #expect(probe, "half-open must permit the probe")
}

@Test func aHalfOpenBreakerPermitsExactlyOneProbe() {
    // The probe is one request for one symbol. If half-open let the whole
    // watchlist through, a still-down upstream would get twenty requests as
    // its reward for the outage.
    let clock = FakeClock()
    var b = networkBreaker(clock)
    for _ in 0..<RateConstants.circuitFailureThreshold { b.recordFailure() }
    clock.advance(RateConstants.circuitOpenSeconds + 1)

    let firstProbe = b.allowsRequest()
    #expect(firstProbe)
    let secondProbe = b.allowsRequest()
    #expect(!secondProbe, "half-open handed out a second concurrent probe")
}

@Test func aFailedProbeReopensTheBreakerForTheFullDuration() {
    let clock = FakeClock()
    var b = networkBreaker(clock)
    for _ in 0..<RateConstants.circuitFailureThreshold { b.recordFailure() }
    clock.advance(RateConstants.circuitOpenSeconds + 1)
    let probe = b.allowsRequest()
    #expect(probe)

    b.recordFailure()
    let afterFailedProbe = b.allowsRequest()
    #expect(!afterFailedProbe)
    clock.advance(RateConstants.circuitOpenSeconds - 1)
    let stillOpen = b.allowsRequest()
    #expect(!stillOpen, "the probe failure did not restart the full timer")
    clock.advance(2)
    let reopened = b.allowsRequest()
    #expect(reopened)
}

@Test func aSuccessfulProbeClosesTheBreakerCompletely() {
    let clock = FakeClock()
    var b = networkBreaker(clock)
    for _ in 0..<RateConstants.circuitFailureThreshold { b.recordFailure() }
    clock.advance(RateConstants.circuitOpenSeconds + 1)
    let probe = b.allowsRequest()
    #expect(probe)

    b.recordSuccess()
    let state = b.state()
    #expect(state == .closed)
    let firstAfterClose = b.allowsRequest()
    #expect(firstAfterClose)
    let secondAfterClose = b.allowsRequest()
    #expect(secondAfterClose, "a closed breaker must not ration requests")
}

@Test func theContractCircuitTripsOnASingleFaultAndHoldsForAnHour() {
    // A schema change will not fix itself in thirty seconds, and hammering
    // an endpoint that is answering 200 with the wrong shape is pure waste.
    let clock = FakeClock()
    var b = CircuitBreaker(clock: clock, threshold: 1,
                           openSeconds: RateConstants.contractFaultCooldown)
    b.recordFailure()
    let blockedImmediately = b.allowsRequest()
    #expect(!blockedImmediately)
    clock.advance(RateConstants.contractFaultCooldown - 1)
    let stillBlocked = b.allowsRequest()
    #expect(!stillBlocked)
    clock.advance(2)
    let allowedNow = b.allowsRequest()
    #expect(allowedNow)
}

@Test func theTwoCircuitsAreIndependent() {
    // A flaky café connection must not be able to silence the schema alarm,
    // and a schema change must not be reported as a network outage.
    let clock = FakeClock()
    var network = networkBreaker(clock)
    var contract = CircuitBreaker(clock: clock, threshold: 1,
                                  openSeconds: RateConstants.contractFaultCooldown)

    for _ in 0..<RateConstants.circuitFailureThreshold { network.recordFailure() }
    let networkBlocked = network.allowsRequest()
    #expect(!networkBlocked)
    let contractStillAllows = contract.allowsRequest()
    #expect(contractStillAllows, "the network circuit tripped the contract circuit")

    network.recordSuccess()
    contract.recordFailure()
    let networkAllowsAgain = network.allowsRequest()
    #expect(networkAllowsAgain)
    let contractBlocked = contract.allowsRequest()
    #expect(!contractBlocked)
}

@Test func trippingExplicitlyIsEquivalentToReachingTheThreshold() {
    // A 429 should open the circuit immediately rather than needing five
    // more requests to prove the point.
    let clock = FakeClock()
    var b = networkBreaker(clock)
    b.trip()
    let blockedAfterTrip = b.allowsRequest()
    #expect(!blockedAfterTrip)
    clock.advance(RateConstants.circuitOpenSeconds + 1)
    let allowedAfterWait = b.allowsRequest()
    #expect(allowedAfterWait)
}

@Test func aClosedBreakerHasNothingLeftToWaitFor() {
    // Callers take the maximum across two breakers. If a closed one reported
    // anything but zero, one healthy breaker could hold the other's work back.
    var b = networkBreaker(FakeClock(0))
    let remaining = b.secondsRemaining()
    #expect(remaining == 0)
}

@Test func anOpenBreakerCountsDownAndReachesZeroExactlyAtExpiry() {
    let clock = FakeClock(0)
    var b = networkBreaker(clock)
    b.trip()
    let initialRemaining = b.secondsRemaining()
    #expect(initialRemaining == RateConstants.circuitOpenSeconds)
    clock.advance(RateConstants.circuitOpenSeconds / 2)
    let halfwayRemaining = b.secondsRemaining()
    #expect(halfwayRemaining == RateConstants.circuitOpenSeconds / 2)
    clock.advance(RateConstants.circuitOpenSeconds / 2)
    // At expiry the breaker is half-open, not open, so there is nothing left
    // to wait for — and the reported wait must never go negative.
    let atExpiryRemaining = b.secondsRemaining()
    #expect(atExpiryRemaining == 0)
    clock.advance(10_000)
    let longAfterRemaining = b.secondsRemaining()
    #expect(longAfterRemaining == 0)
}

@Test func timeGoingBackwardsDoesNotCloseAnOpenBreaker() {
    let clock = FakeClock(10_000)
    var b = networkBreaker(clock)
    b.trip()
    clock.advance(-100_000)
    let allowed = b.allowsRequest()
    #expect(!allowed)
}
