import Foundation
import Testing
import TickerCore
@testable import squigglectl
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// `evaluateTradingPeriods` and `classifyStoreError` are `static` rather than
// `private static` (not `public`: nothing outside `squigglectl` has any
// business calling them), which is what makes the behaviour below assertable
// without a request.
//
// `DoctorRun.run()` itself reaches its client through a concrete
// `YahooClient` rather than an abstraction, so exercising a path that
// actually calls the quote or search endpoint means talking to Yahoo — out of
// reach here. The tests further down that call `run()` directly stay within
// that limit by only ever pointing it at a store whose cooldown is active:
// the gate skips both network checks before either can be reached, so `run()`
// completes without a request.

// MARK: - evaluateTradingPeriods

/// Windows built relative to the wall clock, because `evaluateTradingPeriods`
/// reads `Date()` itself. `offsets` are seconds from now.
private func window(_ from: Double, _ to: Double) -> TradingPeriod.Window {
    let now = Date().timeIntervalSince1970
    return TradingPeriod.Window(startEpoch: now + from, endEpoch: now + to)
}

@Test func aResponseWithNoTradingCalendarIsDegradedRatherThanSilent() {
    let (absent, absentDetail) = DoctorRun.evaluateTradingPeriods(nil)
    #expect(absent == .degraded)
    #expect(absentDetail == "no trading calendar in this response")

    // Present but empty is the same condition wearing a different shape: a
    // `TradingPeriod` whose three windows are all nil says nothing at all.
    let empty = TradingPeriod(pre: nil, regular: nil, post: nil)
    let (emptyStatus, emptyDetail) = DoctorRun.evaluateTradingPeriods(empty)
    #expect(emptyStatus == .degraded)
    #expect(emptyDetail == "no trading calendar in this response")
}

@Test func aDegenerateOrInvertedWindowIsReportedAsInconsistent() {
    // Yahoo emits `start == end` on some holidays, and `Window.contains`
    // answers false for every epoch when it does — a window that contains
    // nothing is not a calendar this check can vouch for.
    let degenerate = TradingPeriod(pre: nil, regular: window(0, 0), post: nil)
    let (degenerateStatus, degenerateDetail) = DoctorRun.evaluateTradingPeriods(degenerate)
    #expect(degenerateStatus == .degraded)
    #expect(degenerateDetail == "trading calendar windows are inconsistent")

    let inverted = TradingPeriod(pre: nil, regular: window(3_600, -3_600), post: nil)
    let (invertedStatus, _) = DoctorRun.evaluateTradingPeriods(inverted)
    #expect(invertedStatus == .degraded)
}

@Test func sessionsOutOfChronologicalOrderAreReportedAsInconsistent() {
    // Pre-market running past the opening bell is not a schedule any venue
    // keeps; it means the payload's fields were mismatched.
    let overlapping = TradingPeriod(pre: window(-7_200, 1_800),
                                    regular: window(-3_600, 3_600),
                                    post: window(3_600, 7_200))
    let (status, detail) = DoctorRun.evaluateTradingPeriods(overlapping)
    #expect(status == .degraded)
    #expect(detail == "trading calendar windows are inconsistent")
}

@Test func sessionsThatTouchExactlyAreAcceptedBecauseWindowsAreHalfOpen() {
    // `Window.contains` is `[start, end)`, so pre ending at the same instant
    // regular begins is the *normal* shape of a trading day, not an overlap:
    // the opening bell belongs to exactly one session. Rejecting it would
    // report every ordinary day as inconsistent.
    let touching = TradingPeriod(pre: window(-7_200, -3_600),
                                 regular: window(-3_600, 3_600),
                                 post: window(3_600, 7_200))
    let (status, _) = DoctorRun.evaluateTradingPeriods(touching)
    #expect(status == .ok)
}

@Test func aConsistentCalendarReportsWhichSessionIsRunningNow() {
    let inRegular = TradingPeriod(pre: window(-7_200, -3_600),
                                  regular: window(-3_600, 3_600),
                                  post: window(3_600, 7_200))
    let (regularStatus, regularDetail) = DoctorRun.evaluateTradingPeriods(inRegular)
    #expect(regularStatus == .ok)
    #expect(regularDetail == Rendering.describe(.regular))

    let inPre = TradingPeriod(pre: window(-1_800, 1_800),
                              regular: window(1_800, 9_000),
                              post: window(9_000, 12_600))
    let (preStatus, preDetail) = DoctorRun.evaluateTradingPeriods(inPre)
    #expect(preStatus == .ok)
    #expect(preDetail == Rendering.describe(.pre))

    let inPost = TradingPeriod(pre: window(-12_600, -9_000),
                               regular: window(-9_000, -1_800),
                               post: window(-1_800, 1_800))
    let (postStatus, postDetail) = DoctorRun.evaluateTradingPeriods(inPost)
    #expect(postStatus == .ok)
    #expect(postDetail == Rendering.describe(.post))
}

@Test func aCalendarWhoseSessionsHaveAllPassedIsHealthyAndClosed() {
    // The check asks whether the calendar is coherent, not whether the market
    // happens to be open. Reporting an evening run as degraded would teach the
    // user to ignore the line.
    let allPast = TradingPeriod(pre: window(-25_200, -21_600),
                                regular: window(-21_600, -14_400),
                                post: window(-14_400, -7_200))
    let (status, detail) = DoctorRun.evaluateTradingPeriods(allPast)
    #expect(status == .ok)
    #expect(detail == Rendering.describe(.closed))
}

@Test func aCalendarWithOnlyOneSessionIsStillJudgedOnItsOwn() {
    // Crypto and some venues report a single window. One window cannot be out
    // of order with anything, so the only question left is whether it is
    // degenerate.
    let onlyRegular = TradingPeriod(pre: nil, regular: window(-3_600, 3_600), post: nil)
    let (status, detail) = DoctorRun.evaluateTradingPeriods(onlyRegular)
    #expect(status == .ok)
    #expect(detail == Rendering.describe(.regular))
}

// MARK: - classifyStoreError

@Test func anUnreadableSchemaBlamesTheSchemaAndNotTheFile() {
    // The bytes were read and parsed; it is the version inside them this build
    // cannot honour. Marking `storeFile` broken here would send the user
    // looking for disk trouble that does not exist.
    let unsupported = DoctorRun.classifyStoreError(.storeSchemaUnsupported(version: 99))
    #expect(unsupported.file == .ok)
    #expect(unsupported.schema == .degraded)

    let unreadable = DoctorRun.classifyStoreError(.storeVersionUnreadable)
    #expect(unreadable.file == .ok)
    #expect(unreadable.schema == .degraded)
}

@Test func aCorruptFileSkipsTheSchemaCheckItMadeUnanswerable() {
    // Nothing parsed, so there is no schema to have an opinion about. Skipped
    // rather than degraded: `Diagnosis.overall` ignores skips, and reporting
    // both lines as degraded would double-count one fault.
    let quarantined = URL(fileURLWithPath: "/Users/example/Library/Application Support/Squiggle/watchlist.json.bad-1")
    let corrupt = DoctorRun.classifyStoreError(.storeCorrupt(quarantinedAt: quarantined))
    #expect(corrupt.file == .degraded)
    #expect(corrupt.schema == .skipped)

    let stuck = DoctorRun.classifyStoreError(.storeQuarantineFailed(at: quarantined))
    #expect(stuck.file == .degraded)
    #expect(stuck.schema == .skipped)
}

@Test func aStoreFaultCarryingAPathPrintsTheNameAndNotTheLocation() {
    // R44: `doctor`'s output has to be safe to paste into a support email, and
    // a store path contains the user's account name. Both store errors that
    // carry a URL are checked here, because both are rendered by `DoctorRun`'s
    // store branch and either one leaking would be the same disclosure.
    let quarantined = URL(fileURLWithPath: "/Users/example/Library/Application Support/Squiggle/watchlist.json.bad-1")
    for error in [TickerError.storeCorrupt(quarantinedAt: quarantined),
                  TickerError.storeQuarantineFailed(at: quarantined)] {
        let rendered = Rendering.diagnosis(error)
        #expect(rendered.contains("watchlist.json.bad-1"))
        #expect(!rendered.contains("/"))
        #expect(!rendered.contains("example"))
    }
}

@Test func aFaultTheStoreCannotProduceIsStillClassifiedRatherThanCrashing() {
    // `FileWatchlistStore.load()` never throws a feed error, but the switch is
    // exhaustive rather than defaulted so a new `TickerError` case fails this
    // build. The arm still has to give a usable answer if one ever arrives:
    // the file line borrows `Diagnosis`'s own classification and the schema
    // line, which nothing has learned anything about, is skipped.
    let transport = DoctorRun.classifyStoreError(.transport(.urlSession(code: -1001)))
    #expect(transport.file == Diagnosis.status(for: .transport(.urlSession(code: -1001))))
    #expect(transport.schema == .skipped)

    let unauthorized = DoctorRun.classifyStoreError(.unauthorized(status: 401))
    #expect(unauthorized.file == .broken)
    #expect(unauthorized.schema == .skipped)
}

// MARK: - run() against a hand-built store, no network

/// An async mutex. `actor` isolation alone does not serialize the critical
/// section below: an `await` inside an actor-isolated method suspends and
/// makes the actor reentrant, so a second queued caller can start running
/// before the first one that is mid-`await` finishes. `acquire()`/`release()`
/// are each a single synchronous actor hop with no `await` in between, so the
/// caller — not the actor — holds the lock across its own `await`, and a
/// second caller genuinely waits rather than interleaving.
private actor AsyncLock {
    static let shared = AsyncLock()

    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// `DoctorRun.run()` prints its findings rather than returning them, so
/// asserting on what it reported means capturing standard output while it
/// runs. `fileno(stdout)` is one file descriptor for the whole process —
/// Swift Testing runs `@Test`s concurrently by default — so the redirect
/// below is wrapped in `AsyncLock` to keep only one capture installed at a
/// time; every `captureStdout` call queues on it.
private func captureStdout(_ body: @Sendable () async -> Int32) async -> (output: String, exitCode: Int32) {
    await AsyncLock.shared.acquire()

    // A temp file rather than a `Pipe`: a pipe's read end blocks until every
    // writer of its write end closes, and the duplicate this installs at
    // `fileno(stdout)` is still held open by the process itself even after
    // `pipe.fileHandleForWriting` is closed — `readDataToEndOfFile()` would
    // hang forever waiting for an EOF that never comes. A file has no such
    // reader/writer handshake: it is simply read back after `stdout` is
    // restored.
    let captureURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("squigglectl-doctor-tests-stdout-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: captureURL.path, contents: nil)
    let captureHandle = FileHandle(forWritingAtPath: captureURL.path)!

    fflush(stdout)
    let savedStdout = dup(fileno(stdout))
    dup2(captureHandle.fileDescriptor, fileno(stdout))

    let exitCode = await body()

    fflush(stdout)
    dup2(savedStdout, fileno(stdout))
    close(savedStdout)
    try? captureHandle.close()

    let data = (try? Data(contentsOf: captureURL)) ?? Data()
    try? FileManager.default.removeItem(at: captureURL)

    await AsyncLock.shared.release()
    return (String(data: data, encoding: .utf8) ?? "", exitCode)
}

private func tempStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("squigglectl-doctor-tests-\(UUID().uuidString)")
        .appendingPathComponent("squiggle.json")
}

/// A cooldown deadline this large is not one `BackoffLadder` could ever have
/// written — its own longest cooldown, `RateConstants.maxCooldownSeconds`, is
/// 3600s (`max(rateLimitBackoffCap, serverBackoffCap, unauthorizedCooldown,
/// contractFaultCooldown)` = `max(1800, 900, 3600, 3600)`). Read back
/// unclamped, it disables both network checks for 8,760 times as long as the
/// app can legitimately impose, and check 7 reported the raw figure — 8
/// digits a support reader has no way to make sense of.
@Test func aCooldownDeadlineAYearOutIsClampedAndTheClampIsNamedOnCheckSeven() async throws {
    let url = tempStoreURL()
    let now = Date().timeIntervalSince1970
    try FileWatchlistStore(url: url).save(Store(cooldownUntilEpoch: now + 31_536_000))

    let (output, exitCode) = await captureStdout {
        await DoctorRun(storeURL: url).run()
    }

    // Both network checks are gated at the clamped figure, not the raw one.
    #expect(output.contains("not asked — backoff active for another 3600s"))
    #expect(!output.contains("31536000"))

    // Check 7 ("backoff") reports the same clamped remaining interval, plus
    // the finding that named the clamp firing. Matched on the check's own
    // label immediately followed by " — " so this cannot pick up check 1 or
    // 2's line, which also contains the word "backoff" inside its detail.
    let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
    let cooldownLine = try #require(lines.first { $0.contains("backoff — ") })
    #expect(cooldownLine.contains("active for another 3600s"))
    #expect(cooldownLine.contains("stored deadline exceeds the longest cooldown"))
    #expect(cooldownLine.contains("treated as that maximum"))
    #expect(!cooldownLine.contains("31536000"))
    // R44: no raw stored value, no path, no epoch.
    #expect(!cooldownLine.contains("/"))

    #expect(exitCode == 1)
}

/// The companion case: a deadline `BackoffLadder` could actually have
/// produced (900s sits under every one of its caps) is reported as itself,
/// with no clamp finding attached.
@Test func aLegitimateNineHundredSecondCooldownIsReportedUnclampedAndUnflagged() async throws {
    let url = tempStoreURL()
    let now = Date().timeIntervalSince1970
    try FileWatchlistStore(url: url).save(Store(cooldownUntilEpoch: now + 900))

    let (output, exitCode) = await captureStdout {
        await DoctorRun(storeURL: url).run()
    }

    #expect(output.contains("not asked — backoff active for another 900s"))

    let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
    let cooldownLine = try #require(lines.first { $0.contains("backoff — ") })
    #expect(cooldownLine.contains("active for another 900s"))
    #expect(!cooldownLine.contains("exceeds the longest cooldown"))
    #expect(!cooldownLine.contains("treated as"))

    #expect(exitCode == 1)
}

/// Check 3 ("trading calendar") is free from `snapshot`, and under a
/// cooldown `snapshot` stays `nil` — check 1 never ran. The check reports
/// that as `.skipped`, not as `.degraded` with a claim about a payload that
/// was never fetched.
@Test func tradingPeriodsIsSkippedRatherThanDegradedWhenTheQuoteCheckNeverRan() async throws {
    let url = tempStoreURL()
    let now = Date().timeIntervalSince1970
    try FileWatchlistStore(url: url).save(Store(cooldownUntilEpoch: now + 900))

    let (output, _) = await captureStdout {
        await DoctorRun(storeURL: url).run()
    }

    let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
    let tradingLine = try #require(lines.first { $0.contains("trading calendar") })
    #expect(tradingLine.contains("[skip]"))
    #expect(tradingLine.contains("no response to read"))
    #expect(!tradingLine.contains("no trading calendar in this response"))
}

// MARK: - N-2's exit-code contract

/// `evaluateTradingPeriods(nil)` used to answer `.degraded`, and check 3
/// carried that into `Diagnosis.overall`; it now answers `.skipped` and does
/// not. `Diagnosis.overall`/`exitCode` are the actual contract — this feeds
/// them the check lists `run()` produces on both paths where `snapshot` is
/// `nil` (check 1 gated by the cooldown, and check 1 itself at fault) and
/// confirms the exit code lands the same place either way. No network: this
/// calls the real classification functions by hand rather than running
/// `DoctorRun` against a live quote fault.
@Test func removingCheckThreesDegradedNeverMovesTheExitCodeWhenSnapshotIsNil() throws {
    func exitCode(tradingStatus: CheckStatus, otherChecks: [Check]) -> Int32 {
        var checks = otherChecks
        checks.insert(Check(id: .tradingPeriods, status: tradingStatus), at: 2)
        return Diagnosis.exitCode(for: Diagnosis.overall(checks))
    }

    // Path 1: check 1 skipped under the cooldown gate. Check 7 is already
    // `.degraded` on this path — that is what made the run `.degraded`
    // (exit 1) before this fix, and still does after it.
    let cooldownGated: [Check] = [
        Check(id: .quoteEndpoint, status: .skipped),
        Check(id: .searchEndpoint, status: .skipped),
        Check(id: .storeFile, status: .ok),
        Check(id: .storeSchema, status: .ok),
        Check(id: .setAsideFiles, status: .ok),
        Check(id: .cooldown, status: .degraded),
        Check(id: .budget, status: .ok),
    ]
    let cooldownOld = exitCode(tradingStatus: .degraded, otherChecks: cooldownGated)
    let cooldownNew = exitCode(tradingStatus: .skipped, otherChecks: cooldownGated)
    #expect(cooldownOld == 1)
    #expect(cooldownNew == cooldownOld)

    // Path 2: check 1 itself answered `.degraded` (offline, rate-limited,
    // a bad symbol, ...). Check 1's own status already carries the
    // `.degraded` that check 3 used to duplicate.
    let quoteDegraded: [Check] = [
        Check(id: .quoteEndpoint, status: .degraded),
        Check(id: .searchEndpoint, status: .ok),
        Check(id: .storeFile, status: .ok),
        Check(id: .storeSchema, status: .ok),
        Check(id: .setAsideFiles, status: .ok),
        Check(id: .cooldown, status: .ok),
        Check(id: .budget, status: .ok),
    ]
    let degradedOld = exitCode(tradingStatus: .degraded, otherChecks: quoteDegraded)
    let degradedNew = exitCode(tradingStatus: .skipped, otherChecks: quoteDegraded)
    #expect(degradedOld == 1)
    #expect(degradedNew == degradedOld)

    // Path 3: check 1 itself answered `.broken` (unauthorized). `.broken`
    // outranks `.degraded` in `Diagnosis.overall`, so check 3's old
    // contribution was already redundant here too.
    let quoteBroken: [Check] = [
        Check(id: .quoteEndpoint, status: .broken),
        Check(id: .searchEndpoint, status: .skipped),
        Check(id: .storeFile, status: .ok),
        Check(id: .storeSchema, status: .ok),
        Check(id: .setAsideFiles, status: .ok),
        Check(id: .cooldown, status: .ok),
        Check(id: .budget, status: .ok),
    ]
    let brokenOld = exitCode(tradingStatus: .degraded, otherChecks: quoteBroken)
    let brokenNew = exitCode(tradingStatus: .skipped, otherChecks: quoteBroken)
    #expect(brokenOld == 2)
    #expect(brokenNew == brokenOld)
}

// MARK: - check 6: the set-aside listing

/// Check 6's comment has always read "names only, never a path", and nothing
/// executed it. The same rule is pinned one layer down by
/// `aStoreFaultCarryingAPathPrintsTheNameAndNotTheLocation`, but that test
/// exercises `Rendering.diagnosis`, and check 6 does not go through
/// `Rendering.diagnosis` at all — it builds its detail itself out of
/// `contentsOfDirectory`, which is exactly the API whose results become
/// absolute paths the moment someone reaches for `URL.path` instead of the
/// entry name. A rule stated in a comment beside code that does not execute
/// it is the failure mode this whole review is about.
///
/// The casualties are set aside by hand rather than by corrupting a store,
/// because what is under test is the *listing*, not the quarantine: two files
/// with check 6's prefix are all it takes, and building them directly also
/// pins that a second casualty in the same second is reported alongside the
/// first rather than hiding it.
@Test func theSetAsideListingNamesTheCasualtiesAndNotTheDirectoryTheyAreIn() async throws {
    let url = tempStoreURL()
    let directory = url.deletingLastPathComponent()
    // An active cooldown keeps `run()` off the network, as at the top of this
    // file. `save` creates the directory the casualties go into.
    let now = Date().timeIntervalSince1970
    try FileWatchlistStore(url: url).save(Store(cooldownUntilEpoch: now + 900))

    let casualties = ["squiggle.json.bad-2026-09-08T12-00-00Z",
                      "squiggle.json.bad-2026-09-08T12-00-00Z-2"]
    for name in casualties {
        try Data("{}".utf8).write(to: directory.appendingPathComponent(name))
    }

    let (output, _) = await captureStdout {
        await DoctorRun(storeURL: url).run()
    }

    let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
    let line = try #require(lines.first { $0.contains("earlier unreadable settings files") })

    // Both, not just the first: the earlier casualty is usually the more
    // informative one, and a listing that stops at one hides it.
    for name in casualties {
        #expect(line.contains(name), "check 6 did not name \(name): \(line)")
    }
    #expect(line.contains("[warn]"))

    // R44, asserted on the character a path cannot avoid rather than on this
    // machine's temporary directory, which is what makes the assertion catch
    // any path and not only the one this test happens to build.
    #expect(!line.contains("/"), "check 6 leaked a path: \(line)")
    #expect(!line.contains(directory.path))
}

// MARK: - check 8: the daily estimate and which floor sets the pace

/// Check 8 printed `~720 requests/day` full stop, and the estimator behind it
/// prices three fixed US equity sessions. Beside a watchlist of `BTC-USD` that
/// is a statement about a day the symbol does not have.
///
/// The fix is the qualification, not a detection: `doctor` reports on stored
/// settings and cannot see what the symbols trade as. So this asserts the
/// printed line names its calendar, and then takes the two numbers that make
/// the qualification necessary — what the estimator says a day costs, and what
/// the same settings cost on a calendar with no closing bell.
@Test func theDailyEstimateSaysWhichCalendarItPriced() async throws {
    let url = tempStoreURL()
    let now = Date().timeIntervalSince1970
    let symbols = (1...RateConstants.maxWatchlistCount).map { index -> Symbol in
        Symbol("SYM\(index)")!
    }
    try FileWatchlistStore(url: url).save(
        Store(symbols: symbols,
              settings: Settings(refreshIntervalSeconds: RateConstants.defaultRefreshInterval),
              cooldownUntilEpoch: now + 900))

    let (output, _) = await captureStdout {
        await DoctorRun(storeURL: url).run()
    }
    let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
    let line = try #require(lines.first { $0.contains("daily request estimate") })
    #expect(line.contains("US market calendar"), "the estimate named no calendar: \(line)")

    // The two figures, re-taken rather than described. 1,120 is what the
    // estimator reports for these exact settings — the number the line above
    // prints — and 1,200 is what the same 20 symbols at the same cycle cost on
    // an instrument that never closes.
    //
    // The gap used to be 480: eight hours of shut market a US calendar did not
    // pay for. It is 80 now, because "forget the market calendar" made the app
    // poll that span like any other, and what is left of the gap is the quiet
    // multiplier on 9.5 hours of extended trading. The qualification is still
    // not cosmetic — it is just far less generous than it was.
    let estimate = Diagnosis.estimatedDailyRequests(
        userIntervalSeconds: RateConstants.defaultRefreshInterval,
        watchlistCount: RateConstants.maxWatchlistCount)
    #expect(estimate == 1_120)
    #expect(line.contains("~1120 requests/day"))

    let cycle = RefreshPolicy.budgetFloor(watchlistCount: RateConstants.maxWatchlistCount)
    let neverClosing = RateConstants.secondsPerDay / cycle
        * Double(RateConstants.maxWatchlistCount)
    #expect(neverClosing == 1_200)
    #expect(neverClosing == Double(RateConstants.dailyRequestBudget))
}

/// F19. Check 8's throttled branch carried the fixed sentence "the 30s spacing
/// floor sets the pace here", and no watchlist size and no offered interval
/// can make that true.
///
/// `cycleInterval` is `max(max(requested, n × spacingSeconds), budgetFloor(n))`,
/// and `budgetFloor(n)` is `n × 86_400 / 1_200` — `n × 72` against `n × 30`.
/// The budget floor is therefore strictly larger at every n ≥ 1, both scale
/// linearly in n so no size crosses over, and whenever either floor binds at
/// all the cycle is exactly `budgetFloor(n)`. The spacing floor cannot be the
/// binding term on its own for any input this app can reach.
///
/// Swept rather than argued, over every watchlist size the app admits and
/// every interval Settings offers, plus the two out-of-menu values a
/// hand-edited file can produce.
@Test func theSpacingFloorCanNeverBeTheBindingTermCheckEightReportsOn() {
    for count in 1...RateConstants.maxWatchlistCount {
        let spacingFloor = Double(count) * RateConstants.spacingSeconds
        let budgetFloor = RefreshPolicy.budgetFloor(watchlistCount: count)
        #expect(budgetFloor > spacingFloor,
                "\(count) symbols: budget floor \(budgetFloor)s did not exceed spacing floor \(spacingFloor)s")

        for interval in RateConstants.refreshIntervalChoices + [0.1, 7_200] {
            let throttled = Diagnosis.pacerThrottlesSettings(userIntervalSeconds: interval,
                                                             watchlistCount: count)
            guard throttled else { continue }
            let cycle = RefreshPolicy.cycleInterval(userIntervalSeconds: interval,
                                                    watchlistCount: count,
                                                    marketState: .regular,
                                                    lowPowerMode: false)
            // Not merely "at least the spacing floor" — exactly the budget
            // floor. That equality is what makes naming the budget floor
            // unconditionally an honest sentence rather than a better guess.
            #expect(cycle == budgetFloor,
                    "\(count) symbols at \(interval)s: cycle \(cycle)s is not the budget floor")
            #expect(cycle > spacingFloor)
        }
    }
}

/// And the line itself, on the case check 8 actually prints for: 20 symbols at
/// the default interval is throttled, and the detail names the floor that is
/// doing it with the cycle it imposes.
@Test func theThrottledEstimateNamesTheBudgetFloorAndTheCycleItImposes() async throws {
    let url = tempStoreURL()
    let now = Date().timeIntervalSince1970
    let symbols = (1...RateConstants.maxWatchlistCount).map { index -> Symbol in
        Symbol("SYM\(index)")!
    }
    try FileWatchlistStore(url: url).save(
        Store(symbols: symbols,
              settings: Settings(refreshIntervalSeconds: RateConstants.defaultRefreshInterval),
              cooldownUntilEpoch: now + 900))

    let (output, _) = await captureStdout {
        await DoctorRun(storeURL: url).run()
    }
    let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
    let line = try #require(lines.first { $0.contains("daily request estimate") })

    #expect(line.contains("daily-budget floor"))
    #expect(line.contains("1440s"))
    #expect(!line.contains("spacing floor"),
            "check 8 named a floor that cannot bind here: \(line)")
    #expect(line.contains("[warn]"))
}
