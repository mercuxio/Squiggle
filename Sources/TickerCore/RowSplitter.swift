/// Divides one watchlist across the menu bar's one or two marquee rows.
///
/// Two ways in, and which one applies is the user's choice rather than this
/// type's. `manualRowOneCount` is an arrangement the user made by hand, in
/// which case this honours it exactly; `nil` means nobody has ever arranged
/// this watchlist and the balancer below picks the split.
///
/// The balancer is greedy least-loaded assignment: walk the items in order and
/// give each to whichever row is currently narrowest. That is not the optimal
/// partition — optimal is NP-hard — but for the ≤20 items Squiggle allows it
/// lands within one item's width of optimal, which is the best any split can
/// do when a single item cannot be divided.
///
/// Walking in order is what keeps each row's indices ascending, so the marquee
/// still reads left to right within a row.
public enum RowSplitter {
    /// - Parameter manualRowOneCount: how many *leading* items the user put in
    ///   row 1, the rest being row 2. One integer rather than a row per
    ///   symbol, because the dropdown that sets this reorders the watchlist in
    ///   the same gesture: dragging a symbol into the second column moves it
    ///   past the boundary, so every arrangement of an ordered list across two
    ///   rows is reachable, and the stored value cannot disagree with the
    ///   watchlist it describes the way a parallel array could.
    ///
    ///   Ignored when there is only one row — there is no boundary to place —
    ///   and clamped, because the store's copy is a user-editable number that
    ///   may outlive the watchlist it was written for.
    public static func split(widths: [Double], rows requestedRows: Int,
                             manualRowOneCount: Int? = nil) -> [[Int]] {
        let rows = max(1, min(requestedRows, 2))
        var buckets = [[Int]](repeating: [], count: rows)
        guard rows > 1 else {
            buckets[0] = Array(widths.indices)
            return buckets
        }

        if let manual = manualRowOneCount {
            let boundary = min(max(manual, 0), widths.count)
            buckets[0] = Array(widths.indices.prefix(boundary))
            buckets[1] = Array(widths.indices.dropFirst(boundary))
            return buckets
        }

        var loads = [Double](repeating: 0, count: rows)

        for (index, rawWidth) in widths.enumerated() {
            // A NaN in a running total makes every later comparison false,
            // which quietly degrades this to "everything in row 0". Negative
            // and infinite widths are equally meaningless. All become zero.
            let width = (rawWidth.isFinite && rawWidth > 0) ? rawWidth : 0

            // `<` rather than `<=` sends ties to the earlier row, so an
            // all-equal watchlist splits the same way on every launch.
            var target = 0
            for candidate in 1..<rows where loads[candidate] < loads[target] {
                target = candidate
            }

            buckets[target].append(index)
            loads[target] += width
        }

        return buckets
    }
}
