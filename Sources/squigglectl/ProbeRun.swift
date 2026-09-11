import Foundation
import TickerCore
import YahooFeed

/// `squigglectl probe <symbol> [--record NAME]` — one request, then either a
/// diff against the recorded shape or a fresh capture named `NAME.json`.
///
/// **Baseline.** The comparison is always against
/// `Tests/Fixtures/yahoo-<TickerCore.payloadObservationDate>/regular-session.json`
/// — "the fixture recorded on 2026-09-08" the brief for this task keeps
/// calling it, singular — rather than against a fixture keyed to whichever
/// symbol was requested. That file is the one every decoder in this package
/// was written against (`YahooQuoteDecodingTests`, `MutationTests`) and the
/// one `ShapeDigestTests.theRecordedFixtureStillMatchesItself` pins, so it is
/// the shape a drift report should be measured from. `<symbol>` only picks
/// which live endpoint to hit; `v8/finance/chart` sends the same envelope
/// shape for every instrument, so a probe of a different symbol still means
/// something against this baseline.
///
/// **Testability without the network.** `client` is `any QuoteFetching` — the
/// same seam `Sources/TickerCore/Fetching.swift` exists for — so tests can
/// hand this a fake that returns fixture bytes and never open a socket
/// (R76: Yahoo has rate-limited this project six times in one day). The
/// filesystem locations and the clock are injected for the same reason: a
/// test exercising `--record` points `fixturesRootURL` and `captureLogURL`
/// at a scratch directory rather than this repository's own `Tests/Fixtures`
/// or `docs/fixture-capture-log.md`, which are never touched by anything but
/// a human running the real command.
struct ProbeRun {
    let client: any QuoteFetching
    let symbol: Symbol
    /// `nil` diffs against the recorded shape; a name captures a fresh
    /// fixture at `yahoo-<today>/<name>.json`. `Command.parse` has already
    /// restricted this to lowercase letters, digits and hyphens by the time
    /// it reaches here.
    let record: String?
    let recordedFixtureURL: URL
    let fixturesRootURL: URL
    let captureLogURL: URL
    let now: () -> Date

    init(client: any QuoteFetching = YahooClient(),
         symbol: Symbol,
         record: String?,
         recordedFixtureURL: URL = ProbeRun.defaultRecordedFixtureURL,
         fixturesRootURL: URL = URL(fileURLWithPath: "Tests/Fixtures"),
         captureLogURL: URL = URL(fileURLWithPath: "docs/fixture-capture-log.md"),
         now: @escaping () -> Date = Date.init) {
        self.client = client
        self.symbol = symbol
        self.record = record
        self.recordedFixtureURL = recordedFixtureURL
        self.fixturesRootURL = fixturesRootURL
        self.captureLogURL = captureLogURL
        self.now = now
    }

    static let defaultRecordedFixtureURL = URL(fileURLWithPath:
        "Tests/Fixtures/yahoo-\(TickerCore.payloadObservationDate)/regular-session.json")

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter
    }()

    func run() async -> Int32 {
        let data: Data
        do {
            data = try await client.fetch(symbol)
        } catch let error as TickerError {
            FileHandle.standardError.write(Data((Rendering.diagnosis(error) + "\n").utf8))
            return 1
        } catch {
            // `QuoteFetching` implementations promise to throw only
            // `TickerError` (see that protocol's own doc comment), but
            // nothing in the language enforces that across an `async throws`
            // boundary — same reasoning as `WatchLoop`'s catch-all.
            let wrapped = TickerError.transport(Rendering.transportFault(for: error))
            FileHandle.standardError.write(Data((Rendering.diagnosis(wrapped) + "\n").utf8))
            return 1
        }

        if let name = record {
            return recordFixture(data, name: name)
        }
        return diffAgainstRecorded(data)
    }

    private func diffAgainstRecorded(_ liveData: Data) -> Int32 {
        let live: ShapeDigest
        do {
            live = try ShapeDigest.digest(of: liveData)
        } catch let error as TickerError {
            FileHandle.standardError.write(Data((Rendering.diagnosis(error) + "\n").utf8))
            return 1
        } catch {
            let wrapped = TickerError.transport(Rendering.transportFault(for: error))
            FileHandle.standardError.write(Data((Rendering.diagnosis(wrapped) + "\n").utf8))
            return 1
        }

        let recorded: ShapeDigest
        do {
            let recordedData = try Data(contentsOf: recordedFixtureURL)
            recorded = try ShapeDigest.digest(of: recordedData)
        } catch {
            // Never the underlying error verbatim — it may carry this
            // machine's absolute path to the fixture (R44).
            FileHandle.standardError.write(Data(
                "could not read the recorded fixture\n".utf8))
            return 1
        }

        let changes = ShapeDigest.diff(recorded: recorded, live: live)
        let breaking = changes.filter(\.breaksSquiggle)
        let informational = changes.filter { !$0.breaksSquiggle }
        print(Rendering.probeReport(breaking: breaking, informational: informational))
        return breaking.isEmpty ? 0 : 2
    }

    private func recordFixture(_ data: Data, name: String) -> Int32 {
        // The three write locations below default to CWD-relative literals, so
        // `--record` run from anywhere but the repository root used to *create*
        // a `Tests/Fixtures/yahoo-<date>/` tree wherever the operator happened
        // to be standing and write a live Yahoo response — prices included —
        // into it, plus a capture log beside it, reporting the same success
        // line either way. Task 19 asks a human to run this during a live
        // trading day, so that is not a hypothetical path.
        //
        // The corpus is already on disk and already recognisable, so the
        // refusal is keyed on finding it rather than on guessing where it
        // should be: no absolute path is derived from the binary's location,
        // because a wrong guess writes prices somewhere else just as silently.
        // The message names no absolute path either (R44) — it says what is
        // wrong, not where this process happens to be.
        var rootIsDirectory: ObjCBool = false
        let rootExists = FileManager.default.fileExists(atPath: fixturesRootURL.path,
                                                        isDirectory: &rootIsDirectory)
        guard rootExists, rootIsDirectory.boolValue else {
            FileHandle.standardError.write(Data(
                (Rendering.probeRefusesMissingFixturesRoot() + "\n").utf8))
            return 1
        }

        let today = Self.dateFormatter.string(from: now())
        let directoryName = "yahoo-\(today)"
        let directory = fixturesRootURL.appendingPathComponent(directoryName, isDirectory: true)
        let relativeDirectory = "Tests/Fixtures/\(directoryName)"

        let fileName = "\(name).json"
        let fileURL = directory.appendingPathComponent(fileName)
        let relativeFile = "\(relativeDirectory)/\(fileName)"

        // A captured fixture is evidence of what the API returned on a
        // particular day; replacing it destroys the only record of the
        // shape the tests were written against. The refusal is keyed on
        // that one file, not on the day's directory — the directory holds
        // one fixture per scenario, and a second scenario captured the same
        // day is a different file, not a collision.
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            FileHandle.standardError.write(Data(
                (Rendering.probeRefusesExistingFixtureFile(relativeFile) + "\n").utf8))
            return 1
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data(
                "could not write the fixture to \(relativeFile)\n".utf8))
            return 1
        }

        // The trading calendar is a bonus fact this same body happens to
        // carry (see `YahooClient.snapshot(for:)`'s own note) — absent here
        // just means the log line says so, not that the capture failed.
        let marketStateText = (try? YahooQuoteDecoding.tradingPeriod(from: data))
            .map { $0.state(atEpoch: now().timeIntervalSince1970) }
            .map(Rendering.describe)
            ?? "unknown"

        let logLine = Rendering.captureLogLine(
            date: today, symbol: symbol.raw, record: name, marketState: marketStateText,
            fileWritten: relativeFile)
        do {
            try append(logLine, to: captureLogURL)
        } catch {
            FileHandle.standardError.write(Data(
                "wrote \(relativeFile) but could not update the capture log\n".utf8))
            return 1
        }

        print(Rendering.probeRecordedFixture(relativeFile))
        return 0
    }

    private func append(_ line: String, to url: URL) throws {
        let text = line + "\n"
        guard FileManager.default.fileExists(atPath: url.path) else {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
    }
}
