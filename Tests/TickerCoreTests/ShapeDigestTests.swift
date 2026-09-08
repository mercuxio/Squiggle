import Foundation
import Testing
@testable import TickerCore

private func digest(_ json: String) throws -> ShapeDigest {
    try ShapeDigest.digest(of: Data(json.utf8))
}

@Test func nestedObjectsBecomeDottedPaths() throws {
    let d = try digest(#"{"chart":{"result":{"meta":{"symbol":"AAPL"}}}}"#)
    #expect(d.paths["chart.result.meta.symbol"] == .string)
}

@Test func arrayIndicesCollapseToASinglePlaceholder() throws {
    // A day of one-minute candles is 390 entries. Recording each index would
    // make every diff a wall of noise and every fixture refresh a rewrite.
    let d = try digest(#"{"a":[{"x":1},{"x":2},{"x":3}]}"#)
    #expect(d.paths["a[].x"] == .number)
    #expect(d.paths.keys.filter { $0.contains("a[") }.count == 1)
}

@Test func everyJsonTypeIsDistinguished() throws {
    let d = try digest("""
    {"n":1,"s":"x","b":true,"z":null,"o":{"k":1},"a":[1]}
    """)
    #expect(d.paths["n"] == .number)
    #expect(d.paths["s"] == .string)
    #expect(d.paths["b"] == .bool)
    #expect(d.paths["z"] == .null)
    #expect(d.paths["o"] == .object)
    #expect(d.paths["a"] == .array)
}

@Test func aBooleanIsNotReportedAsANumber() throws {
    // JSONSerialization bridges true/false to NSNumber on Darwin, so a naive
    // type check reports every bool as a number and the diff misses the one
    // change most likely to break a decoder.
    let d = try digest(#"{"b":true,"n":1}"#)
    #expect(d.paths["b"] == .bool)
    #expect(d.paths["n"] == .number)
}

@Test func anIdenticalResponseProducesNoChanges() throws {
    let d = try digest(#"{"a":{"b":1}}"#)
    #expect(ShapeDigest.diff(recorded: d, live: d).isEmpty)
}

@Test func aFieldThatDisappearedIsReportedAsMissing() throws {
    let before = try digest(#"{"a":1,"b":2}"#)
    let after = try digest(#"{"a":1}"#)
    #expect(ShapeDigest.diff(recorded: before, live: after)
        == [.missing(path: "b", wasType: .number)])
}

@Test func aNewFieldIsReportedAsAddedRatherThanIgnored() throws {
    // A new field is usually harmless, but it is also how Yahoo signals a
    // migration before removing the old one. Worth seeing.
    let before = try digest(#"{"a":1}"#)
    let after = try digest(#"{"a":1,"b":2}"#)
    #expect(ShapeDigest.diff(recorded: before, live: after)
        == [.added(path: "b", type: .number)])
}

@Test func aTypeChangeIsReportedAsOneChangeAndNotAsAPairOfEdits() throws {
    let before = try digest(#"{"a":1}"#)
    let after = try digest(#"{"a":"1"}"#)
    #expect(ShapeDigest.diff(recorded: before, live: after)
        == [.typeChanged(path: "a", from: .number, to: .string)])
}

@Test func changesAreOrderedStablySoTheOutputIsDiffable() throws {
    let before = try digest(#"{"z":1,"a":1,"m":1}"#)
    let after = try digest(#"{"q":1}"#)
    let changes = ShapeDigest.diff(recorded: before, live: after)
    #expect(changes.map(\.path) == changes.map(\.path).sorted())
}

@Test func aChangeToAFieldSquiggleReadsIsFlaggedAsBreaking() throws {
    let path = "chart.result[].meta.regularMarketPrice"
    #expect(ShapeDigest.readPaths.contains(path),
            "the read-path list has drifted from the decoder")
    #expect(ShapeChange.typeChanged(path: path, from: .number, to: .object).breaksSquiggle)
    #expect(ShapeChange.missing(path: path, wasType: .number).breaksSquiggle)
}

/// `["chart","result","0","meta","shortName"]` → `"chart.result[].meta.shortName"`.
private func dotted(_ components: [String]) -> String {
    components.map { $0 == "0" ? "[]" : $0 }
        .joined(separator: ".")
        .replacingOccurrences(of: ".[].", with: "[].")
}

@Test func theTwoListsOfFieldsWeDependOnDescribeTheSameSet() {
    // Task 6's mutation suite and this digest carry two spellings of one fact:
    // which fields Squiggle reads. Adding a field to one and forgetting the
    // other leaves a real dependency either untested or unwatched, and nothing
    // else in the suite would notice.
    let period = "chart.result[].meta.currentTradingPeriod"

    // The mutation suite stops at the trading-period object, because mutating
    // a container already covers every child; the digest names each boundary.
    // Collapse the digest's six down to the one they share.
    let watched = Set(ShapeDigest.readPaths.map {
        $0.hasPrefix(period + ".") ? period : $0
    })
    // Entries shorter than five components are the containers on the way down.
    let mutated = Set(readFields.filter { $0.count > 4 }.map(dotted))

    #expect(watched == mutated,
            "readFields and readPaths have drifted: \(watched.symmetricDifference(mutated))")
}

@Test func everyRequiredPathIsAlsoAWatchedPath() {
    for path in ShapeDigest.requiredPaths {
        #expect(ShapeDigest.readPaths.contains(path),
                "\(path) is required but nothing watches it")
    }
}

@Test func aFieldWithAFallbackGoingMissingIsNotBreaking() {
    // Task 5 falls back from `chartPreviousClose` to `previousClose`, and from
    // a missing name to the symbol itself. Reporting those as breaking would
    // send someone fixing a decoder that already copes.
    #expect(!ShapeChange.missing(path: "chart.result[].meta.previousClose",
                                 wasType: .number).breaksSquiggle)
    #expect(!ShapeChange.missing(path: "chart.result[].meta.shortName",
                                 wasType: .string).breaksSquiggle)
    // The price has nothing behind it.
    #expect(ShapeChange.missing(path: "chart.result[].meta.regularMarketPrice",
                                wasType: .number).breaksSquiggle)
}

@Test func aChangeToAFieldSquiggleIgnoresIsNotBreaking() throws {
    // Yahoo adds and removes fields Squiggle has never read. Flagging those as
    // breaking would train the reader to ignore the tool.
    #expect(!ShapeChange.added(path: "chart.result[].meta.gmtoffset", type: .number)
        .breaksSquiggle)
    #expect(!ShapeChange.missing(path: "chart.result[].indicators.adjclose", wasType: .array)
        .breaksSquiggle)
}

@Test func aNumberToStringChangeOnAPriceIsNotBreakingBecauseLenientDoubleHandlesIt() throws {
    // Task 4 exists precisely because Yahoo has sent prices as strings before.
    // Reporting that as breaking would be wrong — the decoder already copes.
    #expect(!ShapeChange.typeChanged(path: "chart.result[].meta.regularMarketPrice",
                                     from: .number, to: .string).breaksSquiggle)
}

@Test func theRecordedFixtureStillMatchesItself() throws {
    // A regression guard on the digester rather than on Yahoo: if this fails,
    // the digester changed, not the API.
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/yahoo-2026-09-08/regular-session.json")
    let d = try ShapeDigest.digest(of: Data(contentsOf: url))
    #expect(ShapeDigest.diff(recorded: d, live: d).isEmpty)
    // Only the required paths must be present. Yahoo omits some optional
    // fields on some listings, and failing over one of those would make this
    // test a report on Yahoo's mood rather than on the digester.
    for path in ShapeDigest.requiredPaths {
        #expect(d.paths[path] != nil, "the fixture has no \(path); the list is stale")
    }
}

@Test func digestingSomethingThatIsNotJsonThrowsRatherThanReturningEmpty() throws {
    // An empty digest would diff as "every field disappeared", which reads as
    // a catastrophic API change when it is really an error page.
    #expect(throws: TickerError.notJSON) {
        try ShapeDigest.digest(of: Data("<html>429</html>".utf8))
    }
}

@Test func digestingSurvivesEveryTruncationOfTheFixture() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/yahoo-2026-09-08/regular-session.json")
    let data = try Data(contentsOf: url)
    for length in stride(from: 0, to: data.count, by: 11) {
        _ = try? ShapeDigest.digest(of: Data(data.prefix(length)))
    }
}
