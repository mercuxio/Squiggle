import Foundation

/// The network seam. The core parses; it never fetches.
///
/// Bytes in, so that every implementation — URLSession, a fixture reader, a
/// fake that returns a truncated body — is interchangeable in tests.
public protocol QuoteFetching: Sendable {
    func fetch(_ symbol: Symbol) async throws -> Data
}

public protocol SymbolSearching: Sendable {
    func search(_ query: String) async throws -> Data
}
