import Testing
@testable import TickerCore

// NOTE: as in BackoffLadderTests.swift, this suite's `#expect(...)` macro
// mis-compiles whenever the checked expression is a direct call to a
// `mutating` method on a `var` — its call-capturing expansion binds the
// receiver as an immutable `$0`, producing "cannot use mutating member on
// immutable value". `allowsRequest()` is the only such method on
// `CircuitBreaker`, so it — and only it — is hoisted into its own `let`
// before the `#expect` that checks it: one `let` per original call site, in
// the original order, because issuing the half-open probe is a side effect
// and collapsing two calls into one binding would silently change what is
// being tested. `state()` and `secondsRemaining()` are non-mutating and are
// written inline, which is also where a reader should be able to stop
// thinking about it.

private func networkBreaker(_ clock: FakeClock) -> CircuitBreaker {
    CircuitBreaker(clock: clock,
                   threshold: RateConstants.circuitFailureThreshold,
                   openSeconds: RateConstants.circuitOpenSeconds)
}

/// A breaker driven to `.open` by real failures, at the clock's current time.
private func openedBreaker(_ clock: FakeClock) -> CircuitBreaker {
    var b = networkBreaker(clock)
    for _ in 0..<RateConstants.circuitFailureThreshold { b.recordFailure() }
    return b
}

@Test func aFreshBreakerIsClosedAndAllowsRequests() {
    var b = networkBreaker(FakeClock())
    #expect(b.state() == .closed)
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

@Test func consecutiveFailuresReportsTheRunningCountAndNotAConstant() {
    // The only assertion this member used to carry was `== 0`, which a
    // hard-coded zero satisfies by construction: a required public accessor
    // with no positive coverage at all. Pin it at every intermediate count,
    // across a reset, and past the threshold.
    let clock = FakeClock()
    var b = networkBreaker(clock)
    #expect(b.consecutiveFailures == 0)

    for expected in 1..<RateConstants.circuitFailureThreshold {
        b.recordFailure()
        #expect(b.consecutiveFailures == expected)
    }

    b.recordSuccess()
    #expect(b.consecutiveFailures == 0, "a success must clear the run, not decrement it")

    // It keeps counting past the threshold — it is a count of failures
    // recorded, not a latch that stops at the number that opened the circuit.
    for expected in 1...(RateConstants.circuitFailureThreshold + 3) {
        b.recordFailure()
        #expect(b.consecutiveFailures == expected)
    }

    // And `trip()` invents none of them: one 429 is one piece of bad news.
    var tripped = networkBreaker(FakeClock())
    tripped.trip()
    #expect(tripped.consecutiveFailures == 0,
            "trip() reported failures that never happened")
    tripped.recordSuccess()
    #expect(tripped.consecutiveFailures == 0)
}

@Test func anOpenBreakerStaysOpenForItsFullDurationThenGoesHalfOpen() {
    let clock = FakeClock()
    var b = openedBreaker(clock)

    clock.advance(RateConstants.circuitOpenSeconds - 1)
    let stillBlocked = b.allowsRequest()
    #expect(!stillBlocked)
    #expect(b.state() == .open(untilMonotonic: RateConstants.circuitOpenSeconds))

    clock.advance(2)
    #expect(b.state() == .halfOpen)
    let probe = b.allowsRequest()
    #expect(probe, "half-open must permit the probe")
}

@Test func theDeadlineInstantItselfIsAlreadyHalfOpen() {
    // The `<` in `state()` carries a comment calling itself deliberate, and
    // nothing pinned it: the countdown test lands on the deadline but reads
    // only `secondsRemaining()`, which answers 0 under both `<` and `<=`.
    // These two assertions are the ones that can tell them apart.
    let atDeadline = FakeClock(0)
    var b = networkBreaker(atDeadline)
    b.trip()
    atDeadline.advance(RateConstants.circuitOpenSeconds)
    #expect(atDeadline.nowSeconds == RateConstants.circuitOpenSeconds)
    #expect(b.state() == .halfOpen,
            "the deadline instant is out of the open window, not in it")
    let allowedAtDeadline = b.allowsRequest()
    #expect(allowedAtDeadline, "the breaker refused a probe at its own deadline")

    // One millisecond earlier, on a clock that has not been nudged twice, it
    // is still shut — and still says how long for.
    let justBefore = FakeClock(0)
    var m = networkBreaker(justBefore)
    m.trip()
    justBefore.advance(RateConstants.circuitOpenSeconds - 0.001)
    #expect(m.state() == .open(untilMonotonic: RateConstants.circuitOpenSeconds))
    let refusedJustBefore = m.allowsRequest()
    #expect(!refusedJustBefore)
    #expect(m.secondsRemaining() > 0)
}

@Test func aHalfOpenBreakerPermitsExactlyOneProbe() {
    // The probe is one request for one symbol. If half-open let the whole
    // watchlist through, a still-down upstream would get twenty requests as
    // its reward for the outage.
    let clock = FakeClock()
    var b = openedBreaker(clock)
    clock.advance(RateConstants.circuitOpenSeconds + 1)

    let firstProbe = b.allowsRequest()
    #expect(firstProbe)
    let secondProbe = b.allowsRequest()
    #expect(!secondProbe, "half-open handed out a second concurrent probe")
}

@Test func anUnresolvedProbeIsPresumedLostAndAFreshOneIsIssued() {
    // The probe is taken and its outcome never reported — the process was
    // suspended, the app was quit mid-request, the caller forgot. Without a
    // lifetime on the probe the breaker is wedged for the rest of the
    // process: half-open, refusing everything, and answering "wait zero
    // seconds" to anyone who asks how long. That is a hot loop on a battery.
    let clock = FakeClock()
    var b = openedBreaker(clock)
    clock.advance(RateConstants.circuitOpenSeconds + 1)
    let probe = b.allowsRequest()
    #expect(probe)

    // Neither recordSuccess() nor recordFailure(). Ever.
    clock.advance(RateConstants.probeTimeoutSeconds - 1)
    let tooSoon = b.allowsRequest()
    #expect(!tooSoon, "the probe was reissued before it could have timed out")
    #expect(b.secondsRemaining() == 1,
            "a refused breaker must name the interval it is refusing for")

    clock.advance(1)   // exactly `probeTimeoutSeconds` after it was issued
    let reissued = b.allowsRequest()
    #expect(reissued, "an unresolved probe wedged the breaker")

    // And the shape the wedge was first found in: leave the reissued probe
    // unresolved too, then wait an absurdly long time.
    clock.advance(1_000_000)
    #expect(b.state() == .halfOpen)
    #expect(b.secondsRemaining() == 0)
    let afterAnAge = b.allowsRequest()
    #expect(afterAnAge, "the breaker never recovered from a lost probe")
}

@Test func aRefusedRequestAlwaysComesWithAnIntervalToWait() {
    // The invariant, walked across every reachable state. `secondsRemaining()`
    // is a promise that a request would be let through once it elapses; a
    // breaker that answers zero and then refuses leaves its caller nothing to
    // sleep on, and it spins. This is stronger than any single boundary
    // assertion, and it is the one that would have caught the wedge above.
    func check(_ b: inout CircuitBreaker, _ at: String) {
        let remaining = b.secondsRemaining()
        let allowed = b.allowsRequest()
        #expect(allowed || remaining > 0,
                "\(at): refused a request while reporting a zero wait")
    }

    // Closed.
    var fresh = networkBreaker(FakeClock())
    check(&fresh, "closed")

    // Open, well before the deadline.
    let early = FakeClock()
    var earlyBreaker = openedBreaker(early)
    early.advance(1)
    check(&earlyBreaker, "open, one second in")

    // Open, one millisecond before the deadline.
    let late = FakeClock()
    var lateBreaker = openedBreaker(late)
    late.advance(RateConstants.circuitOpenSeconds - 0.001)
    check(&lateBreaker, "open, a millisecond from expiry")

    // Exactly at the deadline: half-open, probe available.
    let atExpiry = FakeClock()
    var atExpiryBreaker = openedBreaker(atExpiry)
    atExpiry.advance(RateConstants.circuitOpenSeconds)
    check(&atExpiryBreaker, "the deadline instant")

    // Half-open with the probe in flight — the state that used to answer
    // zero while refusing.
    let inFlight = FakeClock()
    var inFlightBreaker = openedBreaker(inFlight)
    inFlight.advance(RateConstants.circuitOpenSeconds + 1)
    let taken = inFlightBreaker.allowsRequest()
    #expect(taken)
    check(&inFlightBreaker, "half-open, probe in flight")

    // Half-open with the probe in flight, a millisecond from its timeout.
    let nearlyLost = FakeClock()
    var nearlyLostBreaker = openedBreaker(nearlyLost)
    nearlyLost.advance(RateConstants.circuitOpenSeconds + 1)
    let takenAgain = nearlyLostBreaker.allowsRequest()
    #expect(takenAgain)
    nearlyLost.advance(RateConstants.probeTimeoutSeconds - 0.001)
    check(&nearlyLostBreaker, "half-open, probe about to time out")

    // Half-open with an expired probe.
    let lost = FakeClock()
    var lostBreaker = openedBreaker(lost)
    lost.advance(RateConstants.circuitOpenSeconds + 1)
    let abandoned = lostBreaker.allowsRequest()
    #expect(abandoned)
    lost.advance(RateConstants.probeTimeoutSeconds)
    check(&lostBreaker, "half-open, probe presumed lost")

    // And an abandoned probe an age later, which is where the wedge lived.
    let ancient = FakeClock()
    var ancientBreaker = openedBreaker(ancient)
    ancient.advance(RateConstants.circuitOpenSeconds + 1)
    let ancientProbe = ancientBreaker.allowsRequest()
    #expect(ancientProbe)
    ancient.advance(1_000_000)
    check(&ancientBreaker, "half-open, probe abandoned long ago")
}

@Test func aFailedProbeReopensTheBreakerForTheFullDuration() {
    let clock = FakeClock()
    var b = openedBreaker(clock)
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

@Test func aProbeThatFailsAfterAnExplicitTripAlsoReopensForTheFullDuration() {
    // `trip()` records no failures at all, so the reopen here cannot be
    // carried by the failure count reaching the threshold — it rests entirely
    // on the breaker noticing that it was half-open when the request went
    // out. Nothing tested trip() together with a failing probe, and the two
    // guards that used to hold this path up were each sufficient on their
    // own, so neither was pinned: dropping both granted five consecutive
    // probes with no time passing at all.
    let clock = FakeClock()
    var b = networkBreaker(clock)
    b.trip()
    #expect(b.consecutiveFailures == 0)
    clock.advance(RateConstants.circuitOpenSeconds + 1)

    let probe = b.allowsRequest()
    #expect(probe)
    b.recordFailure()
    #expect(b.consecutiveFailures == 1, "one failed probe is one failure")

    // No time has passed. A breaker that hands out a second probe here is
    // handing the still-broken upstream its whole watchlist back.
    var granted = 0
    for _ in 0..<RateConstants.circuitFailureThreshold {
        let allowed = b.allowsRequest()
        if allowed { granted += 1 }
    }
    #expect(granted == 0, "a failed probe after trip() left the breaker open for business")

    clock.advance(RateConstants.circuitOpenSeconds - 1)
    let stillOpen = b.allowsRequest()
    #expect(!stillOpen, "the failed probe did not restart the full timer")
    clock.advance(2)
    let reopened = b.allowsRequest()
    #expect(reopened)
}

@Test func aFailureRecordedWhileOpenDoesNotExtendTheOutage() {
    // `.open(untilMonotonic:)` publishes a deadline. A caller that reports
    // failures for requests the breaker had already refused — or one that
    // never consulted it — must not be able to push that deadline forward,
    // or a thirty-minute outage silently becomes fifty. A failed *probe* is
    // the opposite case and still reopens in full; the two are distinct.
    let clock = FakeClock(0)
    var b = networkBreaker(clock)
    b.trip()
    let deadline = RateConstants.circuitOpenSeconds
    #expect(b.state() == .open(untilMonotonic: deadline))

    for _ in 0..<10 {
        clock.advance(60)
        b.recordFailure()
        #expect(b.state() == .open(untilMonotonic: deadline),
                "a failure recorded while open moved the deadline")
        #expect(b.secondsRemaining() == deadline - clock.nowSeconds)
    }

    clock.advance(deadline - clock.nowSeconds)
    #expect(b.state() == .halfOpen)
    let probe = b.allowsRequest()
    #expect(probe, "ten stray failure reports extended a thirty-minute outage")
}

@Test func aNewOpenEpisodeStartsWithAProbeOfItsOwn() {
    // A probe token that survives the cycle that issued it refuses the *next*
    // cycle's probe. The open window here is deliberately shorter than
    // `probeTimeoutSeconds`, so the next half-open cycle arrives while a
    // stale token would still be live: with a thirty-minute window the probe
    // timeout would quietly rescue the bug and the test would assert nothing.
    let shortWindow = RateConstants.probeTimeoutSeconds / 6   // 10s
    #expect(shortWindow * 2 < RateConstants.probeTimeoutSeconds)

    func breaker(_ clock: FakeClock) -> CircuitBreaker {
        CircuitBreaker(clock: clock, threshold: 1, openSeconds: shortWindow)
    }

    // A cycle that ended in success, then a fresh one.
    let successClock = FakeClock()
    var afterSuccess = breaker(successClock)
    afterSuccess.recordFailure()
    successClock.advance(shortWindow + 1)
    let firstProbe = afterSuccess.allowsRequest()
    #expect(firstProbe)
    afterSuccess.recordSuccess()
    afterSuccess.recordFailure()
    successClock.advance(shortWindow + 1)
    let afterSuccessProbe = afterSuccess.allowsRequest()
    #expect(afterSuccessProbe, "the episode after a success reused a stale probe token")

    // A cycle reopened by a failed probe.
    let failureClock = FakeClock()
    var afterFailure = breaker(failureClock)
    afterFailure.recordFailure()
    failureClock.advance(shortWindow + 1)
    let failureProbe = afterFailure.allowsRequest()
    #expect(failureProbe)
    afterFailure.recordFailure()
    failureClock.advance(shortWindow + 1)
    let afterFailureProbe = afterFailure.allowsRequest()
    #expect(afterFailureProbe, "a failed probe left its token behind for the next episode")

    // A cycle reopened by an explicit trip.
    let tripClock = FakeClock()
    var afterTrip = breaker(tripClock)
    afterTrip.recordFailure()
    tripClock.advance(shortWindow + 1)
    let tripProbe = afterTrip.allowsRequest()
    #expect(tripProbe)
    afterTrip.trip()
    tripClock.advance(shortWindow + 1)
    let afterTripProbe = afterTrip.allowsRequest()
    #expect(afterTripProbe, "trip() reused the previous episode's probe token")
}

@Test func aSuccessfulProbeClosesTheBreakerCompletely() {
    let clock = FakeClock()
    var b = openedBreaker(clock)
    clock.advance(RateConstants.circuitOpenSeconds + 1)
    let probe = b.allowsRequest()
    #expect(probe)

    b.recordSuccess()
    #expect(b.state() == .closed)
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

@Test func aThresholdBelowOneStillNeedsARealFailureToOpen() {
    // A threshold of zero must not mean "zero failures is enough". Nothing
    // constructed a degenerate breaker, so nothing said what one does; the
    // answer is that the threshold is only ever compared after a failure has
    // been counted, which is why the initializer needs no clamp to defend it.
    for threshold in [0, -3] {
        let clock = FakeClock()
        var b = CircuitBreaker(clock: clock, threshold: threshold,
                               openSeconds: RateConstants.circuitOpenSeconds)
        #expect(b.state() == .closed, "a threshold of \(threshold) was born open")
        #expect(b.consecutiveFailures == 0)
        let beforeAnythingFailed = b.allowsRequest()
        #expect(beforeAnythingFailed,
                "a threshold of \(threshold) refused a request before anything failed")

        b.recordFailure()
        #expect(b.state() == .open(untilMonotonic: RateConstants.circuitOpenSeconds))
        let afterOneFailure = b.allowsRequest()
        #expect(!afterOneFailure)
    }
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
    let b = networkBreaker(FakeClock(0))
    #expect(b.secondsRemaining() == 0)
}

@Test func anOpenBreakerCountsDownAndReachesZeroExactlyAtExpiry() {
    let clock = FakeClock(0)
    var b = networkBreaker(clock)
    b.trip()
    #expect(b.secondsRemaining() == RateConstants.circuitOpenSeconds)
    clock.advance(RateConstants.circuitOpenSeconds / 2)
    #expect(b.secondsRemaining() == RateConstants.circuitOpenSeconds / 2)
    clock.advance(RateConstants.circuitOpenSeconds / 2)
    // At expiry the breaker is half-open with its probe available, so there
    // is genuinely nothing left to wait for — and the reported wait must
    // never go negative.
    #expect(b.secondsRemaining() == 0)
    clock.advance(10_000)
    #expect(b.secondsRemaining() == 0)
}

@Test func timeGoingBackwardsDoesNotCloseAnOpenBreaker() {
    let clock = FakeClock(10_000)
    var b = networkBreaker(clock)
    b.trip()
    clock.advance(-100_000)
    let allowed = b.allowsRequest()
    #expect(!allowed)
}
