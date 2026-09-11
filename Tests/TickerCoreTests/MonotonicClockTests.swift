import Foundation
import Testing
@testable import TickerCore

// R152. The whole no-burst-on-wake property rests on this clock being the
// one that stops while the machine is suspended. A unit test cannot sleep
// a Mac, so it pins the two things it can: that this is uptime, and that
// it is emphatically not the wall clock.

// the system clock reads uptime, not the wall clock
@Test func theClockIsNotTheWallClock() {
    let reading = SystemClock().nowSeconds
    #expect(abs(reading - ProcessInfo.processInfo.systemUptime) < 1)
    // Unix epoch seconds are past 1.7 × 10⁹. Uptime reaching that would
    // be 54 years without a reboot.
    #expect(reading < 1_000_000_000)
}

// the system clock moves forward
@Test func theClockAdvances() {
    let first = SystemClock().nowSeconds
    var spin = 0.0
    for i in 1...200_000 { spin += Double(i) }
    let second = SystemClock().nowSeconds
    #expect(second >= first)
    #expect(spin > 0)   // keeps the loop from being optimised away
}
