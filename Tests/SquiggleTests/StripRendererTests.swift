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
