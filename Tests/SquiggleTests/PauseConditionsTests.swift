import AppKit
import TickerCore
import Testing
@testable import Squiggle

// R138: these five literals are the whole interface to the system, and
// nothing but this test stands between a typo and a marquee that runs on
// a locked Mac forever.
@Test func distributedNamesAreExact() {
    #expect(PauseEvent(distributedName: "com.apple.screenIsLocked") == .screenLocked)
    #expect(PauseEvent(distributedName: "com.apple.screenIsUnlocked") == .screenUnlocked)
    #expect(PauseEvent(distributedName: "com.apple.screensaver.didstart") == .screensaverStarted)
    #expect(PauseEvent(distributedName: "com.apple.screensaver.didstop") == .screensaverStopped)
    #expect(PauseEvent(distributedName: "com.apple.somethingElse") == nil)
}

@Test func workspaceNamesAreExact() {
    #expect(PauseEvent(workspaceName: NSWorkspace.screensDidSleepNotification) == .displaysSlept)
    #expect(PauseEvent(workspaceName: NSWorkspace.screensDidWakeNotification) == .displaysWoke)
    #expect(PauseEvent(workspaceName: NSWorkspace.willSleepNotification) == .systemWillSleep)
    #expect(PauseEvent(workspaceName: NSWorkspace.didWakeNotification) == .systemDidWake)
    #expect(PauseEvent(workspaceName: NSWorkspace.didLaunchApplicationNotification) == nil)
}

// Every name the monitor registers has to be one the reducer recognises,
// or the registration is dead weight.
@Test func everyObservedNameResolves() {
    let distributed = PauseEvent.observedDistributedNames.compactMap {
        PauseEvent(distributedName: $0)
    }
    #expect(distributed.count == PauseEvent.observedDistributedNames.count)
    let workspace = PauseEvent.observedWorkspaceNames.compactMap {
        PauseEvent(workspaceName: $0)
    }
    #expect(workspace.count == PauseEvent.observedWorkspaceNames.count)
}

// Launch assumes nothing is in the way. It is the conservative answer in
// the same direction Task 6 chose: it costs requests, never correctness.
@Test func nothingIsPausedAtLaunch() {
    let fresh = PauseConditions()
    #expect(!fresh.isPaused)
    #expect(fresh.visibility == .visible)
}

@Test func eachConditionPausesOnItsOwn() {
    let starts: [PauseEvent] = [
        .screenLocked, .screensaverStarted, .displaysSlept, .systemWillSleep,
        .occlusionChanged(isVisible: false),
    ]
    for event in starts {
        var conditions = PauseConditions()
        conditions.apply(event)
        #expect(conditions.isPaused, "\(event)")
        #expect(conditions.visibility == .occluded, "\(event)")
    }
}

@Test func eachConditionClears() {
    let pairs: [(PauseEvent, PauseEvent)] = [
        (.screenLocked, .screenUnlocked),
        (.screensaverStarted, .screensaverStopped),
        (.displaysSlept, .displaysWoke),
        (.systemWillSleep, .systemDidWake),
        (.occlusionChanged(isVisible: false), .occlusionChanged(isVisible: true)),
    ]
    for (start, end) in pairs {
        var conditions = PauseConditions()
        conditions.apply(start)
        conditions.apply(end)
        // Ruling 10a: `#expect(conditions.isPaused == false, ...)` is the
        // banned pattern — the standalone swift-testing release mis-resolves
        // any `#expect` whose left operand is already `Bool`/`Bool?`, checking
        // that operand alone and discarding the comparison, so the line would
        // pass whenever `isPaused` is true and never catch a clearing event
        // that fails to clear.
        #expect(!conditions.isPaused, "\(start) then \(end)")
    }
}

// Waking the machine does not unlock it, and this is the bug the pairs
// above would not catch: a wake that cleared everything would start the
// marquee running behind the login window.
@Test func wakingDoesNotUnlock() {
    var conditions = PauseConditions()
    conditions.apply(.screenLocked)
    conditions.apply(.systemWillSleep)
    conditions.apply(.systemDidWake)
    conditions.apply(.displaysWoke)
    #expect(conditions.isPaused)
    conditions.apply(.screenUnlocked)
    #expect(!conditions.isPaused)
}

@Test func oneOfTwoClearingStaysPaused() {
    var conditions = PauseConditions()
    conditions.apply(.screenLocked)
    conditions.apply(.occlusionChanged(isVisible: false))
    conditions.apply(.screenUnlocked)
    #expect(conditions.isPaused)
    conditions.apply(.occlusionChanged(isVisible: true))
    #expect(!conditions.isPaused)
}

// macOS sends `screenIsLocked` more than once in some flows (lock, then
// the screensaver engaging on top of it). Counting would leave the app
// permanently paused after an unlock; flags do not count.
@Test func repeatedEventsAreIdempotent() {
    var conditions = PauseConditions()
    conditions.apply(.screenLocked)
    conditions.apply(.screenLocked)
    conditions.apply(.screenUnlocked)
    #expect(!conditions.isPaused)
}
