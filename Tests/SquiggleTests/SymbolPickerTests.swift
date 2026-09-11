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
