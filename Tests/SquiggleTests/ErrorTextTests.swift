import Foundation
import Testing
import TickerCore
@testable import Squiggle

// The three lines spec §7 writes out longhand. They are quoted in the spec, so
// they are assertions, not suggestions.
@Test func theHealthyFooterNamesTheAgeAndTheNextAttempt() {
    let line = ErrorText.footer(lastSuccessAgoSeconds: 14 * 60,
                                lastError: nil,
                                retryInSeconds: 4 * 60)
    #expect(line == "Updated 14 min ago — retrying in 4 min")
}

@Test func rateLimitingIsNamedAsYahoosDoingBecauseThatChangesWhatTheUserDoes() {
    let line = ErrorText.footer(lastSuccessAgoSeconds: 20 * 60,
                                lastError: .rateLimited(retryAfterSeconds: nil),
                                retryInSeconds: 12 * 60)
    #expect(line == "Yahoo is rate-limiting Squiggle. Retrying in 12 min.")
}

@Test func offlineIsDistinguishedFromYahooFailing() {
    // Spec §7: "Offline and Yahoo-is-failing are distinguished because they
    // imply different user actions." One is fixed by the user, one by waiting.
    let offline = ErrorText.footer(lastSuccessAgoSeconds: 60,
                                   lastError: .offline, retryInSeconds: 60)
    let server = ErrorText.footer(lastSuccessAgoSeconds: 60,
                                  lastError: .serverError(status: 503), retryInSeconds: 60)
    #expect(offline == "No network connection.")
    #expect(offline != server)
}

@Test func aFreshSuccessSaysJustNowRatherThanZeroMinutesAgo() {
    #expect(ErrorText.footer(lastSuccessAgoSeconds: 3, lastError: nil, retryInSeconds: nil)
            == "Updated just now")
}

@Test func havingNeverSucceededIsNotTheSameAsHavingSucceededLongAgo() {
    #expect(ErrorText.footer(lastSuccessAgoSeconds: nil, lastError: nil, retryInSeconds: nil)
            == "Updating…")
}

@Test func aSubMinuteRetryIsNotRoundedDownToZero() {
    let line = ErrorText.footer(lastSuccessAgoSeconds: 90, lastError: nil, retryInSeconds: 20)
    #expect(line == "Updated 2 min ago — retrying in under a minute")
}

@Test func aFaultThatWaitingCannotFixDoesNotPromiseARetry() {
    // The ladder does keep retrying an unauthorized response, but saying so
    // tells the user to wait for something that is not coming: spec §3.1 makes
    // a crumb demand the end of Squiggle's premise, not a blip.
    let line = ErrorText.footer(lastSuccessAgoSeconds: 3600,
                                lastError: .unauthorized(status: 401),
                                retryInSeconds: 600)
    #expect(!line.contains("Retrying"))
    #expect(!line.contains("retrying"))
}

@Test func everyErrorCaseHasWordsAndNoneOfThemLeakSwift() throws {
    // The sweep. `TickerError` is not `CaseIterable` — several cases carry
    // payloads — so the list is written out, and the `switch` inside
    // `ErrorText` is what actually guarantees exhaustiveness. This catches the
    // other half: a case that compiles but renders `Optional(...)`.
    let cases: [TickerError] = [
        .invalidSymbol("puce"), .offline, .transport(.nonHTTPResponse),
        .rateLimited(retryAfterSeconds: 30), .serverError(status: 500),
        .unauthorized(status: 401), .symbolNotFound(try #require(Symbol("ZZZZ"))), .emptyBody,
        .notJSON, .noResult, .missingField(path: "chart.result"),
        .wrongType(path: "meta.regularMarketPrice", expected: "Double"),
        .nonFiniteNumber(path: "meta.regularMarketPrice"),
        .negativeValue(path: "meta.regularMarketPrice", value: -1),
        .storeSchemaUnsupported(version: 9), .storeVersionUnreadable,
        .storeCorrupt(quarantinedAt: URL(fileURLWithPath: "/tmp/squiggle.json.bad")),
        .storeQuarantineFailed(at: URL(fileURLWithPath: "/tmp/squiggle.json")),
    ]

    for error in cases {
        let line = ErrorText.footer(lastSuccessAgoSeconds: 60,
                                    lastError: error, retryInSeconds: 120)
        #expect(!line.isEmpty, "\(error) has no words")
        #expect(!line.contains("Optional("), "\(error) leaked a Swift value")
        #expect(!line.contains("TickerError"), "\(error) leaked its own type name")
        // R44's sibling: the app's footer is read over someone's shoulder in a
        // menu bar. A quarantine path in it is both unreadable and a leak of
        // the user's home directory name.
        #expect(!line.contains("/"), "\(error) leaked a filesystem path")
        let last = try #require(line.last)
        #expect(".!…".contains(last), "\(error) is not a sentence: \(line)")
    }
}
