import AppKit
import Testing
@testable import Squiggle

// The status item's rectangle, as `anchorFrame()` would report it: menu bar
// height, somewhere near the right-hand end of a wide display.
private let anchor = NSRect(x: 1621, y: 1416, width: 248, height: 24)

/// `NSApplication.didResignActiveNotification` is Squiggle's only dismissal for
/// a keyboard-only app switch — a `.popUpMenu` panel otherwise floats over
/// every other app — but it also fires on the *second* click of the status
/// item, before the button's own action runs. Closing there left `toggle`
/// finding nothing showing and reopening immediately, so the click looked dead.
@Suite struct StatusPanelResignActiveTests {
    @Test func aClickHeldOnTheStatusItemLeavesThePanelOpen() {
        #expect(
            !StatusPanel.shouldClose(
                onResignActiveWith: 1, at: NSPoint(x: 1745, y: 1427), anchor: anchor))
    }

    /// ⌘-Tab and Mission Control: no button down, whatever the pointer happens
    /// to be hovering over — including the status item, which is where a user
    /// who just opened the dropdown has left the cursor.
    @Test func aKeyboardSwitchClosesEvenOverTheStatusItem() {
        #expect(
            StatusPanel.shouldClose(
                onResignActiveWith: 0, at: NSPoint(x: 1745, y: 1427), anchor: anchor))
    }

    @Test func aClickHeldElsewhereCloses() {
        #expect(
            StatusPanel.shouldClose(
                onResignActiveWith: 1, at: NSPoint(x: 400, y: 600), anchor: anchor))
    }

    /// No anchor yet — `anchorFrame()` returns `.zero`, which contains nothing,
    /// so the rule falls through to closing as usual.
    @Test func noAnchorClosesOnAnyPress() {
        #expect(
            StatusPanel.shouldClose(
                onResignActiveWith: 1, at: NSPoint(x: 0, y: 0), anchor: .zero))
    }
}
