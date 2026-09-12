import AppKit
import TickerCore

/// The watchlist rows, laid out in one column or two, and draggable between
/// them.
///
/// Frames rather than an `NSStackView`, which is the whole reason this type
/// exists. A drag has to put a row where the pointer is — between two other
/// rows, in the other column, half-way through an animation — and a stack view
/// owns exactly that decision. Fighting it would mean removing and reinserting
/// arranged subviews on every mouse-dragged event, which is how a dragged row
/// ends up flickering between two parents.
///
/// Every decision about *what* the drag means lives in `WatchlistArrangement`.
/// What is left here is geometry: which row is under this point, where a gap
/// opens, and where each row's frame goes.
@MainActor
final class WatchlistColumnsView: NSView {
    /// What a caller must supply to make the rows draggable at all. Absent
    /// means a plain, static list — which is what the dropdown's own tests and
    /// any future read-only use want.
    struct Reordering {
        /// `Store.rowOneCount`: `nil` draws one column, a value draws two and
        /// puts that many rows in the first. The user's rule, verbatim: "if
        /// only 1 row is enable, then just 1 column".
        let rowOneCount: Int?
        /// The arrangement the user released the mouse on. Called once, at the
        /// end of a gesture that actually moved something.
        let commit: (WatchlistArrangement) -> Void
        /// `true` when a drag starts, `false` before `commit`.
        ///
        /// The controller rebuilds this whole view whenever a fetch lands, and
        /// a rebuild mid-gesture would destroy the row under the pointer and
        /// leave the tracking loop holding a view that is in no window. The
        /// controller suppresses those rebuilds while this reads `true`.
        let dragStateChanged: (Bool) -> Void
    }

    private enum Metrics {
        static let spacing: CGFloat = 2
        /// Points the pointer must travel before a press becomes a drag.
        /// Below this it is a click, and a click on a row means nothing — the
        /// only command a row carries is its trash button, which handles its
        /// own mouse events.
        static let dragThreshold: CGFloat = 3
        static let reflowDuration: TimeInterval = 0.12
    }

    private let rowHeight: CGFloat
    private let rows: [Symbol: NSView]
    private let reordering: Reordering?

    /// What is drawn right now. During a drag this is the *gapped* arrangement
    /// — the dragged symbol lifted out — so the rows the user sees are the
    /// rows the drop index is measured against.
    private var arrangement: WatchlistArrangement
    private var gap: (column: Int, row: Int)?

    /// Top-to-bottom, which is what a list is. Without this every frame would
    /// have to be computed from the bottom up, and a row added at the end
    /// would move every other row.
    override var isFlipped: Bool { true }

    /// - Parameters:
    ///   - symbols: the watchlist in `Store.symbols` order.
    ///   - rows: one view per symbol, already built. Built by the caller
    ///     because a row is the dropdown's business — this type knows only
    ///     that a row is a rectangle of a fixed height.
    init(symbols: [Symbol], rows: [Symbol: NSView], rowHeight: CGFloat,
         reordering: Reordering?) {
        self.rowHeight = rowHeight
        self.rows = rows
        self.reordering = reordering
        self.arrangement = WatchlistArrangement(symbols: symbols,
                                                rowOneCount: reordering?.rowOneCount)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for symbol in symbols {
            guard let row = rows[symbol] else { continue }
            row.translatesAutoresizingMaskIntoConstraints = true
            addSubview(row)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("R133: built in code, not a xib") }

    var columnCount: Int { arrangement.isTwoColumn ? 2 : 1 }

    // MARK: - Layout

    /// Tall enough for the longer column. Both columns are laid out to the
    /// same height so that dragging the last row out of one does not resize
    /// the panel under the pointer.
    override var intrinsicContentSize: NSSize {
        let slots = arrangement.depth + (gap == nil ? 0 : 1)
        let height = slots == 0
            ? 0
            : CGFloat(slots) * (rowHeight + Metrics.spacing) - Metrics.spacing
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func layout() {
        super.layout()
        positionRows(animated: false)
    }

    private var columnWidth: CGFloat {
        bounds.width / CGFloat(columnCount)
    }

    private func origin(column: Int, row: Int) -> NSPoint {
        NSPoint(x: CGFloat(column) * columnWidth,
                y: CGFloat(row) * (rowHeight + Metrics.spacing))
    }

    private func positionRows(animated: Bool) {
        let apply = {
            for (column, entries) in self.arrangement.columns.enumerated() {
                var slot = 0
                for symbol in entries {
                    // The gap is a slot nobody occupies: every row at or after
                    // it shifts down by one, which is the "rows part" the user
                    // chose over a drop line.
                    if let gap = self.gap, gap.column == column, gap.row == slot { slot += 1 }
                    guard let row = self.rows[symbol] else { continue }
                    let frame = NSRect(origin: self.origin(column: column, row: slot),
                                       size: NSSize(width: self.columnWidth,
                                                    height: self.rowHeight))
                    if animated {
                        row.animator().frame = frame
                    } else {
                        row.frame = frame
                    }
                    slot += 1
                }
            }
        }

        guard animated else { return apply() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Metrics.reflowDuration
            context.allowsImplicitAnimation = true
            apply()
        }
    }

    // MARK: - Hit testing

    /// Everything but the trash button belongs to the drag.
    ///
    /// Without this, a press on a row's label would be delivered to the
    /// `NSTextField` and the gesture would never reach this view's
    /// `mouseDown`. Returning `self` for the rest of the row makes the whole
    /// row a drag handle while leaving the one control on it clickable.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        var node = hit
        while let current = node {
            if current is RemoveButton { return hit }
            node = current.superview
        }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    private func symbol(at point: NSPoint) -> Symbol? {
        for (column, entries) in arrangement.columns.enumerated() {
            for (row, symbol) in entries.enumerated() {
                let frame = NSRect(origin: origin(column: column, row: row),
                                   size: NSSize(width: columnWidth, height: rowHeight))
                if frame.contains(point) { return symbol }
            }
        }
        return nil
    }

    /// Where a release at `point` would put the dragged row.
    ///
    /// Rounded rather than truncated, so the boundary the user is aiming at is
    /// the nearest one rather than the one above: dropping onto the top half of
    /// a row means "before it". `WatchlistArrangement.moving` clamps both
    /// numbers, so a pointer dragged outside the view still lands somewhere
    /// sensible instead of cancelling the gesture.
    private func dropTarget(at point: NSPoint) -> (column: Int, row: Int) {
        let column = columnCount > 1 && point.x >= columnWidth ? 1 : 0
        let step = rowHeight + Metrics.spacing
        let row = Int((point.y / step).rounded())
        let capacity = arrangement.columns.indices.contains(column)
            ? arrangement.columns[column].count
            : 0
        return (column, min(max(row, 0), capacity))
    }

    // MARK: - Dragging

    override func mouseDown(with event: NSEvent) {
        guard let reordering, let window else { return super.mouseDown(with: event) }
        let start = convert(event.locationInWindow, from: nil)
        guard let symbol = symbol(at: start), let row = rows[symbol] else {
            return super.mouseDown(with: event)
        }

        let grab = NSPoint(x: start.x - row.frame.minX, y: start.y - row.frame.minY)
        let settled = arrangement
        var target = (column: 0, row: 0)
        var moving = false

        // A classic modal tracking loop rather than a pasteboard drag session.
        // `NSDraggingSession` is for dragging *between* views and would put an
        // image of the row under the pointer, with the panel's own dismissal
        // monitors still live behind it. This gesture never leaves the panel.
        trackingLoop: while let event = window.nextEvent(matching: [.leftMouseDragged,
                                                                   .leftMouseUp]) {
            let point = convert(event.locationInWindow, from: nil)
            guard event.type != .leftMouseUp else { break trackingLoop }

            if !moving {
                guard hypot(point.x - start.x, point.y - start.y) > Metrics.dragThreshold
                else { continue }
                moving = true
                reordering.dragStateChanged(true)
                arrangement = settled.removing(symbol)
                // Above its neighbours for the rest of the gesture: the rows it
                // passes over are siblings added before it, and AppKit draws
                // siblings in order.
                addSubview(row, positioned: .above, relativeTo: nil)
            }

            let landing = dropTarget(at: point)
            let changed = landing != target
            target = landing
            gap = landing
            if changed { invalidateIntrinsicContentSize() }
            positionRows(animated: changed)
            // Never animated: the dragged row belongs under the pointer this
            // instant, not 120ms after it.
            row.frame.origin = NSPoint(x: point.x - grab.x, y: point.y - grab.y)
        }

        guard moving else { return }
        let result = arrangement.moving(symbol, toColumn: target.column, row: target.row)
        gap = nil
        arrangement = result
        invalidateIntrinsicContentSize()
        positionRows(animated: false)
        // Cleared before the commit, because the commit rebuilds the dropdown
        // and the controller drops rebuilds that arrive mid-drag.
        reordering.dragStateChanged(false)
        reordering.commit(result)
    }
}
