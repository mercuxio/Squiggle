import Foundation
import TickerCore

/// The watchlist as the dropdown shows it: one column, or two that mirror the
/// menu bar's two marquee rows.
///
/// A value, and deliberately the only thing in the drag that makes a decision.
/// Everything a drop changes — which column a symbol lands in, where in that
/// column, what the flat watchlist becomes and where its row boundary now
/// falls — is settled here, so the tracking loop in the view is left with
/// nothing but geometry, and every rule worth testing can be exercised without
/// a window server or a mouse.
struct WatchlistArrangement: Equatable {
    /// One array per column, in display order. Exactly one or two of them.
    private(set) var columns: [[Symbol]]

    /// - Parameter rowOneCount: the boundary from `Store.rowOneCount`. `nil`
    ///   means one column, which is what the user asked for when only one
    ///   menu-bar row is enabled: "if only 1 row is enable, then just 1
    ///   column".
    init(symbols: [Symbol], rowOneCount: Int?) {
        guard let boundary = rowOneCount else {
            columns = [symbols]
            return
        }
        let cut = min(max(boundary, 0), symbols.count)
        columns = [Array(symbols.prefix(cut)), Array(symbols.dropFirst(cut))]
    }

    private init(columns: [[Symbol]]) {
        self.columns = columns
    }

    /// The watchlist as one list — column 1 then column 2, which is the order
    /// `Store.symbols` holds and the order the boundary below indexes into.
    var flattened: [Symbol] { columns.flatMap { $0 } }

    /// What to write to `Store.rowOneCount`; `nil` when there is no boundary to
    /// record because there is only one column.
    var rowOneCount: Int? { columns.count > 1 ? columns[0].count : nil }

    var isTwoColumn: Bool { columns.count > 1 }

    /// The number of rows the taller column has — the height both columns are
    /// laid out to, so the panel does not resize mid-drag.
    var depth: Int { columns.map(\.count).max() ?? 0 }

    func location(of symbol: Symbol) -> (column: Int, row: Int)? {
        for (column, entries) in columns.enumerated() {
            if let row = entries.firstIndex(of: symbol) { return (column, row) }
        }
        return nil
    }

    /// This arrangement with `symbol` lifted out — what the columns look like
    /// while it is under the pointer and the rows have parted around it.
    ///
    /// The drop index is measured against *this*, which is why the insertion
    /// below needs no correction for the hole the symbol left behind: the row
    /// the user is pointing at is a row of the gapped list they can see.
    func removing(_ symbol: Symbol) -> WatchlistArrangement {
        WatchlistArrangement(columns: columns.map { $0.filter { $0 != symbol } })
    }

    /// `symbol` dropped into `column` at `row`.
    ///
    /// Both are clamped rather than trusted. A pointer dragged off the bottom
    /// of a short column, or past the right edge of the panel, is the user
    /// saying "the end of that one" — the alternative is a gesture that
    /// silently does nothing because it left the frame by three points.
    func moving(_ symbol: Symbol, toColumn column: Int, row: Int) -> WatchlistArrangement {
        var lifted = removing(symbol).columns
        let target = min(max(column, 0), lifted.count - 1)
        let index = min(max(row, 0), lifted[target].count)
        lifted[target].insert(symbol, at: index)
        return WatchlistArrangement(columns: lifted)
    }
}
