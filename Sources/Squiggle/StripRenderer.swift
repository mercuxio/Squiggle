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
    /// Capped at 30 fps by spec §5.1. The minimum is deliberately far below
    /// it: on a ProMotion display an unconstrained range lets Core Animation
    /// choose 120, and the floor lets it choose *less* than 30 when the
    /// system is busy, which for scrolling text nobody is reading is a
    /// trade the app should take every time.
    static let frameRate = CAFrameRateRange(minimum: 8, maximum: 30, preferred: 30)

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

    /// One row's text, laid out twice end to end. The second copy is what
    /// makes the wrap seamless: by the time the first copy has scrolled fully
    /// out to the left, the second is exactly where the first began, so the
    /// animation can snap back to zero with nothing visibly changing.
    ///
    /// `Row.contentWidth` already includes the trailing gap (Task 5), which
    /// is what keeps the join from butting the last symbol against the first.
    static func rowLayer(_ row: StripLayout.Row,
                         metrics: Metrics,
                         scale: Double,
                         color: (ColorRole) -> CGColor) -> CALayer {
        let container = CALayer()
        container.contentsScale = scale
        container.bounds = CGRect(x: 0, y: 0,
                                  width: row.contentWidth * 2,
                                  height: metrics.rowHeight)
        container.anchorPoint = CGPoint(x: 0, y: 0)

        // Text sits on the baseline, not at the top of its box, so the
        // vertical centring is done against the font's own ascent and descent
        // rather than against the layer height.
        let textHeight = Double(metrics.font.ascender - metrics.font.descender)
        let y = (metrics.rowHeight - textHeight) / 2

        for copy in 0..<2 {
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
