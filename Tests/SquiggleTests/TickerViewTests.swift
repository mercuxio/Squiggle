import AppKit
import QuartzCore
import Testing
import TickerCore
@testable import Squiggle

// The same fake measurement `StripLayoutTests` uses: every character is ten
// points wide. Real text measurement varies by OS version and installed font
// (spec §8.5), and none of these tests is about how wide anything is — only
// about whether the strip is moving.
/// Weight-blind on purpose: these tests are about placement arithmetic, and
/// a heavier symbol measuring wider is the caller's business (R131).
private let tenPerCharacter: @Sendable (String, Bool) -> Double = { text, _ in
    Double(text.count) * 10
}

private let posix = Locale(identifier: "en_US_POSIX")

// Two rows, each wider than `narrowWidth` — which is what makes them animated
// at all: spec §5.2's first stopping condition removes the animation from a
// row that fits, and a row with no animation cannot show a pause.
private func wideLayout() throws -> StripLayout {
    let symbols = try ["LONGLONGLONGLONG", "ALSOQUITELONGHERE"].map {
        try #require(Symbol($0))
    }
    return StripLayout.build(symbols: symbols, quotes: [:], dead: [],
                             rows: 2, gap: 20, locale: posix,
                             measure: tenPerCharacter)
}

private let narrowWidth = 40.0

private let labelColor: @Sendable (ColorRole) -> CGColor = { _ in NSColor.labelColor.cgColor }

@MainActor
private func apply(_ view: TickerView, layout: StripLayout, paused: Bool) {
    view.apply(layout: layout,
               metrics: StripRenderer.metrics(rows: 2, barHeight: 22),
               visibleWidth: narrowWidth,
               mode: .scroll,
               pointsPerSecond: 30,
               paused: paused,
               color: labelColor)
}

// `speed` is a `Float`; S3's `Double(...)` wrapping is applied to every
// comparison for the same reason it is applied to `CGFloat`.
@MainActor
private func rowSpeeds(_ view: TickerView) -> [Double] {
    (view.layer?.sublayers ?? []).map { Double($0.speed) }
}

@MainActor
private func everyRowStillCarriesItsAnimation(_ view: TickerView) -> Bool {
    let rows = view.layer?.sublayers ?? []
    return !rows.isEmpty && rows.allSatisfy { !($0.animationKeys() ?? []).isEmpty }
}

// How far through its lap each row's animation is, read back the same way
// `TickerView` reads it.
@MainActor
private func rowPhases(_ view: TickerView) -> [Double] {
    (view.layer?.sublayers ?? []).map { rowLayer in
        guard let animation = rowLayer.animation(forKey: "scroll") else { return 0 }
        let local = rowLayer.convertTime(CACurrentMediaTime(), from: nil)
        return StripRenderer.phase(localTime: local,
                                   beginTime: animation.beginTime,
                                   duration: animation.duration)
    }
}

// Winds each row on so it reads as part of a lap in, without waiting for real
// time to pass. `beginTime` is an absolute layer time, so moving it into the
// past is exactly equivalent to the animation having run that much longer.
@MainActor
private func windForward(_ view: TickerView, laps: Double) {
    for rowLayer in view.layer?.sublayers ?? [] {
        guard let animation = rowLayer.animation(forKey: "scroll") else { continue }
        guard let wound = animation.copy() as? CABasicAnimation else { continue }
        wound.beginTime = animation.beginTime - laps * animation.duration
        rowLayer.removeAnimation(forKey: "scroll")
        rowLayer.add(wound, forKey: "scroll")
    }
}

@MainActor
@Test func rebuildingTheStripKeepsItsPlaceInTheLapInsteadOfSnappingToTheStart() throws {
    // The skip the user reported: every refresh, appearance change, Reduce
    // Motion toggle and settings edit calls `apply`, which tears every row
    // layer down and builds a new one. A new animation starting at phase zero
    // puts the strip back at its first character, mid-scroll, several times a
    // minute. `pause()` one function away already carries its offset across
    // (spec §5.2) — this makes the rebuild do the same.
    let view = TickerView()
    let layout = try wideLayout()
    apply(view, layout: layout, paused: false)
    windForward(view, laps: 0.25)

    apply(view, layout: layout, paused: false)

    // Not exactly 0.25: the media clock advances between winding the old row
    // and reading the new one. A snap to the start would read as ~0.
    for phase in rowPhases(view) {
        #expect(phase > 0.2)
        #expect(phase < 0.3)
    }
}

@MainActor
@Test func aFirstApplyStartsAtTheBeginningOfTheLap() throws {
    // There is no previous row to inherit from, so phase zero is the honest
    // answer — and it is what makes the test above a real assertion rather
    // than one that would pass on any input.
    let view = TickerView()
    apply(view, layout: try wideLayout(), paused: false)

    for phase in rowPhases(view) {
        #expect(phase < 0.01)
    }
}

@MainActor
@Test func applyingWhilePausedLeavesTheStripStopped() throws {
    // The defect this exists for: a refresh tick, an appearance change or a
    // settings edit lands while the screen is locked, `apply` rebuilds the
    // strip, and nothing re-pauses it — `PauseMonitor` fires only on a change
    // and the screen stays locked, so the marquee runs until the user is back.
    let view = TickerView()
    apply(view, layout: try wideLayout(), paused: true)

    #expect(view.isPaused)
    #expect(rowSpeeds(view) == [0, 0])
    // Spec §5.2: paused, not removed. A removed animation would also read as
    // stopped and would jump the strip back to its origin on resume.
    #expect(everyRowStillCarriesItsAnimation(view))
}

@MainActor
@Test func applyingWhileNotPausedLeavesTheStripMoving() throws {
    let view = TickerView()
    apply(view, layout: try wideLayout(), paused: false)

    #expect(!view.isPaused)
    #expect(rowSpeeds(view) == [1, 1])
    #expect(everyRowStillCarriesItsAnimation(view))
}

@MainActor
@Test func aPausedApplyFollowedByAnUnpausedApplyMovesAgain() throws {
    // The unlock side of the same seam: the screen comes back, `applyPause`
    // resumes, and the next render must not re-freeze what it just resumed.
    let view = TickerView()
    let layout = try wideLayout()
    apply(view, layout: layout, paused: true)
    apply(view, layout: layout, paused: false)

    #expect(!view.isPaused)
    #expect(rowSpeeds(view) == [1, 1])
}

/// Row 0 is row 1 of the menu bar, and it has to be the one on top.
///
/// `apply` places row `i` at `y = i * rowHeight`, which only reads downwards if
/// the view is flipped — and a layer-backed view's `isGeometryFlipped` is
/// AppKit's to set, derived from this property. Assigning the layer flag
/// directly is what put row 1 underneath row 2, so this asserts the flag AppKit
/// actually consults.
@MainActor
@Test func theStripCountsItsRowsDownwardsFromTheTop() {
    #expect(TickerView().isFlipped)
}

@MainActor
@Test func aPausedApplyIsIndistinguishableFromAPauseCall() throws {
    // `pause()` guards on `isPaused`, so `apply(paused: true)` has to report
    // the state honestly or a later genuine pause would be silently skipped —
    // and a later `resume()` would then be un-pausing something it believes
    // is already running.
    let view = TickerView()
    apply(view, layout: try wideLayout(), paused: true)
    view.pause()
    #expect(view.isPaused)
    #expect(rowSpeeds(view) == [0, 0])

    view.resume()
    #expect(!view.isPaused)
    #expect(rowSpeeds(view) == [1, 1])
}
