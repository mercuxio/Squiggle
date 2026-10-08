import Foundation
import Testing
@testable import Squiggle

// MARK: - Availability

// Both halves are required, and the test exists because each half alone is a
// plausible-looking build that would put Sparkle on screen with nothing behind
// it: an unbundled binary has no app to replace, and a bundle with the feed key
// dropped from its plist has nowhere to look.
@Test func anUpdateNeedsBothABundleAndAFeed() {
    let feed = "https://example.invalid/appcast.xml"
    #expect(UpdateChecker.canUpdate(bundled: true, feedURL: feed))
    #expect(!UpdateChecker.canUpdate(bundled: false, feedURL: feed))
    #expect(!UpdateChecker.canUpdate(bundled: true, feedURL: nil))
    #expect(!UpdateChecker.canUpdate(bundled: false, feedURL: nil))
}

// Under `swift test` the main bundle is the test runner, which is an `.xctest`
// and not an app. Nothing may start an updater here — a test run that reached
// out to GitHub for an appcast would be both slow and wrong.
@Test func theTestRunnerIsNotAnUpdatableApp() {
    #expect(!UpdateChecker.canUpdate(.main))
}

@MainActor
@Test func theUnavailableCheckerDoesNothing() {
    let checker = UpdateChecker.unavailable
    #expect(!checker.isAvailable)
    #expect(!checker.automaticallyChecks())
    // Neither of these has anywhere to go, and neither may trap.
    checker.setAutomaticallyChecks(true)
    checker.checkNow()
    #expect(!checker.automaticallyChecks())
}

// MARK: - What the window does with it

// The real Info.plist is what the shipped app reads, so a key lost in an edit
// is a silently updater-less release. The three keys are cheap to assert and
// the public one is the half that must match the private key in the keychain.
@Test func theBundledPlistCarriesTheSparkleKeys() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources/Info.plist")
    let plist = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: url), format: nil) as? [String: Any]
    #expect(plist?["SUFeedURL"] as? String
        == "https://raw.githubusercontent.com/mercuxio/Squiggle/main/appcast.xml")
    #expect((plist?["SUPublicEDKey"] as? String)?.isEmpty == false)
    #expect(plist?["SUEnableAutomaticChecks"] as? Bool ?? false)
}

@MainActor
@Test func aModelWithNoUpdaterHidesTheControls() {
    let model = SettingsModel(settings: TickerSettings(),
                              launchAtLogin: stubLogin(),
                              version: nil,
                              onChange: { _ in })
    #expect(!model.showsUpdates)
}

// The toggle reads and writes through to the updater rather than keeping its
// own copy: Sparkle owns this preference and can change it itself after a
// check, so a mirrored `Bool` here would drift.
@MainActor
@Test func theToggleReadsAndWritesThroughToTheUpdater() {
    let flag = Box(false)
    let model = SettingsModel(settings: TickerSettings(),
                              launchAtLogin: stubLogin(),
                              updater: UpdateChecker(
                                isAvailable: true,
                                automaticallyChecks: { flag.value },
                                setAutomaticallyChecks: { flag.value = $0 },
                                checkNow: {}),
                              version: nil,
                              onChange: { _ in })
    #expect(model.showsUpdates)
    #expect(!model.checksForUpdatesAutomatically)
    model.checksForUpdatesAutomatically = true
    #expect(flag.value)
    flag.value = false
    #expect(!model.checksForUpdatesAutomatically)
}

@MainActor
@Test func theButtonAsksTheUpdaterOnceEachTime() {
    let checks = Box(0)
    let model = SettingsModel(settings: TickerSettings(),
                              launchAtLogin: stubLogin(),
                              updater: UpdateChecker(
                                isAvailable: true,
                                automaticallyChecks: { false },
                                setAutomaticallyChecks: { _ in },
                                checkNow: { checks.value += 1 }),
                              version: nil,
                              onChange: { _ in })
    model.checkForUpdates()
    model.checkForUpdates()
    #expect(checks.value == 2)
}

// MARK: - Helpers

@MainActor
private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// A login seam that answers without touching `SMAppService`. The updater
/// tests care nothing for login items, but `SettingsModel` reads one on init.
private func stubLogin() -> LaunchAtLogin {
    LaunchAtLogin(read: { .unavailable },
                  apply: { _ in LoginItemOutcome(.unavailable) })
}
