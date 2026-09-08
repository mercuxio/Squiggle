import Foundation

/// Every way this package can fail, as data.
///
/// No case carries a user-facing sentence. The `path` strings are JSON key
/// paths for diagnostics — `squigglectl doctor` prints them, the app never
/// does. Wording lives in the caller.
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
    case storeCorrupt(quarantinedAt: URL)

    /// Whether this is a fault in the agreement rather than in the network.
    /// Drives the separate one-hour contract circuit (spec §4.3).
    public var isContractFault: Bool {
        switch self {
        case .emptyBody, .notJSON, .noResult, .missingField,
             .wrongType, .nonFiniteNumber, .negativeValue:
            return true
        default:
            return false
        }
    }
}
