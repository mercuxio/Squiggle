import AppKit
import QuartzCore
import Testing
import TickerCore
@testable import Squiggle

// The same fake measurement `StripLayoutTests` uses: every character is ten
// points wide. Real text measurement varies by OS version and installed font
// (spec §8.5), and none of these tests is about how wide anything is — only
// about whether the strip is moving.
private let tenPerCharacter: @Sendable (String) -> Double = { Double($0.count) * 10 }

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
