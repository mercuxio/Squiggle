import Foundation
import Testing
@testable import TickerCore

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("squiggle-tests-\(UUID().uuidString)")
        .appendingPathComponent("squiggle.json")
}

private func write(_ json: String, to url: URL) throws {
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try json.write(to: url, atomically: true, encoding: .utf8)
}

@Test func loadingAMissingFileYieldsTheDefaultsRatherThanAnError() throws {
    // First launch is not an error condition.
    let store = try FileWatchlistStore(url: tempURL()).load()
    #expect(store.symbols.isEmpty)
    #expect(store.settings.rows == 1)
    #expect(store.settings.refreshIntervalSeconds == RateConstants.defaultRefreshInterval)
    #expect(store.cooldownUntilEpoch == nil)
}

@Test func aRoundTripPreservesEverything() throws {
    let url = tempURL()
    let fileStore = FileWatchlistStore(url: url)
    let original = Store(
        schemaVersion: 1,
        symbols: [try #require(Symbol("AAPL")), try #require(Symbol("BTC-USD"))],
        settings: Settings(refreshIntervalSeconds: 300, rows: 2, scrollPointsPerSecond: 24,
                           colorScheme: "monochrome", maxVisibleWidth: 320, launchAtLogin: true),
        cooldownUntilEpoch: 1_757_000_000)

    try fileStore.save(original)
    #expect(try fileStore.load() == original)
}

@Test func theWrittenFileIsHumanReadableAndStablyOrdered() throws {
    // Spec §6: the support policy is "email me your squiggle.json", so it has
    // to be readable, and a stable key order keeps diffs meaningful.
    let url = tempURL()
    try FileWatchlistStore(url: url).save(Store(
        schemaVersion: 1, symbols: [try #require(Symbol("MSFT"))],
        settings: Settings(), cooldownUntilEpoch: nil))

    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("\n"))
    let schemaIndex = try #require(text.range(of: "schemaVersion"))
    let symbolsIndex = try #require(text.range(of: "symbols"))
    #expect(schemaIndex.lowerBound < symbolsIndex.lowerBound)
}

@Test func aMissingKeyTakesItsDefaultInsteadOfFailingTheWholeLoad() throws {
    // decodeIfPresent everywhere: one unknown-to-this-version key must not
    // cost the user their entire watchlist.
    let url = tempURL()
    try write(#"{"schemaVersion":1,"symbols":["AAPL"]}"#, to: url)

    let store = try FileWatchlistStore(url: url).load()
    #expect(store.symbols.count == 1)
    #expect(store.settings.rows == 1)
}

@Test func anUnknownKeyIsIgnoredRatherThanRejected() throws {
    let url = tempURL()
    try write(#"{"schemaVersion":1,"symbols":["AAPL"],"favouriteColour":"puce"}"#, to: url)
    #expect(try FileWatchlistStore(url: url).load().symbols.count == 1)
}

@Test func aNewerSchemaIsRefusedAndTheFileIsLeftUntouched() throws {
    // A future Squiggle's file must survive a downgrade. Silently rewriting
    // it with this version's understanding discards whatever that version knew.
    let url = tempURL()
    let json = #"{"schemaVersion":99,"symbols":["AAPL"]}"#
    try write(json, to: url)

    #expect(throws: TickerError.self) { try FileWatchlistStore(url: url).load() }
    #expect(try String(contentsOf: url, encoding: .utf8) == json)
}

@Test func aCorruptFileIsSetAsideAndReplacedWithDefaults() throws {
    let url = tempURL()
    try write("{ this is not json at all", to: url)
    let fileStore = FileWatchlistStore(url: url)

    var setAside: URL?
    do {
        _ = try fileStore.load()
        Issue.record("a corrupt file loaded successfully")
    } catch let error as TickerError {
        guard case .storeCorrupt(let at) = error else {
            Issue.record("wrong error for a corrupt file: \(error)")
            return
        }
        setAside = at
    }

    let saved = try #require(setAside)
    #expect(FileManager.default.fileExists(atPath: saved.path))
    #expect(saved.lastPathComponent.hasPrefix("squiggle.json.bad-"))
    // The original is renamed aside, so the next load starts clean.
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(try fileStore.load().symbols.isEmpty)
}

@Test func aSecondCorruptionDoesNotOverwriteTheFirstCasualty() throws {
    let url = tempURL()
    let fileStore = FileWatchlistStore(url: url)

    var saved: [URL] = []
    for body in ["{ bad one", "{ bad two"] {
        try write(body, to: url)
        do { _ = try fileStore.load() } catch let e as TickerError {
            if case .storeCorrupt(let at) = e { saved.append(at) }
        }
    }
    #expect(saved.count == 2)
    #expect(saved[0] != saved[1], "the second set-aside landed on top of the first")
}

@Test func theWatchlistIsCappedOnDecodeAndNotJustInTheUI() throws {
    // Spec §4.2: the cap is a budget input, so a hand-edited file must not be
    // able to raise it. Keep the first twenty rather than throwing — the user
    // keeps a working app.
    let url = tempURL()
    let many = (1...50).map { "\"SYM\($0)\"" }.joined(separator: ",")
    try write("{\"schemaVersion\":1,\"symbols\":[\(many)]}", to: url)

    let store = try FileWatchlistStore(url: url).load()
    #expect(store.symbols.count == RateConstants.maxWatchlistCount)
    #expect(store.symbols.first?.raw == "SYM1")
}

@Test func invalidSymbolsInTheFileAreDroppedNotFatal() throws {
    let url = tempURL()
    try write(#"{"schemaVersion":1,"symbols":["AAPL","","bad/symbol","MSFT"]}"#, to: url)
    let store = try FileWatchlistStore(url: url).load()
    #expect(store.symbols.map(\.raw) == ["AAPL", "MSFT"])
}

@Test func duplicateSymbolsAreCollapsedPreservingFirstAppearance() throws {
    let url = tempURL()
    try write(#"{"schemaVersion":1,"symbols":["AAPL","MSFT","AAPL"]}"#, to: url)
    #expect(try FileWatchlistStore(url: url).load().symbols.map(\.raw) == ["AAPL", "MSFT"])
}

@Test func symbolCaseIsPreservedExactlyAsTheUserEnteredIt() throws {
    // Spec: symbols are stored verbatim. Yahoo is case-sensitive for some
    // listings, and helpfully upper-casing them breaks those.
    let url = tempURL()
    try write(#"{"schemaVersion":1,"symbols":["BRK-B","btc-usd"]}"#, to: url)
    #expect(try FileWatchlistStore(url: url).load().symbols.map(\.raw) == ["BRK-B", "btc-usd"])
}

@Test func nonsensicalSettingsValuesAreClampedOnDecode() throws {
    // The file is user-editable by design. Every number read from it is
    // hostile input until clamped.
    let url = tempURL()
    try write("""
    {"schemaVersion":1,"settings":{"refreshIntervalSeconds":-5,"rows":97,
     "scrollPointsPerSecond":100000,"maxVisibleWidth":-3}}
    """, to: url)

    let s = try FileWatchlistStore(url: url).load().settings
    #expect(s.refreshIntervalSeconds >= RateConstants.spacingSeconds)
    #expect(s.rows == 1 || s.rows == 2)
    #expect(s.scrollPointsPerSecond > 0 && s.scrollPointsPerSecond <= 200)
    #expect(s.maxVisibleWidth > 0)
}

@Test func aNonFiniteNumberInTheFileCannotReachTheApp() throws {
    // JSON has no NaN literal, but a huge exponent decodes to infinity, and
    // an infinite width becomes a status item that cannot lay out.
    let url = tempURL()
    try write(#"{"schemaVersion":1,"settings":{"maxVisibleWidth":1e400}}"#, to: url)
    let s = try FileWatchlistStore(url: url).load().settings
    #expect(s.maxVisibleWidth.isFinite)
}

@Test func aPersistedCooldownIsReadBackUnchanged() throws {
    // Converting the epoch into "seconds remaining" is the caller's job
    // (BackoffLadder.adoptPersistedCooldown, Task 9); the store's job is
    // only to hand back exactly what it was given.
    let url = tempURL()
    let deadline: Double = 1_757_000_600
    try write("{\"schemaVersion\":1,\"cooldownUntilEpoch\":\(deadline)}", to: url)

    let store = try FileWatchlistStore(url: url).load()
    #expect(try #require(store.cooldownUntilEpoch) == deadline)
}

@Test func anInfiniteCooldownInTheFileIsDiscarded() throws {
    let url = tempURL()
    try write(#"{"schemaVersion":1,"cooldownUntilEpoch":1e400}"#, to: url)
    #expect(try FileWatchlistStore(url: url).load().cooldownUntilEpoch == nil)
}

@Test func noQuoteDataIsEverWrittenToDisk() throws {
    // Spec §6, and a hard rule: the support policy is "email me your JSON".
    // A price is stale in seconds and worthless in a bug report; a credential
    // would be a leak. Neither goes in the file.
    let url = tempURL()
    try FileWatchlistStore(url: url).save(Store(
        schemaVersion: 1, symbols: [try #require(Symbol("AAPL"))],
        settings: Settings(), cooldownUntilEpoch: nil))

    let text = try String(contentsOf: url, encoding: .utf8).lowercased()
    for forbidden in ["price", "quote", "previousclose", "cookie", "crumb", "token", "session"] {
        #expect(!text.contains(forbidden), "the store file contains \"\(forbidden)\"")
    }
}

@Test func repeatedSavesAlwaysLeaveALoadableFile() throws {
    // Not directly observable in-process; assert the property we can observe —
    // that a save over an existing valid file always leaves a valid file.
    let url = tempURL()
    let fileStore = FileWatchlistStore(url: url)
    for i in 1...25 {
        try fileStore.save(Store(schemaVersion: 1,
                                 symbols: [try #require(Symbol("SYM\(i)"))],
                                 settings: Settings(), cooldownUntilEpoch: nil))
        #expect(try fileStore.load().symbols.count == 1)
    }
}

@Test func anAtomicSaveLeavesNoDebrisBesideTheFile() throws {
    // `options: .atomic` writes to a sibling and renames. The rename is what
    // makes an interrupted write leave the *old* file rather than half of the
    // new one, and a leftover sibling would mean it silently stopped doing
    // that. This is the observable half of atomicity; the guarantee itself
    // is the filesystem's.
    let url = tempURL()
    let store = FileWatchlistStore(url: url)
    try store.save(Store(schemaVersion: 1, symbols: [try #require(Symbol("AAPL"))],
                         settings: Settings(), cooldownUntilEpoch: nil))
    let siblings = try FileManager.default
        .contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
    #expect(siblings == [url.lastPathComponent],
            "save left debris: \(siblings)")
}

@Test func savingCreatesTheContainingDirectoryOnFirstRun() throws {
    let url = tempURL()   // its parent does not exist
    try FileWatchlistStore(url: url).save(Store(
        schemaVersion: 1, symbols: [], settings: Settings(), cooldownUntilEpoch: nil))
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func theDefaultLocationIsUnderApplicationSupport() {
    let url = FileWatchlistStore.defaultURL(applicationName: "Squiggle")
    #expect(url.path.contains("Application Support/Squiggle"))
    #expect(url.lastPathComponent == "squiggle.json")
}
