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
                    launchAtLogin: LaunchAtLogin) -> SettingsWindowController {
    SettingsWindowController(settings: settings,
                             launchAtLogin: launchAtLogin,
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
