import Foundation
import Testing
import TickerCore
@testable import Squiggle

// A measurement function with no font in it: every character is 10 points
// wide. Real text measurement varies by OS version and installed fonts
// (spec §8.5), so the only stable assertions are against a fake.
/// Weight-blind on purpose: these tests are about placement arithmetic, and
/// a heavier symbol measuring wider is the caller's business (R131).
private let tenPerCharacter: @Sendable (String, Bool) -> Double = { text, _ in
    Double(text.count) * 10
}

private let posix = Locale(identifier: "en_US_POSIX")

/// A row's entries, with the dividers between them taken out.
///
/// The interpunct sits *in* the gap and so is not part of any entry: the tests
/// below are about what one watchlist entry is made of and where its pieces
/// land, and a divider threaded through every expected list would bury that.
/// The dividers have their own tests, further down, which is where a build
/// that stopped emitting them fails.
private func entries(of row: StripLayout.Row) -> [StripLayout.Segment] {
    row.segments.filter { $0.role != .separator }
}

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

    let texts = entries(of: layout.rows[0]).map(\.text)
    #expect(texts == ["AAPL ", "232.10 ", "▼", "1.10 (0.47%)"])
}

@Test func onlyTheSymbolIsDrawnHeavy() throws {
    // The same emphasis the dropdown gives a row: the name is the thing the
    // eye is scanning for, the numbers after it are what it stops to read.
    let aapl = try symbol("AAPL")
    let layout = StripLayout.build(
        symbols: [aapl],
        quotes: [aapl: try quote("AAPL", price: 232.1, change: 1.1)],
        dead: [], rows: 1, gap: 20, locale: posix, measure: tenPerCharacter)

    let segments = entries(of: layout.rows[0])
    #expect(segments.map(\.emphasized) == [true, false, false, false])
}

@Test func aSymbolWithNoQuoteIsStillDrawnHeavy() throws {
    // The placeholder path builds its own pair of pieces, so it is its own
    // chance to forget the weight — and a launch showing every symbol
    // un-emphasised until its first quote lands is exactly the flicker this
    // pins against.
    let vod = try symbol("VOD.L")
    let layout = StripLayout.build(
        symbols: [vod], quotes: [:],
        dead: [], rows: 1, gap: 20, locale: posix, measure: tenPerCharacter)

    let segments = entries(of: layout.rows[0])
    #expect(segments[0].text == "VOD.L ")
    #expect(segments.map(\.emphasized) == [true, false])
}

@Test func theHeavierWeightIsMeasuredAtTheHeavierWeight() throws {
    // R131 says the caller binds the font; the flag is how it knows *which*
    // font. A layout that measured the symbol at the regular weight would
    // put every segment after it slightly too far left and hand the marquee
    // a `contentWidth` shorter than the text it tiles.
    let aapl = try symbol("AAPL")
    let doubleWhenHeavy: @Sendable (String, Bool) -> Double = { text, heavy in
        Double(text.count) * (heavy ? 20 : 10)
    }
    let layout = StripLayout.build(
        symbols: [aapl],
        quotes: [aapl: try quote("AAPL", price: 232.1, change: 1.1)],
        dead: [], rows: 1, gap: 20, locale: posix, measure: doubleWhenHeavy)

    let segments = entries(of: layout.rows[0])
    #expect(segments[0].width == 100)   // "AAPL " at the heavier weight
    #expect(segments[1].x == 100)       // and the price starts after all of it
}

@Test func onlyTheDirectionGlyphCarriesDirection() throws {
    // The triangle alone is coloured. The delta and the percentage read as
    // label text in every scheme, so the eye lands on one small mark rather
    // than on a coloured run competing with the price beside it.
    let aapl = try symbol("AAPL")
    let layout = StripLayout.build(
        symbols: [aapl],
        quotes: [aapl: try quote("AAPL", price: 232.1, change: 1.1)],
        dead: [], rows: 1, gap: 20, locale: posix, measure: tenPerCharacter)

    let segments = entries(of: layout.rows[0])
    #expect(segments.map(\.role) == [.label, .label, .direction(.up), .label])
    #expect(segments[2].text == "▲")
    #expect(segments[3].text == "1.10 (0.48%)")
}

@Test func aFlatChangeStillSplitsItsGlyphIntoItsOwnSegment() throws {
    // `.flat` resolves to `.labelColor` in every scheme, so the split buys
    // no colour here — but the segment shape must not depend on direction,
    // or the renderer would have two layouts to reason about instead of one.
    let msft = try symbol("MSFT")
    let layout = StripLayout.build(
        symbols: [msft],
        quotes: [msft: try quote("MSFT", price: 410.0, change: 0)],
        dead: [], rows: 1, gap: 20, locale: posix, measure: tenPerCharacter)

    let segments = entries(of: layout.rows[0])
    #expect(segments.map(\.role) == [.label, .label, .direction(.flat), .label])
    #expect(segments[2].text == "–")
}

/// A quote with no change at all — the first print of a new listing.
///
/// `Quote.init` sets `.unknown` only where it also nils `change`, so this is
/// the *whole* of what `.unknown` looks like on the strip: no glyph, no delta,
/// no brackets, just a name and a price. Asserted as the complete segment list
/// rather than as "no `.direction(.unknown)` anywhere", which was the shape
/// this test had first — and which passes just as well on a build that emits
/// an empty glyph segment, because an empty segment carries `.direction(.flat)`
/// or nothing at all depending on how it breaks.
@Test func aQuoteWithNoChangeYetIsJustANameAndAPrice() throws {
    let ipo = try symbol("IPO")
    let layout = StripLayout.build(
        symbols: [ipo],
        quotes: [ipo: try quote("IPO", price: 12.5, change: nil)],
        dead: [], rows: 1, gap: 20, locale: posix, measure: tenPerCharacter)

    let segments = entries(of: layout.rows[0])
    #expect(segments.map(\.role) == [.label, .label])
    #expect(segments.count == 2)
    let text = segments.map(\.text).joined()
    #expect(text.contains("IPO"))
    #expect(text.contains("12.5"))
    #expect(!text.contains("("))
}

@Test func aDeadSymbolKeepsItsSlotAndCarriesNoDirection() throws {
    // Spec §7: a symbol whose last fetch failed renders `——` and keeps its
    // place, so the strip's shape does not change under the user's eye.
    let dead = try symbol("VOD.L")
    let layout = StripLayout.build(
        symbols: [dead], quotes: [:], dead: [dead],
        rows: 1, gap: 20, locale: posix, measure: tenPerCharacter)

    #expect(entries(of: layout.rows[0]).map(\.text) == ["VOD.L ", "——"])
    #expect(entries(of: layout.rows[0]).map(\.role) == [.label, .label])
}

@Test func aSymbolWithNoQuoteYetIsRenderedLikeADeadOne() throws {
    // At launch nothing has been fetched. The slot still has to exist or the
    // strip visibly re-flows a few seconds after the user logs in.
    let aapl = try symbol("AAPL")
    let layout = StripLayout.build(
        symbols: [aapl], quotes: [:], dead: [],
        rows: 1, gap: 20, locale: posix, measure: tenPerCharacter)
    #expect(entries(of: layout.rows[0]).map(\.text) == ["AAPL ", "——"])
}

@Test func anUnknownDirectionShowsTheNumbersWithoutAGlyphOrAColour() throws {
    // `chartPreviousClose == 0` yields `.unknown` (spec §5.3), whose glyph is
    // empty and which is never coloured.
    let btc = try symbol("BTC-USD")
    let layout = StripLayout.build(
        symbols: [btc],
        quotes: [btc: try quote("BTC-USD", price: 64000, change: nil)],
        dead: [], rows: 1, gap: 20, locale: posix, measure: tenPerCharacter)

    #expect(entries(of: layout.rows[0]).map(\.text) == ["BTC-USD ", "64,000.00"])
    #expect(entries(of: layout.rows[0]).map(\.role) == [.label, .label])
}

@Test func segmentsAreLaidOutLeftToRightWithNoGapsInsideAnEntry() throws {
    let aapl = try symbol("AAPL")
    let layout = StripLayout.build(
        symbols: [aapl],
        quotes: [aapl: try quote("AAPL", price: 232.1, change: -1.1)],
        dead: [], rows: 1, gap: 20, locale: posix, measure: tenPerCharacter)

    let segments = entries(of: layout.rows[0])
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
    let painted = entries(of: row).reduce(0.0) { $0 + $1.width }
    #expect(row.contentWidth == painted + 20)
}

@Test func twoRowsAreBalancedByRenderedWidthNotByCount() throws {
    // Spec §5.1: `RowSplitter` balances by rendered width, and this fixture is
    // chosen so that the two strategies disagree — which the old three-symbol
    // fixture did not, leaving the rule with no app-layer guard.
    //
    // Four entries at ten points per character, each `SYMBOL ` + `——` + a
    // 20-point trailing gap, so an entry costs `name.count * 10 + 50`:
    // `LONGLONGLONGLONG` is 210 and each of `A`, `B`, `C` is 60.
    //
    // Width-based (greedy least-loaded, in order): the long one takes row 0 at
    // 210, and every short one then goes to whichever row is narrower — all
    // three land in row 1, which ends at 180. One entry against three.
    //
    // Count-based: two and two, whichever two it picks — 270 against 120 for a
    // first-half/second-half split, the same for an alternating one. Both fail
    // the segment-count assertions below, which is the point.
    let names = ["LONGLONGLONGLONG", "A", "B", "C"]
    let symbols = try names.map { try symbol($0) }
    // No quotes and nothing dead: every entry renders as `SYMBOL ` + `——`,
    // which keeps the arithmetic above readable. This test measures row
    // widths only, never role or direction.
    let layout = StripLayout.build(symbols: symbols, quotes: [:], dead: [],
                                   rows: 2, gap: 20, locale: posix,
                                   measure: tenPerCharacter)

    #expect(layout.rows.count == 2)
    // Two segments per entry. One entry in row 0, three in row 1 — a
    // count-based splitter would put two entries (four segments) in each.
    #expect(entries(of: layout.rows[0]).count == 2)
    #expect(entries(of: layout.rows[1]).count == 6)
    // And the partition is the one the widths argue for, not merely some
    // one-against-three split.
    #expect(entries(of: layout.rows[0])[0].text == "LONGLONGLONGLONG ")
    let widths = layout.rows.map(\.contentWidth)
    #expect(widths == [210, 180])
}

@Test func askingForOneRowGivesOneRowAndEveryEntryIsInIt() throws {
    let symbols = try ["A", "B", "C"].map { try symbol($0) }
    let layout = StripLayout.build(symbols: symbols, quotes: [:], dead: [],
                                   rows: 1, gap: 20, locale: posix,
                                   measure: tenPerCharacter)
    #expect(layout.rows.count == 1)
    // Two segments per entry (`SYMBOL ` and `——`), three entries.
    #expect(entries(of: layout.rows[0]).count == 6)
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
    let rendered = entries(of: layout.rows[0]).map(\.text).filter { $0 != "——" }
    let expected = raws.map { $0 + " " }
    #expect(rendered == expected)
}

// MARK: - The dividers

@Test func anInterpunctDividesOneEntryFromTheNext() throws {
    let symbols = try ["A", "B"].map { try symbol($0) }
    let layout = StripLayout.build(symbols: symbols, quotes: [:], dead: [],
                                   rows: 1, gap: 20, locale: posix,
                                   measure: tenPerCharacter)

    // One after each entry, the last included: in a scrolling row the
    // trailing gap is the join to the repeat of the first entry, so it
    // divides two entries like any other. `StripRenderer.rowLayer` is what
    // drops the dangling one from a row that does not tile.
    #expect(layout.rows[0].segments.map(\.text) == ["A ", "——", "·", "B ", "——", "·"])
    let roles = layout.rows[0].segments.map(\.role)
    #expect(roles == [.label, .label, .separator, .label, .label, .separator])
}

@Test func theInterpunctIsCentredInTheGapAndCostsNoWidth() throws {
    // The whole point of centring it inside the gap rather than adding it to
    // the gap: `contentWidth` is the lap, the tiling seam and the scroll
    // duration, and a divider that moved it would have changed all three.
    let a = try symbol("A")
    let layout = StripLayout.build(symbols: [a], quotes: [:], dead: [],
                                   rows: 1, gap: 20, locale: posix,
                                   measure: tenPerCharacter)

    let row = layout.rows[0]
    // `A ` is 20 and `——` is 20, so the entry ends at 40 and the 20-point gap
    // runs to 60. A 10-point dot centred in it starts at 45.
    let divider = try #require(row.segments.last)
    #expect(divider.role == .separator)
    #expect(divider.x == 45)
    #expect(divider.width == 10)
    #expect(row.contentWidth == 60)
}

@Test func aGapTooNarrowToHoldTheDividerGetsNone() throws {
    // At ten points per character the dot is 10 wide, so a 10-point gap has
    // no room for it with air either side. Skipped rather than squeezed:
    // overlapping the price is worse than no divider at all.
    let symbols = try ["A", "B"].map { try symbol($0) }
    let layout = StripLayout.build(symbols: symbols, quotes: [:], dead: [],
                                   rows: 1, gap: 10, locale: posix,
                                   measure: tenPerCharacter)

    #expect(!layout.rows[0].segments.contains { $0.role == .separator })
}

@Test func cardsCarryNoDividers() throws {
    // A card is one entry alone in the menu bar. Nothing is beside it, so
    // there is nothing to divide it from.
    let symbols = try ["A", "B"].map { try symbol($0) }
    let layout = StripLayout.cards(symbols: symbols, quotes: [:], dead: [],
                                   locale: posix, measure: tenPerCharacter)

    #expect(layout.rows.count == 2)
    #expect(!layout.rows.contains { $0.segments.contains { $0.role == .separator } })
}

// A card is one entry, measured and emphasised exactly as the strip measures
// and emphasises it — the point of reusing `pieces` rather than assembling
// `SYMBOL price ▲delta (pct%)` a second time.
@Test func aCardIsOneEntryAtItsOwnWidth() throws {
    let symbols = try ["A", "BB"].map { try symbol($0) }
    let layout = StripLayout.cards(symbols: symbols, quotes: [:], dead: [],
                                   locale: posix, measure: tenPerCharacter)

    #expect(layout.rows.count == 2)
    // `A ` plus `——`, then `BB ` plus `——`: no gap, so the width is the text's.
    #expect(layout.rows.map(\.contentWidth) == [40, 50])
    #expect(layout.rows[0].segments.map(\.x) == [0, 20])
    #expect(layout.rows.allSatisfy { $0.segments.first?.emphasized == true })
}

@Test func anEmptyWatchlistProducesNoCards() {
    let layout = StripLayout.cards(symbols: [], quotes: [:], dead: [],
                                   locale: posix, measure: tenPerCharacter)
    #expect(layout.rows.isEmpty)
}

// Flip's shrink-to-fit (`StripRenderer.cardShrink`) re-measures a row by
// multiplication, which works because a scalable font's advances are linear in
// point size. Nothing moves relative to anything else; everything moves in.
@Test func scalingARowBringsItsOffsetsAndWidthsDownTogether() {
    let row = StripLayout.Row(
        segments: [
            StripLayout.Segment(text: "AAPL ", role: .label, x: 0, width: 50,
                                emphasized: true),
            StripLayout.Segment(text: "-0.42%", role: .direction(.down), x: 50, width: 60),
        ],
        contentWidth: 130)

    let half = row.scaled(by: 0.5)

    #expect(half.contentWidth == 65)
    #expect(half.segments.map(\.x) == [0, 25])
    #expect(half.segments.map(\.width) == [25, 30])
    // Everything that is not a measurement is carried through untouched.
    #expect(half.segments.map(\.text) == row.segments.map(\.text))
    #expect(half.segments.map(\.role) == row.segments.map(\.role))
    #expect(half.segments.map(\.emphasized) == [true, false])
}
