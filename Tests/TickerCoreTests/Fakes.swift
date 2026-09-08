import Foundation
@testable import TickerCore

/// Time under the test's control. A class so that advancing it is visible to
/// every holder without threading a value back.
final class FakeClock: MonotonicClock, @unchecked Sendable {
    private(set) var nowSeconds: Double
    init(_ start: Double = 0) { nowSeconds = start }
    func advance(_ seconds: Double) { nowSeconds += seconds }
    func advance(minutes: Double) { advance(minutes * 60) }
    func advance(hours: Double) { advance(hours * 3600) }
}

/// Deterministic jitter. Defaults to the top of the range, which is the
/// worst case for a backoff cap and the best case for catching an overflow.
final class FakeRandom: Randomizing, @unchecked Sendable {
    /// 0 picks the low bound, 1 the high bound.
    var position: Double
    private(set) var calls: [ClosedRange<Double>] = []

    init(position: Double = 1.0) { self.position = position }

    func double(in range: ClosedRange<Double>) -> Double {
        calls.append(range)
        return range.lowerBound + (range.upperBound - range.lowerBound) * position
    }
}
