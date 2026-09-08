/// Randomness, injected, so jitter is reproducible under test.
public protocol Randomizing: Sendable {
    func double(in range: ClosedRange<Double>) -> Double
}

public struct SystemRandom: Randomizing {
    public init() {}
    public func double(in range: ClosedRange<Double>) -> Double {
        guard range.lowerBound < range.upperBound else { return range.lowerBound }
        return Double.random(in: range)
    }
}
