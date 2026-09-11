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
               mode: MotionMode,
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

            animate(rowLayer, row: row, visibleWidth: visibleWidth,
                    mode: mode, pointsPerSecond: pointsPerSecond)
        }
    }

    /// Spec §5.2's first stopping condition is checked here and in one place
    /// only, because it is the same rule in both modes: content that already
    /// fits gets no animation at all — removed, not paused, not slowed.
    private func animate(_ rowLayer: CALayer,
                         row: StripLayout.Row,
                         visibleWidth: Double,
                         mode: MotionMode,
                         pointsPerSecond: Double) {
        guard StripRenderer.fits(contentWidth: row.contentWidth,
                                 visibleWidth: visibleWidth) == false
        else { return }

        switch mode {
        case .scroll:
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

        case .step:
            let offsets = MotionPolicy.pageOffsets(contentWidth: row.contentWidth,
                                                   visibleWidth: visibleWidth)
            let total = MotionPolicy.stepSeconds * Double(offsets.count)

            // Discrete, so the position never interpolates: the layer is at
            // page N and then it is at page N+1, with nothing in between for
            // the eye to track. That is the whole point of Step.
            let move = CAKeyframeAnimation(keyPath: "position.x")
            move.values = offsets
            move.keyTimes = MotionPolicy.pageKeyTimes(pageCount: offsets.count)
                .map { NSNumber(value: $0) }
            move.calculationMode = .discrete
            move.duration = total
            move.repeatCount = .infinity

            let frames = MotionPolicy.fadeKeyframes(pageCount: offsets.count)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = frames.values
            fade.keyTimes = frames.keyTimes.map { NSNumber(value: $0) }
            fade.duration = total
            fade.repeatCount = .infinity

            // Both under one group so `pause()` stops them together. Two
            // independent animations paused a frame apart would leave the
            // text half-faded on a page it had already left.
            //
            // The frame rate cap goes on the group and not on its children:
            // the group is what Core Animation schedules, and a range set on
            // a grouped child is not documented to be honoured.
            let both = CAAnimationGroup()
            both.animations = [move, fade]
            both.duration = total
            both.repeatCount = .infinity
            both.preferredFrameRateRange = StripRenderer.frameRate
            rowLayer.add(both, forKey: "step")
        }
    }

    /// The ticker is a picture, not a control.
    ///
    /// A layer-backed `NSView` sitting inside `NSStatusBarButton` wins the hit
    /// test over the button beneath it, and `NSView`'s default `mouseDown` does
    /// nothing — so without this the strip would swallow every click and the
    /// dropdown would never open. Returning `nil` makes the view invisible to
    /// the mouse and leaves the button to do what a status item button does.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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
