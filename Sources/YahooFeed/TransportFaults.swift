import Foundation
import TickerCore

/// Turns an arbitrary `Error` escaping a network call into a typed
/// `TransportFault`.
///
/// Here rather than in `TickerCore` because `URLError` is a networking type
/// and the core is forbidden them; here rather than in `squigglectl` because
/// the app needs the identical mapping in the identical catch-all, and a
/// second copy of it is a second thing to get wrong (ruling R125). It vends no
/// user-facing string — `Rendering` and `ErrorText` each word the result their
/// own way.
public enum TransportFaults {
    public static func classify(_ error: any Error) -> TransportFault {
        guard let urlError = error as? URLError else { return .unrecognized }
        return .urlSession(code: urlError.code.rawValue)
    }

    /// The `TickerError` a failed request becomes: `.offline` when the
    /// request provably never left the Mac, a transport fault otherwise.
    ///
    /// Right after login the Wi-Fi interface is up but DNS does not answer
    /// yet, and URLSession says `cannotFindHost`, not `notConnectedToInternet`.
    /// Only the second used to count as offline, so the first climbed the
    /// server ladder (30 seconds and up) and, five times over, opened a
    /// thirty-minute circuit meant to protect Yahoo from a fault that was on
    /// our side of the router.
    ///
    /// Deliberately narrow. A timeout, a refused connection or a dropped one
    /// may have reached Yahoo, or be Yahoo refusing, and `.offline` is
    /// charged nothing, so those keep the backoff that protects it.
    public static func tickerError(for error: any Error) -> TickerError {
        if let urlError = error as? URLError, neverLeftTheMac.contains(urlError.code) {
            return .offline
        }
        return .transport(classify(error))
    }

    private static let neverLeftTheMac: Set<URLError.Code> = [
        .notConnectedToInternet,
        .cannotFindHost,
        .dnsLookupFailed,
        .dataNotAllowed,
        .internationalRoamingOff,
        .callIsActive,
    ]
}
