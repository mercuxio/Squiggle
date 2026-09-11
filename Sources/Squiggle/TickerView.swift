import AppKit
import QuartzCore

/// The view the status item button hosts. It owns the row layers and the one
/// animation, and nothing else: no timers, no data, no opinions about when to
/// stop — Task 10 decides that and tells this view. It is told two ways, and
/// both are needed: `pause()` / `resume()` for a genuine lock, screensaver,
/// display-sleep or occlusion transition, and `apply(paused:)` for every
/// re-render that happens *during* one. Without the second, a refresh tick or
/// an appearance change behind a locked screen would rebuild the strip
/// animating and nothing would arrive to stop it again — `PauseMonitor` only
/// reports changes, and nothing changes until the user comes back.
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
    ///
    /// - Parameter paused: the state the rebuilt strip must end in. A rebuild
    ///   starts from nothing, so the old layers' `speed = 0` goes with them —
    ///   the caller passes the current pause state and each new row is frozen
    ///   as it is built, rather than started and stopped a moment later.
    ///   `isPaused` reports the state this argument asked for.
    func apply(layout: StripLayout,
               metrics: StripRenderer.Metrics,
               visibleWidth: Double,
               mode: MotionMode,
               pointsPerSecond: Double,
               paused: Bool,
               color: (ColorRole) -> CGColor) {
        guard let host = layer else { return }
        // Backing scale, so text is drawn for this display rather than at 1x
        // and stretched. `window` is nil before the view is installed; 2 is
        // the right guess on every Mac sold since 2012, and the next `apply`
        // after installation corrects it either way.
        let scale = Double(window?.backingScaleFactor ?? 2)

        // Read before the teardown, because afterwards there is nothing left
        // to ask. A rebuilt row that starts at phase zero snaps the marquee
        // back to its first character — and `apply` runs on every refresh,
        // every appearance change, every Reduce Motion toggle and every
        // settings edit, which is what the user sees as the strip skipping.
        let key = Self.animationKey(for: mode)
        let carried = rowLayers.map { phase(of: $0, key: key) }

        for existing in rowLayers { existing.removeFromSuperlayer() }
        rowLayers = []
        isPaused = paused

        for (index, row) in layout.rows.enumerated() {
            // Spec §5.2's first stopping condition, decided once here and
            // threaded to both the layer builder and the animation: content
            // that already fits gets one copy and no animation, rather than
            // two tiled copies with the animation that would have made the
            // tiling invisible simply not there.
            let animated = StripRenderer.fits(contentWidth: row.contentWidth,
                                              visibleWidth: visibleWidth) == false
            let rowLayer = StripRenderer.rowLayer(row, metrics: metrics, scale: scale,
                                                  copies: animated ? 2 : 1, color: color)
            rowLayer.position = CGPoint(x: 0, y: Double(index) * metrics.rowHeight)
            host.addSublayer(rowLayer)
            rowLayers.append(rowLayer)

            // A row that has no predecessor — first render, or a switch from
            // one row to two — starts at the beginning of its lap, which is
            // the only honest answer when there is nothing to inherit.
            let inherited = index < carried.count ? carried[index] : 0
            animate(rowLayer, row: row, animated: animated, visibleWidth: visibleWidth,
                    mode: mode, pointsPerSecond: pointsPerSecond, startingAt: inherited)
            // Frozen here rather than after the loop, so a row is never live
            // for even the remainder of this rebuild. The animation stays
            // attached — spec §5.2 is `speed = 0`, never a removal — so the
            // strip resumes from where it stands when the screen comes back.
            if paused { freeze(rowLayer) }
        }
    }

    /// Spec §5.2's first stopping condition is decided once, in `apply`, and
    /// passed in as `animated` — content that already fits gets no animation
    /// at all, removed rather than paused or slowed. It is not re-checked
    /// here: `apply` already used it to decide how many copies `rowLayer`
    /// drew, and a second `fits` call here could only ever agree or disagree
    /// with that, never usefully override it.
    ///
    /// - Parameter startingAt: the fraction of a lap the row this one replaces
    ///   had already run. Both branches set `beginTime` explicitly rather than
    ///   leaving it at zero: an unset begin time means "now" to Core Animation
    ///   but reads back as `0`, and `phase(of:key:)` has to read it back on
    ///   the next rebuild.
    private func animate(_ rowLayer: CALayer,
                         row: StripLayout.Row,
                         animated: Bool,
                         visibleWidth: Double,
                         mode: MotionMode,
                         pointsPerSecond: Double,
                         startingAt phase: Double) {
        guard animated else { return }
        let now = rowLayer.convertTime(CACurrentMediaTime(), from: nil)

        switch mode {
        case .scroll:
            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = 0
            slide.toValue = -row.contentWidth
            let lap = StripRenderer.duration(contentWidth: row.contentWidth,
                                             pointsPerSecond: pointsPerSecond)
            slide.duration = lap
            slide.beginTime = StripRenderer.rebuiltBeginTime(nowInLayerTime: now,
                                                             phase: phase,
                                                             duration: lap)
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
            both.beginTime = StripRenderer.rebuiltBeginTime(nowInLayerTime: now,
                                                            phase: phase,
                                                            duration: total)
            both.repeatCount = .infinity
            both.preferredFrameRateRange = StripRenderer.frameRate
            rowLayer.add(both, forKey: "step")
        }
    }

    /// The key each mode's animation is filed under. One function rather than
    /// two string literals at opposite ends of the file: `animate` adds under
    /// this key and `phase(of:key:)` looks it up, and a typo in either would
    /// show only as a strip that silently stopped carrying its place.
    private static func animationKey(for mode: MotionMode) -> String {
        switch mode {
        case .scroll: return "scroll"
        case .step: return "step"
        }
    }

    /// How far through its lap `rowLayer` is, or zero if it is not running the
    /// animation we are about to replace.
    ///
    /// The key has to match: a rebuild that switches Scroll to Step finds no
    /// `scroll` animation and starts the new one from the beginning, which is
    /// right — a phase measured in laps of a marquee means nothing to a
    /// sequence of discrete pages.
    ///
    /// `convertTime` is correct for a frozen row too: a layer at `speed = 0`
    /// converts every wall-clock time to its stored `timeOffset`, so a strip
    /// rebuilt behind a locked screen keeps the place it was paused at.
    private func phase(of rowLayer: CALayer, key: String) -> Double {
        guard let animation = rowLayer.animation(forKey: key) else { return 0 }
        return StripRenderer.phase(
            localTime: rowLayer.convertTime(CACurrentMediaTime(), from: nil),
            beginTime: animation.beginTime,
            duration: animation.duration)
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
        for rowLayer in rowLayers { freeze(rowLayer) }
    }

    /// One layer's half of the pause. Shared with `apply`, so a row built
    /// during a pause is stopped by exactly the code that stops a row when
    /// the pause arrives — two spellings of `speed = 0` would eventually
    /// disagree about the offset, and the disagreement would show as a jump
    /// on the next unlock.
    private func freeze(_ rowLayer: CALayer) {
        let stoppedAt = rowLayer.convertTime(CACurrentMediaTime(), from: nil)
        rowLayer.speed = 0
        rowLayer.timeOffset = stoppedAt
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
