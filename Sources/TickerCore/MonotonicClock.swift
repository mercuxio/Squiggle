import Foundation

/// Time, injected.
///
/// A monotonic source specifically: a backoff deadline must not move when the
/// wall clock is adjusted, or an NTP correction mid-cooldown either resumes
/// polling early or strands the app for hours.
///
/// The one documented exception is the persisted cooldown (spec §4.3), which
/// is wall-clock because it must survive process termination. It enters
/// `TickerCore` as a `Double` parameter, never as a clock read.
public protocol MonotonicClock: Sendable {
    var nowSeconds: Double { get }
}

public struct SystemClock: MonotonicClock {
    public init() {}
    /// Time since boot; unaffected by wall-clock adjustments.
    public var nowSeconds: Double { ProcessInfo.processInfo.systemUptime }
}
