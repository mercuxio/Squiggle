import AppKit
import SwiftUI
import Testing
import TickerCore
@testable import Squiggle

// The window's content is a SwiftUI form, which keeps no controls a test can
// find by title. Everything it shows comes from `SettingsModel`, so that is
// what these tests talk to — through the controller where the controller is
// the thing under test. `LaunchAtLogin` is a struct of closures, so nothing
// here touches `SMAppService` or the user's real Login Items.

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
private func window(settings: TickerSettings = Settings(),
                    launchAtLogin: LaunchAtLogin,
                    version: String? = "1.0.0",
                    onChange: @escaping (TickerSettings) -> Void = { _ in }) -> SettingsWindowController {
    SettingsWindowController(settings: settings,
                             launchAtLogin: launchAtLogin,
                             version: version,
                             onChange: onChange)
}

// MARK: - The window

@MainActor
@Test func theWindowHostsTheFormUnderItsTitle() throws {
    let spy = LoginItemSpy(state: .off, result: .off)
    let controller = window(launchAtLogin: spy.seam)
    let panel = try #require(controller.window)

    #expect(panel.title == ErrorText.settingsTitle)
    #expect(panel.contentViewController is NSHostingController<SettingsView>)
    #expect(!panel.styleMask.contains(.resizable))
}

// MARK: - Editing

@MainActor
@Test func everyEditIsReportedStraightAway() {
    // No OK button: the strip previews each change as it is made, so an edit
    // the controller heard about late would be a preview of the wrong thing.
    let spy = LoginItemSpy(state: .off, result: .off)
    var reported: [TickerSettings] = []
    let controller = window(launchAtLogin: spy.seam, onChange: { reported.append($0) })

    controller.model.edit { $0.rows = 1 }
    controller.model.edit { $0.maxVisibleWidth = 300 }

    #expect(reported.map(\.rows) == [1, 1])
    #expect(reported.last?.maxVisibleWidth == 300)
    #expect(controller.model.settings.maxVisibleWidth == 300)
}

@MainActor
@Test func aChangeFromOutsideIsShownButNotEchoedBack() {
    // `apply` is how the document tells the window; answering with `onChange`
    // would send the same value round again as if the user had made it.
    let spy = LoginItemSpy(state: .off, result: .off)
    var reported = 0
    let controller = window(launchAtLogin: spy.seam, onChange: { _ in reported += 1 })
    var settings = Settings()
    settings.rows = 1

    controller.apply(settings)

    #expect(controller.model.settings.rows == 1)
    #expect(reported == 0)
}

// MARK: - The effective-interval line (spec §4.1)

@MainActor
@Test func theEffectiveIntervalLineFollowsTheWatchlistCount() {
    // The defect: with the settings window open, adding symbols left this
    // line quoting the old watchlist's cadence. `StatusItemController` pushes
    // every count change through the controller; this is the path it uses.
    let spy = LoginItemSpy(state: .off, result: .off)
    var settings = Settings()
    settings.refreshIntervalSeconds = 60
    let controller = window(settings: settings, launchAtLogin: spy.seam)

    controller.watchlistCount = 1
    let one = ErrorText.effectiveInterval(userIntervalSeconds: 60, watchlistCount: 1)
    #expect(controller.model.effectiveInterval == one)

    controller.watchlistCount = RateConstants.maxWatchlistCount
    let twenty = ErrorText.effectiveInterval(
        userIntervalSeconds: 60, watchlistCount: RateConstants.maxWatchlistCount)
    // Different strings, or this would pass on a line that never recomputed.
    #expect(one != twenty)
    #expect(controller.model.effectiveInterval == twenty)
}

// MARK: - Launch at login (R146)

@MainActor
@Test func theToggleOpensShowingWhatTheSystemSays() {
    let spy = LoginItemSpy(state: .on, result: .on)
    let model = window(launchAtLogin: spy.seam).model
    #expect(model.loginState.isOn)
    #expect(model.loginState.isEnabled)
    #expect(model.loginNote == nil)
}

@MainActor
@Test func noBundleLeavesTheToggleVisibleButDead() {
    // What every developer on this project sees: a test process has no
    // bundle to register. It must not look like a bug.
    let spy = LoginItemSpy(state: .unavailable, result: .unavailable)
    let model = window(launchAtLogin: spy.seam).model
    #expect(!model.loginState.isOn)
    #expect(!model.loginState.isEnabled)
    #expect(model.loginNote == ErrorText.loginItemNote(for: .unavailable))
}

@MainActor
@Test func turningItOnRegisters() {
    let spy = LoginItemSpy(state: .off, result: .on)
    let model = window(launchAtLogin: spy.seam).model

    model.setLaunchAtLogin(true)

    #expect(spy.applied == [.register])
    #expect(model.loginState.isOn)
}

@MainActor
@Test func turningItOffUnregisters() {
    let spy = LoginItemSpy(state: .on, result: .off)
    let model = window(launchAtLogin: spy.seam).model

    model.setLaunchAtLogin(false)

    #expect(spy.applied == [.unregister])
    #expect(!model.loginState.isOn)
}

@MainActor
@Test func theBlockedStateSendsTheUserToSystemSettingsInsteadOfRegistering() {
    // R146's reason for existing: `register()` on an already-registered
    // service throws and would not clear the user's own switch anyway.
    let spy = LoginItemSpy(state: .needsApproval, result: .needsApproval)
    let model = window(launchAtLogin: spy.seam).model
    #expect(model.loginState.showsSystemSettingsButton)
    #expect(!model.loginState.isOn)
    #expect(model.loginNote == ErrorText.loginItemNote(for: .needsApproval))

    model.setLaunchAtLogin(true)
    #expect(spy.applied == [.openSystemSettings])

    model.openLoginItems()
    #expect(spy.applied == [.openSystemSettings, .openSystemSettings])
}

@MainActor
@Test func aRefusedRegistrationSaysSoRatherThanJustTurningItselfOff() {
    // Before item 6, a refusal was indistinguishable from a no-op, and the
    // user's report was "the checkbox doesn't work".
    let spy = LoginItemSpy(state: .off, result: .off)
    spy.failure = LoginItemFailure(domain: "SMAppServiceErrorDomain", code: 1)
    let model = window(launchAtLogin: spy.seam).model

    model.setLaunchAtLogin(true)

    #expect(spy.applied == [.register])
    #expect(!model.loginState.isOn)
    #expect(model.loginFailure == spy.failure)
    #expect(model.loginNote == ErrorText.loginItemNote(for: .off, failure: spy.failure))
}

@MainActor
@Test func bringingTheWindowBackClearsALastRefusal() {
    // The note describes one attempt, not a standing condition.
    let spy = LoginItemSpy(state: .off, result: .off)
    spy.failure = LoginItemFailure(domain: "SMAppServiceErrorDomain", code: 1)
    let controller = window(launchAtLogin: spy.seam)
    controller.model.setLaunchAtLogin(true)

    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification,
                                    object: controller.window)

    #expect(controller.model.loginFailure == nil)
    #expect(controller.model.loginNote == nil)
}

@MainActor
@Test func bringingTheWindowBackRereadsTheSystem() {
    // R146: read, never remember. A change made in System Settings while the
    // window sat behind it shows up the moment it comes forward.
    let spy = LoginItemSpy(state: .off, result: .off)
    let controller = window(launchAtLogin: spy.seam)
    spy.state = .needsApproval

    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification,
                                    object: controller.window)

    #expect(controller.model.loginState == .needsApproval)
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

@MainActor
@Test func theVersionLineSaysWhateverTheBundleSays() {
    // The number is passed in, not typed into the window, so a release that
    // bumps `CFBundleShortVersionString` needs no code change here.
    let spy = LoginItemSpy(state: .off, result: .off)
    #expect(window(launchAtLogin: spy.seam, version: "9.9.9").model.versionLine
            == ErrorText.versionLine("9.9.9"))
}

@MainActor
@Test func aVersionlessBuildPrintsNoVersionLineAtAll() {
    let spy = LoginItemSpy(state: .off, result: .off)
    #expect(window(launchAtLogin: spy.seam, version: nil).model.versionLine == nil)
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
    #expect(version == "1.0.2")
}
