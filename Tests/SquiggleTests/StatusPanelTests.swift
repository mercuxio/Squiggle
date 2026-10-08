import AppKit
import Testing
@testable import Squiggle

// The window in which a status-item click still counts as the same gesture
// that deactivated the app. Read from the type rather than written as a
// literal: a test that hard-coded 0.35 would start lying the moment the
// window was retuned.
private let window = StatusPanel.reopenSuppressionWindow

@Test func aClickArrivingRightAfterADeactivationCloseDoesNotReopen() {
    // The reported defect. Clicking the menu bar while the panel is open
    // deactivates Squiggle, macOS delivers that before the button's action,
    // and the panel is already shut by the time `toggleDropdown` looks. Without
    // this the toggle sees nothing showing and opens it again, so the user's
    // second click appears to do nothing.
    #expect(StatusPanel.suppressesReopen(closedAt: 1_000, now: 1_000.01))
}

@Test func aClickLongAfterADeactivationCloseOpensNormally() {
    // ⌘-Tab away, come back later and click the icon: that is a first click,
    // and it must open the panel.
    #expect(!StatusPanel.suppressesReopen(closedAt: 1_000, now: 1_000 + window + 0.01))
}

@Test func aClickWithNoDeactivationCloseBehindItOpensNormally() {
    // The ordinary first click: nothing has closed the panel, so there is
    // nothing to suppress.
    #expect(!StatusPanel.suppressesReopen(closedAt: nil, now: 1_000))
}

@Test func theWindowIsMeasuredForwardsOnly() {
    // `systemUptime` is monotonic, so this should not arise — but a negative
    // gap means the two readings cannot be two halves of one click, and
    // treating it as one would swallow a real click.
    #expect(!StatusPanel.suppressesReopen(closedAt: 1_000, now: 999.9))
}

@Test func theEdgeOfTheWindowIsOutsideIt() {
    // Named so the boundary is a decision rather than an accident: at exactly
    // the window the click opens. Half-open keeps the two tests above from
    // overlapping on one value.
    #expect(!StatusPanel.suppressesReopen(closedAt: 1_000, now: 1_000 + window))
}

@MainActor
@Test func thePanelAnswersTheSuppressionQuestionOnlyOnce() {
    // `toggleDropdown` consumes the answer: the click after a suppressed one
    // is a fresh click and must open the panel, even though it arrives inside
    // the same window.
    let panel = StatusPanel()
    #expect(!panel.closedByDeactivation())
}
