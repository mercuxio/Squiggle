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
}
