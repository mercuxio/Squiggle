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
    /// A 200 whose *shape* is not what we agreed on. Its own circuit, whose
    /// threshold is 1, because a shape change fails every symbol identically.
    case contractFault
    /// This symbol has no data: a 404, or a 200 whose `result` is null or
    /// empty. The rest of the watchlist is fine.
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

        // A 404 and a 200 with `result: null` are the same fact reported two
        // ways — *this symbol has no data* — and they must cost the same.
        //
        // `noResult` used to sit in the contract group below, and the
        // asymmetry was not survivable: the contract circuit's threshold is 1
        // with a one-hour cooldown, so one delisted ticker in a watchlist of
        // twenty stopped every symbol for an hour, while the same ticker
        // returning 404 cost only itself. `YahooQuoteDecoding` throws
        // `noResult` from exactly one place — a chart request for one symbol
        // whose `chart.result` came back null or empty — so it is never a
        // statement about the endpoint, only about the symbol in the URL.
        case .symbolNotFound, .noResult:
            self = .deadSymbol

        // The contract-fault group, and it is now deliberately *narrower* than
        // `TickerError.isContractFault`, which still counts `noResult`. That
        // divergence is the point rather than an oversight: `isContractFault`
        // answers "is this a disagreement about a 200's body", which `noResult`
        // still is, while this enum answers "who does this implicate" — and a
        // null result implicates one symbol where a missing field or a wrong
        // type implicates the endpoint. Only the second question may open a
        // threshold-1 circuit. `ShapeDigest` and `probe` detect the first kind,
        // which is what the threshold of 1 was chosen for.
        case .emptyBody, .notJSON, .missingField,
             .wrongType, .nonFiniteNumber, .negativeValue:
            self = .contractFault

        // None of these can arise from a fetch at all — `invalidSymbol`
        // is rejected before a request is ever built, and the store errors
        // are persistence faults, not network ones. They are classified here
        // only so this switch is total (no `default`, so the compiler is the
        // exhaustiveness checker). Mapped to `.server` — the mildest,
        // shortest, self-correcting rung — *deliberately*: routing an
        // unreachable case into the one-hour contract or unauthorized
        // circuit would turn a local bug into an hour of silence, which is
        // the worst outcome available for something that isn't even a live
        // failure mode.
        case .invalidSymbol, .storeSchemaUnsupported, .storeVersionUnreadable,
             .storeCorrupt, .storeQuarantineFailed:
            self = .server
        }
    }
}
