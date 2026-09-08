import Foundation
import Testing
import TickerCore
@testable import squigglectl

/// Same fixture corpus `TickerCoreTests` reads, located the same way: walk up
/// from this file to `Tests/`, then down into `Fixtures/yahoo-2026-09-08`.
/// Read-only everywhere below — R76 and the "`Tests/Fixtures/` is never
/// modified" ruling for this task both forbid writing there, even in a test.
private enum Fixture {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // squigglectlTests
        .deletingLastPathComponent()      // Tests
        .appendingPathComponent("Fixtures/yahoo-2026-09-08")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }
}

/// A `QuoteFetching` double that returns fixed bytes or throws a fixed
/// error. This is the seam that keeps every test below off the network
/// entirely (R76: Yahoo has rate-limited this project six times in one day;
/// make no network requests of any kind for this task).
private struct FakeFetcher: QuoteFetching {
    let result: Result<Data, any Error>
    func fetch(_ symbol: Symbol) async throws -> Data { try result.get() }
}

private func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("squigglectl-probe-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Mirrors `ProbeRun`'s own (private) date formatter exactly, so a test can
/// predict the directory name `--record` will use for a given `now`.
private let expectedDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.calendar = Calendar(identifier: .gregorian)
    return formatter
}()

// MARK: - default (diff) mode

@Test func identicalLiveBodyAgainstItsOwnRecordingReportsNoChangeAndExitsZero() async throws {
    let data = try Fixture.data("regular-session.json")
    let run = ProbeRun(client: FakeFetcher(result: .success(data)),
                       symbol: try #require(Symbol("AAPL")), record: nil,
                       recordedFixtureURL: Fixture.directory.appendingPathComponent("regular-session.json"))
    #expect(await run.run() == 0)
}

/// `regularMarketPrice` has no fallback (Task 5), so losing it entirely is
/// exactly the case `ShapeChange.breaksSquiggle` exists to catch.
@Test func aLiveBodyMissingARequiredFieldExitsTwo() async throws {
    let liveJSON = #"{"chart":{"result":[{"meta":{"currency":"USD"}}]}}"#
    let run = ProbeRun(client: FakeFetcher(result: .success(Data(liveJSON.utf8))),
                       symbol: try #require(Symbol("AAPL")), record: nil,
                       recordedFixtureURL: Fixture.directory.appendingPathComponent("regular-session.json"))
    #expect(await run.run() == 2)
}

/// A field Squiggle has never read appearing for the first time is
/// informational, not breaking — `ShapeChange.added` is never `breaksSquiggle`
/// — so the exit code must stay 0 even though the shape did move.
@Test func aLiveBodyWithOnlyAHarmlessAddedFieldExitsZero() async throws {
    let recordedData = try Fixture.data("regular-session.json")
    var json = try #require(try JSONSerialization.jsonObject(with: recordedData) as? [String: Any])
    var chart = try #require(json["chart"] as? [String: Any])
    var results = try #require(chart["result"] as? [[String: Any]])
    var meta = try #require(results[0]["meta"] as? [String: Any])
    meta["gmtoffset"] = -14_400
    results[0]["meta"] = meta
    chart["result"] = results
    json["chart"] = chart
    let liveData = try JSONSerialization.data(withJSONObject: json)

    let run = ProbeRun(client: FakeFetcher(result: .success(liveData)),
                       symbol: try #require(Symbol("AAPL")), record: nil,
                       recordedFixtureURL: Fixture.directory.appendingPathComponent("regular-session.json"))
    #expect(await run.run() == 0)
}

@Test func aTickerErrorFromTheClientExitsOneWithoutAttemptingADiff() async throws {
    let run = ProbeRun(client: FakeFetcher(result: .failure(TickerError.rateLimited(retryAfterSeconds: nil))),
                       symbol: try #require(Symbol("AAPL")), record: nil)
    #expect(await run.run() == 1)
}

/// `QuoteFetching`'s doc comment promises only `TickerError`, but nothing in
/// the language enforces that across an `async throws` boundary — same
/// reasoning `ProbeRun.run()`'s catch-all carries. A double that breaks the
/// contract must still exit cleanly rather than crash the process.
@Test func aNonTickerErrorFromTheClientIsWrappedRatherThanCrashing() async throws {
    struct Boom: Error {}
    let run = ProbeRun(client: FakeFetcher(result: .failure(Boom())),
                       symbol: try #require(Symbol("AAPL")), record: nil)
    #expect(await run.run() == 1)
}

/// The 429 body is HTML, not JSON — `ShapeDigest.digest(of:)` throws
/// `.notJSON` rather than reporting an empty digest as "every field
/// vanished". `ProbeRun` must turn that into exit 1, not a crash.
@Test func aNonJSONLiveBodyExitsOneRatherThanCrashing() async throws {
    let run = ProbeRun(client: FakeFetcher(result: .success(Data("<html>429</html>".utf8))),
                       symbol: try #require(Symbol("AAPL")), record: nil,
                       recordedFixtureURL: Fixture.directory.appendingPathComponent("regular-session.json"))
    #expect(await run.run() == 1)
}

@Test func aMissingRecordedFixtureExitsOneRatherThanCrashing() async throws {
    let missing = tempDirectory().appendingPathComponent("does-not-exist.json")
    let run = ProbeRun(client: FakeFetcher(result: .success(Data("{}".utf8))),
                       symbol: try #require(Symbol("AAPL")), record: nil,
                       recordedFixtureURL: missing)
    #expect(await run.run() == 1)
}

// MARK: - --record mode

@Test func recordWritesTheBodyVerbatimToTheNamedFixtureUnderTodaysDirectory() async throws {
    let root = tempDirectory()
    let logURL = root.appendingPathComponent("capture-log.md")
    let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    let body = Data(#"{"chart":{"result":[{"meta":{"regularMarketPrice":1}}]}}"#.utf8)

    let run = ProbeRun(client: FakeFetcher(result: .success(body)),
                       symbol: try #require(Symbol("AAPL")), record: "regular-session",
                       fixturesRootURL: root, captureLogURL: logURL, now: { fixedNow })
    #expect(await run.run() == 0)

    let dateText = expectedDateFormatter.string(from: fixedNow)
    let writtenURL = root.appendingPathComponent("yahoo-\(dateText)")
        .appendingPathComponent("regular-session.json")
    let written = try Data(contentsOf: writtenURL)
    #expect(written == body)
}

/// `meta.currentTradingPeriod` is absent from this body, so
/// `YahooQuoteDecoding.tradingPeriod(from:)` throws and the market state the
/// log line records must fall back to "unknown" rather than crashing the
/// capture that already succeeded.
@Test func recordLogsUnknownMarketStateWhenTheBodyCarriesNoTradingCalendar() async throws {
    let root = tempDirectory()
    let logURL = root.appendingPathComponent("capture-log.md")
    let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    let body = Data(#"{"chart":{"result":[{"meta":{"regularMarketPrice":1}}]}}"#.utf8)

    let run = ProbeRun(client: FakeFetcher(result: .success(body)),
                       symbol: try #require(Symbol("AAPL")), record: "regular-session",
                       fixturesRootURL: root, captureLogURL: logURL, now: { fixedNow })
    #expect(await run.run() == 0)

    let logText = try String(contentsOf: logURL, encoding: .utf8)
    #expect(logText.contains("unknown"))
}

/// The companion case: a body that does carry a trading calendar records the
/// actual session `now` falls in, using the same `TradingPeriod.state(atEpoch:)`
/// / `Rendering.describe(_:)` machinery `doctor` already relies on.
@Test func recordLogsTheActualMarketStateWhenTheBodyCarriesATradingCalendar() async throws {
    let root = tempDirectory()
    let logURL = root.appendingPathComponent("capture-log.md")
    let regularStart = 1_800_000_000.0
    let regularEnd = regularStart + 23_400
    let fixedNow = Date(timeIntervalSince1970: regularStart + 100)
    let body = Data("""
        {"chart":{"result":[{"meta":{
            "regularMarketPrice":1,
            "currentTradingPeriod":{"regular":{"start":\(Int(regularStart)),"end":\(Int(regularEnd))}}
        }}]}}
        """.utf8)

    let run = ProbeRun(client: FakeFetcher(result: .success(body)),
                       symbol: try #require(Symbol("AAPL")), record: "regular-session",
                       fixturesRootURL: root, captureLogURL: logURL, now: { fixedNow })
    #expect(await run.run() == 0)

    let logText = try String(contentsOf: logURL, encoding: .utf8)
    #expect(logText.contains(Rendering.describe(.regular)))
    #expect(!logText.contains("unknown"))
}

/// The exact line `probeRecordedFixture` and `captureLogLine` promise, tied
/// together here rather than only unit-tested in `RenderingTests` — this is
/// what confirms `ProbeRun` actually calls them with a repository-relative
/// path and not `writtenURL.path` (which would leak this machine's temp
/// directory, an R44 violation the type system does nothing to prevent).
@Test func theCaptureLogLineNamesARepositoryRelativePathNotAnAbsoluteOne() async throws {
    let root = tempDirectory()
    let logURL = root.appendingPathComponent("capture-log.md")
    let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    let body = Data(#"{"chart":{"result":[{"meta":{"regularMarketPrice":1}}]}}"#.utf8)

    let run = ProbeRun(client: FakeFetcher(result: .success(body)),
                       symbol: try #require(Symbol("AAPL")), record: "regular-session",
                       fixturesRootURL: root, captureLogURL: logURL, now: { fixedNow })
    #expect(await run.run() == 0)

    let dateText = expectedDateFormatter.string(from: fixedNow)
    let logText = try String(contentsOf: logURL, encoding: .utf8)
    #expect(logText.contains("Tests/Fixtures/yahoo-\(dateText)/regular-session.json"))
    // Never this machine's actual temp path.
    #expect(!logText.contains(root.path))
}

@Test func recordAppendsRatherThanOverwritesAnExistingLog() async throws {
    let root = tempDirectory()
    let logURL = root.appendingPathComponent("capture-log.md")
    try "existing line\n".write(to: logURL, atomically: true, encoding: .utf8)
    let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    let body = Data(#"{"chart":{"result":[{"meta":{"regularMarketPrice":1}}]}}"#.utf8)

    let run = ProbeRun(client: FakeFetcher(result: .success(body)),
                       symbol: try #require(Symbol("AAPL")), record: "regular-session",
                       fixturesRootURL: root, captureLogURL: logURL, now: { fixedNow })
    #expect(await run.run() == 0)

    let logText = try String(contentsOf: logURL, encoding: .utf8)
    #expect(logText.hasPrefix("existing line\n"))
    #expect(logText.contains("AAPL"))
}

/// F-1 (fix round 1), measurement 1: the refusal is keyed on the fixture
/// file, not on the day's directory. `docs/fixture-capture-log.md` requires
/// two captures on one Saturday (`weekend` and
/// `crypto-while-equities-closed`, both AAPL and BTC-USD respectively) — two
/// different scenario names on the same simulated day must both succeed,
/// and both files must actually be on disk afterwards.
@Test func twoDifferentlyNamedRecordsOnTheSameDayBothSucceed() async throws {
    let root = tempDirectory()
    let logURL = root.appendingPathComponent("capture-log.md")
    let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    let dateText = expectedDateFormatter.string(from: fixedNow)
    let directory = root.appendingPathComponent("yahoo-\(dateText)")

    let first = ProbeRun(client: FakeFetcher(result: .success(Data(#"{"first":true}"#.utf8))),
                         symbol: try #require(Symbol("AAPL")), record: "weekend",
                         fixturesRootURL: root, captureLogURL: logURL, now: { fixedNow })
    let firstExitCode = await first.run()
    #expect(firstExitCode == 0)

    let second = ProbeRun(
        client: FakeFetcher(result: .success(Data(#"{"second":true}"#.utf8))),
        symbol: try #require(Symbol("BTC-USD")), record: "crypto-while-equities-closed",
        fixturesRootURL: root, captureLogURL: logURL, now: { fixedNow })
    let secondExitCode = await second.run()
    #expect(secondExitCode == 0)

    #expect(FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("weekend.json").path))
    #expect(FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("crypto-while-equities-closed.json").path))
}

/// F-1, measurement 2: the same name twice on the same simulated day is
/// still refused, and the first capture's bytes are untouched — asserted on
/// the bytes themselves, not just the exit code, so a refusal that quietly
/// truncated or re-wrote the file would still fail this.
@Test func recordingTheSameNameTwiceOnTheSameDayRefusesTheSecondAndLeavesTheFirstUntouched() async throws {
    let root = tempDirectory()
    let logURL = root.appendingPathComponent("capture-log.md")
    let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    let dateText = expectedDateFormatter.string(from: fixedNow)
    let fixtureURL = root.appendingPathComponent("yahoo-\(dateText)").appendingPathComponent("weekend.json")

    let firstBody = Data(#"{"chart":{"result":[{"meta":{"regularMarketPrice":1}}]}}"#.utf8)
    let first = ProbeRun(client: FakeFetcher(result: .success(firstBody)),
                         symbol: try #require(Symbol("AAPL")), record: "weekend",
                         fixturesRootURL: root, captureLogURL: logURL, now: { fixedNow })
    #expect(await first.run() == 0)

    let second = ProbeRun(client: FakeFetcher(result: .success(Data(#"{"different":true}"#.utf8))),
                          symbol: try #require(Symbol("AAPL")), record: "weekend",
                          fixturesRootURL: root, captureLogURL: logURL, now: { fixedNow })
    let secondExitCode = await second.run()
    #expect(secondExitCode == 1)

    let stillThere = try Data(contentsOf: fixtureURL)
    #expect(stillThere == firstBody)
}

/// F-1, measurement 3, end to end: `Command.parse` rejects a record name
/// carrying a path separator or `..` — `CommandTests.swift` covers the
/// parse error itself. `Command.parse` never touches the filesystem (see its
/// own doc comment), so there is no write for this test to check against; the
/// parse-error assertions below are the whole test.
@Test func aRecordNameWithAPathSeparatorIsRejectedBeforeAnythingIsWritten() throws {
    for badName in ["../escape", "a/b", ".."] {
        do {
            _ = try Command.parse(["probe", "AAPL", "--record", badName])
            Issue.record("expected a ParseError for record name \(badName)")
        } catch is ParseError {
            // Expected.
        }
    }
}

/// F-1, measurement 4: `--record` given with nothing after it is a parse
/// error, using the same `takeValue(_:)` helper `--interval` and `--limit`
/// already rely on for this — not a flag that silently does nothing.
@Test func recordWithNoValueFollowingItIsAParseError() {
    #expect(throws: ParseError.self) { try Command.parse(["probe", "AAPL", "--record"]) }
}

