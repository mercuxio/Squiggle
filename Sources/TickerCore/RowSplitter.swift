/// Divides one watchlist across the menu bar's one or two marquee rows.
///
/// The algorithm is greedy least-loaded assignment: walk the items in order
/// and give each to whichever row is currently narrowest. That is not the
/// optimal partition — optimal is NP-hard — but for the ≤20 items Squiggle
/// allows it lands within one item's width of optimal, which is the best any
/// split can do when a single item cannot be divided.
///
/// Walking in order is what keeps each row's indices ascending, so the
/// marquee still reads left to right within a row.
public enum RowSplitter {
    public static func split(widths: [Double], rows requestedRows: Int) -> [[Int]] {
        let rows = max(1, min(requestedRows, 2))
        var buckets = [[Int]](repeating: [], count: rows)
        guard rows > 1 else {
            buckets[0] = Array(widths.indices)
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
