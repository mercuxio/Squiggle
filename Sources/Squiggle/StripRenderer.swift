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
        /// The same face and size a shade heavier, for the symbol at the head
        /// of each entry. A second font rather than a weight applied at draw
        /// time because `StatusItemController` has to measure with it too, and
        /// measurement and drawing disagreeing is a strip laid out at the
        /// wrong offsets.
        let emphasisFont: NSFont
        let rowHeight: Double

        /// The same metrics with both fonts a fraction of their size, for a
        /// Flip card that has to shrink to fit (see `cardShrink`). The row
        /// height is deliberately untouched: the card still occupies the whole
        /// menu bar, and `rowLayer` centres the smaller text inside it against
        /// the font's own ascent and descent.
        func scaled(by factor: Double) -> Metrics {
            Metrics(
                rowCount: rowCount,
                font: .monospacedDigitSystemFont(
                    ofSize: font.pointSize * factor, weight: .regular),
                emphasisFont: .monospacedDigitSystemFont(
                    ofSize: emphasisFont.pointSize * factor, weight: .semibold),
                rowHeight: rowHeight)
        }
    }

    /// How small a Flip card's text may get before clipping is the better
    /// answer. Eight points is about the floor for the menu bar: below it the
    /// digits stop being readable at a glance, which is the only thing the
    /// card is for.
    static let minimumCardFontSize: Double = 8

    /// R135: monospaced digits, so a price changing from `178.11` to `178.88`
    /// does not shift everything to its right.
    static func metrics(rows: Int, barHeight: Double) -> Metrics {
        // The same 1...2 clamp `RowSplitter.split` applies. Duplicated rather
        // than shared because `RowSplitter` lives in TickerCore and takes no
        // interest in fonts; `StripRendererTests` asserts the two agree.
        let rowCount = max(1, min(rows, 2))
        // 12, not the 13 this started at: at full menu bar height 13pt sat
        // heavier than the clock beside it. One point down matches the rest
        // of the bar and costs no legibility. Flip comes through here too —
        // a deck is one row by definition — so the two share the figure.
        let size: CGFloat = rowCount == 1 ? 12 : 10
        return Metrics(
            rowCount: rowCount,
            font: .monospacedDigitSystemFont(ofSize: size, weight: .regular),
            // `.semibold`, not `.bold`: at 10pt in a two-row strip a full bold
            // fills its counters and reads as a smudge rather than as weight.
            emphasisFont: .monospacedDigitSystemFont(ofSize: size, weight: .semibold),
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

        // An untiled row has nothing after its last entry, so the interpunct
        // `StripLayout` put in the trailing gap would hang off the end with
        // nothing on its right to divide. Dropped here rather than left out
        // of the layout, because whether a row tiles is the caller's answer
        // (`fits`) and the layout is built before anyone has asked.
        var segments = row.segments
        if copyCount == 1, segments.last?.role == ColorRole.separator {
            segments.removeLast()
        }

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
            for segment in segments {
                let text = CATextLayer()
                text.contentsScale = scale
                let font = segment.emphasized ? metrics.emphasisFont : metrics.font
                text.string = segment.text
                text.font = font
                text.fontSize = font.pointSize
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

    /// One Flip card: the same layers a row is made of, hung so it can turn.
    ///
    /// Two differences from a row, and both are about the rotation. The anchor
    /// moves to the layer's vertical middle, so the card turns about its own
    /// centreline rather than swinging from the top edge of the menu bar — the
    /// `position` moves by the same half-height, which leaves the card drawn
    /// exactly where a row would be. And it starts fully transparent: every
    /// card in the deck is built at once and its own keyframes decide when it
    /// is on screen, so a card built visible would flash for the frame before
    /// the animation's first value lands.
    ///
    /// One copy, never two: tiling exists to hide a marquee's wrap, and a card
    /// does not scroll.
    ///
    /// `visibleWidth` is the only thing a card needs the window for: it is
    /// centred in it rather than left-aligned. A marquee has no use for
    /// centring — its content is wider than the window by definition — but a
    /// deck of one symbol is narrower than the status item almost always, and
    /// a single short card pinned to the left edge of a fixed-width item
    /// reads as a layout mistake rather than as a choice.
    static func cardLayer(_ card: StripLayout.Row,
                          metrics: Metrics,
                          visibleWidth: Double,
                          scale: Double,
                          color: (ColorRole) -> CGColor) -> CALayer {
        // A card too wide for the status item shrinks to fit rather than being
        // clipped. Both the type and the positions it was measured at have to
        // come down together — a smaller font with the original offsets would
        // leave the card full of gaps.
        let shrink = cardShrink(contentWidth: card.contentWidth,
                                visibleWidth: visibleWidth,
                                fontSize: metrics.font.pointSize)
        let card = shrink < 1 ? card.scaled(by: shrink) : card
        let metrics = shrink < 1 ? metrics.scaled(by: shrink) : metrics

        let layer = rowLayer(card, metrics: metrics, scale: scale, copies: 1, color: color)
        layer.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer.position = CGPoint(x: cardOrigin(contentWidth: card.contentWidth,
                                               visibleWidth: visibleWidth),
                                 y: metrics.rowHeight / 2)
        layer.opacity = 0
        return layer
    }

    /// How far a card's type has to come down to fit the status item, as a
    /// fraction of its font size — 1 when it already fits.
    ///
    /// A marquee answers this problem by scrolling, which is why only Flip
    /// needs it: a card does not move, so anything past the right edge of the
    /// status item is simply never read. Shrinking is the only way a long
    /// symbol at a four-figure price can show all of itself.
    ///
    /// Measured against `contentWidth`, which includes the trailing gap, for
    /// the same reason `cardOrigin` is: the two have to agree about how wide
    /// the card is or the shrunk card would not end up centred. It makes this
    /// very slightly conservative — a card overflowing by less than its gap
    /// shrinks when it need not — and a gap's worth of air at the edges of a
    /// fixed-width item is worth keeping anyway.
    ///
    /// Floored at `minimumCardFontSize`, so a watchlist entry long enough to
    /// need 5pt type gets clipped by `cardOrigin` as before rather than
    /// rendered unreadably small.
    static func cardShrink(contentWidth: Double,
                           visibleWidth: Double,
                           fontSize: Double) -> Double {
        guard contentWidth > visibleWidth, visibleWidth > 0, fontSize > 0 else { return 1 }
        let smallest = min(1, minimumCardFontSize / fontSize)
        return max(visibleWidth / contentWidth, smallest)
    }

    /// Where a card's left edge goes so the card sits in the middle of the
    /// window.
    ///
    /// Floored at zero, which is what makes this worth a function. A card
    /// wider than the window would otherwise get a negative origin and hang
    /// off the left, hiding the symbol — the one part of a card that is
    /// always worth reading — behind the edge of the status item. Clipped on
    /// the right is the lesser loss.
    ///
    /// The anchor point plays no part: `rotation.x` turns a layer about a
    /// horizontal axis, so only `anchorPoint.y` affects the turn and this
    /// value is the left edge either way.
    static func cardOrigin(contentWidth: Double, visibleWidth: Double) -> Double {
        max(0, (visibleWidth - contentWidth) / 2)
    }
}
