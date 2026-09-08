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
    var drained = 0
    while pacer.take() {
        drained += 1
        if drained >= 100 { break }
    }
    #expect(drained < 100, "take() never returned false")

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
    var initialDrain = 0
    while pacer.take() {
        initialDrain += 1
        if initialDrain >= 100 { break }
    }
    #expect(initialDrain < 100, "take() never returned false")

    clock.advance(hours: 168)
    var granted = 0
    while pacer.take() {
        granted += 1
        if granted >= 100 { break }
    }
    #expect(granted < 100, "take() never returned false")
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
    while pacer.take() {
        granted += 1
        if granted >= 100 { break }
    }
    #expect(granted < 100, "take() never returned false")
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
    var drained = 0
    while pacer.take() {
        drained += 1
        if drained >= 100 { break }
    }
    #expect(drained < 100, "take() never returned false")

    let rewound = FakeClock(0)
    var rewoundPacer = RequestPacer(clock: rewound)
    var rewoundDrained = 0
    while rewoundPacer.take() {
        rewoundDrained += 1
        if rewoundDrained >= 100 { break }
    }
    #expect(rewoundDrained < 100, "take() never returned false")
    rewound.advance(-500)
    let mintedFromRewind = rewoundPacer.take()
    #expect(!mintedFromRewind)
}

@Test func anOscillatingClockDoesNotMintTokens() {
    // A clock that jumps backward and then returns to (or through) a point
    // it has already visited must not be credited twice for a span of time
    // that never actually elapsed. Drain the bucket, then oscillate several
    // times and confirm no tokens appeared.
    let clock = FakeClock(0)
    var pacer = RequestPacer(clock: clock)
    var drained = 0
    while pacer.take() {
        drained += 1
        if drained >= 100 { break }
    }
    #expect(drained < 100, "take() never returned false")
    #expect(pacer.availableTokens == 0)

    for _ in 0..<5 {
        clock.advance(-100)
        _ = pacer.secondsUntilNextToken() // forces a refill() without spending a token
        clock.advance(100)
        _ = pacer.secondsUntilNextToken()
    }

    #expect(
        pacer.availableTokens == 0,
        "oscillating the clock back to its starting point minted \(pacer.availableTokens) tokens"
    )

    // A genuine forward advance past the high-water mark must still credit
    // correctly — exactly one token for one spacing interval, not more.
    clock.advance(RateConstants.spacingSeconds)
    let earned = pacer.take()
    #expect(earned, "a real spacing interval should have earned a token")
    let extra = pacer.take()
    #expect(!extra, "the oscillation should not have earned a bonus token")
}

@Test func theWaitReportedMatchesTheWaitEnforced() {
    let clock = FakeClock()
    var pacer = RequestPacer(clock: clock)
    var drained = 0
    while pacer.take() {
        drained += 1
        if drained >= 100 { break }
    }
    #expect(drained < 100, "take() never returned false")

    let wait = pacer.secondsUntilNextToken()
    #expect(wait > 0)
    clock.advance(wait)
    let granted = pacer.take()
    #expect(granted, "the pacer reported a wait of \(wait) and then refused")
}
