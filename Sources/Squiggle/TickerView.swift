import AppKit
import QuartzCore

/// The view the status item button hosts. It owns the row layers and the one
/// animation, and nothing else: no timers, no data, no opinions about when to
/// stop — Task 10 decides that and calls `pause()`.
@MainActor
final class TickerView: NSView {
    private var rowLayers: [CALayer] = []
    private(set) var isPaused = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The strip is wider than the window by design; this is what turns
        // that from a bug into a marquee.
        layer?.masksToBounds = true
        // Rows are numbered top-down by `RowSplitter`, and flipping the
        // container's geometry is what makes row 0 draw at the top instead of
        // needing every y computed backwards from the height.
        layer?.isGeometryFlipped = true
    }

    // `NSView` declares this required; nothing in Squiggle loads a nib, so
    // reaching it means something is very wrong rather than something needs
    // handling.
    required init?(coder: NSCoder) {
        fatalError("Squiggle builds its views in code")
    }

    /// Replaces the strip wholesale. Called on every successful refresh and on
    /// every settings change, which at one refresh every few minutes is rare
    /// enough that rebuilding beats diffing.
    func apply(layout: StripLayout,
               metrics: StripRenderer.Metrics,
               visibleWidth: Double,
               pointsPerSecond: Double,
               color: (ColorRole) -> CGColor) {
        guard let host = layer else { return }
        // Backing scale, so text is drawn for this display rather than at 1x
        // and stretched. `window` is nil before the view is installed; 2 is
        // the right guess on every Mac sold since 2012, and the next `apply`
        // after installation corrects it either way.
        let scale = Double(window?.backingScaleFactor ?? 2)

        for existing in rowLayers { existing.removeFromSuperlayer() }
        rowLayers = []
        isPaused = false

        for (index, row) in layout.rows.enumerated() {
            let rowLayer = StripRenderer.rowLayer(row, metrics: metrics,
                                                  scale: scale, color: color)
            rowLayer.position = CGPoint(x: 0, y: Double(index) * metrics.rowHeight)
            host.addSublayer(rowLayer)
            rowLayers.append(rowLayer)

            // Spec §5.2: content that already fits gets no animation at all —
            // removed, not paused, not slowed. Each row is judged on its own
            // width, so a short row stays still while a long one scrolls.
            guard StripRenderer.fits(contentWidth: row.contentWidth,
                                     visibleWidth: visibleWidth) == false
            else { continue }

            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = 0
            slide.toValue = -row.contentWidth
            slide.duration = StripRenderer.duration(contentWidth: row.contentWidth,
                                                    pointsPerSecond: pointsPerSecond)
            slide.repeatCount = .infinity
            // Linear, and it has to be: the default ease-in-out would make the
            // strip visibly accelerate and brake once per lap.
            slide.timingFunction = CAMediaTimingFunction(name: .linear)
            slide.preferredFrameRateRange = StripRenderer.frameRate
            rowLayer.add(slide, forKey: "scroll")
        }
    }

    /// Spec §5.2: `speed = 0` with the offset captured, never a removal.
    func pause() {
        guard isPaused == false else { return }
        isPaused = true
        for rowLayer in rowLayers {
            let stoppedAt = rowLayer.convertTime(CACurrentMediaTime(), from: nil)
            rowLayer.speed = 0
            rowLayer.timeOffset = stoppedAt
        }
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        for rowLayer in rowLayers {
            let pausedOffset = rowLayer.timeOffset
            rowLayer.speed = 1
            rowLayer.timeOffset = 0
            rowLayer.beginTime = 0
            let now = rowLayer.convertTime(CACurrentMediaTime(), from: nil)
            rowLayer.beginTime = StripRenderer.resumedBeginTime(nowInLayerTime: now,
                                                                pausedOffset: pausedOffset)
        }
    }
}
