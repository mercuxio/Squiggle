import ServiceManagement
import Testing
@testable import Squiggle

// every status the framework defines maps to a state
@Test func statusesMap() {
    #expect(LoginItemState(status: .enabled) == .on)
    #expect(LoginItemState(status: .notRegistered) == .off)
    #expect(LoginItemState(status: .requiresApproval) == .needsApproval)
    // No bundle — `swift run`, or a test process. Not an error: the
    // control is simply not operable here.
    #expect(LoginItemState(status: .notFound) == .unavailable)
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

@Test func theButtonIsWhereTheAppIsPowerless() {
    #expect(LoginItemState.needsApproval.showsSystemSettingsButton)
    #expect(!LoginItemState.on.showsSystemSettingsButton)
    #expect(!LoginItemState.off.showsSystemSettingsButton)
    #expect(!LoginItemState.unavailable.showsSystemSettingsButton)
}
