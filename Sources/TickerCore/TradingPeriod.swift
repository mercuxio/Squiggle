/// Where the market is right now.
public enum MarketState: Equatable, Sendable {
    case pre
    case regular
    case post
    case closed
}

/// The session windows for one instrument, straight from the payload.
///
/// **No local exchange calendar ships with Squiggle** (spec §4.2). Holidays,
/// half-days, both DST regimes, per-symbol venues and crypto's 24-hour session
/// all fall out of this for free. A hand-maintained holiday table would be
/// silently wrong every Thanksgiving.
///
/// Epochs are wall-clock seconds and enter as parameters. The core still reads
/// no clock: `state(atEpoch:)` is a pure function of its argument.
public struct TradingPeriod: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        public let startEpoch: Double
        public let endEpoch: Double

        public init(startEpoch: Double, endEpoch: Double) {
            self.startEpoch = startEpoch
            self.endEpoch = endEpoch
        }

        /// Half-open: `[start, end)`. The boundary belongs to exactly one
        /// window, so a poll landing on the opening bell has one answer.
        /// A zero-length or inverted window contains nothing — Yahoo emits
        /// `start == end` on some holidays.
        public func contains(_ epoch: Double) -> Bool {
            startEpoch < endEpoch && epoch >= startEpoch && epoch < endEpoch
        }
    }

    public let pre: Window?
    public let regular: Window?
    public let post: Window?

    public init(pre: Window?, regular: Window?, post: Window?) {
        self.pre = pre
        self.regular = regular
        self.post = post
    }

    /// Regular is checked first so that an overlap — which Yahoo does emit
    /// for some venues — resolves to the busier session rather than to
    /// whichever happens to be tested first.
    public func state(atEpoch epoch: Double) -> MarketState {
        if regular?.contains(epoch) ?? false { return .regular }
        if pre?.contains(epoch) ?? false { return .pre }
        if post?.contains(epoch) ?? false { return .post }
        return .closed
    }

    /// When to set the single wake while the market is closed: the earliest
    /// session start still ahead of `epoch`, across **all three** sessions,
    /// or nil if this payload does not describe a future open.
    ///
    /// Deliberately not "the next regular open". Pre-market runs 04:00-09:30,
    /// and a wake set to 09:30 means a Mac left on overnight sleeps straight
    /// through it: `.pre` would then be reachable only for a user who happened
    /// to already be awake and polling when the session opened, which the
    /// closed-market branch has just made impossible. Spec §4.2's cost table
    /// has an explicit Extended column; polling extended hours is the design.
    ///
    /// A malformed window (`startEpoch >= endEpoch`, which Yahoo emits on some
    /// holidays) contributes nothing, exactly as it contains nothing.
    public func nextSessionOpenEpoch(after epoch: Double) -> Double? {
        [pre, regular, post]
            .compactMap { $0 }
            .filter { $0.startEpoch < $0.endEpoch && $0.startEpoch > epoch }
            .map(\.startEpoch)
            .min()
    }
}
