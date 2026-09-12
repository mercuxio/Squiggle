import AppKit
import Testing
import TickerCore
@testable import Squiggle

// `SettingsWindowController` builds its window in code (R133) and takes its
// `LaunchAtLogin` as a struct of closures, so the whole window is reachable
// from a test: no status bar, no run loop, and nothing that touches
// `SMAppService` or the user's real Login Items.
//
// The controls themselves are private, which is right — nothing outside the
// window should be able to poke them — so these tests find them the way a
// user does, by what they say.

private final class LoginItemSpy: @unchecked Sendable {
    var state: LoginItemState
    var applied: [LoginItemAction] = []
    /// What `apply` reports back afterwards. The real one re-reads the system
    /// rather than assuming the action worked (spec §6), and R146 turns on
    /// the window believing that answer over the checkbox it came from.
    var result: LoginItemState
    /// What `apply` reports having gone wrong. `nil` is the ordinary case and
    /// the one every test written before item 6 assumes.
    var failure: LoginItemFailure?

    init(state: LoginItemState, result: LoginItemState) {
        self.state = state
        self.result = result
    }

    var seam: LaunchAtLogin {
        LaunchAtLogin(read: { [self] in state },
                      apply: { [self] action in
                          applied.append(action)
                          return LoginItemOutcome(result, failure: failure)
                      })
    }
}

@MainActor
private func everyView(in root: NSView) -> [NSView] {
    root.subviews.reduce([root]) { $0 + everyView(in: $1) }
}

@MainActor
private func button(titled title: String, in controller: NSWindowController) -> NSButton? {
    guard let content = controller.window?.contentView else { return nil }
    let buttons = everyView(in: content).compactMap { $0 as? NSButton }
    return buttons.first { $0.title == title }
}

@MainActor
private func labelExists(_ text: String, in controller: NSWindowController) -> Bool {
    guard let content = controller.window?.contentView else { return false }
    let fields = everyView(in: content).compactMap { $0 as? NSTextField }
    return fields.contains { $0.stringValue == text }
}

@MainActor
private func label(_ text: String, in controller: NSWindowController) -> NSTextField? {
    guard let content = controller.window?.contentView else { return nil }
    let fields = everyView(in: content).compactMap { $0 as? NSTextField }
    return fields.first { $0.stringValue == text }
}

@MainActor
private func window(settings: Settings = Settings(),
                    launchAtLogin: LaunchAtLogin,
                    version: String? = "1.0.0") -> SettingsWindowController {
    SettingsWindowController(settings: settings,
                             launchAtLogin: launchAtLogin,
                             version: version,
                             onChange: { _ in })
}

// MARK: - The effective-interval line (spec §4.1)

@MainActor
@Test func theEffectiveIntervalLineFollowsTheWatchlistCount() {
    // The defect: with the settings window open, adding symbols left this
    // line quoting the old watchlist's cadence — "Every 1 min" where the app
    // would actually honour 24. The `didSet` was always there; nothing was
    // assigning to it after `openSettings`.
    let spy = LoginItemSpy(state: .off, result: .off)
    var settings = Settings()
    settings.refreshIntervalSeconds = 60
    let controller = window(settings: settings, launchAtLogin: spy.seam)

    controller.watchlistCount = 1
    let one = ErrorText.effectiveInterval(userIntervalSeconds: 60, watchlistCount: 1)
    #expect(labelExists(one, in: controller))

    controller.watchlistCount = RateConstants.maxWatchlistCount
    let twenty = ErrorText.effectiveInterval(
        userIntervalSeconds: 60, watchlistCount: RateConstants.maxWatchlistCount)
    // The two are different strings, or this test would pass on a window that
    // never recomputed anything.
    #expect(one != twenty)
    #expect(labelExists(twenty, in: controller))
    #expect(!labelExists(one, in: controller))
}

// MARK: - Layout (the user's report: "too much empty space on the left")

@MainActor
@Test func theLabelColumnHugsItsLabelsInsteadOfPaddingTheWindow() throws {
    // The window used to be built at a fixed 380pt while the grid only wanted
    // 322. Column 1 is pinned to `columnWidth`, so column 0 was the only one
    // free to absorb the 58pt of slack — and column 0 is `.trailing`, so all
    // of it landed to the *left* of every label. Measured before the fix:
    // "Refresh" began at x=79 inside a 20pt margin.
    //
    // The fix is a zero-width `contentRect`, which lets Auto Layout size the
    // window from the grid instead of the grid from the window. This test
    // fails on any width typed back in.
    let spy = LoginItemSpy(state: .off, result: .off)
    let controller = window(launchAtLogin: spy.seam)
    let content = try #require(controller.window?.contentView)
    controller.window?.layoutIfNeeded()

    // The widest label, so it is the one that defines the column's edge.
    let widest = try #require(label(ErrorText.intervalLabel, in: controller))
    let left = Double(widest.convert(widest.bounds, to: content).minX)
    // 20pt of window margin, less the 2pt an `NSTextField` insets its own
    // text inside its frame. Anything past this is slack with nowhere to go.
    #expect(left < 24)
}

@MainActor
@Test func theControlColumnHasOneRightEdge() throws {
    // Left to themselves the pop-ups stop at their longest title — 150pt and
    // 127pt — against sliders running the column's full width. Four controls
    // ending at four different x positions is most of what read as unpolished.
    let spy = LoginItemSpy(state: .off, result: .off)
    let controller = window(launchAtLogin: spy.seam)
    let content = try #require(controller.window?.contentView)
    controller.window?.layoutIfNeeded()

    let stretchy = everyView(in: content).filter { $0 is NSPopUpButton || $0 is NSSlider }
    // Two pop-ups and two sliders, each wrapped by AppKit in a hosting view
    // that shares its frame — so the count is what the window has, doubled.
    #expect(stretchy.count >= 4)
    let edges = stretchy.map { Double($0.convert($0.bounds, to: content).maxX) }
    let first = try #require(edges.first)
    let aligned = edges.allSatisfy { abs($0 - first) < 0.5 }
    #expect(aligned)
}

@MainActor
@Test func aNoteWithNothingToSayGivesItsRowBack() throws {
    // Hiding the note's *view* left the row's height behind: a blank band
    // under the checkbox in the ordinary case, which is every case where the
    // app is working. The row itself has to hide.
    //
    // `.needsApproval` is the comparison, not `.unavailable`: that one's note
    // wraps to two lines, so its window is taller whether or not the empty
    // rows collapse — measured, and it passed against the unfixed code.
    // `.needsApproval` says one short line and shows the button, which is
    // exactly the two rows at issue and nothing else.
    let quiet = LoginItemSpy(state: .off, result: .off)
    let explaining = LoginItemSpy(state: .needsApproval, result: .needsApproval)
    let a = window(launchAtLogin: quiet.seam)
    let b = window(launchAtLogin: explaining.seam)
    a.window?.layoutIfNeeded()
    b.window?.layoutIfNeeded()

    let short = try #require(a.window?.contentView)
    let tall = try #require(b.window?.contentView)
    // `.off` has neither a note nor a button, so its window must be shorter.
    #expect(Double(short.bounds.height) < Double(tall.bounds.height))
    // And the same width regardless — the sentence wraps, it does not widen.
    #expect(Double(short.bounds.width) == Double(tall.bounds.width))
}

// MARK: - Launch at login (R146)

@MainActor
@Test func theCheckboxOpensShowingWhatTheSystemSays() throws {
    let spy = LoginItemSpy(state: .on, result: .on)
    let controller = window(launchAtLogin: spy.seam)
    let box = try #require(button(titled: ErrorText.launchAtLoginLabel, in: controller))
    #expect(box.state == .on)
    #expect(box.isEnabled)
}

@MainActor
@Test func noBundleLeavesTheCheckboxVisibleButDead() throws {
    // What every developer on this project sees: `.notFound`, because a test
    // process has no bundle to register. It must not look like a bug.
    let spy = LoginItemSpy(state: .unavailable, result: .unavailable)
    let controller = window(launchAtLogin: spy.seam)
    let box = try #require(button(titled: ErrorText.launchAtLoginLabel, in: controller))
    #expect(box.state == .off)
    #expect(!box.isEnabled)
    // Hoisted: `??` is kept out of the macro's argument rewrite.
    let note = try #require(ErrorText.loginItemNote(for: .unavailable))
    #expect(labelExists(note, in: controller))
}

/// The user's report: the note read "…running from ar" and stopped.
///
/// It is a one-line `NSTextField` in a grid column pinned to 220pt, so any
/// note longer than that column loses its ending — and the ending is the half
/// that says what to do about it. The sentence has to wrap instead.
///
/// Asserted against the window's own column width rather than a number typed
/// here, so widening the column cannot quietly turn this into a test of
/// nothing.
@MainActor
@Test func aLongNoteWrapsInsteadOfLosingItsEnding() throws {
    let spy = LoginItemSpy(state: .unavailable, result: .unavailable)
    let controller = window(launchAtLogin: spy.seam)
    let text = try #require(ErrorText.loginItemNote(for: .unavailable))
    let note = try #require(label(text, in: controller))

    controller.window?.layoutIfNeeded()
    // Wide enough to hold this sentence on one line, and the column is not.
    let huge = CGFloat(100_000)
    let oneLine = note.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: huge, height: huge))
    let unwrapped = try #require(oneLine)
    #expect(Double(unwrapped.width) > Double(note.frame.width))

    // So it must be taller than a single line — which is the whole claim.
    #expect(Double(note.frame.height) > Double(unwrapped.height))
    #expect(note.maximumNumberOfLines != 1)
}

@MainActor
@Test func tickingTheBoxRegisters() throws {
    let spy = LoginItemSpy(state: .off, result: .on)
    let controller = window(launchAtLogin: spy.seam)
    let box = try #require(button(titled: ErrorText.launchAtLoginLabel, in: controller))

    // `performClick` toggles the checkbox and fires its action, which is the
    // wiring under test — the window reads the system again at that moment
    // rather than trusting the box it was just handed.
    spy.state = .off
    box.performClick(nil)

    #expect(spy.applied == [.register])
    #expect(box.state == .on)
}

@MainActor
@Test func untickingTheBoxUnregisters() throws {
    let spy = LoginItemSpy(state: .on, result: .off)
    let controller = window(launchAtLogin: spy.seam)
    let box = try #require(button(titled: ErrorText.launchAtLoginLabel, in: controller))

    box.performClick(nil)

    #expect(spy.applied == [.unregister])
    #expect(box.state == .off)
}

@MainActor
@Test func theBlockedStateSendsTheUserToSystemSettingsInsteadOfRegistering() throws {
    // R146's whole reason for existing: `register()` on an already-registered
    // service throws and would not clear the user's own switch anyway. The
    // window must offer the button, and clicking the box must open Settings
    // rather than attempt a registration that cannot help.
    let spy = LoginItemSpy(state: .needsApproval, result: .needsApproval)
    let controller = window(launchAtLogin: spy.seam)
    let box = try #require(button(titled: ErrorText.launchAtLoginLabel, in: controller))
    let settingsButton = try #require(button(titled: ErrorText.openLoginItems,
                                             in: controller))
    let hidden = settingsButton.isHidden
    #expect(!hidden)
    // `.needsApproval` will not launch, so the box is not ticked — the note
    // and the button are what explain the difference.
    #expect(box.state == .off)
    let note = try #require(ErrorText.loginItemNote(for: .needsApproval))
    #expect(labelExists(note, in: controller))

    box.performClick(nil)
    #expect(spy.applied == [.openSystemSettings])
}

// MARK: - Saying why, when macOS refuses (the punch list's item 6)

@MainActor
@Test func aRefusedRegistrationSaysSoRatherThanJustUntickingItself() throws {
    // Item 6 end to end. Before this, `register()` ran through `try?` and a
    // refusal was indistinguishable from a no-op: the window re-read `.off`,
    // put the box back down and said nothing. The user's report was "the
    // checkbox doesn't work", which is exactly what a silent refusal looks
    // like from outside.
    let spy = LoginItemSpy(state: .off, result: .off)
    spy.failure = LoginItemFailure(domain: "SMAppServiceErrorDomain", code: 1)
    let controller = window(launchAtLogin: spy.seam)
    let box = try #require(button(titled: ErrorText.launchAtLoginLabel, in: controller))

    box.performClick(nil)

    #expect(spy.applied == [.register])
    #expect(box.state == .off)
    let note = try #require(ErrorText.loginItemNote(for: .off, failure: spy.failure))
    #expect(labelExists(note, in: controller))
}

@MainActor
@Test func openingTheWindowAgainClearsALastRefusal() throws {
    // The note describes one attempt, not a standing condition. `read()`
    // cannot fail, so a window brought back to key has nothing to report and
    // must not still be showing why something went wrong minutes ago.
    let spy = LoginItemSpy(state: .off, result: .off)
    spy.failure = LoginItemFailure(domain: "SMAppServiceErrorDomain", code: 1)
    let controller = window(launchAtLogin: spy.seam)
    let box = try #require(button(titled: ErrorText.launchAtLoginLabel, in: controller))
    box.performClick(nil)

    controller.refreshLoginItemForTesting()

    let note = try #require(ErrorText.loginItemNote(for: .off, failure: spy.failure))
    #expect(!labelExists(note, in: controller))
}

// MARK: - Escape

/// "esc should be able to close the settings dialog."
///
/// Asserted by sending `cancelOperation` — which is what the Escape key turns
/// into once AppKit has offered it to the field editor — rather than by
/// synthesising a key event, which needs a run loop and a key window and would
/// be testing `NSApplication` rather than this window.
@MainActor
@Test func escapeClosesTheSettingsWindow() throws {
    let spy = LoginItemSpy(state: .off, result: .off)
    let controller = window(launchAtLogin: spy.seam)
    let panel = try #require(controller.window)
    panel.orderFront(nil)
    #expect(panel.isVisible)

    panel.cancelOperation(nil)

    #expect(!panel.isVisible)
}

/// The window is reopened from the footer after an Escape, so closing must not
/// destroy it — `isReleasedWhenClosed` is already false for that reason, and
/// this is the assertion that would catch a subclass quietly changing it.
@MainActor
@Test func escapePutsTheSettingsWindowAwayWithoutReleasingIt() throws {
    let spy = LoginItemSpy(state: .off, result: .off)
    let controller = window(launchAtLogin: spy.seam)
    let panel = try #require(controller.window)
    panel.orderFront(nil)

    panel.cancelOperation(nil)
    panel.orderFront(nil)

    #expect(panel.isVisible)
    #expect(controller.window === panel)
}

// MARK: - The version line

/// "also put the squiggle version in the settings dialog".
///
/// Asserted against `ErrorText.versionLine` rather than against the literal
/// "Version 1.0.0": the wording belongs to `ErrorText` and nowhere else, so a
/// test that spelled it out here would be a second copy to keep in step.
@MainActor
@Test func theSettingsWindowPrintsTheAppVersion() {
    let spy = LoginItemSpy(state: .off, result: .off)
    let controller = window(launchAtLogin: spy.seam, version: "1.0.0")

    #expect(labelExists(ErrorText.versionLine("1.0.0"), in: controller))
}

/// The number is the bundle's, not a literal typed into the window — so a
/// release that bumps `CFBundleShortVersionString` needs no code change here,
/// and this is the assertion that would catch one being hard-coded back in.
@MainActor
@Test func theVersionLineSaysWhateverTheBundleSays() {
    let spy = LoginItemSpy(state: .off, result: .off)
    let controller = window(launchAtLogin: spy.seam, version: "9.9.9")

    #expect(labelExists(ErrorText.versionLine("9.9.9"), in: controller))
    #expect(!labelExists(ErrorText.versionLine("1.0.0"), in: controller))
}

/// Run as a bare binary with no bundle around it there is no version to give,
/// and the window says nothing rather than trailing off after "Version". The
/// label is still in the row — an empty one claims no width, so there is
/// nothing to hide and no gap where it would have been.
@MainActor
@Test func aVersionlessBuildPrintsNoVersionLineAtAll() throws {
    let spy = LoginItemSpy(state: .off, result: .off)
    let controller = window(launchAtLogin: spy.seam, version: nil)
    let content = try #require(controller.window?.contentView)
    let printed = everyView(in: content).compactMap { $0 as? NSTextField }
        .map(\.stringValue)

    #expect(!printed.contains { $0.contains("Version") })
}

/// "version can be in the same row as open at login. open at login to align
/// left and the version to align right."
///
/// Frames rather than gravity areas: `addView(_:in: .trailing)` is how the
/// right edge is asked for, and this asserts it was granted — a stack whose
/// cell stopped filling the column would still hold the same two gravities
/// while drawing the version halfway across the window.
@MainActor
@Test func theVersionSitsAtTheRightEndOfTheLoginRow() throws {
    let spy = LoginItemSpy(state: .off, result: .off)
    let controller = window(launchAtLogin: spy.seam, version: "1.0.0")
    let content = try #require(controller.window?.contentView)
    content.layoutSubtreeIfNeeded()

    let row = try #require(everyView(in: content).compactMap { $0 as? NSStackView }
        .first { stack in
            stack.views.contains { ($0 as? NSButton)?.title == ErrorText.launchAtLoginLabel }
        })
    let checkbox = try #require(row.views.compactMap { $0 as? NSButton }.first)
    let version = try #require(row.views.compactMap { $0 as? NSTextField }.first)

    #expect(version.stringValue == ErrorText.versionLine("1.0.0"))
    // Alignment rects, not frames: a stack aligns those, and an `NSTextField`
    // insets its own by 2pt — so the frame overhangs the stack by 2pt while
    // the text it draws sits exactly on the edge. The text is what the user
    // asked to line up.
    #expect(Double(checkbox.alignmentRect(forFrame: checkbox.frame).minX)
            == Double(row.bounds.minX))
    #expect(Double(version.alignmentRect(forFrame: version.frame).maxX)
            == Double(row.bounds.maxX))
    // Two ends of one row, not two rows: the same stack, and no overlap.
    #expect(Double(version.frame.minX) > Double(checkbox.frame.maxX))
}

/// The app's real bundle carries the version the settings window will show, so
/// a release that forgot to set it would ship a window with a blank foot. Read
/// from the source plist rather than `Bundle.main`, which under `swift test` is
/// the test runner and knows nothing about Squiggle.
@Test func theShippedBundleCarriesAMarketingVersion() throws {
    let plist = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SquiggleTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root
        .appendingPathComponent("Resources/Info.plist")
    let contents = try Data(contentsOf: plist)
    let parsed = try #require(
        try PropertyListSerialization.propertyList(from: contents, format: nil)
            as? [String: Any])

    let version = try #require(parsed["CFBundleShortVersionString"] as? String)
    #expect(version == "1.0.0")
}
