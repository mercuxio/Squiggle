import Testing
@testable import TickerCore

/// Sum of the widths a row was given.
private func load(_ row: [Int], _ widths: [Double]) -> Double {
    row.reduce(0) { $0 + widths[$1] }
}

@Test func oneRowIsTheIdentity() {
    let widths = [10.0, 3.0, 88.0, 1.0]
    #expect(RowSplitter.split(widths: widths, rows: 1) == [[0, 1, 2, 3]])
}

@Test func indicesStayAscendingWithinEachRow() {
    // The marquee reads left to right. A row whose indices are out of order
    // would show the user's watchlist shuffled, which looks like a bug even
    // though every symbol is present.
    let widths = (0..<40).map { Double(($0 * 37) % 23 + 1) }
    for row in RowSplitter.split(widths: widths, rows: 2) {
        #expect(row == row.sorted())
    }
}

@Test func everyItemAppearsExactlyOnce() {
    let widths = (0..<40).map { Double(($0 * 37) % 23 + 1) }
    let rows = RowSplitter.split(widths: widths, rows: 2)
    #expect(rows.flatMap { $0 }.sorted() == Array(0..<widths.count))
}

@Test func theTwoRowsEndUpCloseInTotalWidth() {
    // The property that matters: rows that differ a lot in width look broken
    // and finish their scroll cycles at very different times.
    let widths = [40.0, 38.0, 41.0, 39.0, 42.0, 37.0]
    let rows = RowSplitter.split(widths: widths, rows: 2)
    let difference = abs(load(rows[0], widths) - load(rows[1], widths))
    let widest = widths.max() ?? 0
    #expect(difference <= widest)
}

@Test func balanceHoldsEvenWhenOneItemDominates() {
    // A single very wide item cannot be split, so the best achievable
    // imbalance is that item's own width minus the rest. Assert we hit it.
    let widths = [500.0, 10.0, 10.0, 10.0, 10.0]
    let rows = RowSplitter.split(widths: widths, rows: 2)
    let difference = abs(load(rows[0], widths) - load(rows[1], widths))
    #expect(difference == 460)
}

@Test func alternatingWidthsAreNotJustDealtRoundRobin() {
    // Round-robin would put every wide item in row 0 and every narrow one in
    // row 1 — the exact failure this type exists to prevent.
    let widths = [100.0, 1.0, 100.0, 1.0, 100.0, 1.0]
    let rows = RowSplitter.split(widths: widths, rows: 2)
    let difference = abs(load(rows[0], widths) - load(rows[1], widths))
    let widest = widths.max() ?? 0
    #expect(difference <= widest, "greedy least-loaded guarantees the rows end within one item's width of each other")
}

@Test func tiesGoToTheEarlierRowSoTheSplitIsDeterministic() {
    // Equal widths must produce the same answer on every launch; a split that
    // changes between runs makes the ticker visibly reshuffle for no reason.
    let widths = [10.0, 10.0, 10.0, 10.0]
    let first = RowSplitter.split(widths: widths, rows: 2)
    #expect(first == RowSplitter.split(widths: widths, rows: 2))
    #expect(first[0].first == 0)
}

@Test func anEmptyWatchlistYieldsTheRightNumberOfEmptyRows() {
    #expect(RowSplitter.split(widths: [], rows: 2) == [[], []])
    #expect(RowSplitter.split(widths: [], rows: 1) == [[]])
}

@Test func aSingleItemLeavesTheSecondRowEmptyRatherThanDuplicating() {
    #expect(RowSplitter.split(widths: [7.0], rows: 2) == [[0], []])
}

@Test func aNonsensicalRowCountIsClampedIntoRange() {
    // `rows` reaches here from a hand-edited settings file (Task 13 clamps to
    // 1 or 2, but the splitter must not depend on that having happened).
    #expect(RowSplitter.split(widths: [1.0, 2.0], rows: 0).count == 1)
    #expect(RowSplitter.split(widths: [1.0, 2.0], rows: -5).count == 1)
    #expect(RowSplitter.split(widths: [1.0, 2.0], rows: 99).count == 2)
}

@Test func nonFiniteAndNegativeWidthsDoNotPoisonTheBalance() {
    // A NaN in a running total makes every subsequent comparison false, which
    // silently degrades the splitter to "everything in row 0".
    let widths = [10.0, .nan, 10.0, -50.0, 10.0, .infinity, 10.0]
    let rows = RowSplitter.split(widths: widths, rows: 2)
    #expect(rows.flatMap { $0 }.sorted() == Array(0..<widths.count))
    #expect(!rows[0].isEmpty)
    #expect(!rows[1].isEmpty)

    // Witness: the four genuinely-10.0-wide items (indices 0, 2, 4, 6) must
    // land two to a row under correct sanitization. Without sanitization the
    // NaN at index 1 poisons row 1's running total to NaN immediately after
    // seeding it, so every later "is row 1 less loaded" comparison is false
    // and all four 10.0-wide items pile into row 0 instead.
    let tenWideIndices: Set<Int> = [0, 2, 4, 6]
    let tenWideInRow0 = rows[0].filter { tenWideIndices.contains($0) }.count
    #expect(tenWideInRow0 == 2)
}

@Test func theSplitScalesToTheWatchlistCap() {
    let widths = (0..<RateConstants.maxWatchlistCount).map { Double($0 + 1) * 3 }
    let rows = RowSplitter.split(widths: widths, rows: 2)
    #expect(rows.flatMap { $0 }.count == RateConstants.maxWatchlistCount)
    let difference = abs(load(rows[0], widths) - load(rows[1], widths))
    let widest = widths.max() ?? 0
    #expect(difference <= widest)
}
