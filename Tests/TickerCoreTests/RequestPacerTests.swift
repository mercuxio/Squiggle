import Testing
@testable import TickerCore

// NOTE: this suite's standalone `swift-testing` package (see
// ExpectMacroTests.swift) also mis-compiles `#expect(...)` whenever the
// checked expression is a direct call to a `mutating` method on a `var` —
// its call-capturing expansion binds the receiver as an immutable `$0`.
// `RequestPacer.take()` is exactly that shape, so every such call is hoisted
// into a `let` before the `#expect` rather than written inline.

@Test func aFreshPacerAllowsABurstUpToCapacityAndNoMore() {
    let clock = FakeClock()
    var pacer = RequestPacer(clock: clock)

    // Capacity 5 exists so a launch, an unocclusion and a manual refresh do
    // not each have to wait 30 seconds. It is a burst allowance, not a rate.
    for attempt in 1...Int(RateConstants.bucketCapacity) {
        let granted = pacer.take()
        #expect(granted, "token \(attempt) should have been available")
    }
    let extra = pacer.take()
    #expect(!extra)
}

@Test func theBucketRefillsAtExactlyOnePerSpacingInterval() {
    let clock = FakeClock()
    var pacer = RequestPacer(clock: clock)
    while pacer.take() {}

    clock.advance(RateConstants.spacingSeconds - 0.001)
    let tooEarly = pacer.take()
    #expect(!tooEarly, "a token appeared before the spacing floor elapsed")

    clock.advance(0.002)
    let onTime = pacer.take()
    #expect(onTime)
    let secondInARow = pacer.take()
    #expect(!secondInARow, "two tokens appeared for one interval")
}

@Test func theBucketNeverAccumulatesMoreThanCapacity() {
    // A machine asleep for a week must not wake with a week of tokens. This
    // is the invariant that makes the daily budget hold across a lid-open.
    let clock = FakeClock()
    var pacer = RequestPacer(clock: clock)
    while pacer.take() {}

    clock.advance(hours: 168)
    var granted = 0
    while pacer.take() { granted += 1 }
    #expect(granted == Int(RateConstants.bucketCapacity))
}

@Test func theLongRunRateIsOnePerSpacingIntervalNoMatterHowOftenItIsAsked() {
    // Poll it every second for a simulated day. The bucket, not the caller,
    // decides the rate.
    let clock = FakeClock()
    var pacer = RequestPacer(clock: clock)
    var granted = 0
    for _ in 0..<86_400 {
        if pacer.take() { granted += 1 }
        clock.advance(1)
    }
    let ceiling = Int(86_400 / RateConstants.spacingSeconds + RateConstants.bucketCapacity)
    #expect(granted <= ceiling, "granted \(granted), ceiling \(ceiling)")
    #expect(granted >= ceiling - 2, "granted \(granted); the bucket is throttling below its rate")
}

@Test func halvingTheCapacityHalvesTheBurstAndTheRate() {
    // AIMD on a 429 (spec §4.3): back off multiplicatively, recover additively
    // — which here means not recovering at all within the session.
    let clock = FakeClock()
    var pacer = RequestPacer(clock: clock)
    pacer.halveCapacity()

    var granted = 0
    while pacer.take() { granted += 1 }
    #expect(granted == Int(RateConstants.bucketCapacity / 2))

    clock.advance(RateConstants.spacingSeconds * 2)
    let refilled = pacer.take()
    #expect(refilled)
    let second = pacer.take()
    #expect(!second, "halving did not slow the refill")
}

@Test func capacityNeverHalvesBelowOne() {
    // Repeated 429s must leave the app able to make progress eventually;
    // a capacity of zero is a permanent outage that no success can clear.
    let clock = FakeClock()
    var pacer = RequestPacer(clock: clock)
    for _ in 0..<10 { pacer.halveCapacity() }
    clock.advance(RateConstants.spacingSeconds * 10)
    let granted = pacer.take()
    #expect(granted)
}

@Test func timeGoingBackwardsDoesNotMintTokens() {
    // A monotonic clock should not go backwards, but a fake, a suspended
    // process, or a future refactor to a wall clock could. Never trust it.
    let clock = FakeClock(1000)
    var pacer = RequestPacer(clock: clock)
    while pacer.take() {}

    let rewound = FakeClock(0)
    var rewoundPacer = RequestPacer(clock: rewound)
    while rewoundPacer.take() {}
    rewound.advance(-500)
    let mintedFromRewind = rewoundPacer.take()
    #expect(!mintedFromRewind)
}

@Test func theWaitReportedMatchesTheWaitEnforced() {
    let clock = FakeClock()
    var pacer = RequestPacer(clock: clock)
    while pacer.take() {}

    let wait = pacer.secondsUntilNextToken()
    #expect(wait > 0)
    clock.advance(wait)
    let granted = pacer.take()
    #expect(granted, "the pacer reported a wait of \(wait) and then refused")
}
