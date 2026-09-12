import AppKit
import Testing
@testable import Squiggle

// The menu bar is 22pt on an ordinary display, 24 on some notched ones.
// Hard-coded here rather than read from NSStatusBar so the arithmetic is
// the thing under test and not the machine the test runs on.
private let barHeight = 22.0

@Test func oneRowIsThirteenPoint() {
    let metrics = StripRenderer.metrics(rows: 1, barHeight: barHeight)
    #expect(metrics.rowCount == 1)
    #expect(metrics.font.pointSize == 13)
    #expect(metrics.rowHeight == 22.0)
}

@Test func twoRowsAreTenPoint() {
    let metrics = StripRenderer.metrics(rows: 2, barHeight: barHeight)
    #expect(metrics.rowCount == 2)
    #expect(metrics.font.pointSize == 10)
    #expect(metrics.rowHeight == 11.0)
}

// The emphasis face is the same face at the same size, one step heavier —
// anything else would change the strip's line height or its digit widths,
// and R135 (monospaced digits) has to survive the emphasis.
@Test func theEmphasisFontIsTheSameSizeAndHeavier() {
    let metrics = StripRenderer.metrics(rows: 2, barHeight: barHeight)
    #expect(metrics.emphasisFont.pointSize == metrics.font.pointSize)
    #expect(metrics.emphasisFont != metrics.font)
}

// The layer, not just the metrics: a renderer that read one font for every
// segment would pass the test above and still draw a flat strip.
@Test func onlyTheEmphasisedSegmentGetsTheHeavierFont() throws {
    let metrics = StripRenderer.metrics(rows: 1, barHeight: barHeight)
    let row = StripLayout.Row(
        segments: [
            StripLayout.Segment(text: "AAPL ", role: .label, x: 0, width: 40,
                                emphasized: true),
            StripLayout.Segment(text: "232.10", role: .label, x: 40, width: 60),
        ],
        contentWidth: 120)

    let container = StripRenderer.rowLayer(row, metrics: metrics, scale: 2, copies: 1,
                                           color: { _ in NSColor.labelColor.cgColor })

    let sublayers = try #require(container.sublayers)
    let texts = try #require(sublayers as? [CATextLayer])
    #expect(texts.map(\.fontSize) == [metrics.emphasisFont.pointSize,
                                      metrics.font.pointSize])
}

// The same clamp `RowSplitter.split` applies. Two places agreeing by
// accident is a bug waiting for someone to change one of them, so it is
// asserted in both.
@Test func rowCountsAreClamped() {
    #expect(StripRenderer.metrics(rows: 0, barHeight: barHeight).rowCount == 1)
    #expect(StripRenderer.metrics(rows: -4, barHeight: barHeight).rowCount == 1)
    #expect(StripRenderer.metrics(rows: 7, barHeight: barHeight).rowCount == 2)
}

@Test func durationIsWidthOverSpeed() {
    #expect(StripRenderer.duration(contentWidth: 480, pointsPerSecond: 24) == 20)
    #expect(StripRenderer.duration(contentWidth: 48, pointsPerSecond: 24) == 2)
}

// A zero or negative speed divides to infinity or runs the strip
// backwards; Core Animation accepts both and the result is a frozen or
// reversed bar. The floor is the cheapest place to stop it.
@Test func durationRefusesAZeroSpeed() {
    let stopped = StripRenderer.duration(contentWidth: 480, pointsPerSecond: 0)
    #expect(stopped.isFinite)
    #expect(stopped > 0)
    #expect(StripRenderer.duration(contentWidth: 480, pointsPerSecond: -24) == stopped)
}

@Test func durationRefusesAZeroWidth() {
    let empty = StripRenderer.duration(contentWidth: 0, pointsPerSecond: 24)
    #expect(empty.isFinite)
    #expect(empty > 0)
}

// Spec §5.2: the animation is removed, not slowed, when the content
// already fits. Equal widths fit — a strip exactly as wide as its window
// has nothing to reveal by moving.
@Test func narrowContentFits() {
    #expect(StripRenderer.fits(contentWidth: 100, visibleWidth: 260))
    #expect(StripRenderer.fits(contentWidth: 260, visibleWidth: 260))
}

@Test func wideContentDoesNotFit() {
    let overflowing = StripRenderer.fits(contentWidth: 261, visibleWidth: 260)
    #expect(!overflowing)
}

// The Core Animation pause/resume recipe: on resume the layer's begin
// time is pushed forward by exactly as much wall time as the pause
// consumed, so the strip carries on from where it stopped instead of
// snapping back to the animation's origin.
@Test func resumingShiftsBeginTime() {
    #expect(StripRenderer.resumedBeginTime(nowInLayerTime: 100, pausedOffset: 40) == 60)
    #expect(StripRenderer.resumedBeginTime(nowInLayerTime: 40, pausedOffset: 40) == 0)
}

// Never negative: a layer whose beginTime is in the future is a layer
// that renders nothing at all until that time arrives, which is a blank
// menu bar for however far the clock went backwards.
@Test func resumingNeverGoesNegative() {
    #expect(StripRenderer.resumedBeginTime(nowInLayerTime: 10, pausedOffset: 40) == 0)
}

// A row that fits its window is never animated (see `narrowContentFits`
// above), so it has nothing to tile into: one copy of its segments, and a
// container exactly as wide as the row's own content.
//
// `container.bounds.width` is `CGFloat`; wrapped in `Double(...)` before the
// `#expect` because the standalone swift-testing macro's expansion of a bare
// `CGFloat == Double` comparison reports a spurious failure on values that
// are bit-for-bit equal — converting to a matching type on both sides of the
// `==` avoids the mis-resolution rather than working around it after the fact.
@Test func oneCopyDrawsEachSegmentOnce() {
    let metrics = StripRenderer.metrics(rows: 1, barHeight: barHeight)
    let row = StripLayout.Row(
        segments: [
            StripLayout.Segment(text: "AAPL ", role: .label, x: 0, width: 40),
            StripLayout.Segment(text: "▲1.23 (3.5%)", role: .direction(.up), x: 40, width: 90),
        ],
        contentWidth: 150)

    let container = StripRenderer.rowLayer(row, metrics: metrics, scale: 2, copies: 1,
                                           color: { _ in NSColor.labelColor.cgColor })

    #expect(container.sublayers?.count == row.segments.count)
    #expect(Double(container.bounds.width) == row.contentWidth)
}

// A row that overflows its window is animated, and the second copy is what
// makes the wrap seamless — so it gets two of everything, and a container
// twice as wide.
@Test func twoCopiesDrawEachSegmentTwice() {
    let metrics = StripRenderer.metrics(rows: 1, barHeight: barHeight)
    let row = StripLayout.Row(
        segments: [
            StripLayout.Segment(text: "AAPL ", role: .label, x: 0, width: 40),
            StripLayout.Segment(text: "▲1.23 (3.5%)", role: .direction(.up), x: 40, width: 90),
        ],
        contentWidth: 150)

    let container = StripRenderer.rowLayer(row, metrics: metrics, scale: 2, copies: 2,
                                           color: { _ in NSColor.labelColor.cgColor })

    #expect(container.sublayers?.count == row.segments.count * 2)
    #expect(Double(container.bounds.width) == row.contentWidth * 2)
}

// A caller asking for fewer than one copy still gets a row, not an empty
// layer — the same floor `metrics(rows:)` applies to row count.
@Test func copiesBelowOneAreClampedToOne() {
    let metrics = StripRenderer.metrics(rows: 1, barHeight: barHeight)
    let row = StripLayout.Row(
        segments: [StripLayout.Segment(text: "AAPL ", role: .label, x: 0, width: 40)],
        contentWidth: 40)

    let container = StripRenderer.rowLayer(row, metrics: metrics, scale: 2, copies: 0,
                                           color: { _ in NSColor.labelColor.cgColor })

    #expect(container.sublayers?.count == row.segments.count)
    #expect(Double(container.bounds.width) == row.contentWidth)
}

// MARK: - Carrying the scroll phase across a rebuild

@Test func phaseIsTheFractionOfALapAnAnimationHasRun() {
    #expect(StripRenderer.phase(localTime: 5, beginTime: 0, duration: 20) == 0.25)
    #expect(StripRenderer.phase(localTime: 105, beginTime: 100, duration: 20) == 0.25)
}

@Test func phaseWrapsRatherThanGrowingPastOne() {
    // `repeatCount = .infinity` means elapsed time runs away without bound.
    // A phase of 3.25 laps is a phase of 0.25, and anything using the
    // unwrapped value would push the rebuilt row's begin time arbitrarily far
    // into the past.
    #expect(StripRenderer.phase(localTime: 65, beginTime: 0, duration: 20) == 0.25)
}

@Test func phaseIsZeroWhereThereIsNoLapToBeFractionOf() {
    // A zero duration cannot be divided into, and a local time before the
    // animation began has not started its first lap. Both mean "start at the
    // beginning", which is what a rebuild did anyway — so the caller needs no
    // special case of its own.
    #expect(StripRenderer.phase(localTime: 5, beginTime: 0, duration: 0) == 0)
    #expect(StripRenderer.phase(localTime: 0, beginTime: 5, duration: 20) == 0)
}

@Test func aRebuiltRowBeginsInThePastByExactlyThePhaseItInherited() {
    // The whole fix in one line: the replacement animation is told it started
    // a quarter of a lap ago, so its first drawn frame is the frame the strip
    // was already showing.
    #expect(StripRenderer.rebuiltBeginTime(nowInLayerTime: 100,
                                           phase: 0.25, duration: 20) == 95)
}

@Test func aRebuiltRowAtPhaseZeroBeginsExactlyNow() {
    #expect(StripRenderer.rebuiltBeginTime(nowInLayerTime: 100,
                                           phase: 0, duration: 20) == 100)
}
