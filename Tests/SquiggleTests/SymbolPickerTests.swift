import Foundation
import TickerCore
import Testing
@testable import Squiggle

// `Symbol.init?` is failable. Force-unwrapped here and nowhere in the
// app: every argument below is a literal this file controls, so a `nil`
// is a typo in the test, and a crash names the line.
private func result(_ symbol: String, _ name: String = "Some Company",
                    exchange: String = "NMS", kind: String = "EQUITY") -> SearchResult {
    SearchResult(symbol: Symbol(symbol)!, name: name, exchange: exchange, kind: kind)
}

// MARK: - SearchSession (R148)

@Test func theCurrentGenerationIsAccepted() {
    var session = SearchSession()
    let generation = session.begin()
    #expect(session.accepts(generation))
}

// The out-of-order case: `AA` is still in flight when `AAPL` starts, and
// then answers second. Its results are for a query the user has already
// moved past.
@Test func anOlderGenerationIsRejected() {
    var session = SearchSession()
    let stale = session.begin()
    let current = session.begin()
    #expect(!session.accepts(stale))
    #expect(session.accepts(current))
}

// MARK: - Rows

// in the order the search returned them
@Test func resultsAreRows() {
    let found = [result("AAPL"), result("AAPU")]
    let model = SymbolPickerModel.build(query: "aap", results: found,
                                        error: nil, watchlist: [])
    #expect(model.rows == [.result(found[0], isAdded: false),
                           .result(found[1], isAdded: false)])
    #expect(model.message == nil)
}

// R150: shown, marked, and not addable.
// is listed and flagged
@Test func aDuplicateIsVisibleButMarked() {
    let found = [result("AAPL")]
    let model = SymbolPickerModel.build(query: "aapl", results: found,
                                        error: nil, watchlist: [Symbol("AAPL")!])
    #expect(model.rows == [.result(found[0], isAdded: true)])
}

// R149. `Symbol` is not upper-cased, not trimmed, not touched.
// offers the typed text exactly as typed
@Test func theLiteralFallbackIsVerbatim() {
    let model = SymbolPickerModel.build(query: "eurusd=x", results: [],
                                        error: nil, watchlist: [])
    #expect(model.rows == [.literal(Symbol("eurusd=x")!)])
}

@Test func theLiteralFallbackKeepsPunctuation() {
    let carets = SymbolPickerModel.build(query: "^GSPC", results: [],
                                         error: nil, watchlist: [])
    #expect(carets.rows == [.literal(Symbol("^GSPC")!)])
    let dotted = SymbolPickerModel.build(query: "VOD.L", results: [],
                                         error: nil, watchlist: [])
    #expect(dotted.rows == [.literal(Symbol("VOD.L")!)])
}

// `Symbol.init?` rejects whitespace, so a company name typed out in full
// has no literal to fall back to.
@Test func theLiteralFallbackRespectsSymbolValidation() {
    let model = SymbolPickerModel.build(query: "apple inc", results: [],
                                        error: nil, watchlist: [])
    #expect(model.rows.isEmpty)
    #expect(model.message == ErrorText.notASymbol)
}

@Test func nothingTypedIsNotASymbol() {
    let model = SymbolPickerModel.build(query: "", results: [],
                                        error: nil, watchlist: [])
    #expect(model.rows.isEmpty)
    #expect(model.message == nil)
}

// Offline is exactly when a user who knows their symbol should still be
// able to add it — the strip renders a dead symbol as `——` and recovers on
// its own when the network comes back.
// and says why
@Test func anErrorDoesNotBlockTheFallback() {
    let model = SymbolPickerModel.build(query: "AAPL", results: [],
                                        error: .offline, watchlist: [])
    #expect(model.rows == [.literal(Symbol("AAPL")!)])
    #expect(model.message == ErrorText.message(for: .offline))
}

@Test func anEmptyResultSetExplainsItself() {
    let model = SymbolPickerModel.build(query: "zzzz", results: [],
                                        error: nil, watchlist: [])
    #expect(model.message == ErrorText.noMatches)
}

// MARK: - The cap (R150)

// and says why
@Test func twentyIsTheLimit() {
    let full = (0..<RateConstants.maxWatchlistCount).map { Symbol("S\($0)")! }
    let model = SymbolPickerModel.build(query: "aapl", results: [result("AAPL")],
                                        error: nil, watchlist: full)
    #expect(model.isFull)
    #expect(model.message == ErrorText.watchlistFull)
}

// still shows what was searched for
@Test func refusingIsNotHiding() {
    let full = (0..<RateConstants.maxWatchlistCount).map { Symbol("S\($0)")! }
    let found = [result("AAPL")]
    let model = SymbolPickerModel.build(query: "aapl", results: found,
                                        error: nil, watchlist: full)
    #expect(model.rows == [.result(found[0], isAdded: false)])
}

@Test func nineteenIsFine() {
    let nearly = (0..<(RateConstants.maxWatchlistCount - 1)).map { Symbol("S\($0)")! }
    let model = SymbolPickerModel.build(query: "aapl", results: [result("AAPL")],
                                        error: nil, watchlist: nearly)
    #expect(!model.isFull)
    #expect(model.message == nil)
}

// MARK: - The cap against the other three inputs

// Every combination below reaches the same rule from a different arm of
// `build`: the cap outranks whatever else the picker would have said. It has
// to, because the cap is the one message that names something the user can
// act on — an error or a "no matches" shown instead would send them typing
// again at a list that will refuse them either way.

// The window opens on a full watchlist with nothing typed yet: no query is
// not a query, but the cap still has to announce itself before the user
// spends a search finding out.
@Test func nothingTypedAgainstAFullWatchlistStillSaysWhyNothingCanBeAdded() {
    let full = (0..<RateConstants.maxWatchlistCount).map { Symbol("S\($0)")! }
    let model = SymbolPickerModel.build(query: "", results: [],
                                        error: nil, watchlist: full)
    #expect(model.rows.isEmpty)
    #expect(model.isFull)
    #expect(model.message == ErrorText.watchlistFull)
}

// Offline *and* full. The literal fallback is still offered as a row — the
// cap is about adding, not about showing — but the line reports the cap
// rather than the network, because the network is not what is in the way.
@Test func theCapOutranksASearchFailure() {
    let full = (0..<RateConstants.maxWatchlistCount).map { Symbol("S\($0)")! }
    let model = SymbolPickerModel.build(query: "AAPL", results: [],
                                        error: .offline, watchlist: full)
    #expect(model.rows == [.literal(Symbol("AAPL")!)])
    #expect(model.isFull)
    #expect(model.message == ErrorText.watchlistFull)
}

// Offline, full, and what was typed cannot be a symbol either. Three reasons
// to say no and only one line to say it in; the cap is the one that survives.
@Test func theCapOutranksASearchFailureOverUnparseableText() {
    let full = (0..<RateConstants.maxWatchlistCount).map { Symbol("S\($0)")! }
    let model = SymbolPickerModel.build(query: "apple inc", results: [],
                                        error: .offline, watchlist: full)
    #expect(model.rows.isEmpty)
    #expect(model.isFull)
    #expect(model.message == ErrorText.watchlistFull)
}
