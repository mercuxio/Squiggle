/// How a request went wrong, reduced to the six shapes Squiggle responds to
/// differently (spec §4.3). Classification, not uniform backoff: punishing a
/// flaky wifi connection with a thirty-minute cooldown leaves the ticker dead
/// long after the network returns.
public enum FailureKind: Equatable, Sendable {
    /// The path monitor says there is no network. Do not attempt, do not
    /// advance the ladder; resume on the path edge.
    case offline
    case rateLimited(retryAfterSeconds: Double?)
    /// 5xx or a timeout. Yahoo's problem, and usually brief.
    case server
    /// 401/403. The authentication assumption is broken; backoff cannot fix it.
    case unauthorized
    /// A 200 whose body is not what we agreed on. Its own circuit.
    case contractFault
    /// 404. This symbol is gone; the rest of the watchlist is fine.
    case deadSymbol

    public init(_ error: TickerError) {
        switch error {
        case .offline:
            self = .offline

        case .rateLimited(let retryAfter):
            self = .rateLimited(retryAfterSeconds: retryAfter)

        case .serverError, .transport:
            self = .server

        case .unauthorized:
            self = .unauthorized

        case .symbolNotFound:
            self = .deadSymbol

        // These four are the contract-fault group exactly as
        // `TickerError.isContractFault` defines it: a 200 whose body is not
        // what we agreed on. Its own one-hour circuit, separate from network
        // faults, because retrying a parse failure faster buys nothing.
        case .emptyBody, .notJSON, .noResult, .missingField,
             .wrongType, .nonFiniteNumber, .negativeValue:
            self = .contractFault

        // None of these three can arise from a fetch at all — `invalidSymbol`
        // is rejected before a request is ever built, and the store errors
        // are persistence faults, not network ones. They are classified here
        // only so this switch is total (no `default`, so the compiler is the
        // exhaustiveness checker). Mapped to `.server` — the mildest,
        // shortest, self-correcting rung — *deliberately*: routing an
        // unreachable case into the one-hour contract or unauthorized
        // circuit would turn a local bug into an hour of silence, which is
        // the worst outcome available for something that isn't even a live
        // failure mode.
        case .invalidSymbol, .storeSchemaUnsupported, .storeCorrupt:
            self = .server
        }
    }
}
