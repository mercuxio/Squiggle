import Foundation
import Testing
import TickerCore
import YahooFeed
@testable import squigglectl

// R125: both executables need this mapping in the same catch-all, and it
// produces no user-facing string, so it belongs in the target that owns every
// URL type in the package. `Rendering.transportFault` now forwards to it.
@Test func aURLErrorBecomesItsOwnCodeRatherThanTheCatchAll() {
    let offline = URLError(.notConnectedToInternet)
    #expect(TransportFaults.classify(offline) == .urlSession(code: URLError.Code.notConnectedToInternet.rawValue))
}

@Test func somethingThatIsNotAURLErrorIsUnrecognised() {
    struct Nonsense: Error {}
    #expect(TransportFaults.classify(Nonsense()) == .unrecognized)
}

@Test func renderingStillAnswersForTheCallersThatUseIt() {
    // The forwarder is not ceremony: `WatchLoop` and `ProbeRun` both call
    // `Rendering.transportFault`, and a move that broke them would be a
    // refactor that cost the CLI to serve the app.
    let timedOut = URLError(.timedOut)
    #expect(Rendering.transportFault(for: timedOut) == TransportFaults.classify(timedOut))
}

// At login the network is half up: the interface exists but DNS does not
// answer yet. Those failures never left the Mac, so they are `.offline` —
// retried in seconds and charged nothing — not a transport fault that climbs
// the server ladder and, five times over, opens a thirty-minute circuit.
@Test(arguments: [URLError.Code.notConnectedToInternet, .cannotFindHost, .dnsLookupFailed,
                  .dataNotAllowed, .internationalRoamingOff, .callIsActive])
func aRequestThatNeverLeftTheMacIsOffline(_ code: URLError.Code) {
    #expect(TransportFaults.tickerError(for: URLError(code)) == .offline)
}

// These may have reached Yahoo, or Yahoo may be the one refusing, so they
// keep the backoff that protects it.
@Test(arguments: [URLError.Code.timedOut, .cannotConnectToHost, .networkConnectionLost,
                  .secureConnectionFailed])
func aRequestThatMayHaveReachedYahooIsATransportFault(_ code: URLError.Code) {
    #expect(TransportFaults.tickerError(for: URLError(code)) == .transport(.urlSession(code: code.rawValue)))
}

@Test func somethingThatIsNotAURLErrorIsStillATransportFault() {
    struct Nonsense: Error {}
    #expect(TransportFaults.tickerError(for: Nonsense()) == .transport(.unrecognized))
}
