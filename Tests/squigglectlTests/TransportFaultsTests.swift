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
