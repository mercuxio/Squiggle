import Foundation
import Testing
import TickerCore
@testable import squigglectl

@Test func quoteTakesASymbolAndOptionalRawFlag() throws {
    let parsed = try Command.parse(["quote", "AAPL"])
    #expect(parsed == .quote(symbol: "AAPL", raw: false))

    let rawForm = try Command.parse(["quote", "^GSPC", "--raw"])
    #expect(rawForm == .quote(symbol: "^GSPC", raw: true))
}

@Test func quoteWithoutASymbolIsAParseError() {
    #expect(throws: ParseError.self) { try Command.parse(["quote"]) }
}

@Test func anUnknownSubcommandIsAParseError() {
    #expect(throws: ParseError.self) { try Command.parse(["frobnicate"]) }
}

@Test func noArgumentsPrintsHelpRatherThanFailing() throws {
    let parsed = try Command.parse([])
    #expect(parsed == .help)
}

@Test func watchTakesSymbolsAndDefaultsIntervalAndCycles() throws {
    let aapl = try #require(Symbol("AAPL"))
    let msft = try #require(Symbol("MSFT"))
    let parsed = try Command.parse(["watch", "AAPL", "MSFT"])
    #expect(parsed == .watch(symbols: [aapl, msft],
                             intervalSeconds: RateConstants.defaultRefreshInterval,
                             maxCycles: nil))
}

@Test func watchWithNoSymbolsParsesToAnEmptyListForMainToFallBackOn() throws {
    // `Command.parse` touches no filesystem (see its own doc comment), so an
    // empty watchlist-fallback list is `main.swift`'s job, not this parser's.
    // This just confirms parsing bare `watch` doesn't fail outright.
    let parsed = try Command.parse(["watch"])
    #expect(parsed == .watch(symbols: [], intervalSeconds: RateConstants.defaultRefreshInterval,
                             maxCycles: nil))
}

@Test func watchClampsAnIntervalBelowTheOfferedRangeUpToTheMinimum() throws {
    let aapl = try #require(Symbol("AAPL"))
    let parsed = try Command.parse(["watch", "AAPL", "--interval", "10"])
    #expect(parsed == .watch(symbols: [aapl], intervalSeconds: 60, maxCycles: nil))
}

@Test func watchClampsAnIntervalAboveTheOfferedRangeDownToTheMaximum() throws {
    let aapl = try #require(Symbol("AAPL"))
    let parsed = try Command.parse(["watch", "AAPL", "--interval", "7200"])
    #expect(parsed == .watch(symbols: [aapl], intervalSeconds: 900, maxCycles: nil))
}

@Test func watchRejectsANonNumericInterval() {
    #expect(throws: ParseError.self) {
        try Command.parse(["watch", "AAPL", "--interval", "soon"])
    }
}

@Test func watchParsesAPositiveCycleCount() throws {
    let aapl = try #require(Symbol("AAPL"))
    let parsed = try Command.parse(["watch", "AAPL", "--cycles", "4"])
    #expect(parsed == .watch(symbols: [aapl], intervalSeconds: RateConstants.defaultRefreshInterval,
                             maxCycles: 4))
}

@Test func watchRejectsAZeroOrNegativeCycleCount() {
    #expect(throws: ParseError.self) { try Command.parse(["watch", "AAPL", "--cycles", "0"]) }
    #expect(throws: ParseError.self) { try Command.parse(["watch", "AAPL", "--cycles", "-1"]) }
}

@Test func watchRejectsANonNumericCycleCount() {
    #expect(throws: ParseError.self) {
        try Command.parse(["watch", "AAPL", "--cycles", "soon"])
    }
}

@Test func watchRejectsATokenThatIsNotAUsableSymbol() {
    // A "/" cannot appear in a symbol (Symbol.init rejects it — it's a URL
    // path separator), so this is deliberately not a mistyped ticker.
    #expect(throws: ParseError.self) { try Command.parse(["watch", "AA/PL"]) }
}

@Test func searchTakesAMultiWordQueryWithoutQuoting() throws {
    let parsed = try Command.parse(["search", "berkshire", "hathaway"])
    #expect(parsed == .search(query: "berkshire hathaway", limit: 10))
}

@Test func searchAcceptsALimitAnywhereInTheArguments() throws {
    let leading = try Command.parse(["search", "--limit", "3", "apple"])
    #expect(leading == .search(query: "apple", limit: 3))

    let trailing = try Command.parse(["search", "apple", "--limit", "3"])
    #expect(trailing == .search(query: "apple", limit: 3))
}

@Test func theLimitIsCappedSoOneCommandCannotBecomeALargeRequest() throws {
    let parsed = try Command.parse(["search", "apple", "--limit", "5000"])
    #expect(parsed == .search(query: "apple", limit: RateConstants.maxSearchResultCount))
}

@Test func aNonNumericOrZeroLimitIsRejectedWithAMessage() {
    #expect(throws: ParseError.self) { try Command.parse(["search", "apple", "--limit", "lots"]) }
    #expect(throws: ParseError.self) { try Command.parse(["search", "apple", "--limit", "0"]) }
    #expect(throws: ParseError.self) { try Command.parse(["search", "apple", "--limit"]) }
}

@Test func searchWithNothingToSearchForIsRejected() {
    #expect(throws: ParseError.self) { try Command.parse(["search"]) }
    #expect(throws: ParseError.self) { try Command.parse(["search", "--limit", "5"]) }
}

/// F-5: `quote --json AAPL` used to silently treat `--json` as the symbol
/// (R64 removed the flag from the parser but nothing rejected it). An
/// unrecognised `--flag` is a user error, wherever it appears.
@Test func quoteRejectsAnUnknownFlagRatherThanTreatingItAsTheSymbol() {
    #expect(throws: ParseError.self) { try Command.parse(["quote", "--json", "AAPL"]) }
    #expect(throws: ParseError.self) { try Command.parse(["quote", "AAPL", "--json"]) }
}

/// F-5: an unrecognised `--flag` used to silently join the search query
/// instead of being reported as a mistake.
@Test func searchRejectsAnUnknownFlagRatherThanJoiningItIntoTheQuery() {
    #expect(throws: ParseError.self) { try Command.parse(["search", "--bogus", "apple"]) }
    #expect(throws: ParseError.self) { try Command.parse(["search", "apple", "--bogus"]) }
}

@Test func usageMentionsEveryVerbTheToolAccepts() {
    // A verb that works but is undocumented is a verb nobody uses.
    for verb in ["quote", "watch", "search", "doctor", "probe"] {
        #expect(Rendering.usage.contains("squigglectl \(verb)"))
    }
}

/// F-4 (fix round 2): the name outran both the parser and the test. The
/// parser rejected only `--`-prefixed leftovers and silently discarded the
/// rest, so `Command.parse(["doctor", "AAPL"])` succeeded; the test asserted
/// only that the bare form parses, which the broken parser also did. Both
/// halves of the rule the name states are now asserted.
@Test func doctorTakesNoArguments() throws {
    let parsed = try Command.parse(["doctor"])
    #expect(parsed == .doctor)
    #expect(throws: ParseError.self) { try Command.parse(["doctor", "AAPL"]) }
    #expect(throws: ParseError.self) { try Command.parse(["doctor", "AAPL", "MSFT"]) }
}

/// Same rule as `quote` and `search`: `doctor` has no flags of its own yet,
/// so a stray `--flag` is a mistake to report, not a token to ignore. Kept
/// distinct from the positional case above because the two get different
/// wording — calling `AAPL` an unknown flag would misdiagnose the mistake.
@Test func doctorRejectsAnUnknownFlag() {
    #expect(throws: ParseError.self) { try Command.parse(["doctor", "--bogus"]) }
}

@Test func doctorNamesTheOffendingTokenWithoutCallingItAFlag() throws {
    do {
        _ = try Command.parse(["doctor", "AAPL"])
        Issue.record("doctor accepted a positional argument")
    } catch let error as ParseError {
        #expect(error.message.contains("AAPL"))
        #expect(!error.message.contains("flag"))
    }
}

// MARK: - probe (Task 18)

@Test func probeTakesASymbolAndOptionalRecordFlag() throws {
    let parsed = try Command.parse(["probe", "AAPL"])
    #expect(parsed == .probe(symbol: "AAPL", record: nil))

    let recordForm = try Command.parse(["probe", "^GSPC", "--record", "index"])
    #expect(recordForm == .probe(symbol: "^GSPC", record: "index"))

    // The flag's position relative to the symbol must not matter, same as
    // `quote`'s `--raw` — as long as the token right after `--record` is
    // read as its value rather than the symbol.
    let flagFirst = try Command.parse(["probe", "--record", "regular-session", "AAPL"])
    #expect(flagFirst == .probe(symbol: "AAPL", record: "regular-session"))
}

@Test func probeWithoutASymbolIsAParseError() {
    #expect(throws: ParseError.self) { try Command.parse(["probe"]) }
    // `--record` with no symbol left after it (the value token is consumed
    // by `--record` itself) is also a missing-symbol error.
    #expect(throws: ParseError.self) { try Command.parse(["probe", "--record", "regular-session"]) }
}

/// F-1 (fix round 1): `--record` given with nothing following it is a parse
/// error, the same rule `--interval` and `--limit` already follow — not a
/// flag that silently does nothing.
@Test func probeRecordWithNoValueIsAParseError() {
    #expect(throws: ParseError.self) { try Command.parse(["probe", "AAPL", "--record"]) }
    #expect(throws: ParseError.self) { try Command.parse(["probe", "--record"]) }
}

/// F-1: the name becomes a path component
/// (`Tests/Fixtures/yahoo-<date>/<name>.json`), so anything that could climb
/// out of that directory or otherwise misbehave as a path is rejected
/// before `probe` ever runs, not sanitised into something else.
@Test func probeRejectsARecordNameThatIsNotLowercaseLettersDigitsAndHyphens() {
    #expect(throws: ParseError.self) { try Command.parse(["probe", "AAPL", "--record", "../escape"]) }
    #expect(throws: ParseError.self) { try Command.parse(["probe", "AAPL", "--record", "a/b"]) }
    #expect(throws: ParseError.self) { try Command.parse(["probe", "AAPL", "--record", "Regular-Session"]) }
    #expect(throws: ParseError.self) { try Command.parse(["probe", "AAPL", "--record", "has space"]) }
    #expect(throws: ParseError.self) { try Command.parse(["probe", "AAPL", "--record", "."]) }
    #expect(throws: ParseError.self) { try Command.parse(["probe", "AAPL", "--record", ""]) }
}

/// F-B (fix round 2): `takeValue("--record")` strips `--record` and the
/// token right after it from `rest` before the unknown-flag sweep below ever
/// runs, so a stray flag given as that token was consumed as the fixture
/// name instead of being reported. Measured on the built binary:
/// `probe --record --raw` reports a missing symbol (proving `--raw` was
/// eaten as the name), where `probe --raw` alone correctly reports
/// `unknown flag: --raw`. A value beginning with `-` is now rejected by the
/// name validation itself, which is the only place left that can catch it —
/// moving the sweep earlier would misreport `--record` itself as unknown.
@Test func probeRejectsARecordNameThatBeginsWithAHyphen() throws {
    do {
        _ = try Command.parse(["probe", "--record", "--raw", "AAPL"])
        Issue.record("expected a ParseError for --record --raw AAPL")
    } catch let error as ParseError {
        #expect(error.message.contains("--raw"))
    }

    #expect(throws: ParseError.self) { try Command.parse(["probe", "--record", "-x", "AAPL"]) }
    #expect(throws: ParseError.self) { try Command.parse(["probe", "--record", "--record", "AAPL"]) }
}

/// The fix above must not regress a legitimate hyphenated scenario name — a
/// hyphen stays legal everywhere but the first character. `regular-session`,
/// `crypto-while-equities-closed` and `pre-market` are real scenario names in
/// this project's fixture corpus (see `docs/fixture-capture-log.md`).
@Test func probeStillAcceptsARecordNameThatContainsAHyphen() throws {
    let parsed = try Command.parse(["probe", "--record", "regular-session", "AAPL"])
    #expect(parsed == .probe(symbol: "AAPL", record: "regular-session"))
}

/// Same rule as `quote`, `search` and `doctor`: an unrecognised `--flag`
/// must be reported, not silently treated as (or joined into) the symbol.
@Test func probeRejectsAnUnknownFlag() {
    #expect(throws: ParseError.self) { try Command.parse(["probe", "--bogus", "AAPL"]) }
    #expect(throws: ParseError.self) { try Command.parse(["probe", "AAPL", "--bogus"]) }
}

// MARK: - the unknown-flag sweep, on every verb and on one hyphen

@Test func everyVerbRejectsASingleHyphenFlagInsteadOfTakingItAsAnArgument() throws {
    // `watch` had no sweep at all, so `watch --raw AAPL` parsed as a watchlist
    // of two symbols: `Symbol`'s forbidden set has no hyphen in it, so `--raw`
    // is a perfectly constructible symbol, and the loop fetched it every cycle
    // until Yahoo answered "not found". The other four swept `hasPrefix("--")`
    // only, so `-x` walked through all of them.
    let attempts: [[String]] = [
        ["quote", "-x", "AAPL"], ["quote", "--raw2", "AAPL"],
        ["watch", "-x", "AAPL"], ["watch", "--raw", "AAPL"],
        ["search", "-x", "apple"], ["search", "--json", "apple"],
        ["doctor", "-x"], ["doctor", "--json"],
        ["probe", "-x", "AAPL"], ["probe", "--json", "AAPL"],
    ]
    for arguments in attempts {
        do {
            let parsed = try Command.parse(arguments)
            Issue.record("\(arguments) parsed as \(parsed)")
        } catch let error as ParseError {
            #expect(error.message.contains("unknown flag"), "\(arguments): \(error.message)")
        }
    }
}

@Test func theSweepCostsNoRealSymbolAndNoRealRecordName() throws {
    // The sweep tests `hasPrefix("-")`, which is a wider net than the `--` it
    // replaces, so the things that legitimately carry punctuation have to be
    // re-checked through every verb that accepts one. These five are the
    // spellings this project treats as the canonical awkward cases.
    for raw in ["^GSPC", "BRK-B", "VOD.L", "BTC-USD", "EURUSD=X"] {
        #expect(try Command.parse(["quote", raw]) == .quote(symbol: raw, raw: false))
        #expect(try Command.parse(["probe", raw]) == .probe(symbol: raw, record: nil))
        let symbol = try #require(Symbol(raw))
        #expect(try Command.parse(["watch", raw])
            == .watch(symbols: [symbol],
                      intervalSeconds: RateConstants.defaultRefreshInterval,
                      maxCycles: nil))
    }

    // And the scenario names `probe --record` is documented with, all of which
    // contain hyphens. `takeValue` strips the name before the sweep sees it,
    // which is what keeps them legal.
    for name in ["regular-session", "pre-market", "crypto-while-equities-closed"] {
        #expect(try Command.parse(["probe", "AAPL", "--record", name])
            == .probe(symbol: "AAPL", record: name))
    }
}

@Test func aNegativeFlagValueStillReachesItsOwnErrorRatherThanTheSweep() throws {
    // The reason a `-` sweep is safe: `takeValue` removes each known flag
    // *and the token after it* before the sweep runs, so a negative number
    // given to `--interval` or `--cycles` is diagnosed by the code that knows
    // what those flags mean. Reported as "unknown flag: -5" it would send the
    // operator looking for a flag they never typed.
    //
    // `--interval -5` is the one that does not end in an error at all: -5 is a
    // number, so it reaches the clamp and runs at the bottom of the offered
    // range. That is the same point from the other side — what matters is that
    // the value is handled by the flag that asked for it, not intercepted as a
    // flag of its own.
    #expect(try Command.parse(["watch", "--interval", "-5", "AAPL"])
        == .watch(symbols: [try #require(Symbol("AAPL"))],
                  intervalSeconds: RateConstants.offeredRefreshIntervals.lowerBound,
                  maxCycles: nil))

    for arguments in [["watch", "--cycles", "-1", "AAPL"],
                      ["search", "--limit", "-3", "apple"]] {
        do {
            let parsed = try Command.parse(arguments)
            Issue.record("\(arguments) parsed as \(parsed)")
        } catch let error as ParseError {
            #expect(!error.message.contains("unknown flag"), "\(arguments): \(error.message)")
            #expect(error.message.contains(arguments[1]), "\(arguments): \(error.message)")
        }
    }
}

// MARK: - one symbol means one symbol

@Test func quoteAndProbeRefuseASecondSymbolRatherThanQuotingOnlyTheFirst() throws {
    // Both took `rest.first` and dropped the remainder in silence, so
    // `quote AAPL MSFT` printed a correct answer to a question the user did
    // not ask — and `probe AAPL MSFT` made one request and reported on it as
    // though the second symbol had never been typed. Diagnosed the way
    // `doctor` already diagnoses a stray positional: named, and not called a
    // flag.
    for arguments in [["quote", "AAPL", "MSFT"], ["probe", "AAPL", "MSFT"],
                      ["quote", "--raw", "AAPL", "MSFT"],
                      ["probe", "AAPL", "MSFT", "--record", "regular-session"]] {
        do {
            let parsed = try Command.parse(arguments)
            Issue.record("\(arguments) parsed as \(parsed)")
        } catch let error as ParseError {
            #expect(error.message.contains("MSFT"), "\(arguments): \(error.message)")
            #expect(!error.message.contains("flag"), "\(arguments): \(error.message)")
        }
    }

    // `search` is the exception and stays one: joining its leftovers is the
    // whole point of not making people quote a multi-word query.
    #expect(try Command.parse(["search", "berkshire", "hathaway"])
        == .search(query: "berkshire hathaway", limit: 10))
}

// MARK: - the two interval rules, which are not the same rule

@Test func theCommandLineClampAndTheStoreDecoderDisagreeOnPurpose() throws {
    // `watch --interval`'s comment used to claim its clamp was "the same rule
    // `Settings` applies to a hand-edited store file". It is not: the decoder
    // replaces an interval outside the offered menu with the *default*, while
    // the command line snaps it to the nearest end of the range. Both halves
    // are pinned here, against each other, so the comment cannot drift back
    // into being true-sounding.
    let range = RateConstants.offeredRefreshIntervals
    #expect(try Command.parse(["watch", "--interval", "7200", "AAPL"])
        == .watch(symbols: [try #require(Symbol("AAPL"))],
                  intervalSeconds: range.upperBound, maxCycles: nil))

    let decoded = try JSONDecoder().decode(
        Settings.self, from: Data(#"{"refreshIntervalSeconds":7200}"#.utf8))
    #expect(decoded.refreshIntervalSeconds == RateConstants.defaultRefreshInterval)
    #expect(decoded.refreshIntervalSeconds != range.upperBound,
            "the two rules have converged; the comment describing them must be re-read")
}
