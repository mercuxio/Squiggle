import Foundation

/// Every way this package can fail, as data.
///
/// No case carries a user-facing sentence. The payloads are diagnostics —
/// `squigglectl doctor` prints them, the app never does. The `path` strings on
/// the contract faults are JSON key paths; the persistence cases carry a
/// filesystem `URL` instead, which is an absolute path under the user's home
/// directory, so `doctor` must render it relative to the store's own directory
/// rather than verbatim. Wording lives in the caller.
public enum TickerError: Error, Equatable, Sendable {
    case invalidSymbol(String)

    // Transport and status, classified by how Squiggle must respond (spec §4.3).
    case offline
    case transport(String)
    case rateLimited(retryAfterSeconds: Double?)
    case serverError(status: Int)
    case unauthorized(status: Int)
    case symbolNotFound(Symbol)

    // Contract faults: a 200 whose body is not what we agreed on. Separate
    // from network faults because retrying a parse failure faster buys nothing.
    case emptyBody
    case notJSON
    case noResult
    case missingField(path: String)
    case wrongType(path: String, expected: String)
    case nonFiniteNumber(path: String)
    case negativeValue(path: String, value: Double)

    // Persistence.
    case storeSchemaUnsupported(version: Int)
    /// `schemaVersion` is present but cannot be read as an `Int` — a quoted
    /// `"99"`, a `99.5`, an object. Distinct from `storeSchemaUnsupported`
    /// because there is no version to report, and a sentinel like `-1` smuggled
    /// through that case would be printed by `doctor` as a real version.
    /// Refusing leaves the file untouched: an unreadable version might belong
    /// to a newer Squiggle, and rewriting it would discard whatever that
    /// version knew.
    case storeVersionUnreadable
    case storeCorrupt(quarantinedAt: URL)
    /// The file is unreadable *and* could not be moved out of the way — a
    /// read-only or full disk, wrong ownership after a restore. The payload is
    /// where the file still is, not where it went. The caller must be able to
    /// tell this from `storeCorrupt`: there the user's next launch starts
    /// clean, here the same file is waiting to fail again.
    case storeQuarantineFailed(at: URL)

    /// Whether this is a fault in the agreement rather than in the network.
    /// Drives the separate one-hour contract circuit (spec §4.3).
    public var isContractFault: Bool {
        switch self {
        case .emptyBody, .notJSON, .noResult, .missingField,
             .wrongType, .nonFiniteNumber, .negativeValue:
            return true

        // Everything else is not a contract fault: network/status cases
        // (their own circuits, spec §4.3), `invalidSymbol` (rejected before
        // a request is built), and the persistence cases (filesystem
        // faults, not a disagreement about a 200's body). Enumerated rather
        // than `default:`, so the compiler is the exhaustiveness checker.
        case .invalidSymbol, .offline, .transport, .rateLimited, .serverError,
             .unauthorized, .symbolNotFound, .storeSchemaUnsupported,
             .storeVersionUnreadable, .storeCorrupt, .storeQuarantineFailed:
            return false
        }
    }
}
