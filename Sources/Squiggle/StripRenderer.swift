import AppKit
import QuartzCore

/// Turns a `StripLayout` into layers, and owns the arithmetic behind the one
/// animation the app runs.
///
/// Split into pure statics and layer-building because the arithmetic is the
/// part that can be wrong in a way a test can see. Whether Core Animation
/// draws a `CATextLayer` where it was told to is not this project's problem;
/// whether a 480pt strip at 24pt/s takes 20 seconds to cross is.
enum StripRenderer {
    /// Capped at 30 fps by spec §5.1 — on a ProMotion display an unconstrained
    /// range lets Core Animation choose 120, which this exists to prevent.
    ///
    /// The floor is 30 as well, and that is a change from the original 8. A
    /// low floor is licence for the compositor to drop frames under load, and
    /// dropped frames in a linear marquee read as a stutter rather than as a
    /// smooth slowdown — the user reported the strip "jerks". That diagnosis
    /// is *suspected and unmeasured*: the frame pacing was never instrumented,
    /// and the separate, certain defect (the rebuild snapping the strip back
    /// to its first character, fixed by `phase`/`rebuiltBeginTime` above) may
    /// account for the whole report on its own. 30 fps of text that moves a
    /// pixel a frame costs little enough that removing the licence is the
    /// cheaper bet either way.
    static let frameRate = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)

    struct Metrics {
        let rowCount: Int
        let font: NSFont
        let rowHeight: Double
    }

    /// R135: monospaced digits, so a price changing from `178.11` to `178.88`
    /// does not shift everything to its right.
    static func metrics(rows: Int, barHeight: Double) -> Metrics {
        // The same 1...2 clamp `RowSplitter.split` applies. Duplicated rather
        // than shared because `RowSplitter` lives in TickerCore and takes no
        // interest in fonts; `StripRendererTests` asserts the two agree.
        let rowCount = max(1, min(rows, 2))
        let size: CGFloat = rowCount == 1 ? 13 : 10
        return Metrics(
            rowCount: rowCount,
            font: .monospacedDigitSystemFont(ofSize: size, weight: .regular),
            rowHeight: barHeight / Double(rowCount))
    }

    /// How long one full lap takes. Floored on both terms: Core Animation
    /// accepts a zero or infinite duration and renders a frozen strip, which
    /// spec §5.2 says explicitly must never happen — "a frozen bar reads as a
    /// crash".
    static func duration(contentWidth: Double, pointsPerSecond: Double) -> Double {
        let speed = max(1, pointsPerSecond)
        let width = max(1, contentWidth)
        return width / speed
    }

    /// Spec §5.2's first stopping condition. Equal widths fit: a strip exactly
    /// as wide as its window has nothing left to reveal.
    static func fits(contentWidth: Double, visibleWidth: Double) -> Bool {
        contentWidth <= visibleWidth
    }

    /// The resume half of the `speed = 0` / `timeOffset` recipe. Pushing the
    /// layer's begin time forward by the paused interval is what makes resume
    /// seamless — the animation carries on from where it stopped rather than
    /// snapping back to its origin.
    ///
    /// Clamped at zero. A begin time in the future means the layer renders
    /// nothing until that time arrives, and the only way to get one is a
    /// backwards jump in the media clock, which is not worth a blank menu bar.
    static func resumedBeginTime(nowInLayerTime: Double, pausedOffset: Double) -> Double {
        max(0, nowInLayerTime - pausedOffset)
    }

    /// How far through its lap a repeating animation is, as a fraction in
    /// `[0, 1)`. `TickerView.apply` reads this from the row it is about to
    /// discard and hands it to the row that replaces it.
    ///
    /// A *fraction*, not an offset in seconds, because the strip it is carried
    /// onto is rarely the same width: a price gaining a digit changes
    /// `contentWidth` and so changes the lap. The fraction keeps the strip in
    /// the same proportional place; an absolute offset would land somewhere
    /// arbitrary on the new one.
    static func phase(localTime: Double, beginTime: Double, duration: Double) -> Double {
        guard duration > 0, localTime.isFinite, beginTime.isFinite else { return 0 }
        let elapsed = localTime - beginTime
        guard elapsed > 0 else { return 0 }
        return elapsed.truncatingRemainder(dividingBy: duration) / duration
    }

    /// The begin time a rebuilt row needs so it picks up its lap where the row
    /// it replaces left off: far enough in the past that its first drawn frame
    /// is the frame already on screen.
    ///
    /// Not clamped at zero, unlike `resumedBeginTime`. The media clock is
    /// uptime in seconds, so a phase worth less than one lap cannot push this
    /// negative on any machine awake long enough to have launched the app.
    static func rebuiltBeginTime(nowInLayerTime: Double,
                                 phase: Double,
                                 duration: Double) -> Double {
        nowInLayerTime - phase * duration
    }

    /// One row's text, laid out once if the row fits its window and twice if
    /// it doesn't. The second copy is what makes the wrap seamless: by the
    /// time the first copy has scrolled fully out to the left, the second is
    /// exactly where the first began, so the animation can snap back to zero
    /// with nothing visibly changing. A row that already fits is never
    /// animated, so a second copy there would just be duplicate text sitting
    /// in the strip with nothing to wrap into.
    ///
    /// `copies` is not a second opinion: `TickerView.apply` runs the `fits`
    /// check once and hands the answer to both this function and `animate`,
    /// which does not re-check it. So the tiling here and the decision to
    /// animate cannot disagree about whether this row moves.
    ///
    /// `Row.contentWidth` already includes the trailing gap (Task 5), which
    /// is what keeps the join from butting the last symbol against the first.
    static func rowLayer(_ row: StripLayout.Row,
                         metrics: Metrics,
                         scale: Double,
                         copies: Int,
                         color: (ColorRole) -> CGColor) -> CALayer {
        // A caller asking for fewer than one copy is asking for an empty row,
        // which is never the intent — one copy, undrawn tiling, is the
        // cheapest safe answer.
        let copyCount = max(1, copies)

        let container = CALayer()
        container.contentsScale = scale
        container.bounds = CGRect(x: 0, y: 0,
                                  width: row.contentWidth * Double(copyCount),
                                  height: metrics.rowHeight)
        container.anchorPoint = CGPoint(x: 0, y: 0)

        // Text sits on the baseline, not at the top of its box, so the
        // vertical centring is done against the font's own ascent and descent
        // rather than against the layer height.
        let textHeight = Double(metrics.font.ascender - metrics.font.descender)
        let y = (metrics.rowHeight - textHeight) / 2

        for copy in 0..<copyCount {
            let shift = Double(copy) * row.contentWidth
            for segment in row.segments {
                let text = CATextLayer()
                text.contentsScale = scale
                text.string = segment.text
                text.font = metrics.font
                text.fontSize = metrics.font.pointSize
                text.foregroundColor = color(segment.role)
                text.alignmentMode = .left
                // A ticker never wraps and never ellipsises: the strip is as
                // wide as it needs to be and the window is what clips it.
                text.isWrapped = false
                text.truncationMode = .none
                text.frame = CGRect(x: segment.x + shift, y: y,
                                    width: segment.width, height: textHeight)
                container.addSublayer(text)
            }
        }
        return container
    }
}
