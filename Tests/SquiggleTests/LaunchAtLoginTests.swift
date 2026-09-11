import Foundation
import ServiceManagement
import Testing
@testable import Squiggle

// every status the framework defines maps to a state
@Test func statusesMap() {
    #expect(LoginItemState(status: .enabled, bundled: true) == .on)
    #expect(LoginItemState(status: .notRegistered, bundled: true) == .off)
    #expect(LoginItemState(status: .requiresApproval, bundled: true) == .needsApproval)
}

/// The defect behind the user's "why is the open at login checkbox disabled?".
///
/// `.notFound` was read as "there is no bundle" and mapped to `.unavailable`,
/// which greys the checkbox out. It is also what a perfectly good, correctly
/// signed, freshly installed bundle reports before it has ever been
/// registered — measured on a throwaway `.app`, which prints `notFound` on its
/// first run. So the one state where ticking the box would have worked was the
/// state that disabled the box.
///
/// No `SMAppService.Status` value distinguishes the two. Only `Bundle` knows.
@Test func notFoundInsideARealBundleIsJustNotRegisteredYet() {
    #expect(LoginItemState(status: .notFound, bundled: true) == .off)
    #expect(LaunchAtLogin.action(desired: true,
                                 current: LoginItemState(status: .notFound, bundled: true))
            == .register)
}

/// The genuine no-bundle case: `swift run`, or this test process. There is
/// nothing to register, and the control says so by being dead.
@Test func withoutABundleEveryStatusIsUnavailable() {
    for status in [SMAppService.Status.enabled, .notRegistered,
                   .requiresApproval, .notFound] {
        #expect(LoginItemState(status: status, bundled: false) == .unavailable)
    }
}

/// Whether this process has a bundle to register is a question about the
/// executable's own home, and `swift run` answers it honestly: the binary
/// sits in `.build`, and a test process in an `.xctest`. Neither is an `.app`.
@Test func theBundleCheckIsAboutTheExtensionNotTheStatus() {
    #expect(!LaunchAtLogin.isBundledApp(Bundle.main))
}

// R146: the two off-ish states differ in what fixes them, and the
// difference is the whole reason they are separate cases.
@Test func turningItOn() {
    #expect(LaunchAtLogin.action(desired: true, current: .off) == .register)
    #expect(LaunchAtLogin.action(desired: true, current: .needsApproval)
            == .openSystemSettings)
}

@Test func turningItOff() {
    #expect(LaunchAtLogin.action(desired: false, current: .on) == .unregister)
    // Registered but switched off by the user: unchecking the box should
    // still remove the pending item, not leave it lying in Login Items.
    #expect(LaunchAtLogin.action(desired: false, current: .needsApproval) == .unregister)
}

// `register()` throws when the service is already registered, so asking
// for what is already true has to be a no-op rather than a call.
@Test func idempotence() {
    #expect(LaunchAtLogin.action(desired: true, current: .on) == .nothing)
    #expect(LaunchAtLogin.action(desired: false, current: .off) == .nothing)
}

// nothing is attempted when there is no bundle to register
@Test func unavailableIsInert() {
    #expect(LaunchAtLogin.action(desired: true, current: .unavailable) == .nothing)
    #expect(LaunchAtLogin.action(desired: false, current: .unavailable) == .nothing)
}

// The checkbox shows what the system will actually do at the next login.
// `.needsApproval` means it will not launch, so the box is not ticked —
// the note and the button are what explain the difference.
@Test func theBoxFollowsTheSystem() {
    #expect(LoginItemState.on.isOn)
    #expect(!LoginItemState.off.isOn)
    #expect(!LoginItemState.needsApproval.isOn)
    #expect(!LoginItemState.unavailable.isOn)
}

// the control is operable in every state but the one with no bundle
@Test func onlyAMissingBundleDisablesIt() {
    #expect(LoginItemState.on.isEnabled)
    #expect(LoginItemState.off.isEnabled)
    #expect(LoginItemState.needsApproval.isEnabled)
    #expect(!LoginItemState.unavailable.isEnabled)
}

// R146: a state whose fix lives outside this app has to say so.
@Test func onlyTheConfusingStatesExplainThemselves() {
    #expect(ErrorText.loginItemNote(for: .on) == nil)
    #expect(ErrorText.loginItemNote(for: .off) == nil)
    #expect(ErrorText.loginItemNote(for: .needsApproval) != nil)
    #expect(ErrorText.loginItemNote(for: .unavailable) != nil)
}

// the button appears exactly where clicking the box cannot help
@Test func theButtonIsWhereTheAppIsPowerless() {
    #expect(LoginItemState.needsApproval.showsSystemSettingsButton)
    #expect(!LoginItemState.on.showsSystemSettingsButton)
    #expect(!LoginItemState.off.showsSystemSettingsButton)
    #expect(!LoginItemState.unavailable.showsSystemSettingsButton)
}

// MARK: - Saying why, when macOS refuses (the punch list's item 6)

// The defect: `register()` was called through `try?`, so a refusal and a
// success were the same event as far as this app could tell. The user saw a
// checkbox that would not tick and no reason anywhere on screen.
@Test func aRefusalExplainsItselfInsteadOfLeavingTheBoxSilentlyUnticked() throws {
    let refused = LoginItemFailure(domain: "SMAppServiceErrorDomain", code: 1)
    let note = try #require(ErrorText.loginItemNote(for: .off, failure: refused))
    #expect(note.contains("SMAppServiceErrorDomain"))
    #expect(note.contains("1"))
}

// The state note answers "what will happen at next login"; a failure answers
// "why did nothing happen just now". The second is the newer news.
@Test func aRefusalOutranksTheStateItLeftBehind() throws {
    let refused = LoginItemFailure(domain: "SMAppServiceErrorDomain", code: 1)
    let plain = try #require(ErrorText.loginItemNote(for: .needsApproval))
    let failed = try #require(ErrorText.loginItemNote(for: .needsApproval,
                                                     failure: refused))
    #expect(plain != failed)
}

@Test func withNothingRefusedTheStateSpeaksForItself() {
    for state in [LoginItemState.on, .off, .needsApproval, .unavailable] {
        #expect(ErrorText.loginItemNote(for: state, failure: nil)
                == ErrorText.loginItemNote(for: state))
    }
}

// R44: this line is meant to be safe to read aloud or paste into an email, so
// it carries the domain and code and nothing the system put a path into.
@Test func aRefusalNoteNamesNoFile() throws {
    let raw = NSError(domain: "NSCocoaErrorDomain", code: 513, userInfo: [
        NSLocalizedDescriptionKey: "No permission to save /Users/someone/thing.",
        NSFilePathErrorKey: "/Users/someone/thing",
    ])
    let note = try #require(ErrorText.loginItemNote(for: .off,
                                                   failure: LoginItemFailure(raw)))
    #expect(!note.contains("/"))
}

// An `Error` reduces to the two facts worth showing. Everything else about an
// `NSError` — userInfo, the underlying error, the recovery suggestion — is
// where the paths live.
@Test func anErrorReducesToItsDomainAndCode() {
    let raw = NSError(domain: "SMAppServiceErrorDomain", code: 1,
                      userInfo: [NSFilePathErrorKey: "/Applications/Squiggle.app"])
    let failure = LoginItemFailure(raw)
    #expect(failure.domain == "SMAppServiceErrorDomain")
    #expect(failure.code == 1)
}

// An outcome with nothing wrong reads exactly as the state did before this
// existed, so every caller that only cares about the state stays honest.
@Test func anOutcomeWithoutAFailureIsJustAState() {
    #expect(LoginItemOutcome(.on).state == .on)
    #expect(LoginItemOutcome(.on).failure == nil)
}
