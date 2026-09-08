/// Which way the number went. No `NSColor` here — the core does not know what
/// a colour is, and colour is redundant reinforcement anyway (spec §5.3).
public enum Direction: Equatable, Sendable {
    case up
    case down
    case flat
    /// No usable previous close: newly listed, or a zero that would otherwise
    /// divide into infinity. Never coloured, never given an arrow.
    case unknown

    /// The glyph that carries direction in every colour scheme.
    /// A glyph, not a colour, is the primary carrier — WCAG 1.4.1.
    public var glyph: String {
        switch self {
        case .up: return "\u{25B2}"     // ▲
        case .down: return "\u{25BC}"   // ▼
        case .flat: return "\u{2013}"   // –
        case .unknown: return ""
        }
    }
}

/// One instrument, as of one moment. Never written to disk (spec §6).
public struct Quote: Equatable, Sendable {
    public let symbol: Symbol
    /// Yahoo's own display name. Data from the network, not app copy.
    public let shortName: String?
    public let price: Double
    public let previousClose: Double?
    public let change: Double?
    public let changePercent: Double?
    public let currency: String?
    public let direction: Direction
    /// Wall-clock epoch seconds, from the payload — not from a local clock.
    public let asOfEpoch: Double?

    public init(
        symbol: Symbol,
        shortName: String?,
        price: Double,
        previousClose: Double?,
        currency: String?,
        asOfEpoch: Double?
    ) {
        self.symbol = symbol
        self.shortName = shortName
        self.price = price
        self.previousClose = previousClose
        self.currency = currency
        self.asOfEpoch = asOfEpoch

        // A previous close of zero is not a previous close. Guarding here
        // rather than at each use site means no caller can reintroduce the
        // division.
        if let base = previousClose, base != 0 {
            let delta = price - base
            self.change = delta
            self.changePercent = delta / base * 100
            self.direction = delta > 0 ? .up : (delta < 0 ? .down : .flat)
        } else {
            self.change = nil
            self.changePercent = nil
            self.direction = .unknown
        }
    }
}
