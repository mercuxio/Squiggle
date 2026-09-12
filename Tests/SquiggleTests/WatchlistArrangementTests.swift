import TickerCore
import Testing
@testable import Squiggle

/// The drag's rules, exercised without a window server or a mouse.
///
/// `WatchlistColumnsView` contributes geometry — which row is under a point,
/// where a gap opens — and `WatchlistArrangement` contributes every decision
/// that outlives the gesture. Everything the user can lose by a wrong drop is
/// therefore testable here: what the watchlist becomes, and where the boundary
/// between the two menu-bar rows now falls.

private func sym(_ raw: String) throws -> Symbol {
    try #require(Symbol(raw))
}

private func watchlist() throws -> [Symbol] {
    [try sym("AAPL"), try sym("MSFT"), try sym("VOD.L"), try sym("BTC-USD")]
}

@Test func aNilBoundaryIsOneColumn() throws {
    // The user's rule: "if only 1 row is enable, then just 1 column".
    let symbols = try watchlist()
    let arrangement = WatchlistArrangement(symbols: symbols, rowOneCount: nil)
    #expect(arrangement.columns == [symbols])
    #expect(!arrangement.isTwoColumn)
    #expect(arrangement.rowOneCount == nil)
}

@Test func aBoundarySplitsTheLeadingSymbolsIntoTheFirstColumn() throws {
    let symbols = try watchlist()
    let arrangement = WatchlistArrangement(symbols: symbols, rowOneCount: 3)
    #expect(arrangement.columns == [Array(symbols.prefix(3)), [symbols[3]]])
    #expect(arrangement.rowOneCount == 3)
    #expect(arrangement.flattened == symbols)
}

@Test func aBoundaryPastTheEndClampsRatherThanCrashing() throws {
    // `Store.rowOneCount` is a hand-editable number in a file the support
    // policy invites users to edit. A boundary of 99 must not trap on
    // `prefix`'s sibling, `dropFirst`, nor produce a column the watchlist
    // cannot fill.
    let symbols = try watchlist()
    let over = WatchlistArrangement(symbols: symbols, rowOneCount: 99)
    #expect(over.columns == [symbols, []])
    #expect(over.rowOneCount == symbols.count)

    let under = WatchlistArrangement(symbols: symbols, rowOneCount: -4)
    #expect(under.columns == [[], symbols])
    #expect(under.rowOneCount == 0)
}

@Test func zeroInRowOneIsNotTheSameAsNeverArranged() throws {
    // `nil` means "the balancer may still choose"; `0` means the user put
    // everything in row 2. Collapsing the two would silently re-balance a
    // watchlist somebody arranged by hand.
    let symbols = try watchlist()
    let arranged = WatchlistArrangement(symbols: symbols, rowOneCount: 0)
    #expect(arranged.isTwoColumn)
    #expect(arranged.rowOneCount == 0)
}

@Test func depthIsTheTallerColumn() throws {
    let symbols = try watchlist()
    #expect(WatchlistArrangement(symbols: symbols, rowOneCount: 1).depth == 3)
    #expect(WatchlistArrangement(symbols: symbols, rowOneCount: nil).depth == 4)
    #expect(WatchlistArrangement(symbols: [], rowOneCount: nil).depth == 0)
}

@Test func locationFindsASymbolInEitherColumn() throws {
    let symbols = try watchlist()
    let arrangement = WatchlistArrangement(symbols: symbols, rowOneCount: 2)
    let first = try #require(arrangement.location(of: symbols[0]))
    let third = try #require(arrangement.location(of: symbols[2]))
    #expect(first == (column: 0, row: 0))
    #expect(third == (column: 1, row: 0))
    let absent = arrangement.location(of: try sym("NVDA"))
    #expect(absent == nil)
}

@Test func removingLiftsTheSymbolOutOfWhicheverColumnHeldIt() throws {
    let symbols = try watchlist()
    let arrangement = WatchlistArrangement(symbols: symbols, rowOneCount: 2)
    let lifted = arrangement.removing(symbols[2])
    #expect(lifted.columns == [[symbols[0], symbols[1]], [symbols[3]]])
    // Still two columns: a drag that empties a column must not turn the panel
    // into a one-column panel half-way through the gesture.
    #expect(lifted.isTwoColumn)
}

@Test func movingWithinAColumnReordersTheWatchlist() throws {
    let symbols = try watchlist()
    let arrangement = WatchlistArrangement(symbols: symbols, rowOneCount: 3)
    let moved = arrangement.moving(symbols[2], toColumn: 0, row: 0)
    #expect(moved.columns == [[symbols[2], symbols[0], symbols[1]], [symbols[3]]])
    #expect(moved.rowOneCount == 3, "moving inside row 1 must not move the boundary")
    #expect(moved.flattened == [symbols[2], symbols[0], symbols[1], symbols[3]])
}

@Test func movingAcrossColumnsMovesTheBoundaryWithIt() throws {
    // The one integer has to absorb a cross-column drag: dragging the last
    // symbol of row 1 into row 2 is a boundary of 3 becoming a boundary of 2.
    let symbols = try watchlist()
    let arrangement = WatchlistArrangement(symbols: symbols, rowOneCount: 3)
    let moved = arrangement.moving(symbols[2], toColumn: 1, row: 0)
    #expect(moved.columns == [[symbols[0], symbols[1]], [symbols[2], symbols[3]]])
    #expect(moved.rowOneCount == 2)
    #expect(moved.flattened == [symbols[0], symbols[1], symbols[2], symbols[3]])
}

@Test func aDropIndexIsMeasuredAgainstTheGappedColumns() throws {
    // What the view does per mouse event: lift, then drop at the row the user
    // is pointing at *in the list they can see*. Since the gapped list is what
    // the index addresses, no correction for the hole is needed anywhere.
    let symbols = try watchlist()
    let settled = WatchlistArrangement(symbols: symbols, rowOneCount: 4)
    let gapped = settled.removing(symbols[0])
    #expect(gapped.columns[0] == [symbols[1], symbols[2], symbols[3]])
    let dropped = settled.moving(symbols[0], toColumn: 0, row: 2)
    #expect(dropped.columns[0] == [symbols[1], symbols[2], symbols[0], symbols[3]])
}

@Test func aDropPastTheEndOfAColumnLandsAtItsEnd() throws {
    // A pointer dragged three points below the last row is the user saying
    // "put it at the bottom", not "cancel the gesture".
    let symbols = try watchlist()
    let arrangement = WatchlistArrangement(symbols: symbols, rowOneCount: 2)
    let moved = arrangement.moving(symbols[0], toColumn: 1, row: 99)
    #expect(moved.columns == [[symbols[1]], [symbols[2], symbols[3], symbols[0]]])
    #expect(moved.rowOneCount == 1)
}

@Test func aDropPastTheLastColumnLandsInTheLastColumn() throws {
    let symbols = try watchlist()
    let two = WatchlistArrangement(symbols: symbols, rowOneCount: 2)
    let past = two.moving(symbols[0], toColumn: 7, row: 0)
    #expect(past.columns == [[symbols[1]], [symbols[0], symbols[2], symbols[3]]])

    // And a one-column arrangement has nowhere else to put it: a drag to the
    // right of a single column is still a reorder within that column.
    let one = WatchlistArrangement(symbols: symbols, rowOneCount: nil)
    let clamped = one.moving(symbols[3], toColumn: 1, row: 0)
    #expect(clamped.columns == [[symbols[3], symbols[0], symbols[1], symbols[2]]])
    #expect(clamped.rowOneCount == nil)
}

@Test func everyDropKeepsTheSameSetOfSymbols() throws {
    // The property `StatusItemController.applyArrangement` guards on before it
    // writes anything to the store. A drop that gained or lost a symbol would
    // cost the user a watchlist entry, so it is worth pinning across the whole
    // grid of targets rather than at the one or two the examples above reach.
    let symbols = try watchlist()
    let arrangement = WatchlistArrangement(symbols: symbols, rowOneCount: 2)
    for symbol in symbols {
        for column in -1...2 {
            for row in -1...5 {
                let moved = arrangement.moving(symbol, toColumn: column, row: row)
                #expect(Set(moved.flattened) == Set(symbols))
                #expect(moved.flattened.count == symbols.count)
            }
        }
    }
}
