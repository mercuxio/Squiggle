import Foundation
import Testing
import TickerCore
@testable import Squiggle

// A measurement function with no font in it: every character is 10 points
// wide. Real text measurement varies by OS version and installed fonts
// (spec §8.5), so the only stable assertions are against a fake.
private let tenPerCharacter: @Sendable (String) -> Double = { Double($0.count) * 10 }

private let posix = Locale(identifier: "en_US_POSIX")

private func symbol(_ raw: String) throws -> Symbol {
    try #require(Symbol(raw))
}

// DEVIATION FROM THE BRIEF: `Quote`'s real initialiser
// (Sources/TickerCore/Quote.swift:37) takes `previousClose`, not
// `change`/`changePercent`/`direction` directly — it derives all three
// itself. This helper reconstructs `previousClose = price - change` so
// `Quote` derives the same `change` (and the `direction` its sign implies).
// `percent` and `direction` are not parameters here: nothing downstream
// reads them, and every test that cares about either already pins them in
// its expected segment text or role, not in how the fixture is built.
private func quote(_ raw: String, price: Double, change: Double?) throws -> Quote {
    let previousClose = change.map { price - $0 }
    return Quote(symbol: try symbol(raw), shortName: nil, price: price,
                 previousClose: previousClose, currency: "USD", asOfEpoch: nil)
}

@Test func oneSymbolBecomesThreeSegmentsInSpecOrder() throws {
    let aapl = try symbol("AAPL")
    let layout = StripLayout.build(
        symbols: [aapl],
        quotes: [aapl: try quote("AAPL", price: 232.1, change: -1.1)],
        dead: [], rows: 1, gap: 20, locale: posix, measure: tenPerCharacter)

    let texts = layout.rows[0].segments.map(\.text)
    #expect(texts == ["AAPL ", "232.10 ", "▼1.10 (0.47%)"])
}

@Test func onlyTheChangeSegmentCarriesDirection() throws {
    // Spec §5.3: colour applies to the delta and the percentage, never to
    // the symbol or the price.
    let aapl = try symbol("AAPL")
    let layout = StripLayout.build(
        symbols: [aapl],
        quotes: [aapl: try quote("AAPL", price: 232.1, change: 1.1)],
        dead: [], rows: 1, gap: 20, locale: posix, measure: tenPerCharacter)

    #expect(layout.rows[0].segments.map(\.role)
            == [.label, .label, .direction(.up)])
}

@Test func aDeadSymbolKeepsItsSlotAndCarriesNoDirection() throws {
    // Spec §7: a symbol whose last fetch failed renders `——` and keeps its
    // place, so the strip's shape does not change under the user's eye.
    let dead = try symbol("VOD.L")
    let layout = StripLayout.build(
        symbols: [dead], quotes: [:], dead: [dead],
        rows: 1, gap: 20, locale: posix, measure: tenPerCharacter)

    #expect(layout.rows[0].segments.map(\.text) == ["VOD.L ", "——"])
    #expect(layout.rows[0].segments.map(\.role) == [.label, .label])
}

@Test func aSymbolWithNoQuoteYetIsRenderedLikeADeadOne() throws {
    // At launch nothing has been fetched. The slot still has to exist or the
    // strip visibly re-flows a few seconds after the user logs in.
    let aapl = try symbol("AAPL")
    let layout = StripLayout.build(
        symbols: [aapl], quotes: [:], dead: [],
        rows: 1, gap: 20, locale: posix, measure: tenPerCharacter)
    #expect(layout.rows[0].segments.map(\.text) == ["AAPL ", "——"])
}

@Test func anUnknownDirectionShowsTheNumbersWithoutAGlyphOrAColour() throws {
    // `chartPreviousClose == 0` yields `.unknown` (spec §5.3), whose glyph is
    // empty and which is never coloured.
    let btc = try symbol("BTC-USD")
    let layout = StripLayout.build(
        symbols: [btc],
        quotes: [btc: try quote("BTC-USD", price: 64000, change: nil)],
        dead: [], rows: 1, gap: 20, locale: posix, measure: tenPerCharacter)

    #expect(layout.rows[0].segments.map(\.text) == ["BTC-USD ", "64,000.00"])
    #expect(layout.rows[0].segments.map(\.role) == [.label, .label])
}

@Test func segmentsAreLaidOutLeftToRightWithNoGapsInsideAnEntry() throws {
    let aapl = try symbol("AAPL")
    let layout = StripLayout.build(
        symbols: [aapl],
        quotes: [aapl: try quote("AAPL", price: 232.1, change: -1.1)],
        dead: [], rows: 1, gap: 20, locale: posix, measure: tenPerCharacter)

    let segments = layout.rows[0].segments
    #expect(segments[0].x == 0)
    for (previous, next) in zip(segments, segments.dropFirst()) {
        #expect(next.x == previous.x + previous.width)
    }
}

@Test func aRowsContentWidthIncludesTheTrailingGapSoACopyTiles() throws {
    // The animation translates by exactly this much (Task 8). If it excluded
    // the trailing gap the two copies would overlap by `gap` once per loop.
    let aapl = try symbol("AAPL")
    let layout = StripLayout.build(
        symbols: [aapl],
        quotes: [aapl: try quote("AAPL", price: 1.0, change: nil)],
        dead: [], rows: 1, gap: 20, locale: posix, measure: tenPerCharacter)

    let row = layout.rows[0]
    let painted = row.segments.reduce(0.0) { $0 + $1.width }
    #expect(row.contentWidth == painted + 20)
}

@Test func twoRowsAreBalancedByRenderedWidthNotByCount() throws {
    // Spec §5.1: `RowSplitter` balances by rendered width. With the fake
    // measurement one long symbol outweighs two short ones, so a
    // count-based split would put two in each row and this would fail.
    let names = ["A", "B", "LONGLONGLONGLONG"]
    let symbols = try names.map { try symbol($0) }
    var quotes: [Symbol: Quote] = [:]
    // `previousClose: nil` makes every fixture here direction-less
    // (`.unknown`, no change/percent) on purpose: this test measures row
    // widths only, never role or direction.
    for s in symbols {
        quotes[s] = Quote(symbol: s, shortName: nil, price: 1, previousClose: nil,
                          currency: nil, asOfEpoch: nil)
    }
    let layout = StripLayout.build(symbols: symbols, quotes: quotes, dead: [],
                                   rows: 2, gap: 20, locale: posix,
                                   measure: tenPerCharacter)

    #expect(layout.rows.count == 2)
    let widths = layout.rows.map(\.contentWidth)
    // Neither row is empty, and the long symbol is alone in its own row.
    // Hoisted out of `#expect`: the macro re-writes its argument expression,
    // and this codebase keeps trailing closures out of that rewrite.
    let bothRowsUsed = layout.rows.allSatisfy { !$0.segments.isEmpty }
    #expect(bothRowsUsed)
    #expect(abs(widths[0] - widths[1]) < max(widths[0], widths[1]))
}

@Test func askingForOneRowGivesOneRowAndEveryEntryIsInIt() throws {
    let symbols = try ["A", "B", "C"].map { try symbol($0) }
    let layout = StripLayout.build(symbols: symbols, quotes: [:], dead: [],
                                   rows: 1, gap: 20, locale: posix,
                                   measure: tenPerCharacter)
    #expect(layout.rows.count == 1)
    // Two segments per entry (`SYMBOL ` and `——`), three entries.
    #expect(layout.rows[0].segments.count == 6)
}

@Test func anEmptyWatchlistProducesEmptyRowsRatherThanNoRows() throws {
    // The renderer asks for `rows[0]` unconditionally; a watchlist emptied in
    // the picker must not take the status item out with it.
    let layout = StripLayout.build(symbols: [], quotes: [:], dead: [],
                                   rows: 2, gap: 20, locale: posix,
                                   measure: tenPerCharacter)
    let allEmpty = layout.rows.allSatisfy { $0.segments.isEmpty }
    let allZeroWidth = layout.rows.allSatisfy { $0.contentWidth == 0 }
    #expect(layout.rows.count == 2)
    #expect(allEmpty)
    #expect(allZeroWidth)
}

@Test func theWidestRowIsWhatTheFitsTheWidthTestWillCompare() throws {
    let symbols = try ["A", "LONGLONGLONG"].map { try symbol($0) }
    let layout = StripLayout.build(symbols: symbols, quotes: [:], dead: [],
                                   rows: 2, gap: 20, locale: posix,
                                   measure: tenPerCharacter)
    let widest = layout.rows.map(\.contentWidth).max()
    #expect(layout.widestRowWidth == widest)
}

@Test func symbolsAreRenderedExactlyAsTheUserStoredThem() throws {
    // Case is significant and never normalised: `BRK-B`, `^GSPC`, `VOD.L`.
    let raws = ["^GSPC", "BRK-B", "EURUSD=X"]
    let symbols = try raws.map { try symbol($0) }
    let layout = StripLayout.build(symbols: symbols, quotes: [:], dead: [],
                                   rows: 1, gap: 20, locale: posix,
                                   measure: tenPerCharacter)
    let rendered = layout.rows[0].segments.map(\.text).filter { $0 != "——" }
    let expected = raws.map { $0 + " " }
    #expect(rendered == expected)
}
