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
    #expect(store.settings.rows == 2)
    #expect(store.settings.refreshIntervalSeconds == RateConstants.defaultRefreshInterval)
    #expect(store.cooldownUntilEpoch == nil)
}

@Test func theDefaultsAreTheOnesTheSpecNames() {
    // Spec §5.1 "Two rows is the default", §5.3's table "Monochrome
    // (default)", §5.1's two motion modes with Scroll named default. These
    // were `1` and `"auto"` until ruling R118/R119 — and `"auto"` was never
    // a scheme the spec defined at all, only a word a doc comment invented.
    let s = Settings()
    #expect(s.rows == 2)
    #expect(s.colorScheme == "monochrome")
    #expect(s.motionMode == "scroll")
}

@Test func aFileWrittenBeforeMotionModeExistedStillLoads() throws {
    // R120: the key is new and `schemaVersion` deliberately did NOT move.
    // `lenient` is what makes that safe, and this is the test that says so.
    let url = tempURL()
    try write(#"{"schemaVersion":1,"symbols":["AAPL"],"settings":{"rows":1}}"#, to: url)

    let store = try FileWatchlistStore(url: url).load()
    #expect(store.settings.motionMode == "scroll")
    #expect(store.settings.rows == 1, "an explicit 1 must survive the new default")
}

@Test func anUnknownMotionModeIsCarriedThroughRatherThanRejected() throws {
    // Same contract as `colorScheme`: a file from a future version survives a
    // downgrade unchanged, and the consumer defaults when it maps.
    let url = tempURL()
    try write(#"{"schemaVersion":1,"settings":{"motionMode":"teleport"}}"#, to: url)

    let store = try FileWatchlistStore(url: url).load()
    #expect(store.settings.motionMode == "teleport")
}

@Test func aMotionModeOfTheWrongTypeCostsOnlyItself() throws {
    let url = tempURL()
    try write(#"{"schemaVersion":1,"symbols":["AAPL"],"settings":{"motionMode":7,"rows":1}}"#,
              to: url)

    let store = try FileWatchlistStore(url: url).load()
    #expect(store.settings.motionMode == Settings().motionMode)
    #expect(store.settings.rows == 1, "one bad field cost a good one")
    #expect(store.symbols.count == 1)
}

@Test func aRoundTripPreservesEverything() throws {
    let url = tempURL()
    let fileStore = FileWatchlistStore(url: url)
    let original = Store(
        schemaVersion: 1,
        symbols: [try #require(Symbol("AAPL")), try #require(Symbol("BTC-USD"))],
        settings: Settings(refreshIntervalSeconds: 300, rows: 2, scrollPointsPerSecond: 24,
                           colorScheme: "monochrome", motionMode: "step", maxVisibleWidth: 320),
        cooldownUntilEpoch: 1_757_000_000)

    try fileStore.save(original)
    #expect(try fileStore.load() == original)
}

@Test func theWrittenFileIsHumanReadableAndStablyOrdered() throws {
    // Spec §6: the support policy is "email me your squiggle.json", so it has
    // to be readable, and a stable key order keeps diffs meaningful.
    //
    // The old version checked only that `schemaVersion` preceded `symbols`,
    // which is true with or without `.sortedKeys` — the synthesized
    // `CodingKeys` happen to agree on that pair, so it pinned nothing. Without
    // the flag the order is a dictionary's, which is arbitrary and reseeded
    // every process, so nothing short of the *whole* sequence is safe to
    // assert. Both levels are checked: ten keys in a specific order is not
    // something an unsorted encoder produces twice.
    //
    // The cooldown has to be non-nil — `JSONEncoder` omits a nil optional
    // entirely, and it is the key whose sorted position is most obviously not
    // its declared one.
    let url = tempURL()
    try FileWatchlistStore(url: url).save(Store(
        schemaVersion: 1, symbols: [try #require(Symbol("MSFT"))],
        settings: Settings(), cooldownUntilEpoch: 1_757_000_000))

    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("\n"), "the file is not pretty-printed")

    // `.prettyPrinted` writes `"key" : value`, two spaces per level, so a line
    // holding `" : ` at indent 2 is a top-level key and at indent 4 a settings
    // key. Array elements have no `" : ` and drop out.
    var topLevel: [String] = []
    var settingsKeys: [String] = []
    for line in text.split(separator: "\n") {
        let body = line.drop(while: { $0 == " " })
        guard body.contains("\" : "), body.hasPrefix("\""),
              let close = body.dropFirst().firstIndex(of: "\"") else { continue }
        let key = String(body.dropFirst()[..<close])
        switch line.count - body.count {
        case 2: topLevel.append(key)
        case 4: settingsKeys.append(key)
        default: break
        }
    }

    #expect(topLevel == ["cooldownUntilEpoch", "schemaVersion", "settings", "symbols"],
            "top-level keys are not sorted: \(topLevel)")
    #expect(settingsKeys.count == 6, "did not find the settings keys: \(settingsKeys)")
    #expect(settingsKeys == settingsKeys.sorted(),
            "settings keys are not sorted: \(settingsKeys)")
}

@Test func aMissingKeyTakesItsDefaultInsteadOfFailingTheWholeLoad() throws {
    // decodeIfPresent everywhere: one unknown-to-this-version key must not
    // cost the user their entire watchlist.
    let url = tempURL()
    try write(#"{"schemaVersion":1,"symbols":["AAPL"]}"#, to: url)

    let store = try FileWatchlistStore(url: url).load()
    #expect(store.symbols.count == 1)
    #expect(store.settings.rows == 2)
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

    // do/catch rather than `#expect(throws: TickerError.self)`: that form does
    // not pin *which* case, so a gate that threw `.storeCorrupt` — quarantining
    // the newer file, the one outcome this rule exists to prevent — would still
    // satisfy it.
    var caught: TickerError?
    do {
        _ = try FileWatchlistStore(url: url).load()
        Issue.record("a newer schema loaded successfully")
    } catch let error as TickerError {
        caught = error
    }
    let error = try #require(caught)
    #expect(error == .storeSchemaUnsupported(version: 99))
    #expect(try String(contentsOf: url, encoding: .utf8) == json)
}

@Test func aStoreFileOverTheSizeBoundIsRefusedRatherThanRead() throws {
    // `Data(contentsOf:)` has no bound of its own, and neither does the
    // decoder behind it, so the size of the store was whatever the filesystem
    // was willing to hold. One measurement of the pathological case took 97.9
    // seconds and 2.6 GB of peak footprint to answer with the twenty symbols
    // the cap allows anyway.
    //
    // Padded with whitespace rather than with symbols: this is a test about
    // size, and a document that is valid JSON all the way through proves the
    // refusal happened before the read rather than as a decode failure that
    // would have quarantined it.
    let url = tempURL()
    let padding = String(repeating: " ", count: Int(FileWatchlistStore.maximumStoreBytes))
    let json = #"{"schemaVersion":1,"symbols":["AAPL"]}"# + padding
    try write(json, to: url)

    var caught: TickerError?
    do {
        let loaded = try FileWatchlistStore(url: url).load()
        Issue.record("an oversized store loaded as \(loaded.symbols.count) symbols")
    } catch let error as TickerError {
        caught = error
    } catch {
        Issue.record("load() threw a non-TickerError: \(error)")
    }
    #expect(try #require(caught) == .storeQuarantineFailed(at: url))

    // Not truncated and not quarantined: the file is exactly as long as it
    // was, and it is the only thing in its directory.
    #expect(try Data(contentsOf: url).count == json.utf8.count)
    let siblings = try FileManager.default.contentsOfDirectory(
        atPath: url.deletingLastPathComponent().path)
    #expect(siblings == ["squiggle.json"], "the refusal moved something: \(siblings)")
}

@Test func theWorstLegitimateStoreIsFarInsideTheSizeBound() throws {
    // The other side of the bound, and the thing that keeps the derivation in
    // `readIfPresent`'s comment honest: the largest document this program can
    // itself write — a full watchlist of maximum-length symbols, every setting
    // populated, a cooldown, pretty-printed and sorted — must load, and must
    // sit orders of magnitude below the bound rather than just under it. If
    // `maxWatchlistCount`, `Symbol`'s length cap or `Settings` ever grow enough
    // to threaten that, this fails while there is still room to think.
    // The 32 is `Symbol`'s own length cap, which nothing else in the suite
    // pins. Without this line the test would go on measuring a document the
    // app can no longer produce the moment that cap grew — and the size bound
    // derived from it, in `readIfPresent`'s comment, would be measuring
    // history.
    let longest = String(repeating: "A", count: 32)
    #expect(Symbol(longest) != nil)
    #expect(Symbol(longest + "A") == nil, "Symbol's length cap moved past 32")
    let symbols = try (0..<RateConstants.maxWatchlistCount).map { index in
        try #require(Symbol(String(longest.dropLast(2)) + String(format: "%02d", index)))
    }
    let fat = Store(schemaVersion: Store.currentSchemaVersion,
                    symbols: symbols,
                    settings: Settings(refreshIntervalSeconds: 900, rows: 2,
                                       scrollPointsPerSecond: 24,
                                       colorScheme: "monochrome", motionMode: "step",
                                       maxVisibleWidth: 320),
                    cooldownUntilEpoch: 1_757_000_000)

    let url = tempURL()
    let store = FileWatchlistStore(url: url)
    try store.save(fat)
    let written = try Data(contentsOf: url).count

    // Two assertions, because `readIfPresent`'s comment makes two claims and
    // the ratio alone would let the figure in it rot: 100x of a mebibyte is
    // ten kilobytes, so the original assertion passed at any size up to nine
    // times the one the comment quotes. The two-kilobyte ceiling is what
    // re-takes "1,080 bytes on this build"; the ratio is the property the
    // bound was chosen for.
    #expect(written < 2_048,
            "the worst legitimate store is \(written) bytes; readIfPresent() quotes 1,080")
    #expect(written * 100 < Int(FileWatchlistStore.maximumStoreBytes),
            "the worst legitimate store is \(written) bytes, within 100x of the bound")
    #expect(try store.load() == fat)
}

@Test func aSchemaVersionBelowOneIsRefusedAndLeftWhereItIs() throws {
    // The gate was bounded on one side only — `version <= 1` — so `0` and
    // `-5` were "old enough to be safe" and loaded under v1 rules, after
    // which `save()` would rewrite the file in v1's understanding. No
    // Squiggle ever wrote a version below 1, so such a file was written by
    // something else or damaged, which is the same reason the *upper* bound
    // exists, mirrored.
    //
    // `storeVersionUnreadable`, not `storeSchemaUnsupported(version:)`:
    // `doctor` renders the latter as "store schema -5 is not supported by this
    // version", which reads as a report about a newer Squiggle and names a
    // version that never existed.
    for version in [0, -5] {
        let url = tempURL()
        let json = "{\"schemaVersion\":\(version),\"symbols\":[\"AAPL\"]}"
        try write(json, to: url)

        var caught: TickerError?
        do {
            let loaded = try FileWatchlistStore(url: url).load()
            Issue.record("schemaVersion \(version) loaded as \(loaded.symbols.count) symbols")
        } catch let error as TickerError {
            caught = error
        } catch {
            Issue.record("load() threw a non-TickerError: \(error)")
        }
        #expect(try #require(caught) == .storeVersionUnreadable)

        // Refusing must never be destructive, and specifically must not
        // quarantine: the file is still there, byte for byte, and nothing has
        // been set aside next to it.
        #expect(try String(contentsOf: url, encoding: .utf8) == json)
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: url.deletingLastPathComponent().path)
        #expect(siblings == ["squiggle.json"], "the refusal moved something: \(siblings)")
    }
}

@Test func aStoreFileThatCannotBeReadIsAFaultRatherThanAFirstLaunch() throws {
    // `load()` and `save()` both read the file through `try? Data(contentsOf:)`,
    // which answers `nil` to two different questions: "there is no file" and
    // "there is a file and I cannot read it". Absent is a first launch, so an
    // unreadable store — chmod 000 after a migration, wrong ownership after a
    // restore from backup, an unreadable mount — loaded as an empty watchlist
    // with no error reported, and the next `save()` then read the same `nil`,
    // skipped the version gate that was supposed to protect the file, and
    // wrote the empty watchlist straight over it. Two steps, both silent, and
    // the user's symbols are gone.
    //
    // Both halves are asserted here because either alone leaves the data loss
    // intact: a `load()` that throws is no protection if `save()` still
    // overwrites, and vice versa.
    let url = tempURL()
    let json = #"{"schemaVersion":1,"symbols":["AAPL","BRK-B"]}"#
    try write(json, to: url)
    let before = try Data(contentsOf: url)

    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                               ofItemAtPath: url.path)
    }
    // The premise, not the assertion: if this process can still read the file
    // (running as root, say) the rest of the test proves nothing, and saying so
    // is better than passing vacuously.
    let readBack = try? Data(contentsOf: url)
    #expect(readBack == nil, "the file is still readable, so this test is vacuous")

    let store = FileWatchlistStore(url: url)

    var caughtOnLoad: TickerError?
    do {
        let loaded = try store.load()
        Issue.record("an unreadable store loaded as \(loaded.symbols.count) symbols")
    } catch let error as TickerError {
        caughtOnLoad = error
    } catch {
        Issue.record("load() threw a non-TickerError: \(error)")
    }
    #expect(try #require(caughtOnLoad) == .storeQuarantineFailed(at: url))

    var caughtOnSave: TickerError?
    do {
        try store.save(Store())
        Issue.record("save() wrote over a file it could not read")
    } catch let error as TickerError {
        caughtOnSave = error
    } catch {
        Issue.record("save() threw a non-TickerError: \(error)")
    }
    #expect(try #require(caughtOnSave) == .storeQuarantineFailed(at: url))

    // The point of the whole finding: byte for byte, the user's file.
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    #expect(try Data(contentsOf: url) == before)
}

@Test func anUnreadableSchemaVersionIsRefusedRatherThanQuarantined() throws {
    // `{"schemaVersion":"99"}` — a future Squiggle that quotes the version, or
    // any hand-edit that does. It used to miss the gate's `as? Int`, fail the
    // decoder's strict `Int`, and get the *newer* file renamed away. There is
    // no version to report, hence its own case rather than a `-1` sentinel
    // smuggled through `storeSchemaUnsupported`.
    let url = tempURL()
    let json = #"{"schemaVersion":"99","symbols":["AAPL"]}"#
    try write(json, to: url)

    var caught: TickerError?
    do {
        _ = try FileWatchlistStore(url: url).load()
        Issue.record("an unreadable schemaVersion loaded successfully")
    } catch let error as TickerError {
        caught = error
    }
    let error = try #require(caught)
    #expect(error == .storeVersionUnreadable)
    // The whole point: the file is still there, byte for byte.
    #expect(try String(contentsOf: url, encoding: .utf8) == json)
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func everySchemaVersionThisBuildCanHonourLoads() throws {
    // The gate refuses in both directions but only outside its range: a file
    // this version can understand is read normally.
    //
    // This used to stand on `{"schemaVersion":0}`, on the reading that 0 is
    // simply an older version. It is not: `Store.currentSchemaVersion` has
    // been 1 since the first release, so no Squiggle ever wrote a 0, and a
    // file claiming one was written by something else or damaged — which is
    // why the gate now has a lower bound too. Swept over the honourable range
    // instead, so it keeps meaning what it says when that range grows.
    for version in 1...Store.currentSchemaVersion {
        let url = tempURL()
        try write("{\"schemaVersion\":\(version),\"symbols\":[\"AAPL\",\"MSFT\"]}", to: url)
        let store = try FileWatchlistStore(url: url).load()
        #expect(store.symbols.map(\.raw) == ["AAPL", "MSFT"])
    }
}

@Test func savingOverANewerFileIsRefusedTooNotJustReadingIt() throws {
    // Load refusing is half a rule: nothing stopped the app from saving a
    // moment later and destroying the v99 file anyway.
    let url = tempURL()
    let json = #"{"schemaVersion":99,"symbols":["AAPL"]}"#
    try write(json, to: url)

    var caught: TickerError?
    do {
        try FileWatchlistStore(url: url).save(Store())
        Issue.record("saved over a newer file")
    } catch let error as TickerError {
        caught = error
    }
    let error = try #require(caught)
    #expect(error == .storeSchemaUnsupported(version: 99))
    #expect(try String(contentsOf: url, encoding: .utf8) == json)
}

@Test func savingOverAFileWithAnUnreadableVersionIsRefused() throws {
    let url = tempURL()
    let json = #"{"schemaVersion":"99","symbols":["AAPL"]}"#
    try write(json, to: url)

    var caught: TickerError?
    do {
        try FileWatchlistStore(url: url).save(Store())
        Issue.record("saved over a file whose version could not be read")
    } catch let error as TickerError {
        caught = error
    }
    let error = try #require(caught)
    #expect(error == .storeVersionUnreadable)
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

@Test func noNonsensicalSettingsValueSurvivesTheDecode() throws {
    // The file is user-editable by design. Every number read from it is
    // hostile input until it has been dealt with.
    //
    // F8, the rename: this was `nonsensicalSettingsValuesAreClampedOnDecode`,
    // and three of its four fields are indeed clamped — but the refresh
    // interval is not. `Settings.init(from:)` *rejects* an out-of-range
    // interval and falls back to the default, and its own comment argues at
    // length that clamping it would be wrong. A name covering both behaviours
    // and naming only one is how the wrong assertion below went unnoticed, so
    // the name now states the invariant and claims no mechanism.
    let url = tempURL()
    try write("""
    {"schemaVersion":1,"settings":{"refreshIntervalSeconds":-5,"rows":97,
     "scrollPointsPerSecond":100000,"maxVisibleWidth":-3}}
    """, to: url)

    let s = try FileWatchlistStore(url: url).load().settings
    // F8, the assertion: this read `>= RateConstants.spacingSeconds`, which is
    // 30 — half the app's own minimum offered interval of 60, and not a value
    // any code path here produces. An implementation that clamped a hostile
    // `-5` to 30 would have satisfied it and then driven the whole app at
    // twice its intended cadence. The actual post-condition is the default,
    // exactly, because rejection falls back rather than clamping.
    #expect(s.refreshIntervalSeconds == RateConstants.defaultRefreshInterval)
    #expect(s.rows == 1 || s.rows == 2)
    #expect(s.scrollPointsPerSecond > 0 && s.scrollPointsPerSecond <= 200)
    #expect(s.maxVisibleWidth > 0)
}

@Test func aWidthTooLargeToRepresentDegradesToTheDefaultRatherThanQuarantining() throws {
    // JSON has no NaN or Infinity literal, and `1e400` does not decode to
    // `.infinity` either: `JSONDecoder` throws
    // `numberIsNotRepresentableInSwift`. What this pins is therefore the
    // *leniency*, not the `isFinite` guard — without the per-field catch the
    // whole decode would throw and the file would be wrongly set aside.
    // (The old name, `aNonFiniteNumberInTheFileCannotReachTheApp`, claimed a
    // guard no JSON input can reach; the clamp would have satisfied it anyway.)
    let url = tempURL()
    try write(#"{"schemaVersion":1,"symbols":["AAPL"],"settings":{"maxVisibleWidth":1e400}}"#,
              to: url)
    let store = try FileWatchlistStore(url: url).load()
    #expect(store.settings.maxVisibleWidth == Settings().maxVisibleWidth)
    #expect(store.symbols.map(\.raw) == ["AAPL"], "a bad number cost the watchlist")
    #expect(FileManager.default.fileExists(atPath: url.path), "the file was set aside")
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

@Test func aCooldownTooLargeToRepresentIsDroppedRatherThanQuarantining() throws {
    // Same correction as the width test above: `1e400` throws inside the
    // decoder rather than arriving as `.infinity`, so what is verified here is
    // that the per-field catch turns it into "no cooldown" instead of into a
    // quarantine. The `isFinite` guard beside it is belt and braces.
    let url = tempURL()
    try write(#"{"schemaVersion":1,"symbols":["AAPL"],"cooldownUntilEpoch":1e400}"#, to: url)
    let store = try FileWatchlistStore(url: url).load()
    #expect(store.cooldownUntilEpoch == nil)
    #expect(store.symbols.map(\.raw) == ["AAPL"], "a bad number cost the watchlist")
    #expect(FileManager.default.fileExists(atPath: url.path), "the file was set aside")
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
    // new one. The guarantee itself is the filesystem's; what is observable
    // in-process is the *reference*: a rename installs a new inode, while a
    // plain write truncates the existing file in place and keeps it. Comparing
    // inodes across a save is what actually pins the flag — the sibling check
    // below does not, because a non-atomic write also leaves exactly one file
    // and no debris. (It is kept because a leftover sibling would still be a
    // real regression, just not this one.)
    let url = tempURL()
    let store = FileWatchlistStore(url: url)
    func inode() throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    try store.save(Store(schemaVersion: 1, symbols: [try #require(Symbol("AAPL"))],
                         settings: Settings(), cooldownUntilEpoch: nil))
    let before = try inode()
    try store.save(Store(schemaVersion: 1, symbols: [try #require(Symbol("MSFT"))],
                         settings: Settings(), cooldownUntilEpoch: nil))
    let after = try inode()
    #expect(before != after, "the save wrote in place; it was not atomic")

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

// MARK: - Set-aside, when it collides and when it cannot happen

@Test func aQuarantineNameThatIsAlreadyTakenGetsTheNextSuffix() throws {
    // `aSecondCorruptionDoesNotOverwriteTheFirstCasualty` passes on the
    // timestamp alone whenever the two loads straddle a second boundary, so it
    // does not pin the collision branch. Here the base name is claimed for
    // every second the load could plausibly land in, which forces the branch
    // whatever the clock says, and the `-2` suffix is asserted explicitly.
    let url = tempURL()
    try write("{ bad", to: url)
    let directory = url.deletingLastPathComponent()

    let formatter = ISO8601DateFormatter()
    for offset in 0...3 {
        let stamp = formatter.string(from: Date().addingTimeInterval(Double(offset)))
            .replacingOccurrences(of: ":", with: "-")
        try Data().write(to: directory.appendingPathComponent("squiggle.json.bad-\(stamp)"))
    }

    var caught: TickerError?
    do {
        _ = try FileWatchlistStore(url: url).load()
        Issue.record("a corrupt file loaded successfully")
    } catch let error as TickerError {
        caught = error
    }
    let error = try #require(caught)
    guard case .storeCorrupt(let quarantine) = error else {
        Issue.record("wrong error for a corrupt file: \(error)")
        return
    }
    #expect(quarantine.lastPathComponent.hasSuffix("-2"),
            "the collision branch did not run: \(quarantine.lastPathComponent)")
    #expect(FileManager.default.fileExists(atPath: quarantine.path))
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func theQuarantineNameSearchGivesUpRatherThanReportingSomeoneElsesFile() throws {
    // The bounded search has to end somewhere. What it must not do is fall
    // back to the *unsuffixed* name — that file belongs to an earlier
    // casualty, and returning it would tell the caller "your file is safely at
    // X" while X held somebody else's data and the current file had not moved.
    // Driven through `quarantineTarget` directly so the stamp is fixed and the
    // branch is reachable without racing a second boundary.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("squiggle-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stamp = "2026-09-08T12-00-00Z"

    try Data().write(to: directory.appendingPathComponent("squiggle.json.bad-\(stamp)"))
    for suffix in 2...1_000 {
        try Data().write(to: directory.appendingPathComponent("squiggle.json.bad-\(stamp)-\(suffix)"))
    }

    let exhausted = FileWatchlistStore.quarantineTarget(directory: directory,
                                                       base: "squiggle.json",
                                                       stamp: stamp)
    #expect(exhausted == nil)

    // And one collision short of exhaustion still resolves.
    try FileManager.default.removeItem(
        at: directory.appendingPathComponent("squiggle.json.bad-\(stamp)-1000"))
    let resolved = FileWatchlistStore.quarantineTarget(directory: directory,
                                                      base: "squiggle.json",
                                                      stamp: stamp)
    #expect(resolved?.lastPathComponent == "squiggle.json.bad-\(stamp)-1000")
}

@Test func aSetAsideThatCannotHappenIsReportedAsATickerErrorNotAsAnNSError() throws {
    // The one path where "the user gets a working app back" used to be false.
    // `throw .storeCorrupt(quarantinedAt: try setAside())` evaluated the rename
    // first, so a failed rename escaped as a raw `NSError`: the decode error
    // was lost, every `catch let e as TickerError` missed it, and the corrupt
    // file stayed put to fail again on every relaunch. A read-only directory
    // is not exotic — a full disk, a restored container with wrong ownership.
    let url = tempURL()
    try write("{ this is not json at all", to: url)
    let directory = url.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                          ofItemAtPath: directory.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: directory.path)
    }

    var caught: TickerError?
    do {
        _ = try FileWatchlistStore(url: url).load()
        Issue.record("a corrupt file loaded successfully")
    } catch let error as TickerError {
        caught = error
    } catch {
        Issue.record("load() threw a non-TickerError: \(error)")
    }
    let error = try #require(caught)
    #expect(error == .storeQuarantineFailed(at: url))
    // Still where it was: the caller has to be able to tell "safely aside"
    // from "still in the way".
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func exhaustingTheQuarantineNameSearchIsReportedAsQuarantineFailedNotAsCorrupt() throws {
    // `setAside()`'s own mapping from `quarantineTarget == nil` to
    // `storeQuarantineFailed(at: url)` (WatchlistStore.swift) was uncovered:
    // `theQuarantineNameSearchGivesUpRatherThanReportingSomeoneElsesFile`
    // exercises `quarantineTarget` in isolation, and
    // `aSetAsideThatCannotHappenIsReportedAsATickerErrorNotAsAnNSError` reaches
    // `setAside()`'s failure path only through a `moveItem` failure (chmod).
    // Neither drives the exhaustion branch through the real `setAside()`. A
    // mutation that reported `.storeCorrupt(quarantinedAt: url)` here instead
    // — naming the still-present original file as its own quarantine, the
    // same lie F2 was raised about — passed the whole suite.
    //
    // `setAside(stamp:)` takes its stamp as a parameter for the same reason
    // `quarantineTarget` does, so the exhaustion set only has to be built
    // once, at a fixed stamp, rather than raced across real seconds.
    let url = tempURL()
    try write("{ bad", to: url)
    let directory = url.deletingLastPathComponent()
    let stamp = "2026-09-08T13-00-00Z"

    try Data().write(to: directory.appendingPathComponent("squiggle.json.bad-\(stamp)"))
    for suffix in 2...1_000 {
        try Data().write(to: directory.appendingPathComponent("squiggle.json.bad-\(stamp)-\(suffix)"))
    }

    var caught: TickerError?
    do {
        _ = try FileWatchlistStore(url: url).setAside(stamp: stamp)
        Issue.record("setAside() succeeded despite an exhausted quarantine name search")
    } catch let error as TickerError {
        caught = error
    } catch {
        Issue.record("setAside() threw a non-TickerError: \(error)")
    }
    let error = try #require(caught)
    #expect(error == .storeQuarantineFailed(at: url))
    // Nothing was moved, so the original file has to still be exactly where
    // it was — the caller must be able to tell this from `storeCorrupt`.
    #expect(FileManager.default.fileExists(atPath: url.path))
}

// MARK: - Leniency: a typo in a cosmetic setting must not cost the watchlist

@Test func aWrongTypeInAnySettingCostsThatSettingAndNothingElse() throws {
    // The file is user-editable by design and the support policy is "email me
    // your JSON", so a hand-edit is an expected input, not a corrupt file.
    // `decodeIfPresent` returns nil only for an *absent* key; a present key of
    // the wrong type throws, and that throw used to reach the quarantine.
    // Each case carries a *good* setting alongside the bad one, and the whole
    // `Settings` value is compared. Without that witness the test could not
    // tell per-field leniency from the container-level leniency wrapping it:
    // a strict field throws out of `Settings.init(from:)`, `settings` as a
    // whole degrades to its default, and the watchlist survives anyway. The
    // witness is what says only the one field was lost.
    // `motionMode` is the witness: it is orthogonal to every field under test
    // here, which `colorScheme` is not, and unlike the `launchAtLogin` this
    // replaces (R145) it is a field the app actually reads.
    let witness = #""motionMode":"step""#
    let cases: [(String, String, Settings)] = [
        (#""refreshIntervalSeconds":"fast""#, witness, Settings(motionMode: "step")),
        (#""rows":"one""#, witness, Settings(motionMode: "step")),
        (#""scrollPointsPerSecond":"quick""#, witness, Settings(motionMode: "step")),
        (#""colorScheme":7"#, witness, Settings(motionMode: "step")),
        (#""maxVisibleWidth":"wide""#, witness, Settings(motionMode: "step")),
        // `motionMode` is the one under test here, so something else
        // witnesses for it.
        (#""motionMode":7"#, #""colorScheme":"classic""#, Settings(colorScheme: "classic")),
    ]

    for (bad, good, expected) in cases {
        let url = tempURL()
        try write("{\"schemaVersion\":1,\"symbols\":[\"AAPL\"],\"settings\":{\(bad),\(good)}}",
                  to: url)
        let store = try FileWatchlistStore(url: url).load()
        #expect(store.symbols.map(\.raw) == ["AAPL"], "\(bad) cost the watchlist")
        #expect(store.settings == expected, "\(bad) cost more than its own setting")
        #expect(FileManager.default.fileExists(atPath: url.path),
                "\(bad) got the file set aside")
    }
}

@Test func aWrongTypeInSchemaVersionSettingsOrCooldownAlsoKeepsTheWatchlist() throws {
    // The three container-level decodes. A scalar where `settings` should be
    // an object used to cost the whole file.
    let bodies = [
        #"{"schemaVersion":true,"symbols":["AAPL"]}"#,
        #"{"schemaVersion":1,"symbols":["AAPL"],"settings":5}"#,
        #"{"schemaVersion":1,"symbols":["AAPL"],"cooldownUntilEpoch":"soon"}"#,
    ]
    for body in bodies {
        let url = tempURL()
        try write(body, to: url)
        let store = try FileWatchlistStore(url: url).load()
        #expect(store.symbols.map(\.raw) == ["AAPL"], "lost the watchlist to: \(body)")
        #expect(store.settings == Settings())
        #expect(FileManager.default.fileExists(atPath: url.path), "set aside: \(body)")
    }
}

@Test func oneNonStringElementCostsOneEntryNotTheWholeWatchlist() throws {
    // The comment two lines above the symbols decode said exactly this and the
    // line under it did the opposite: `[String]` is all-or-nothing.
    let url = tempURL()
    try write(#"{"schemaVersion":1,"symbols":["AAPL",7,null,{"a":1},"MSFT"]}"#, to: url)
    let store = try FileWatchlistStore(url: url).load()
    #expect(store.symbols.map(\.raw) == ["AAPL", "MSFT"])
}

@Test func aScalarWhereTheSymbolsArrayShouldBeLosesOnlyTheSymbols() throws {
    let url = tempURL()
    // `rows` is deliberately the NON-default 1 (R118 moved the default to 2):
    // asserting the default here would pass even if the settings were dropped
    // entirely, which is the failure this test exists to catch.
    try write(#"{"schemaVersion":1,"symbols":"AAPL","settings":{"rows":1}}"#, to: url)
    let store = try FileWatchlistStore(url: url).load()
    #expect(store.symbols.isEmpty)
    #expect(store.settings.rows == 1, "a bad symbols array cost the settings too")
}

@Test func theCapStillHoldsWhenTheArrayIsDecodedElementWise() throws {
    // The one thing leniency must not relax. Element-wise decoding rebuilds the
    // array, so the cap has to survive that rewrite.
    let url = tempURL()
    let many = (1...50).map { $0 % 5 == 0 ? "\($0)" : "\"SYM\($0)\"" }.joined(separator: ",")
    try write("{\"schemaVersion\":1,\"symbols\":[\(many)]}", to: url)
    let store = try FileWatchlistStore(url: url).load()
    #expect(store.symbols.count == RateConstants.maxWatchlistCount)
    #expect(store.symbols.first?.raw == "SYM1")
}

// MARK: - Bounds

@Test func theUpperClampsOnWidthAndSpeedAreRealNotDecorative() throws {
    let url = tempURL()
    try write("""
    {"schemaVersion":1,"settings":{"maxVisibleWidth":99999,"scrollPointsPerSecond":99999}}
    """, to: url)
    let s = try FileWatchlistStore(url: url).load().settings
    #expect(s.maxVisibleWidth == 1200)
    #expect(s.scrollPointsPerSecond == 200)
}

@Test func theStoreAndTheRefreshPolicyAgreeOnAHandEditedInterval() throws {
    // A file saying 7200 used to be clamped to 3600 by the store, silently
    // replaced with the default by `RefreshPolicy.cycleInterval`, and re-saved
    // as 3600 — three different numbers for one setting, and the persisted one
    // a lie about what the app was actually running on. The store now admits
    // exactly what the policy accepts: `RateConstants.offeredRefreshIntervals`,
    // derived from the menu Settings offers rather than written down twice.
    let url = tempURL()
    try write(#"{"schemaVersion":1,"settings":{"refreshIntervalSeconds":7200}}"#, to: url)
    let stored = try FileWatchlistStore(url: url).load().settings.refreshIntervalSeconds
    #expect(stored == RateConstants.defaultRefreshInterval)

    let fromStore = RefreshPolicy.cycleInterval(userIntervalSeconds: stored,
                                                watchlistCount: 1,
                                                marketState: .regular,
                                                lowPowerMode: false)
    let fromFile = RefreshPolicy.cycleInterval(userIntervalSeconds: 7200,
                                               watchlistCount: 1,
                                               marketState: .regular,
                                               lowPowerMode: false)
    #expect(fromStore == fromFile,
            "the store persisted a cadence the policy does not run on")
}

@Test func anIntervalInsideTheOfferedMenuIsKeptExactly() throws {
    for choice in RateConstants.refreshIntervalChoices {
        let url = tempURL()
        try write("{\"schemaVersion\":1,\"settings\":{\"refreshIntervalSeconds\":\(choice)}}",
                  to: url)
        let stored = try FileWatchlistStore(url: url).load().settings.refreshIntervalSeconds
        #expect(stored == choice)
    }
}

// MARK: - The row split the user arranged

@Test func aRowSplitSurvivesARoundTrip() throws {
    // The whole point of persisting one integer: the arrangement the user
    // dragged in the dropdown is still theirs after a relaunch.
    let url = tempURL()
    let file = try FileWatchlistStore(url: url)
    try file.save(Store(symbols: [try #require(Symbol("AAPL")),
                                  try #require(Symbol("MSFT"))],
                        rowOneCount: 1))

    let loaded = try file.load()
    #expect(loaded.rowOneCount == 1)
    #expect(loaded.symbols.map(\.raw) == ["AAPL", "MSFT"])
}

@Test func anAbsentRowSplitStaysAbsentRatherThanBecomingZero() throws {
    // R120 again, with a sharper distinction than the other lenient fields
    // carry: `nil` means "nobody has arranged this, the balancer may choose",
    // while `0` means "the user put every symbol in row 2". Defaulting to zero
    // would freeze every never-arranged watchlist into one empty row.
    let url = tempURL()
    try write(#"{"schemaVersion":1,"symbols":["AAPL","MSFT"]}"#, to: url)

    let store = try FileWatchlistStore(url: url).load()
    #expect(store.rowOneCount == nil)
}

@Test func aRowSplitOfTheWrongTypeCostsOnlyItself() throws {
    let url = tempURL()
    try write(#"{"schemaVersion":1,"symbols":["AAPL"],"rowOneCount":"top"}"#, to: url)

    let store = try FileWatchlistStore(url: url).load()
    #expect(store.rowOneCount == nil)
    #expect(store.symbols.count == 1, "one bad key cost the user their watchlist")
}

@Test func aRowSplitIsClampedAgainstTheSymbolsThatSurvivedTheDecode() throws {
    // The case the clamp exists for: the boundary was written for three
    // symbols, one of them no longer parses, and a boundary of 3 against the
    // surviving two would send both to row 1 and leave row 2 empty — the
    // user's arrangement silently replaced by a different one.
    let url = tempURL()
    try write(#"{"schemaVersion":1,"symbols":["AAPL","","MSFT"],"rowOneCount":3}"#, to: url)

    let store = try FileWatchlistStore(url: url).load()
    #expect(store.symbols.map(\.raw) == ["AAPL", "MSFT"])
    #expect(store.rowOneCount == 2)
}

@Test func aNegativeRowSplitClampsToZero() throws {
    let url = tempURL()
    try write(#"{"schemaVersion":1,"symbols":["AAPL"],"rowOneCount":-5}"#, to: url)

    let store = try FileWatchlistStore(url: url).load()
    #expect(store.rowOneCount == 0)
}
