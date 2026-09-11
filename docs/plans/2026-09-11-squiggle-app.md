# Squiggle — The App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `Sources/Squiggle/` — the AppKit menu bar app that puts the watchlist in the menu bar as one or two scrolling rows, with a settings window, a search-driven symbol picker, launch-at-login, and a signed `.app` bundle — on top of the `TickerCore` that plan 1 already proved.

**Architecture:** One `NSStatusItem` whose button hosts a single `NSView` backed by a pre-rendered `CALayer` strip. A `TickerRunner` owns the only real timer in the system: it asks `FeedEngine` what to do next and obeys, exactly as `squigglectl watch` already does. Every scheduling, staleness and rate-limit decision comes from `TickerCore`; the app supplies words, pixels and AppKit lifecycle, and nothing else. Text measurement happens once per data change, not per frame.

**Tech Stack:** Swift 6, SwiftPM, AppKit, Core Animation, ServiceManagement (`SMAppService`), swift-testing. No Xcode, no SwiftUI, no third-party runtime dependencies.

**Spec:** `docs/specs/2026-09-08-squiggle-design.md`

**Predecessor:** `docs/plans/2026-09-08-tickercore-and-cli.md` (Tasks 1–18 complete; Task 19 skipped by ruling R117).

## Scope

This plan implements **steps 5–9 of the spec's build order (§9)** — with step 9 brought forward, see R123 below. It starts from a green `swift test` on `main` and ends with a `Squiggle.app` you can put in `/Applications` and log in to.

It also carries **the one obligation ruling R117 left behind**: the trading day that was skipped would have caught a request burst on wake-from-sleep, and nothing in `swift test` can suspend a machine. Task 16 is that verification, and it is not optional.

### What this plan does not build

- A second data source, charts, alerts, price triggers, portfolio quantities, multiple watchlists, logos. Spec §10 puts all of these out of scope for 1.0 and nothing here changes that.
- Notarisation. `scripts/package-app.sh` ad-hoc-signs, exactly as Pitch's does; shipping needs a Developer ID identity this machine does not hold (spec §9 step 9 says "notarised zip" — see R126).

## Rulings carried into this plan

Plan 1's ledger ends at R117. These continue that numbering, and each was taken while writing this plan rather than during execution, so they are settled before Task 1 rather than mid-flight. An executor who disagrees with one should say so before starting the task that implements it — every one of them is cheap to reverse now and expensive later.

**R118 — `Settings.rows` defaults to 2, not 1.** Spec §5.1: *"Two rows is the default."* `Sources/TickerCore/Store.swift:67` ships `rows: Int = 1`, and `WatchlistStoreTests.swift:21` and `:95` pin that. The spec is the binding authority and the code is wrong. Task 1 changes it. *Cost if wrong:* a first launch shows two 10pt rows where the owner wanted one; changing it back is one line and one setting.

**R119 — `Settings.colorScheme` defaults to `"monochrome"`, and its vocabulary is the spec's.** The field defaults to `"auto"` and its doc comment names `"auto" | "monochrome" | "color"`. Spec §5.3's table has exactly three schemes — **Monochrome (default)**, Classic, Accessible — and "auto" is in none of them. The doc comment is this codebase's most reliable defect signature (a comment stating a rule the adjacent code breaks) pointed at a vocabulary that was never designed. Task 1 replaces the default with `"monochrome"` and the comment's list with `"monochrome" | "classic" | "accessible"`. The field stays a `String` and stays lenient: an unknown value is carried through, and the app maps it to its own enum defaulting to monochrome, which is how `NSColor` stays out of `TickerCore`. *Cost if wrong:* a first launch is uncoloured, which is the accessible default anyway.

**R120 — `Settings` gains `motionMode`.** Spec §5.1 requires two *selectable* motion modes and `Settings` has no field to select with. `"scroll" | "step"`, default `"scroll"`, same lenient string treatment as `colorScheme`. **`schemaVersion` stays 1**: every field decodes through `lenient(_:_:default:)`, so a file written before this key existed reads with the default and a file written after it reads on an older build with the key ignored. That is precisely the property the hand-written `init(from:)` was built for, and bumping the version would refuse files the current build can read perfectly. *Cost if wrong:* nothing — an unused string in a JSON file.

**R121 — `WatchLoop.Calendars` moves into `TickerCore` as `TradingCalendars`.** `EngineContext` takes one `marketState` and one `nextSessionOpenEpoch`, and the only source for either is the `TradingPeriod` riding along in each quote's body. `squigglectl` already solved this — aggregate to the *most open* state, wake at the *earliest* open — and the reasoning behind it (a crypto symbol must not put nineteen equities to sleep, an equity symbol must not put crypto to sleep for nine hours) is a hundred lines of hard-won judgement that the app must not re-derive. The type is pure: no I/O, no clock, no strings. It belongs in the core, and Task 2 moves it with its tests. *Cost if wrong:* a public type in `TickerCore` with two callers instead of one.

**R122 — `Snapshot` and the both-facts-from-one-body decode move into `TickerCore`.** `YahooFeed.Snapshot` and `YahooClient.snapshot(for:)` exist so that one request yields both the quote and the trading calendar (spec §3.2). The struct holds two `TickerCore` values and no `URLSession`, and the method is `fetch` plus two pure decodes. Task 2 moves the struct and adds `YahooQuoteDecoding.snapshot(from:symbol:)`; `YahooClient.snapshot(for:)` stays, delegating. This is what lets `TickerRunner` take `any QuoteFetching` instead of a concrete `YahooClient` — which is the parked testability finding from plan 1, closed here rather than carried further. *Cost if wrong:* one file's worth of moved code.

**R123 — Packaging moves from build-order step 9 to Task 7, right after the static status item.** `SMAppService.mainApp` requires a real bundle with a real `CFBundleIdentifier`; so does anything that reads `Bundle.main`. Leaving packaging last means launch-at-login (step 7) is written blind and tested once, at the end, with no way to bisect a failure. Building the bundle early costs one task and makes every later task run in the artifact the user will actually run. The spec's ordering was about proving the feed before the pixels, and that concern is fully discharged by plan 1. *Cost if wrong:* a bundle script written before the app it wraps is finished, which is the normal order anyway.

**R124 — `StripLayout` lives in `Sources/Squiggle/`, not `TickerCore`.** Spec §2.1 lists it among the core types. Spec §2 forbids `TickerCore` from holding AppKit or user-facing strings — and a strip layout's segments *are* formatted, user-facing text whose widths come from `NSAttributedString`. The two rules cannot both hold and §2 is the one the whole architecture rests on. The genuinely pure half is already in the core and stays there: `RowSplitter` takes widths in and deals indices out, and `StripLayout` calls it. Spec §8.5's requirement is unaffected — the type is still *"tested as a data structure — segments, offsets, colour roles"*, just from `Tests/SquiggleTests/`. *Cost if wrong:* a pure-ish type in the app target rather than the library, testable either way.

**R125 — `Rendering.transportFault(for:)` moves to `YahooFeed`.** Both executables need the same `URLError` → `TransportFault` mapping in the same catch-all, and it produces no user-facing string. It cannot go in `TickerCore` (Global Constraints forbid the networking types) and must not be copied into the app. `YahooFeed` already owns every URL type in the package. Task 2 moves it and leaves `Rendering.transportFault` as a one-line forwarder so `squigglectl`'s tests keep their entry point. *Cost if wrong:* a function in the target that owns its inputs.

**R126 — "Notarised zip" in spec §9 step 9 is delivered as an ad-hoc-signed bundle plus the Gatekeeper instruction Pitch ships.** Notarisation needs a paid Developer ID identity and `xcrun notarytool`; this machine has Command Line Tools and no such identity. Pitch shipped the same way: `codesign --force --deep --sign -`, plus a README line telling the user to clear the quarantine flag. Task 7 delivers that and `scripts/package-app.sh` carries a comment saying exactly what distribution would additionally need. *Cost if wrong:* nothing that can be fixed by writing code; it needs an Apple account.

**R127 — the strip renders `SYMBOL price ▲delta (pct%)`, and the currency code is not in it.** The spec fixes what is coloured and what carries direction but never fixes the segment order or whether the currency appears. A 10pt menu bar row is the scarcest space in the app and the user chose the symbols, so the code goes in the dropdown row where there is room for it — which is also where the `GBp` rule can be read by a human. Dead symbols render `SYMBOL ——`, keeping the slot (spec §7). The delta is rendered as an **absolute** value because the glyph already carries the sign — spec §5.3 makes the glyph the direction carrier in every scheme, and `▼-1.10` says it twice, once confusingly. *Cost if wrong:* a format string in one file.

**R128 — numbers are formatted through a `NumberFormatter` against an explicit `Locale`, defaulted to `.autoupdatingCurrent`.** `String(format: "%.2f")` is always `1234.56`, which is wrong for most of the world; `NumberFormatter` with the current locale is right and untestable unless the locale is a parameter. So every `Formatting` entry point takes `locale: Locale = .autoupdatingCurrent` and the tests pass `Locale(identifier: "en_US_POSIX")`. Decimals: 2 when `abs(value) >= 1`, 4 below it, so a $0.0431 token does not render as `$0.04` and an index does not render as `5432.1000`. *Cost if wrong:* a German user sees a full stop.

**R129 — `Formatting` formats numbers and `ErrorText` owns every sentence, including any rounding inside one.** "Updated 14 min ago" is not a number with a suffix; the choice to say "14 min" rather than "13.7 min", and to say "just now" under a minute, is a wording decision. So `ErrorText` takes raw seconds and does its own rounding, and `Formatting` never returns a sentence. This keeps the boundary testable: every `Formatting` output is a numeral, every `ErrorText` output is prose. *Cost if wrong:* one rounding helper on the wrong side of a file boundary.

**R130 — `StripLayout` segments carry a `ColorRole`, never an `NSColor`.** Spec §8.5 wants the type tested as *"segments, offsets, colour roles"*, and spec §5.3 makes the actual colour depend on the scheme, on `differentiateWithoutColor`, and on the *status item button's* effective appearance — three things that change without the layout changing. So a segment holds `.label` or `.direction(Direction)`, `ColorScheme` resolves the role at draw time, and the layout tests never touch AppKit colours. *Cost if wrong:* one indirection.

**R131 — text measurement is injected into `StripLayout` as `(String) -> Double`.** Spec §8.5: *"Pixel comparison of macOS text rendering flakes across OS versions."* The same is true of widths — `NSAttributedString.size()` differs by OS version and by installed fonts. Production passes the real measurement; tests pass a deterministic fake (a fixed width per character), which is what makes the balance, wrap and fits-the-width assertions stable. The font is not a parameter of the closure because it is fixed for the whole of one build — one row means 13pt, two rows mean 10pt for both — so the caller binds the font when it makes the closure, and `StripLayout` never imports AppKit at all. *Cost if wrong:* a closure parameter.

**R132 — the dropdown is an `NSMenu` rebuilt on `menuNeedsUpdate`, not a custom panel.** It is a list of rows, a footer line, *Refresh now* and *Quit*; `NSMenu` gets keyboard navigation, VoiceOver, dismissal and menu bar behaviour for free, and rebuilding on open means no cell ever holds a stale price. A custom `NSPanel` would re-implement all of it to gain nothing spec §7 asks for. *Cost if wrong:* a menu instead of a panel, replaceable later without touching the data path.

**R133 — Settings and the symbol picker are `NSWindow`s built in code.** No xib, no storyboard, no SwiftUI: there is no Xcode on this machine to edit a xib with, and SwiftUI would pull a second UI framework into a 15-file app whose whole visual surface is one `CALayer` and two dialogs. *Cost if wrong:* more layout code than a xib would need.

**R134 — pause conditions arrive as notifications, not as a polled predicate.** Screen lock and unlock come from `DistributedNotificationCenter` (`com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`), sleep and wake from `NSWorkspace.shared.notificationCenter`, occlusion from `NSWindow.didChangeOcclusionStateNotification`. Polling any of them would mean a timer whose entire purpose is to discover that nothing is happening, in an app whose hardest requirement is resource efficiency. The distributed-notification route needs the app to be un-sandboxed, which an ad-hoc-signed bundle with no entitlements is (R126). `PauseConditions` itself stays a pure struct of `Bool`s so it can be tested without any of them. *Cost if wrong:* the strip keeps animating behind a lock screen, which costs battery and nothing else.

---

## Global Constraints

Every task's requirements implicitly include this section. Everything in plan 1's Global Constraints still binds; these are the ones that bite in this plan, restated so no executor has to open the other document.

- **Platform floor:** macOS 14.0, arm64 only.
- **Bundle identifier (fixed, permanent):** `com.houlanyit.Squiggle`.
- **Toolchain:** Command Line Tools only. Xcode is **not** installed; `xcodebuild`, `actool` and `xcrun notarytool` are unavailable. Do not write a step that calls them. Icons are built with `iconutil`, which *is* available.
- **Every `swift build` / `swift test` / `swift run` invocation MUST pass `--build-system native`.** It prints a deprecation warning about `native`; ignore it. Without it the build fails under Command Line Tools.
- **`swift-testing` is the only dependency and must not be removed,** whatever the deprecation warnings on `@Test` advise. The toolchain ships the library but the CLT SDK does not expose the module.
- **Never write `== true` or `== false` inside `#expect`.** The macro checks the left operand alone and discards the comparison, so `#expect(x == false)` passes for every value of `x`. Write `#expect(x)` / `#expect(!x)`, or hoist into a `let` first. `??` inside `#expect` is mis-instrumented too, and a `mutating` method cannot be called inside one. A plain `try` inside `#expect` is fine. **This plan is full of `Bool` predicates — pause conditions, staleness, occlusion — which is exactly the shape the landmine hides in.**
- **No `default:` in a `switch` over one of this project's own enums,** and no `case let leaf:` standing in for one. Both silently opt out of exhaustiveness checking, which is the only thing making a new enum case a compile error instead of a shipped bug.
- **`TickerCore` must not import AppKit, SwiftUI, `UserDefaults`, `URLSession` or `Network`, and must never produce a user-facing string.** Every word the user reads in the app lives in `Sources/Squiggle/ErrorText.swift`; every number they read is formatted in `Sources/Squiggle/Formatting.swift`.
- **No `UserDefaults` anywhere, in any target.** `~/Library/Application Support/Squiggle/squiggle.json` is the whole of persistence. Launch-at-login state is owned by `SMAppService` and read back, never mirrored into the file as truth.
- **Never persist a quote and never persist a credential.** Not to the store, not to a cache, not to a log.
- **Zero alerts and zero notifications, ever** (spec §7). No `NSAlert`, no `UNUserNotificationCenter`, no modal error anywhere in this plan.
- **Symbols are stored, transmitted and displayed verbatim** as Yahoo spells them — `^GSPC`, `BRK-B`, `VOD.L`, `BTC-USD`, `EURUSD=X`. Never normalised, upper-cased or trimmed. Case is significant.
- **Never upper-case a currency code and never validate against ISO 4217.** London listings report `GBp` — pence, not pounds. Upper-casing it renders prices 100× wrong.
- **Watchlist cap: 20 symbols,** enforced on decode as well as in the picker.
- **The 30-second spacing floor is a safety property.** No code path may bypass `RequestPacer`, which means no code path may fetch except through `FeedEngine.next()` returning `.fetch`. *Refresh now* included — it takes a token like everything else.
- **Staleness is three *cycles*, not three intervals.** At 20 symbols the cycle is floored at 1,440s, so three cycles is 72 minutes and three intervals would be 9. Call `RefreshPolicy.isStale`; never compute an age and compare it to a setting.
- **Commit after every task.** Conventional prefixes (`feat:`, `test:`, `chore:`, `docs:`).

---

## File Structure

```
Package.swift                              SPM manifest — gains the Squiggle
                                           executable target and SquiggleTests
Resources/
  Info.plist                               LSUIElement bundle metadata
  AppIcon.icns                             generated, committed
Tools/
  GenerateIcon.swift                       draws the iconset with Core Graphics
scripts/
  package-app.sh                           assembles + ad-hoc-signs Squiggle.app
Sources/TickerCore/
  Store.swift                    MODIFIED  R118/R119/R120: defaults + motionMode
  TradingCalendars.swift         NEW       R121: moved from WatchLoop.Calendars
  YahooQuoteDecoding.swift       MODIFIED  R122: + Snapshot + snapshot(from:symbol:)
Sources/YahooFeed/
  YahooClient.swift              MODIFIED  R122: Snapshot moves out; delegate
  TransportFaults.swift          NEW       R125: URLError -> TransportFault
Sources/squigglectl/
  WatchLoop.swift                MODIFIED  R121: uses TickerCore.TradingCalendars
  Rendering.swift                MODIFIED  R125: transportFault forwards
Sources/Squiggle/                          (task that creates it in brackets)
  main.swift                 [3]  entry point: NSApplication, .accessory, delegate
  AppDelegate.swift          [3]  lifecycle; owns the controller; no dock menu
  Formatting.swift           [3]  price / delta / percent / age — no colour
  ErrorText.swift            [4]  every user-facing string in the app
  StripLayout.swift          [5]  segments, widths, offsets, colour roles (R124)
  TickerRunner.swift         [6]  drives FeedEngine against any QuoteFetching
  StatusItemController.swift [6]  the NSStatusItem, the one timer, the dropdown
  StripRenderer.swift        [8]  StripLayout -> CALayer + the one animation
  TickerView.swift           [8]  the NSView the status item button hosts
  MotionPolicy.swift         [9]  scroll vs step; Reduce Motion forces step
  PauseConditions.swift     [10]  occlusion, lock, screensaver, display sleep
  PauseMonitor.swift        [10]  the notification observers behind them (R134)
  MenuModel.swift           [11]  the dropdown as a value; rebuilt on demand
  ColorScheme.swift         [12]  the three schemes; NSColor resolution (R136)
  SettingsForm.swift        [13]  the settings window as a value, clamps and all
  SettingsWindow.swift      [13]  the NSWindow built in code (R133)
  LaunchAtLogin.swift       [14]  SMAppService, read back not mirrored (R146)
  SymbolPickerModel.swift   [15]  rows + message; generations live here (R148)
  SymbolPickerWindow.swift  [15]  search-driven picker with literal fallback
Tests/SquiggleTests/
  FormattingTests.swift      [3]
  ErrorTextTests.swift       [4]
  StripLayoutTests.swift     [5]
  TickerRunnerTests.swift    [6]   modified again by [12]
  StripRendererTests.swift   [8]
  MotionPolicyTests.swift    [9]
  PauseConditionsTests.swift [10]
  MenuModelTests.swift      [11]   extended by [13] and [15]
  ColorSchemeTests.swift    [12]
  SettingsFormTests.swift   [13]
  LaunchAtLoginTests.swift  [14]
  SymbolPickerTests.swift   [15]
  WakeTests.swift           [16]
Tests/TickerCoreTests/
  WatchlistStoreTests.swift  [1]   MODIFIED  R118/R119/R120; again by [14]
  TradingCalendarsTests.swift [2]  NEW  R121: moved from squigglectlTests
  FeedEngineTests.swift     [11]   MODIFIED  requestImmediateCycle
  MonotonicClockTests.swift [16]   NEW  R152: SystemClock is uptime, not a wall clock
docs/
  wake-from-sleep-log.md    [16]  the sleep audit's result (R153); no prices
```

Two names in an earlier draft of this map turned out not to survive contact
with the tasks, and are corrected above: there is no `SettingsBindingTests.swift`
(Task 13 writes `SettingsFormTests.swift`, because what it tests is a value
type and not a binding), and `PauseConditions.swift` does not hold its own
observers (Task 10 splits the watching into `PauseMonitor.swift` so the
conditions stay a pure value — R134).

---

## Task 1: Settle the settings vocabulary

The app cannot be written against `Settings` until `Settings` says what the spec says. Three fields are wrong or missing (R118, R119, R120), and all three are in one file with one decoder. Doing them together is one commit and one review; splitting them would mean three passes over the same initialiser.

**Files:**
- Modify: `Sources/TickerCore/Store.swift:52-127`
- Test: `Tests/TickerCoreTests/WatchlistStoreTests.swift:17-24`, `:90-97`, `:806-813`, plus new tests

**Interfaces:**
- Consumes: nothing new.
- Produces: `Settings.init(refreshIntervalSeconds:rows:scrollPointsPerSecond:colorScheme:motionMode:maxVisibleWidth:launchAtLogin:)` — note `motionMode` sits **after** `colorScheme` and **before** `maxVisibleWidth`, so every existing call site that passes arguments positionally must be checked. `Settings().rows == 2`, `Settings().colorScheme == "monochrome"`, `Settings().motionMode == "scroll"`. Tasks 12, 13 and 9 read all three.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/TickerCoreTests/WatchlistStoreTests.swift`:

```swift
@Test func theDefaultsAreTheOnesTheSpecNames() {
    // Spec §5.1 "Two rows is the default", §5.3's table "Monochrome
    // (default)", §5.1's two motion modes with Scroll named default. These
    // were `1` and `"auto"` until ruling R118/R119 — and `"auto"` was never
    // a scheme the spec defined at all, only a word a doc comment invented.
    let s = Settings()
    #expect(s.rows == 2)
    #expect(s.colorScheme == "monochrome")
    #expect(s.motionMode == "scroll")
}

@Test func aFileWrittenBeforeMotionModeExistedStillLoads() throws {
    // R120: the key is new and `schemaVersion` deliberately did NOT move.
    // `lenient` is what makes that safe, and this is the test that says so.
    let url = tempURL()
    try write(#"{"schemaVersion":1,"symbols":["AAPL"],"settings":{"rows":1}}"#, to: url)

    let store = try FileWatchlistStore(url: url).load()
    #expect(store.settings.motionMode == "scroll")
    #expect(store.settings.rows == 1, "an explicit 1 must survive the new default")
}

@Test func anUnknownMotionModeIsCarriedThroughRatherThanRejected() throws {
    // Same contract as `colorScheme`: a file from a future version survives a
    // downgrade unchanged, and the consumer defaults when it maps.
    let url = tempURL()
    try write(#"{"schemaVersion":1,"settings":{"motionMode":"teleport"}}"#, to: url)

    let store = try FileWatchlistStore(url: url).load()
    #expect(store.settings.motionMode == "teleport")
}

@Test func aMotionModeOfTheWrongTypeCostsOnlyItself() throws {
    let url = tempURL()
    try write(#"{"schemaVersion":1,"symbols":["AAPL"],"settings":{"motionMode":7,"rows":1}}"#,
              to: url)

    let store = try FileWatchlistStore(url: url).load()
    #expect(store.settings.motionMode == Settings().motionMode)
    #expect(store.settings.rows == 1, "one bad field cost a good one")
    #expect(store.symbols.count == 1)
}
```

Then fix the three existing tests that pin the old defaults:

- `:21` in `loadingAMissingFileYieldsTheDefaultsRatherThanAnError` — `#expect(store.settings.rows == 1)` becomes `#expect(store.settings.rows == 2)`.
- `:95` in the test whose fixture is `{"schemaVersion":1,"symbols":["AAPL"]}` (no `settings` object at all) — `#expect(store.settings.rows == 1)` becomes `#expect(store.settings.rows == 2)`.
- `:806-812` `aScalarWhereTheSymbolsArrayShouldBeLosesOnlyTheSymbols` — **this one is not a number swap.** Its fixture is `{"symbols":"AAPL","settings":{"rows":2}}` and it asserts `rows == 2` to prove the settings survived a bad `symbols`. Once 2 *is* the default, the assertion passes whether the settings survived or not, and the test stops testing anything. Flip the fixture to the non-default value:

```swift
@Test func aScalarWhereTheSymbolsArrayShouldBeLosesOnlyTheSymbols() throws {
    let url = tempURL()
    // `rows` is deliberately the NON-default 1 (R118 moved the default to 2):
    // asserting the default here would pass even if the settings were dropped
    // entirely, which is the failure this test exists to catch.
    try write(#"{"schemaVersion":1,"symbols":"AAPL","settings":{"rows":1}}"#, to: url)
    let store = try FileWatchlistStore(url: url).load()
    #expect(store.symbols.isEmpty)
    #expect(store.settings.rows == 1, "a bad symbols array cost the settings too")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
swift test --build-system native --filter WatchlistStore
```

Expected: the four new tests fail to compile (`value of type 'Settings' has no member 'motionMode'`), and `theDefaultsAreTheOnesTheSpecNames` fails on `rows` and `colorScheme` once it does compile.

- [ ] **Step 3: Change the defaults and add the field**

In `Sources/TickerCore/Store.swift`, replace the `colorScheme` doc comment and the stored properties:

```swift
    /// "monochrome" | "classic" | "accessible" (spec §5.3), stored verbatim:
    /// an unknown value is carried through rather than rejected, so a file
    /// written by a future version survives a downgrade unchanged. The
    /// consumer maps the string to its own enum and defaults there — this type
    /// does not know the menu, and it must not learn `NSColor`.
    public var colorScheme: String
    /// "scroll" | "step" (spec §5.1). Same carry-through contract as
    /// `colorScheme`. Step is *forced* when Reduce Motion is on, which is a
    /// decision the renderer makes at draw time and never writes back here —
    /// the setting records what the user chose, not what accessibility
    /// overrode it with.
    public var motionMode: String
    public var maxVisibleWidth: Double
    public var launchAtLogin: Bool

    public init(refreshIntervalSeconds: Double = RateConstants.defaultRefreshInterval,
                rows: Int = 2,
                scrollPointsPerSecond: Double = 24,
                colorScheme: String = "monochrome",
                motionMode: String = "scroll",
                maxVisibleWidth: Double = 260,
                launchAtLogin: Bool = false) {
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.rows = rows
        self.scrollPointsPerSecond = scrollPointsPerSecond
        self.colorScheme = colorScheme
        self.motionMode = motionMode
        self.maxVisibleWidth = maxVisibleWidth
        self.launchAtLogin = launchAtLogin
    }
```

And in `init(from:)`, immediately after the `colorScheme` line:

```swift
        colorScheme = c.lenient(String.self, .colorScheme, default: defaults.colorScheme)
        motionMode = c.lenient(String.self, .motionMode, default: defaults.motionMode)
```

`CodingKeys` is synthesised from the stored properties, so `.motionMode` appears without further work. Do **not** bump `Store.currentSchemaVersion`: R120 explains why, and the new `aFileWrittenBeforeMotionModeExistedStillLoads` test is the guard.

- [ ] **Step 4: Run the whole suite**

```bash
swift test --build-system native 2>&1 | tail -20
```

Expected: PASS. If anything outside `WatchlistStoreTests` fails, it is a positional `Settings(...)` call that now binds `maxVisibleWidth` to `motionMode`'s slot — the compiler catches the type mismatch, but a call passing only leading arguments may not error. Grep for every construction and read it:

```bash
grep -rn "Settings(" Sources/ Tests/ | grep -v "func \|// "
```

- [ ] **Step 5: Commit**

```bash
git add Sources/TickerCore/Store.swift Tests/TickerCoreTests/WatchlistStoreTests.swift
git commit -m "feat: make Settings say what the spec says (R118, R119, R120)"
```

---

## Task 2: Give the app the loop's shape without copying it

`squigglectl watch` already solved three problems the app has: aggregating N per-symbol trading calendars into the one `marketState` the engine takes, getting a quote and a calendar out of a single request, and turning an arbitrary `Error` into a `TransportFault`. All three currently live where only the CLI can reach them. This task moves each to the target that should own it (R121, R122, R125), so Task 6 can write `TickerRunner` without a single copied line.

Nothing here changes a signature `FeedEngine`, `RowSplitter`, `Store` or `Diagnosis` vends. It moves three types between modules and adds one pure function.

**Files:**
- Create: `Sources/TickerCore/TradingCalendars.swift`
- Create: `Sources/YahooFeed/TransportFaults.swift`
- Modify: `Sources/TickerCore/YahooQuoteDecoding.swift` (append `Snapshot` and `snapshot(from:symbol:)`)
- Modify: `Sources/YahooFeed/YahooClient.swift:8-23` (delete `Snapshot`), `:69-79` (delegate)
- Modify: `Sources/squigglectl/WatchLoop.swift` (delete `Calendars`, use `TradingCalendars`)
- Modify: `Sources/squigglectl/Rendering.swift:126` (forward `transportFault`)
- Create: `Tests/TickerCoreTests/TradingCalendarsTests.swift` (moved from `Tests/squigglectlTests/WatchLoopTests.swift:63-164`)
- Test: `Tests/squigglectlTests/WatchLoopTests.swift` keeps only the `tolerance` tests

**Interfaces:**
- Produces, in `TickerCore`:
  - `public struct TradingCalendars: Sendable` with `public init()`, `mutating func record(_ period: TradingPeriod, for symbol: Symbol)`, `mutating func retain(_ live: Set<Symbol>)`, `func aggregateState(atEpoch: Double) -> MarketState?`, `func earliestSessionOpenEpoch(after: Double) -> Double?`, `func state(for: Symbol, atEpoch: Double) -> MarketState?`, `static func openness(_ state: MarketState) -> Int`.
  - `public struct Snapshot: Sendable { public let quote: Quote; public let tradingPeriod: TradingPeriod?; public init(quote:tradingPeriod:) }`
  - `public static func YahooQuoteDecoding.snapshot(from data: Data, symbol: Symbol) throws -> Snapshot`
- Produces, in `YahooFeed`: `public enum TransportFaults { public static func classify(_ error: any Error) -> TransportFault }`
- Task 6's `TickerRunner` consumes all four.

- [ ] **Step 1: Move the `Calendars` tests and point them at the new name**

Create `Tests/TickerCoreTests/TradingCalendarsTests.swift` containing lines 63–164 of `Tests/squigglectlTests/WatchLoopTests.swift` verbatim, with `import Testing` / `import TickerCore` at the top, `import squigglectl` **removed**, and every `WatchLoop.Calendars` rewritten as `TradingCalendars`. Delete those same lines from `WatchLoopTests.swift`, leaving its three `tolerance` tests and its header comment.

Do this mechanically. The bodies of those seven tests are the evidence for R121's reasoning and rewriting them from memory is how that reasoning gets lost:

```bash
sed -n '63,164p' Tests/squigglectlTests/WatchLoopTests.swift \
  | sed 's/WatchLoop\.Calendars/TradingCalendars/g' > /tmp/calendars-body.swift
wc -l /tmp/calendars-body.swift   # expect 102
```

Prepend the imports and a header:

```swift
import Foundation
import Testing
@testable import TickerCore

// Moved from `squigglectlTests/WatchLoopTests.swift` by ruling R121, unchanged
// except for the type's name. The reasoning these tests pin — most-open state
// wins, earliest open wins, a dead symbol stops voting — belongs to whoever
// builds an `EngineContext`, and after this plan that is two callers, not one.
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --build-system native --filter TradingCalendars
```

Expected: FAIL — `cannot find 'TradingCalendars' in scope`.

- [ ] **Step 3: Create the type**

`Sources/TickerCore/TradingCalendars.swift` is `WatchLoop.Calendars` lifted out of its enclosing struct, made `public`, with every member that the tests or `WatchLoop` call made `public`. Copy the doc comment across whole — it is the argument for the aggregation rule and it must not be summarised:

```swift
import Foundation

/// One trading calendar per symbol, and the aggregate the engine actually
/// consumes.
///
/// The engine takes a *single* `marketState`, so something has to turn N
/// calendars into one. Keeping only the most recent one makes the answer
/// depend on which symbol happened to be fetched last, and the two failure
/// directions are not symmetric:
///
/// - A crypto symbol fetched last reports `.regular` at 03:00, and every
///   equity symbol is then polled as though its exchange were open.
/// - An equity symbol fetched last reports `.closed` with a 09:30 open, and
///   `RefreshPolicy` then puts the **whole loop** to sleep until 09:30 —
///   including the 24-hour instrument, which had a live price the entire time.
///   A ticker that shows a nine-hour-old crypto price is broken in a way that
///   a ticker making a few extra requests is not.
///
/// So the aggregate is the *most open* state across the live watchlist, and
/// the wake is the *earliest* open across it. The caller never sleeps through
/// a session that some symbol it is watching is actually in.
///
/// The cost of the first direction is real and is paid deliberately: the
/// nineteen equity symbols do get polled overnight at the continuous cadence.
/// It is affordable only because `RefreshPolicy.budgetFloor` exists — it
/// prices a 24-hour instrument directly, so this aggregate is bounded at the
/// daily budget instead of running to 2,880 requests. Per-symbol *cadence*
/// would avoid even that, but `FeedEngine` paces one round-robin pass against
/// one `cycleDeadline`; giving each symbol its own would be a redesign of
/// `FeedEngine.next()`, not a change to its callers.
///
/// Lives in `TickerCore` by ruling R121: `squigglectl watch` and the app's
/// `TickerRunner` both have to build an `EngineContext`, and this is the only
/// thing that knows how.
public struct TradingCalendars: Sendable {
    private var periods: [Symbol: TradingPeriod] = [:]

    public init() {}

    public mutating func record(_ period: TradingPeriod, for symbol: Symbol) {
        periods[symbol] = period
    }

    /// Forgets calendars for symbols no longer being polled. Without this a
    /// symbol the engine has marked dead keeps voting: a delisted crypto
    /// ticker that 404s forever would hold the whole watchlist at `.regular`
    /// for the life of the process, which is the original bug with a longer
    /// fuse.
    public mutating func retain(_ live: Set<Symbol>) {
        periods = periods.filter { live.contains($0.key) }
    }

    /// `nil` when nothing has reported yet — the caller decides what to assume
    /// before the first successful quote, and that assumption is not this
    /// type's to make.
    public func aggregateState(atEpoch epoch: Double) -> MarketState? {
        let states = periods.values.map { $0.state(atEpoch: epoch) }
        guard !states.isEmpty else { return nil }
        return states.max { Self.openness($0) < Self.openness($1) }
    }

    /// The earliest open any watched symbol still has ahead of it. Only
    /// consulted while the aggregate is `.closed`, which by construction means
    /// every symbol is closed, so this is the first one to reopen.
    public func earliestSessionOpenEpoch(after epoch: Double) -> Double? {
        periods.values.compactMap { $0.nextSessionOpenEpoch(after: epoch) }.min()
    }

    /// One symbol's own state, unaggregated. Nothing in the app reads this; it
    /// exists so a test can show that an equity symbol keeps its own calendar
    /// while a crypto symbol drives the aggregate.
    public func state(for symbol: Symbol, atEpoch epoch: Double) -> MarketState? {
        periods[symbol]?.state(atEpoch: epoch)
    }

    /// How open a state is. `.pre` outranks `.post` only to keep the aggregate
    /// deterministic when both appear — `RefreshPolicy` stretches the cycle
    /// identically for the two, so the choice cannot change what the engine
    /// does. A `switch` with no `default:`, so a fifth `MarketState` fails the
    /// build here rather than silently ranking as something.
    public static func openness(_ state: MarketState) -> Int {
        switch state {
        case .closed: return 0
        case .post: return 1
        case .pre: return 2
        case .regular: return 3
        }
    }
}
```

Then delete the whole `struct Calendars { ... }` from `Sources/squigglectl/WatchLoop.swift` along with its doc comment, and change the two uses in `run()` from `var calendars = Calendars()` to `var calendars = TradingCalendars()`. Nothing else in `WatchLoop` changes.

- [ ] **Step 4: Run to verify it passes**

```bash
swift test --build-system native --filter "TradingCalendars|WatchLoop"
```

Expected: PASS, 10 tests (7 moved + 3 tolerance).

- [ ] **Step 5: Write the failing test for `Snapshot` in the core**

Add to `Tests/TickerCoreTests/YahooQuoteDecodingTests.swift`:

```swift
@Test func oneBodyYieldsBothTheQuoteAndTheCalendar() throws {
    // Spec §3.2: asking a second endpoint for the calendar would double the
    // app's share of the daily budget. R122 moved this decode into the core so
    // the app gets it without depending on `YahooClient`.
    let data = try Fixture.data("regular-session.json")
    let symbol = try #require(Symbol("AAPL"))

    let snapshot = try YahooQuoteDecoding.snapshot(from: data, symbol: symbol)
    #expect(snapshot.quote.symbol == symbol)
    #expect(snapshot.tradingPeriod != nil)
}

@Test func aBodyWithNoUsableCalendarStillYieldsItsQuote() throws {
    // The calendar is a bonus fact the body happens to carry, not a promise.
    // An instrument whose `tradingPeriods` Yahoo has not sent this session must
    // not cost the user a perfectly good price.
    let data = try Fixture.data("crypto.json")
    let symbol = try #require(Symbol("BTC-USD"))

    let snapshot = try YahooQuoteDecoding.snapshot(from: data, symbol: symbol)
    #expect(snapshot.quote.price > 0)
}
```

`Fixture` is the enum already declared at the top of that file; `regular-session.json` and `crypto.json` are both already in `Tests/Fixtures/yahoo-2026-09-08/`. **Do not add, edit or overwrite anything under `Tests/Fixtures/`** — those bytes are recorded evidence of what Yahoo actually sent, and this task needs no new ones.

- [ ] **Step 6: Run to verify it fails**

```bash
swift test --build-system native --filter YahooQuoteDecoding
```

Expected: FAIL — `type 'YahooQuoteDecoding' has no member 'snapshot'`.

- [ ] **Step 7: Move `Snapshot` into the core**

Append to `Sources/TickerCore/YahooQuoteDecoding.swift`:

```swift
/// One instrument's price and its exchange's calendar, from one response body.
///
/// Lives here rather than in `YahooFeed` (ruling R122) because it holds two
/// `TickerCore` values and no networking type at all. That is what lets a
/// caller hold `any QuoteFetching` — bytes in, both facts out — instead of a
/// concrete client, which is the difference between a testable polling loop
/// and one that can only be run against the live endpoint.
public struct Snapshot: Sendable {
    public let quote: Quote
    public let tradingPeriod: TradingPeriod?

    public init(quote: Quote, tradingPeriod: TradingPeriod?) {
        self.quote = quote
        self.tradingPeriod = tradingPeriod
    }
}

extension YahooQuoteDecoding {
    /// One request, both facts (spec §3.2). Asking a second endpoint for the
    /// calendar would double Squiggle's share of the daily budget.
    public static func snapshot(from data: Data, symbol: Symbol) throws -> Snapshot {
        Snapshot(
            quote: try quote(from: data, symbol: symbol),
            // A `try?`, deliberately: the calendar is a bonus fact this body
            // happens to carry, not something this function promises. An older
            // instrument, or a shape Yahoo has not sent this session, yields
            // `nil` rather than failing a request that produced a good quote.
            tradingPeriod: try? tradingPeriod(from: data))
    }
}
```

Delete `public struct Snapshot` from `Sources/YahooFeed/YahooClient.swift` (lines 8–23) and reduce the method to a forwarder:

```swift
    /// One request, both facts — see `YahooQuoteDecoding.snapshot(from:symbol:)`,
    /// which is where the decode lives after ruling R122. Kept as a method
    /// because `squigglectl` and the app both spell the operation this way and
    /// because `fetch` is the thing being paced.
    public func snapshot(for symbol: Symbol) async throws -> Snapshot {
        try YahooQuoteDecoding.snapshot(from: try await fetch(symbol), symbol: symbol)
    }
```

`squigglectl` imports both modules, so `Snapshot` still resolves at every existing call site with no edit.

- [ ] **Step 8: Write the failing test for the transport-fault move**

`TransportFaults` lives in `YahooFeed`, which has no test target of its own, and the forwarding assertion needs `squigglectl` anyway — so the tests go in `Tests/squigglectlTests/TransportFaultsTests.swift`. That target does not yet depend on `YahooFeed`; add it in `Package.swift` first:

```swift
        .testTarget(
            name: "squigglectlTests",
            dependencies: [
                "squigglectl",
                "TickerCore",
                "YahooFeed",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
```

Then create `Tests/squigglectlTests/TransportFaultsTests.swift`:

```swift
import Foundation
import Testing
import TickerCore
import YahooFeed
@testable import squigglectl

// R125: both executables need this mapping in the same catch-all, and it
// produces no user-facing string, so it belongs in the target that owns every
// URL type in the package. `Rendering.transportFault` now forwards to it.
@Test func aURLErrorBecomesItsOwnCodeRatherThanTheCatchAll() {
    let offline = URLError(.notConnectedToInternet)
    #expect(TransportFaults.classify(offline) == .urlSession(code: URLError.Code.notConnectedToInternet.rawValue))
}

@Test func somethingThatIsNotAURLErrorIsUnrecognised() {
    struct Nonsense: Error {}
    #expect(TransportFaults.classify(Nonsense()) == .unrecognized)
}

@Test func renderingStillAnswersForTheCallersThatUseIt() {
    // The forwarder is not ceremony: `WatchLoop` and `ProbeRun` both call
    // `Rendering.transportFault`, and a move that broke them would be a
    // refactor that cost the CLI to serve the app.
    let timedOut = URLError(.timedOut)
    #expect(Rendering.transportFault(for: timedOut) == TransportFaults.classify(timedOut))
}
```

- [ ] **Step 9: Run to verify it fails**

```bash
swift test --build-system native --filter TransportFaults
```

Expected: FAIL — `cannot find 'TransportFaults' in scope`.

- [ ] **Step 10: Move the classifier**

Create `Sources/YahooFeed/TransportFaults.swift` holding the body of `Rendering.transportFault(for:)` verbatim — read `Sources/squigglectl/Rendering.swift:126` and move what is there, do not rewrite it from the enum:

```swift
import Foundation
import TickerCore

/// Turns an arbitrary `Error` escaping a network call into a typed
/// `TransportFault`.
///
/// Here rather than in `TickerCore` because `URLError` is a networking type
/// and the core is forbidden them; here rather than in `squigglectl` because
/// the app needs the identical mapping in the identical catch-all, and a
/// second copy of it is a second thing to get wrong (ruling R125). It vends no
/// user-facing string — `Rendering` and `ErrorText` each word the result their
/// own way.
public enum TransportFaults {
    public static func classify(_ error: any Error) -> TransportFault {
        // <-- the body currently at Sources/squigglectl/Rendering.swift:126,
        //     moved unchanged.
    }
}
```

Then reduce `Rendering.transportFault(for:)` to:

```swift
    /// Forwards to `YahooFeed.TransportFaults` (R125). Kept as an entry point
    /// because `WatchLoop`, `ProbeRun` and `RenderingTests` all call it here.
    public static func transportFault(for error: any Error) -> TransportFault {
        TransportFaults.classify(error)
    }
```

`Sources/squigglectl/Rendering.swift` must now `import YahooFeed`; check whether it already does before adding it.

- [ ] **Step 11: Run the whole suite**

```bash
swift test --build-system native 2>&1 | tail -20
```

Expected: PASS, no fewer tests than before the task started. Confirm the count:

```bash
swift test --build-system native 2>&1 | grep -E "Test run with [0-9]+ tests"
```

- [ ] **Step 12: Commit**

```bash
git add -A
git commit -m "refactor: move the loop's shared parts where two callers can reach them"
```

---

## Task 3: Stand up the app target, and the numbers it prints

Nothing in `Sources/Squiggle/` exists yet, so the first task there has to create the target as well as the first file in it. They go together: an `executableTarget` that does not compile is not a reviewable deliverable, and `Formatting` is the one file that needs no AppKit state to test.

The app entry point is written in its final form here. `AppDelegate` is created too, because `main.swift` cannot compile without it — its `applicationDidFinishLaunching` body is empty at the end of this task and the status item arrives in Task 6. That is the file's honest state, not a placeholder: an `LSUIElement` app with nothing installed yet correctly shows nothing.

**Files:**
- Modify: `Package.swift:7-11` (products), `:14-36` (targets)
- Create: `Sources/Squiggle/main.swift`
- Create: `Sources/Squiggle/AppDelegate.swift`
- Create: `Sources/Squiggle/Formatting.swift`
- Test: `Tests/SquiggleTests/FormattingTests.swift`

**Interfaces:**
- Consumes: nothing from Tasks 1–2.
- Produces:
  - A `Squiggle` executable target and product, and a `SquiggleTests` test target that depends on it. Every later task in this plan adds files to these two.
  - `final class AppDelegate: NSObject, NSApplicationDelegate` — Task 6 adds a `controller` property to it.
  - `enum Formatting` with `static func price(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String`, `static func delta(_ change: Double?, locale: Locale = .autoupdatingCurrent) -> String`, `static func percent(_ changePercent: Double?, locale: Locale = .autoupdatingCurrent) -> String`, and `static let deadPlaceholder = "——"`. Tasks 5 and 11 call all four.

- [ ] **Step 1: Add the target so there is somewhere to put a test**

In `Package.swift`, add to `products`:

```swift
        .executable(name: "Squiggle", targets: ["Squiggle"]),
```

and to `targets`, after the `squigglectl` executable target:

```swift
        .executableTarget(name: "Squiggle", dependencies: ["TickerCore", "YahooFeed"]),
```

and after the `squigglectlTests` test target:

```swift
        .testTarget(
            name: "SquiggleTests",
            dependencies: [
                "Squiggle",
                "TickerCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
```

A test target depending on an executable target works in this toolchain — `/Users/ben/Projects/Pitch` ships exactly this arrangement — but it only works once the executable actually builds, so Steps 2 and 3 come before the first test run.

- [ ] **Step 2: Write the entry point**

`Sources/Squiggle/main.swift`:

```swift
import AppKit

// `LSUIElement` in the Info.plist is what makes the *bundle* an agent, and
// this line is what makes the *process* one. They are not redundant: during
// development the app is launched by `swift run`, which has no bundle and no
// plist, and without this a dock icon and a menu bar menu appear for a program
// whose entire UI is supposed to be one status item.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Held in a `let` for the process's lifetime: `NSApplication.delegate` is a
// weak reference, so a delegate assigned from a temporary is deallocated
// before `run()` ever calls it.
let delegate = AppDelegate()
app.delegate = delegate

app.run()
```

`Sources/Squiggle/AppDelegate.swift`:

```swift
import AppKit

/// Process lifecycle, and nothing else. Everything the user can see belongs to
/// `StatusItemController`; this type exists to own it and to be the one place
/// that knows the app has started.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Task 6 constructs the status item here. Until then the app launches,
        // shows nothing, and keeps running — which is the correct behaviour for
        // an agent with no status item, not a stub.
    }
}
```

- [ ] **Step 3: Verify the target builds**

```bash
swift build --build-system native --product Squiggle
```

Expected: succeeds. Do **not** run it — an agent app with no status item has no window and no quit item, so `swift run` would have to be killed from another terminal.

- [ ] **Step 4: Write the failing tests**

`Tests/SquiggleTests/FormattingTests.swift`:

```swift
import Foundation
import Testing
@testable import Squiggle

// Every test pins an explicit locale (R128). `.autoupdatingCurrent` is the
// production default and is exactly what must not appear in an assertion: a
// suite that passes in en_US and fails in de_DE is testing the machine.
private let posix = Locale(identifier: "en_US_POSIX")
private let german = Locale(identifier: "de_DE")

@Test func aPriceAtOrAboveOneKeepsTwoDecimals() {
    #expect(Formatting.price(232.1, locale: posix) == "232.10")
}

@Test func aPriceBelowOneKeepsFour() {
    // A sub-dollar instrument rendered to two decimals loses most of its
    // information — $0.0431 becomes $0.04, and a 10% move becomes invisible.
    #expect(Formatting.price(0.0431, locale: posix) == "0.0431")
}

@Test func indexScaleNumbersKeepTheirGroupingSeparator() {
    // If this one fails, `en_US_POSIX` on this toolchain does not group; pin
    // `Locale(identifier: "en_US")` for this test only and leave the rest on
    // POSIX. Do not respond by deleting the assertion — an index printed as
    // `5432.10` in the menu bar is the thing it exists to catch.
    #expect(Formatting.price(5432.1, locale: posix) == "5,432.10")
}

@Test func theLocaleIsTheCallersNotTheProcessS() {
    #expect(Formatting.price(1234.5, locale: german) == "1.234,50")
}

@Test func aDeltaIsAbsoluteBecauseTheGlyphCarriesTheSign() {
    // R127: the strip renders `▼` next to this, so a minus sign would say the
    // same thing twice — and `▼-1.10` reads as a double negative.
    #expect(Formatting.delta(-1.1, locale: posix) == "1.10")
    #expect(Formatting.delta(0.42, locale: posix) == "0.42")
}

@Test func aPercentageKeepsTwoDecimalsAndItsSignIsAlsoTheGlyphS() {
    #expect(Formatting.percent(0.1834, locale: posix) == "0.18%")
    #expect(Formatting.percent(-2.5, locale: posix) == "2.50%")
}

@Test func anAbsentNumberRendersNothingRatherThanAWord() {
    // The caller drops the whole segment when this is empty (Task 5). Returning
    // "n/a" or "—" here would put a second em-dash next to the dead-symbol one
    // and mean something different.
    #expect(Formatting.delta(nil, locale: posix).isEmpty)
    #expect(Formatting.percent(nil, locale: posix).isEmpty)
}

@Test func aNonFiniteNumberRendersNothingRatherThanInf() {
    // `chartPreviousClose == 0` is supposed to yield `.unknown` upstream
    // (spec §5.3), but this is the last line before the menu bar and
    // `NumberFormatter` renders infinity as "∞" quite happily.
    #expect(Formatting.percent(.infinity, locale: posix).isEmpty)
    #expect(Formatting.percent(.nan, locale: posix).isEmpty)
    #expect(Formatting.delta(.infinity, locale: posix).isEmpty)
    #expect(Formatting.price(.nan, locale: posix) == Formatting.deadPlaceholder)
}
```

- [ ] **Step 5: Run to verify they fail**

```bash
swift test --build-system native --filter Formatting
```

Expected: FAIL — `cannot find 'Formatting' in scope`.

- [ ] **Step 6: Write `Formatting`**

`Sources/Squiggle/Formatting.swift`:

```swift
import Foundation

/// Every number the user reads, and nothing else: no colour, no sentences
/// (R129), no AppKit. Sentences live in `ErrorText`; colour lives in
/// `ColorScheme`.
enum Formatting {
    /// Spec §7's per-symbol dead state. Two em-dashes, not one: a single `—`
    /// next to a symbol reads as a hyphenated name, and `–` is already the
    /// `.flat` direction glyph.
    static let deadPlaceholder = "——"

    /// Price, with the locale's own separators (R128).
    ///
    /// Non-finite input renders as the dead placeholder rather than "∞": this
    /// is the last function before the menu bar, and the one thing spec §8.2
    /// forbids everywhere is a plausible-but-wrong number reaching the user.
    static func price(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        guard value.isFinite else { return deadPlaceholder }
        return formatter(locale: locale, fractionDigits: fractionDigits(for: value))
            .string(from: value as NSNumber) ?? deadPlaceholder
    }

    /// The absolute change. The caller prefixes `Direction.glyph`, which is
    /// what carries the sign (R127).
    static func delta(_ change: Double?, locale: Locale = .autoupdatingCurrent) -> String {
        guard let change, change.isFinite else { return "" }
        let magnitude = abs(change)
        return formatter(locale: locale, fractionDigits: fractionDigits(for: magnitude))
            .string(from: magnitude as NSNumber) ?? ""
    }

    /// The absolute percentage, with its sign carried by the same glyph. Always
    /// two decimals — a percentage's useful range does not vary with the price's
    /// magnitude the way the price itself does.
    static func percent(_ changePercent: Double?, locale: Locale = .autoupdatingCurrent) -> String {
        guard let changePercent, changePercent.isFinite else { return "" }
        guard let text = formatter(locale: locale, fractionDigits: 2)
            .string(from: abs(changePercent) as NSNumber) else { return "" }
        return text + "%"
    }

    /// Two decimals normally; four under 1.0, where two would round most of the
    /// number away (a $0.0431 token, an FX cross). The threshold is on the
    /// magnitude, so it is the same either side of zero.
    private static func fractionDigits(for value: Double) -> Int {
        abs(value) >= 1 ? 2 : 4
    }

    /// A fresh `NumberFormatter` per call. They are not cheap, but this runs
    /// once per segment per *data change* — a handful of times a minute at
    /// most, never per frame (the strip is pre-rendered, spec §5.1) — and a
    /// cached one would have to be keyed on locale and digit count and made
    /// thread-safe to save nothing measurable.
    private static func formatter(locale: Locale, fractionDigits: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.minimumFractionDigits = fractionDigits
        f.maximumFractionDigits = fractionDigits
        return f
    }
}
```

- [ ] **Step 7: Run to verify they pass**

```bash
swift test --build-system native --filter Formatting
```

Expected: PASS, 8 tests.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/Squiggle Tests/SquiggleTests
git commit -m "feat: add the Squiggle app target and its number formatting"
```

---

## Task 4: Every word the app says

Spec §7 puts all wording in one file, and the reason is not tidiness: `TickerCore` emits eighteen typed errors and the app has to turn each into a sentence *"naming the user's move rather than the diagnosis"*. Keeping them in one exhaustive `switch` is what makes "did we word every error?" a compile error rather than a discovery.

This task writes the file and its tests. Nothing calls it yet — Task 11 builds the dropdown that shows the footer line, and Tasks 13 and 15 take their control titles from here.

**Files:**
- Create: `Sources/Squiggle/ErrorText.swift`
- Test: `Tests/SquiggleTests/ErrorTextTests.swift`

**Interfaces:**
- Consumes: `TickerError` and all eighteen of its cases (`TickerCore`).
- Produces: `enum ErrorText` with
  - `static func footer(lastSuccessAgoSeconds: Double?, lastError: TickerError?, retryInSeconds: Double?) -> String`
  - `static let refreshNow`, `settings`, `addSymbol`, `quit`, `removeSymbol` — menu titles used by Tasks 11, 13 and 15.
  - `static func menuRow(symbol: String, price: String, change: String, currency: String?) -> String` — one dropdown row (Task 11).

- [ ] **Step 1: Write the failing tests**

`Tests/SquiggleTests/ErrorTextTests.swift`:

```swift
import Foundation
import Testing
import TickerCore
@testable import Squiggle

// The three lines spec §7 writes out longhand. They are quoted in the spec, so
// they are assertions, not suggestions.
@Test func theHealthyFooterNamesTheAgeAndTheNextAttempt() {
    let line = ErrorText.footer(lastSuccessAgoSeconds: 14 * 60,
                                lastError: nil,
                                retryInSeconds: 4 * 60)
    #expect(line == "Updated 14 min ago — retrying in 4 min")
}

@Test func rateLimitingIsNamedAsYahoosDoingBecauseThatChangesWhatTheUserDoes() {
    let line = ErrorText.footer(lastSuccessAgoSeconds: 20 * 60,
                                lastError: .rateLimited(retryAfterSeconds: nil),
                                retryInSeconds: 12 * 60)
    #expect(line == "Yahoo is rate-limiting Squiggle. Retrying in 12 min.")
}

@Test func offlineIsDistinguishedFromYahooFailing() {
    // Spec §7: "Offline and Yahoo-is-failing are distinguished because they
    // imply different user actions." One is fixed by the user, one by waiting.
    let offline = ErrorText.footer(lastSuccessAgoSeconds: 60,
                                   lastError: .offline, retryInSeconds: 60)
    let server = ErrorText.footer(lastSuccessAgoSeconds: 60,
                                  lastError: .serverError(status: 503), retryInSeconds: 60)
    #expect(offline == "No network connection.")
    #expect(offline != server)
}

@Test func aFreshSuccessSaysJustNowRatherThanZeroMinutesAgo() {
    #expect(ErrorText.footer(lastSuccessAgoSeconds: 3, lastError: nil, retryInSeconds: nil)
            == "Updated just now")
}

@Test func havingNeverSucceededIsNotTheSameAsHavingSucceededLongAgo() {
    #expect(ErrorText.footer(lastSuccessAgoSeconds: nil, lastError: nil, retryInSeconds: nil)
            == "Updating…")
}

@Test func aSubMinuteRetryIsNotRoundedDownToZero() {
    let line = ErrorText.footer(lastSuccessAgoSeconds: 90, lastError: nil, retryInSeconds: 20)
    #expect(line == "Updated 2 min ago — retrying in under a minute")
}

@Test func aFaultThatWaitingCannotFixDoesNotPromiseARetry() {
    // The ladder does keep retrying an unauthorized response, but saying so
    // tells the user to wait for something that is not coming: spec §3.1 makes
    // a crumb demand the end of Squiggle's premise, not a blip.
    let line = ErrorText.footer(lastSuccessAgoSeconds: 3600,
                                lastError: .unauthorized(status: 401),
                                retryInSeconds: 600)
    #expect(!line.contains("Retrying"))
    #expect(!line.contains("retrying"))
}

@Test func everyErrorCaseHasWordsAndNoneOfThemLeakSwift() throws {
    // The sweep. `TickerError` is not `CaseIterable` — several cases carry
    // payloads — so the list is written out, and the `switch` inside
    // `ErrorText` is what actually guarantees exhaustiveness. This catches the
    // other half: a case that compiles but renders `Optional(...)`.
    let cases: [TickerError] = [
        .invalidSymbol("puce"), .offline, .transport(.nonHTTPResponse),
        .rateLimited(retryAfterSeconds: 30), .serverError(status: 500),
        .unauthorized(status: 401), .symbolNotFound(try #require(Symbol("ZZZZ"))), .emptyBody,
        .notJSON, .noResult, .missingField(path: "chart.result"),
        .wrongType(path: "meta.regularMarketPrice", expected: "Double"),
        .nonFiniteNumber(path: "meta.regularMarketPrice"),
        .negativeValue(path: "meta.regularMarketPrice", value: -1),
        .storeSchemaUnsupported(version: 9), .storeVersionUnreadable,
        .storeCorrupt(quarantinedAt: URL(fileURLWithPath: "/tmp/squiggle.json.bad")),
        .storeQuarantineFailed(at: URL(fileURLWithPath: "/tmp/squiggle.json")),
    ]

    for error in cases {
        let line = ErrorText.footer(lastSuccessAgoSeconds: 60,
                                    lastError: error, retryInSeconds: 120)
        #expect(!line.isEmpty, "\(error) has no words")
        #expect(!line.contains("Optional("), "\(error) leaked a Swift value")
        #expect(!line.contains("TickerError"), "\(error) leaked its own type name")
        // R44's sibling: the app's footer is read over someone's shoulder in a
        // menu bar. A quarantine path in it is both unreadable and a leak of
        // the user's home directory name.
        #expect(!line.contains("/"), "\(error) leaked a filesystem path")
        let last = try #require(line.last)
        #expect(".!…".contains(last), "\(error) is not a sentence: \(line)")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
swift test --build-system native --filter ErrorText
```

Expected: FAIL — `cannot find 'ErrorText' in scope`.

- [ ] **Step 3: Write `ErrorText`**

`Sources/Squiggle/ErrorText.swift`:

```swift
import Foundation
import TickerCore

/// Every user-facing string in the app (spec §7). `TickerCore` emits typed
/// errors and carries no words; this is where they become sentences.
///
/// The rule the wording follows is spec §7's: name the user's move, not the
/// diagnosis. "Yahoo is rate-limiting Squiggle" tells someone to wait; "HTTP
/// 429" tells them to search the web. The one thing this file must never do is
/// print a value out of the error payload that is not the user's own input —
/// paths, statuses and field names belong in `squigglectl doctor`, whose
/// output is meant to be pasted into an email, not read in a menu bar.
enum ErrorText {
    // MARK: - Menu titles

    static let refreshNow = "Refresh Now"
    static let settings = "Settings…"
    static let addSymbol = "Add Symbol…"
    static let removeSymbol = "Remove"
    static let quit = "Quit Squiggle"

    // MARK: - The footer line

    /// The one line at the foot of the dropdown (spec §7). There is no other
    /// error surface in the app: no alerts, no notifications, no badge.
    static func footer(lastSuccessAgoSeconds: Double?,
                       lastError: TickerError?,
                       retryInSeconds: Double?) -> String {
        guard let lastError else {
            let updated = freshness(lastSuccessAgoSeconds)
            guard let retryInSeconds else { return updated }
            return updated + " — retrying in " + duration(retryInSeconds)
        }
        let sentence = message(for: lastError)
        guard waitingHelps(lastError), let retryInSeconds else { return sentence }
        return sentence + " Retrying in " + duration(retryInSeconds) + "."
    }

    /// One dropdown row. The currency code is rendered **verbatim** — a London
    /// listing reports `GBp`, meaning pence, and upper-casing it would claim
    /// the price was in pounds and be wrong by a factor of 100.
    static func menuRow(symbol: String, price: String,
                        change: String, currency: String?) -> String {
        let money = currency.map { "\(price) \($0)" } ?? price
        return change.isEmpty ? "\(symbol)  \(money)" : "\(symbol)  \(money)  \(change)"
    }

    // MARK: - Wording

    /// Exhaustive over `TickerError`, with no `default:`: a nineteenth case
    /// must fail the build here rather than reach a user as an empty line.
    private static func message(for error: TickerError) -> String {
        switch error {
        case .offline:
            return "No network connection."
        case .rateLimited:
            return "Yahoo is rate-limiting Squiggle."
        case .serverError, .transport:
            return "Yahoo isn't responding."
        case .unauthorized:
            // Spec §3.1: the whole premise is that this endpoint needs no
            // credentials. If it starts to, waiting will not fix it and
            // Squiggle will not start holding a cookie.
            return "Yahoo now wants a sign-in that Squiggle doesn't do."
        case .invalidSymbol(let raw):
            // Echoing the user's own typed text back is sanctioned; it is the
            // only way to say which of twenty symbols is the problem.
            return "Squiggle can't read the symbol “\(raw)”."
        case .symbolNotFound(let symbol):
            return "Yahoo doesn't know “\(symbol.raw)”."
        case .emptyBody, .notJSON, .noResult, .missingField,
             .wrongType, .nonFiniteNumber, .negativeValue:
            // Every contract fault gets the same sentence on purpose. The user
            // can do exactly one thing about any of them, and which JSON key
            // path moved is a question for `squigglectl doctor`.
            return "Yahoo changed what it sends. Squiggle needs an update."
        case .storeSchemaUnsupported:
            return "Your watchlist was written by a newer Squiggle."
        case .storeVersionUnreadable, .storeCorrupt:
            return "Your watchlist couldn't be read, so Squiggle set it aside and started fresh."
        case .storeQuarantineFailed:
            return "Your watchlist couldn't be read and couldn't be set aside, so Squiggle isn't saving changes."
        }
    }

    /// Whether a retry is worth telling the user about. A contract fault, a
    /// credential demand or an unreadable file will look identical in four
    /// minutes, and promising otherwise is the one way a footer line can lie.
    private static func waitingHelps(_ error: TickerError) -> Bool {
        switch error {
        case .offline, .transport, .rateLimited, .serverError,
             .symbolNotFound, .invalidSymbol:
            return true
        case .unauthorized, .emptyBody, .notJSON, .noResult, .missingField,
             .wrongType, .nonFiniteNumber, .negativeValue,
             .storeSchemaUnsupported, .storeVersionUnreadable,
             .storeCorrupt, .storeQuarantineFailed:
            return false
        }
    }

    private static func freshness(_ agoSeconds: Double?) -> String {
        guard let agoSeconds, agoSeconds.isFinite else { return "Updating…" }
        if agoSeconds < 60 { return "Updated just now" }
        return "Updated \(minutes(agoSeconds)) min ago"
    }

    /// R129: the rounding is a wording decision, so it lives here rather than
    /// in `Formatting`. "under a minute" instead of "0 min" — a countdown that
    /// reaches zero and stays there reads as a stuck app.
    private static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 60 else { return "under a minute" }
        return "\(minutes(seconds)) min"
    }

    private static func minutes(_ seconds: Double) -> Int {
        max(1, Int((seconds / 60).rounded()))
    }
}
```

- [ ] **Step 4: Run to verify they pass**

```bash
swift test --build-system native --filter ErrorText
```

Expected: PASS, 8 tests. If `everyErrorCaseHasWordsAndNoneOfThemLeakSwift` fails on the trailing-punctuation assertion, the fix is the wording, not the assertion.

- [ ] **Step 5: Commit**

```bash
git add Sources/Squiggle/ErrorText.swift Tests/SquiggleTests/ErrorTextTests.swift
git commit -m "feat: give the app its words, one exhaustive switch wide"
```

---

## Task 5: The strip, as a data structure

`StripLayout` is the whole visual composition with no pixels in it: which segments exist, in what order, how wide each one is, where it sits, and what colour role it carries. `StripRenderer` (Task 8) turns one of these into layers, and the reason that split exists is spec §8.5 — *"`StripLayout` is tested as a data structure — segments, offsets, colour roles. Pixel comparison of macOS text rendering flakes across OS versions."*

Two properties make the tests meaningful rather than tautological. First, measurement is injected (R131), so a test can say "every character is 10 wide" and then assert real arithmetic. Second, each row's `contentWidth` is the width of exactly one pass **including the trailing gap**, which is the number Task 8's animation translates by — a layer copy placed at `x + contentWidth` tiles the row seamlessly, and getting it wrong produces a visible stutter once per loop that no pixel test would catch either.

**Files:**
- Create: `Sources/Squiggle/StripLayout.swift`
- Test: `Tests/SquiggleTests/StripLayoutTests.swift`

**Interfaces:**
- Consumes: `Quote`, `Symbol`, `Direction` (and `Direction.glyph`), `RowSplitter.split(widths:rows:)` from `TickerCore`; `Formatting.price/delta/percent/deadPlaceholder` from Task 3.
- Produces:
  - `enum ColorRole: Equatable, Sendable { case label; case direction(Direction) }` — Task 12 maps this to an `NSColor`.
  - `struct StripLayout: Equatable` with nested `Segment` (`text`, `role`, `x`, `width`), nested `Row` (`segments`, `contentWidth`), and `let rows: [Row]`.
  - `static func build(symbols: [Symbol], quotes: [Symbol: Quote], dead: Set<Symbol>, rows requestedRows: Int, gap: Double, locale: Locale = .autoupdatingCurrent, measure: (String) -> Double) -> StripLayout`
  - `var widestRowWidth: Double` — Task 10's fits-the-width test reads this.

- [ ] **Step 1: Write the failing tests**

`Tests/SquiggleTests/StripLayoutTests.swift`:

```swift
import Foundation
import Testing
import TickerCore
@testable import Squiggle

// A measurement function with no font in it: every character is 10 points
// wide. Real text measurement varies by OS version and installed fonts
// (spec §8.5), so the only stable assertions are against a fake.
private let tenPerCharacter: (String) -> Double = { Double($0.count) * 10 }

private let posix = Locale(identifier: "en_US_POSIX")

private func symbol(_ raw: String) throws -> Symbol {
    try #require(Symbol(raw))
}

private func quote(_ raw: String, price: Double, change: Double?,
                   percent: Double?, direction: Direction) throws -> Quote {
    Quote(symbol: try symbol(raw), shortName: nil, price: price,
          previousClose: nil, change: change, changePercent: percent,
          currency: "USD", direction: direction, asOfEpoch: nil)
}

@Test func oneSymbolBecomesThreeSegmentsInSpecOrder() throws {
    let aapl = try symbol("AAPL")
    let layout = StripLayout.build(
        symbols: [aapl],
        quotes: [aapl: try quote("AAPL", price: 232.1, change: -1.1,
                                 percent: -0.47, direction: .down)],
        dead: [], rows: 1, gap: 20, locale: posix, measure: tenPerCharacter)

    let texts = layout.rows[0].segments.map(\.text)
    #expect(texts == ["AAPL ", "232.10 ", "▼1.10 (0.47%)"])
}

@Test func onlyTheChangeSegmentCarriesDirection() throws {
    // Spec §5.3: colour applies to the delta and the percentage, never to
    // the symbol or the price.
    let aapl = try symbol("AAPL")
    let layout = StripLayout.build(
        symbols: [aapl],
        quotes: [aapl: try quote("AAPL", price: 232.1, change: 1.1,
                                 percent: 0.47, direction: .up)],
        dead: [], rows: 1, gap: 20, locale: posix, measure: tenPerCharacter)

    #expect(layout.rows[0].segments.map(\.role)
            == [.label, .label, .direction(.up)])
}

@Test func aDeadSymbolKeepsItsSlotAndCarriesNoDirection() throws {
    // Spec §7: a symbol whose last fetch failed renders `——` and keeps its
    // place, so the strip's shape does not change under the user's eye.
    let dead = try symbol("VOD.L")
    let layout = StripLayout.build(
        symbols: [dead], quotes: [:], dead: [dead],
        rows: 1, gap: 20, locale: posix, measure: tenPerCharacter)

    #expect(layout.rows[0].segments.map(\.text) == ["VOD.L ", "——"])
    #expect(layout.rows[0].segments.map(\.role) == [.label, .label])
}

@Test func aSymbolWithNoQuoteYetIsRenderedLikeADeadOne() throws {
    // At launch nothing has been fetched. The slot still has to exist or the
    // strip visibly re-flows a few seconds after the user logs in.
    let aapl = try symbol("AAPL")
    let layout = StripLayout.build(
        symbols: [aapl], quotes: [:], dead: [],
        rows: 1, gap: 20, locale: posix, measure: tenPerCharacter)
    #expect(layout.rows[0].segments.map(\.text) == ["AAPL ", "——"])
}

@Test func anUnknownDirectionShowsTheNumbersWithoutAGlyphOrAColour() throws {
    // `chartPreviousClose == 0` yields `.unknown` (spec §5.3), whose glyph is
    // empty and which is never coloured.
    let btc = try symbol("BTC-USD")
    let layout = StripLayout.build(
        symbols: [btc],
        quotes: [btc: try quote("BTC-USD", price: 64000, change: nil,
                                percent: nil, direction: .unknown)],
        dead: [], rows: 1, gap: 20, locale: posix, measure: tenPerCharacter)

    #expect(layout.rows[0].segments.map(\.text) == ["BTC-USD ", "64,000.00"])
    #expect(layout.rows[0].segments.map(\.role) == [.label, .label])
}

@Test func segmentsAreLaidOutLeftToRightWithNoGapsInsideAnEntry() throws {
    let aapl = try symbol("AAPL")
    let layout = StripLayout.build(
        symbols: [aapl],
        quotes: [aapl: try quote("AAPL", price: 232.1, change: -1.1,
                                 percent: -0.47, direction: .down)],
        dead: [], rows: 1, gap: 20, locale: posix, measure: tenPerCharacter)

    let segments = layout.rows[0].segments
    #expect(segments[0].x == 0)
    for (previous, next) in zip(segments, segments.dropFirst()) {
        #expect(next.x == previous.x + previous.width)
    }
}

@Test func aRowsContentWidthIncludesTheTrailingGapSoACopyTiles() throws {
    // The animation translates by exactly this much (Task 8). If it excluded
    // the trailing gap the two copies would overlap by `gap` once per loop.
    let aapl = try symbol("AAPL")
    let layout = StripLayout.build(
        symbols: [aapl],
        quotes: [aapl: try quote("AAPL", price: 1.0, change: nil,
                                 percent: nil, direction: .flat)],
        dead: [], rows: 1, gap: 20, locale: posix, measure: tenPerCharacter)

    let row = layout.rows[0]
    let painted = row.segments.reduce(0.0) { $0 + $1.width }
    #expect(row.contentWidth == painted + 20)
}

@Test func twoRowsAreBalancedByRenderedWidthNotByCount() throws {
    // Spec §5.1: `RowSplitter` balances by rendered width. With the fake
    // measurement one long symbol outweighs two short ones, so a
    // count-based split would put two in each row and this would fail.
    let names = ["A", "B", "LONGLONGLONGLONG"]
    let symbols = try names.map { try symbol($0) }
    var quotes: [Symbol: Quote] = [:]
    for s in symbols {
        quotes[s] = Quote(symbol: s, shortName: nil, price: 1, previousClose: nil,
                          change: nil, changePercent: nil, currency: nil,
                          direction: .flat, asOfEpoch: nil)
    }
    let layout = StripLayout.build(symbols: symbols, quotes: quotes, dead: [],
                                   rows: 2, gap: 20, locale: posix,
                                   measure: tenPerCharacter)

    #expect(layout.rows.count == 2)
    let widths = layout.rows.map(\.contentWidth)
    // Neither row is empty, and the long symbol is alone in its own row.
    // Hoisted out of `#expect`: the macro re-writes its argument expression,
    // and this codebase keeps trailing closures out of that rewrite.
    let bothRowsUsed = layout.rows.allSatisfy { !$0.segments.isEmpty }
    #expect(bothRowsUsed)
    #expect(abs(widths[0] - widths[1]) < max(widths[0], widths[1]))
}

@Test func askingForOneRowGivesOneRowAndEveryEntryIsInIt() throws {
    let symbols = try ["A", "B", "C"].map { try symbol($0) }
    let layout = StripLayout.build(symbols: symbols, quotes: [:], dead: [],
                                   rows: 1, gap: 20, locale: posix,
                                   measure: tenPerCharacter)
    #expect(layout.rows.count == 1)
    // Two segments per entry (`SYMBOL ` and `——`), three entries.
    #expect(layout.rows[0].segments.count == 6)
}

@Test func anEmptyWatchlistProducesEmptyRowsRatherThanNoRows() throws {
    // The renderer asks for `rows[0]` unconditionally; a watchlist emptied in
    // the picker must not take the status item out with it.
    let layout = StripLayout.build(symbols: [], quotes: [:], dead: [],
                                   rows: 2, gap: 20, locale: posix,
                                   measure: tenPerCharacter)
    let allEmpty = layout.rows.allSatisfy { $0.segments.isEmpty }
    let allZeroWidth = layout.rows.allSatisfy { $0.contentWidth == 0 }
    #expect(layout.rows.count == 2)
    #expect(allEmpty)
    #expect(allZeroWidth)
}

@Test func theWidestRowIsWhatTheFitsTheWidthTestWillCompare() throws {
    let symbols = try ["A", "LONGLONGLONG"].map { try symbol($0) }
    let layout = StripLayout.build(symbols: symbols, quotes: [:], dead: [],
                                   rows: 2, gap: 20, locale: posix,
                                   measure: tenPerCharacter)
    let widest = layout.rows.map(\.contentWidth).max()
    #expect(layout.widestRowWidth == widest)
}

@Test func symbolsAreRenderedExactlyAsTheUserStoredThem() throws {
    // Case is significant and never normalised: `BRK-B`, `^GSPC`, `VOD.L`.
    let raws = ["^GSPC", "BRK-B", "EURUSD=X"]
    let symbols = try raws.map { try symbol($0) }
    let layout = StripLayout.build(symbols: symbols, quotes: [:], dead: [],
                                   rows: 1, gap: 20, locale: posix,
                                   measure: tenPerCharacter)
    let rendered = layout.rows[0].segments.map(\.text).filter { $0 != "——" }
    let expected = raws.map { $0 + " " }
    #expect(rendered == expected)
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
swift test --build-system native --filter StripLayout
```

Expected: FAIL — `cannot find 'StripLayout' in scope`.

- [ ] **Step 3: Write `StripLayout`**

`Sources/Squiggle/StripLayout.swift`:

```swift
import Foundation
import TickerCore

/// What a segment's colour means, rather than what colour it is (R130).
/// `ColorScheme` (Task 12) resolves one of these to an `NSColor` against the
/// status item button's own appearance — which is why the layout must not
/// hold a colour: the same layout is re-rendered, unchanged, when the menu
/// bar switches between light and dark.
enum ColorRole: Equatable, Sendable {
    case label
    case direction(Direction)
}

/// The whole strip as data: segments, widths, offsets and colour roles, with
/// no pixels and no AppKit. Spec §8.5 tests it at exactly this level.
struct StripLayout: Equatable {
    struct Segment: Equatable {
        let text: String
        let role: ColorRole
        /// Points from the left edge of its row.
        let x: Double
        let width: Double
    }

    struct Row: Equatable {
        let segments: [Segment]
        /// One full pass, trailing gap included. Task 8's animation
        /// translates by exactly this, and a second copy of the row drawn at
        /// `x + contentWidth` tiles it seamlessly.
        let contentWidth: Double
    }

    let rows: [Row]

    var widestRowWidth: Double {
        rows.map(\.contentWidth).max() ?? 0
    }

    /// One entry's worth of text, before it has been placed.
    private struct Piece {
        let text: String
        let role: ColorRole
    }

    /// - Parameters:
    ///   - symbols: the watchlist, in the user's order. Order is the user's,
    ///     not sorted: a watchlist that re-orders itself is unreadable.
    ///   - dead: symbols the engine has given up on (spec §7).
    ///   - gap: points between one entry and the next, and between the last
    ///     entry and the repeat of the first.
    ///   - measure: injected text measurement (R131). The caller binds the
    ///     font; nothing here knows what a font is.
    static func build(symbols: [Symbol],
                      quotes: [Symbol: Quote],
                      dead: Set<Symbol>,
                      rows requestedRows: Int,
                      gap: Double,
                      locale: Locale = .autoupdatingCurrent,
                      measure: (String) -> Double) -> StripLayout {
        let rowCount = max(1, min(requestedRows, 2))
        // Named `entries`, not `pieces`: a local called `pieces` would shadow
        // the static `pieces(for:…)` it is initialised from, which Swift
        // rejects as a variable used inside its own initial value.
        let entries = symbols.map { pieces(for: $0, quotes: quotes, dead: dead, locale: locale) }
        let entryWidths = entries.map { entry in
            entry.reduce(0.0) { $0 + measure($1.text) } + gap
        }

        // `RowSplitter` balances by rendered width (spec §5.1) and is the one
        // place that decision lives — duplicating it here is how the CLI and
        // the app would end up disagreeing about the same watchlist.
        let buckets = RowSplitter.split(widths: entryWidths, rows: rowCount)

        // `RowSplitter` always returns exactly `rowCount` buckets, empty ones
        // included, so an emptied watchlist still yields the rows the renderer
        // indexes unconditionally. No padding needed here — and none written,
        // because unreachable padding would read as a guarantee this function
        // makes rather than one it relies on.
        return StripLayout(rows: buckets.map { indices -> Row in
            var segments: [Segment] = []
            var x = 0.0
            for index in indices {
                for piece in entries[index] {
                    let width = measure(piece.text)
                    segments.append(Segment(text: piece.text, role: piece.role,
                                            x: x, width: width))
                    x += width
                }
                x += gap
            }
            return Row(segments: segments, contentWidth: x)
        })
    }

    /// R127's segment order: `SYMBOL price ▲delta (pct%)`. The currency code
    /// is deliberately absent — it is in the dropdown row instead, where
    /// `GBp` can be read as pence by a human rather than squeezed into a
    /// scrolling strip.
    private static func pieces(for symbol: Symbol,
                               quotes: [Symbol: Quote],
                               dead: Set<Symbol>,
                               locale: Locale) -> [Piece] {
        let name = Piece(text: symbol.raw + " ", role: .label)

        // No quote yet and given-up-on are rendered the same way on purpose:
        // both mean "there is no number for this slot right now", and the
        // difference between them is a sentence in the dropdown footer, not
        // a second glyph in the menu bar.
        guard !dead.contains(symbol), let quote = quotes[symbol] else {
            return [name, Piece(text: Formatting.deadPlaceholder, role: .label)]
        }

        let delta = Formatting.delta(quote.change, locale: locale)
        let percent = Formatting.percent(quote.changePercent, locale: locale)
        let glyph = quote.direction.glyph

        // Nothing to say about the change: show the price alone rather than a
        // bare glyph or an empty pair of brackets.
        guard !delta.isEmpty || !percent.isEmpty else {
            return [name, Piece(text: Formatting.price(quote.price, locale: locale), role: .label)]
        }

        var change = glyph + delta
        if !percent.isEmpty {
            change += change.isEmpty ? "(\(percent))" : " (\(percent))"
        }

        return [
            name,
            Piece(text: Formatting.price(quote.price, locale: locale) + " ", role: .label),
            Piece(text: change, role: .direction(quote.direction)),
        ]
    }
}
```

- [ ] **Step 4: Run to verify they pass**

```bash
swift test --build-system native --filter StripLayout
```

Expected: PASS, 12 tests.

- [ ] **Step 5: Confirm the layout really is AppKit-free**

```bash
grep -n "import" Sources/Squiggle/StripLayout.swift
```

Expected: exactly `import Foundation` and `import TickerCore`. An `import AppKit` creeping in here means a colour or a font has leaked into the layout, which is what R130 and R131 exist to prevent.

- [ ] **Step 6: Commit**

```bash
git add Sources/Squiggle/StripLayout.swift Tests/SquiggleTests/StripLayoutTests.swift
git commit -m "feat: compose the strip as data — segments, offsets, colour roles"
```

---

## Task 6: A status item that shows real prices, and the loop behind it

Build-order step 5: *"A static status item showing one row of text, driven by the real feed."* No animation yet — the strip is painted into the button's `attributedTitle` and sits still. That is deliberate: it puts the whole data path under a user's eye with none of Core Animation's machinery in the way, so a wrong price here can only be a data bug.

`TickerRunner` is the loop `WatchLoop` proved out, minus the printing and minus the `while`. It holds the engine, the calendars, and the two facts `FeedEngine` does not track — when the last success was and what the last failure was — because spec §7's footer needs both and nothing else in the system remembers them.

The single real timer in the app lives in `StatusItemController` (spec §2.2), and it is a one-shot rescheduled after each step rather than a repeating timer: the interval the engine asks for changes every tick.

**Files:**
- Create: `Sources/Squiggle/TickerRunner.swift`
- Create: `Sources/Squiggle/StatusItemController.swift`
- Modify: `Sources/Squiggle/AppDelegate.swift`
- Test: `Tests/SquiggleTests/TickerRunnerTests.swift`

**Interfaces:**
- Consumes: `FeedEngine`, `EngineContext`, `EngineAction`, `Visibility`, `MonotonicClock`, `QuoteFetching`, `TickerError`, `RateConstants`, `TradingCalendars` (Task 2), `YahooQuoteDecoding.snapshot(from:symbol:)` (Task 2), `StripLayout` (Task 5), `ColorRole` (Task 5).
- Produces:
  - `@MainActor final class TickerRunner` with `init(symbols:userIntervalSeconds:fetcher:clock:)`, `func step(nowEpoch:visibility:lowPowerMode:) async -> Double`, and read-only `quotes`, `deadSymbols`, `lastSuccessEpoch`, `lastError`, `symbols`, `userIntervalSeconds`. Tasks 8, 11, 12, 13 and 15 all read these.
  - `@MainActor final class StatusItemController` with `init(runner:settings:)`, `func start()`, `func stop()`. Task 8 replaces its rendering, Task 10 its pause handling, Task 11 adds its menu.

- [ ] **Step 1: Write the failing tests**

`Tests/SquiggleTests/TickerRunnerTests.swift`:

```swift
import Foundation
import Testing
import TickerCore
@testable import Squiggle

/// The recorded Yahoo bodies from plan 1. Reached by path rather than by
/// resource bundle because `Tests/Fixtures/` is shared by three test targets.
private enum Fixture {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // SquiggleTests
        .deletingLastPathComponent()      // Tests
        .appendingPathComponent("Fixtures/yahoo-2026-09-08")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }
}

/// Hands back canned bytes, or throws a canned error. No network: the project
/// has been rate-limited enough times already, and a test that reaches Yahoo
/// is a test that fails on an aeroplane.
private final class FakeFetcher: QuoteFetching, @unchecked Sendable {
    var body: Data?
    var error: (any Error)?
    private(set) var fetchCount = 0

    func fetch(_ symbol: Symbol) async throws -> Data {
        fetchCount += 1
        if let error { throw error }
        return body ?? Data()
    }
}

private final class FakeClock: MonotonicClock, @unchecked Sendable {
    var nowSeconds: Double = 0
}

@MainActor
@Test func aSuccessfulStepStoresTheQuoteAndStampsTheSuccess() async throws {
    let aapl = try #require(Symbol("AAPL"))
    let fetcher = FakeFetcher()
    fetcher.body = try Fixture.data("regular-session.json")
    let runner = TickerRunner(symbols: [aapl], userIntervalSeconds: 180,
                              fetcher: fetcher, clock: FakeClock())

    _ = await runner.step(nowEpoch: 1_000, visibility: .visible, lowPowerMode: false)

    #expect(runner.quotes[aapl]?.symbol == aapl)
    #expect(runner.lastSuccessEpoch == 1_000)
    #expect(runner.lastError == nil)
}

@MainActor
@Test func aFailedStepKeepsTheOldSuccessStampAndRecordsTheError() async throws {
    // Spec §7's stale state: prices are still shown, dimmed. Clearing the
    // stamp on failure would make a two-minute blip look like a cold start.
    let aapl = try #require(Symbol("AAPL"))
    let fetcher = FakeFetcher()
    fetcher.body = try Fixture.data("regular-session.json")
    let clock = FakeClock()
    let runner = TickerRunner(symbols: [aapl], userIntervalSeconds: 180,
                              fetcher: fetcher, clock: clock)
    _ = await runner.step(nowEpoch: 1_000, visibility: .visible, lowPowerMode: false)

    fetcher.error = TickerError.offline
    // Far enough ahead that the pacer's spacing floor has expired.
    clock.nowSeconds = 10_000
    var later = 0.0
    for _ in 0..<40 where runner.lastError == nil {
        later = await runner.step(nowEpoch: 11_000, visibility: .visible, lowPowerMode: false)
        clock.nowSeconds += max(later, 1)
    }

    #expect(runner.lastError == .offline)
    #expect(runner.lastSuccessEpoch == 1_000)
    #expect(runner.quotes[aapl] != nil)
}

@MainActor
@Test func theCalendarOutOfTheBodyIsWhatDrivesTheNextContext() async throws {
    // Spec §3.2 and R122: one request yields both the quote and the trading
    // calendar. If the calendar were dropped, every symbol would be polled
    // at the regular cadence around the clock.
    let aapl = try #require(Symbol("AAPL"))
    let fetcher = FakeFetcher()
    fetcher.body = try Fixture.data("overnight-closed.json")
    let runner = TickerRunner(symbols: [aapl], userIntervalSeconds: 180,
                              fetcher: fetcher, clock: FakeClock())

    _ = await runner.step(nowEpoch: 1_000, visibility: .visible, lowPowerMode: false)

    #expect(runner.marketStateForTesting(atEpoch: 1_000) != nil)
}

@MainActor
@Test func stepNeverThrowsEvenWhenTheFetcherThrowsSomethingUnexpected() async throws {
    // `QuoteFetching` promises `TickerError`, but nothing in the language
    // enforces that across an `async throws` boundary, and an uncaught throw
    // here would take the status item's timer with it.
    struct Surprise: Error {}
    let aapl = try #require(Symbol("AAPL"))
    let fetcher = FakeFetcher()
    fetcher.error = Surprise()
    let clock = FakeClock()
    let runner = TickerRunner(symbols: [aapl], userIntervalSeconds: 180,
                              fetcher: fetcher, clock: clock)

    for _ in 0..<40 where runner.lastError == nil {
        let wait = await runner.step(nowEpoch: 1_000, visibility: .visible, lowPowerMode: false)
        clock.nowSeconds += max(wait, 1)
    }
    #expect(runner.lastError != nil)
}

@MainActor
@Test func anOccludedRunnerStillReportsAWaitRatherThanFetching() async throws {
    // Spec §5.2: occlusion stops the animation. `FeedEngine` also stretches
    // the cadence for it, and the runner must pass the fact through rather
    // than hard-code `.visible` the way the CLI does.
    let aapl = try #require(Symbol("AAPL"))
    let fetcher = FakeFetcher()
    fetcher.body = try Fixture.data("regular-session.json")
    let clock = FakeClock()
    let runner = TickerRunner(symbols: [aapl], userIntervalSeconds: 60,
                              fetcher: fetcher, clock: clock)
    _ = await runner.step(nowEpoch: 1_000, visibility: .occluded, lowPowerMode: false)
    let countAfterFirst = fetcher.fetchCount

    clock.nowSeconds = 100
    _ = await runner.step(nowEpoch: 1_100, visibility: .occluded, lowPowerMode: false)
    #expect(fetcher.fetchCount == countAfterFirst)
}

@MainActor
@Test func replacingTheWatchlistDropsQuotesForSymbolsNoLongerWatched() async throws {
    // Otherwise a symbol removed in the picker keeps its last price in
    // `quotes` and the dropdown quietly shows a row for something the user
    // deleted.
    let aapl = try #require(Symbol("AAPL"))
    let vod = try #require(Symbol("VOD.L"))
    let fetcher = FakeFetcher()
    fetcher.body = try Fixture.data("regular-session.json")
    let runner = TickerRunner(symbols: [aapl], userIntervalSeconds: 180,
                              fetcher: fetcher, clock: FakeClock())
    _ = await runner.step(nowEpoch: 1_000, visibility: .visible, lowPowerMode: false)
    #expect(runner.quotes[aapl] != nil)

    runner.replaceWatchlist([vod])
    #expect(runner.quotes[aapl] == nil)
    #expect(runner.symbols == [vod])
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
swift test --build-system native --filter TickerRunner
```

Expected: FAIL — `cannot find 'TickerRunner' in scope`.

- [ ] **Step 3: Write `TickerRunner`**

`Sources/Squiggle/TickerRunner.swift`:

```swift
import Foundation
import TickerCore

/// One turn of `FeedEngine`'s crank, with no timer and no printing.
/// `squigglectl`'s `WatchLoop` is the same logic wrapped in a `while`; this is
/// the same logic wrapped in nothing, so the status item's timer can drive it.
///
/// It decides nothing the engine could decide. The only state it owns that the
/// engine does not is the pair spec §7's footer needs — when the last success
/// was, and what the last failure was — which `FeedEngine` deliberately does
/// not track because nothing in its own policy depends on them.
@MainActor
final class TickerRunner {
    private var engine: FeedEngine
    private let fetcher: any QuoteFetching
    private var calendars = TradingCalendars()

    private(set) var symbols: [Symbol]
    private(set) var userIntervalSeconds: Double
    private(set) var quotes: [Symbol: Quote] = [:]
    private(set) var lastSuccessEpoch: Double?
    private(set) var lastError: TickerError?

    var deadSymbols: Set<Symbol> { engine.deadSymbols }
    var diagnosticSnapshot: FeedEngine.DiagnosticSnapshot { engine.diagnosticSnapshot }

    init(symbols: [Symbol], userIntervalSeconds: Double,
         fetcher: any QuoteFetching, clock: any MonotonicClock = SystemClock()) {
        self.symbols = symbols
        self.userIntervalSeconds = userIntervalSeconds
        self.fetcher = fetcher
        self.engine = FeedEngine(clock: clock, symbols: symbols,
                                 userIntervalSeconds: userIntervalSeconds)
    }

    /// Ask the engine what to do and do it. Returns the seconds the caller
    /// should wait before calling again; `0` means "the engine is mid-cycle,
    /// come straight back", which the caller clamps to its own floor.
    ///
    /// Never throws. An escaping error here would kill the status item's
    /// timer and the app would sit there with a frozen price and no way to
    /// say so.
    @discardableResult
    func step(nowEpoch: Double, visibility: Visibility, lowPowerMode: Bool) async -> Double {
        calendars.retain(Set(symbols).subtracting(engine.deadSymbols))
        let context = EngineContext(
            nowEpoch: nowEpoch,
            // Before the first successful quote, assume the market is open:
            // one wasted request beats a ticker that never starts.
            marketState: calendars.aggregateState(atEpoch: nowEpoch) ?? .regular,
            visibility: visibility,
            lowPowerMode: lowPowerMode,
            nextSessionOpenEpoch: calendars.earliestSessionOpenEpoch(after: nowEpoch))

        switch engine.next(context) {
        case .sleep(let seconds):
            return seconds

        case .fetch(let symbol):
            do {
                let bytes = try await fetcher.fetch(symbol)
                let snapshot = try YahooQuoteDecoding.snapshot(from: bytes, symbol: symbol)
                engine.recordSuccess(snapshot.quote, for: symbol)
                quotes[symbol] = snapshot.quote
                lastSuccessEpoch = nowEpoch
                lastError = nil
                if let period = snapshot.tradingPeriod {
                    calendars.record(period, for: symbol)
                }
            } catch let error as TickerError {
                engine.record(error, for: symbol)
                lastError = error
            } catch {
                // Same reasoning as `WatchLoop`'s catch-all: the protocol
                // promises `TickerError` and the language does not enforce it.
                let wrapped = TickerError.transport(YahooFeedTransportFaultBridge.classify(error))
                engine.record(wrapped, for: symbol)
                lastError = wrapped
            }
            return 0
        }
    }

    func replaceWatchlist(_ newSymbols: [Symbol]) {
        symbols = newSymbols
        engine.replaceWatchlist(newSymbols)
        let live = Set(newSymbols)
        quotes = quotes.filter { live.contains($0.key) }
        calendars.retain(live)
    }

    func setUserInterval(_ seconds: Double) {
        userIntervalSeconds = seconds
        engine.setUserInterval(seconds)
    }

    /// Exists for `theCalendarOutOfTheBodyIsWhatDrivesTheNextContext`. The
    /// aggregate is otherwise private because nothing outside `step` needs it,
    /// and a calendar read from elsewhere would be a second opinion about
    /// market hours.
    func marketStateForTesting(atEpoch epoch: Double) -> MarketState? {
        calendars.aggregateState(atEpoch: epoch)
    }
}
```

The catch-all needs a classifier. `TransportFaults.classify` lives in `YahooFeed` (Task 2), and the app target already depends on `YahooFeed` (Task 3), so import it and call it directly — replace the `YahooFeedTransportFaultBridge.classify(error)` placeholder name above with the real one:

```swift
import YahooFeed
// …
let wrapped = TickerError.transport(TransportFaults.classify(error))
```

Write it that way the first time; the two-step is only here so the dependency is impossible to miss.

- [ ] **Step 4: Run to verify they pass**

```bash
swift test --build-system native --filter TickerRunner
```

Expected: PASS, 6 tests.

If `aFailedStepKeepsTheOldSuccessStampAndRecordsTheError` or `stepNeverThrows…` spins all forty iterations without recording, the engine is in a cooldown the fake clock is not advancing past — raise the clock increment, do not raise the iteration count.

- [ ] **Step 5: Write `StatusItemController`**

`Sources/Squiggle/StatusItemController.swift`:

```swift
import AppKit
import TickerCore

/// The `NSStatusItem`, and the one real timer in the app (spec §2.2).
///
/// The timer is a one-shot, rescheduled after every step rather than a
/// repeating one: the interval `FeedEngine` asks for changes with the market
/// state, Low Power Mode, and the ladder's cooldown, so a repeating timer
/// would be answering a question that had already changed.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let runner: TickerRunner
    private var settings: Settings
    private var timer: Timer?

    init(runner: TickerRunner, settings: Settings) {
        self.runner = runner
        self.settings = settings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = ""
    }

    func start() {
        render()
        scheduleStep(after: 0)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func scheduleStep(after seconds: Double) {
        timer?.invalidate()
        let delay = max(seconds, RateConstants.minimumWaitSeconds)
        let fired = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            // `Timer`'s block is not main-actor-isolated, so hop explicitly
            // rather than annotating the closure and hoping.
            Task { @MainActor in await self?.stepOnce() }
        }
        // R56: let the OS coalesce this wakeup with other system timers. The
        // app is explicitly not time-critical, and tolerance buys more
        // battery than any interval choice does.
        fired.tolerance = delay * RateConstants.timerLeewayFraction
        timer = fired
        RunLoop.main.add(fired, forMode: .common)
    }

    private func stepOnce() async {
        let wait = await runner.step(nowEpoch: Date().timeIntervalSince1970,
                                     visibility: visibility(),
                                     lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
        render()
        scheduleStep(after: wait)
    }

    /// Task 10 replaces this with the notification-driven version (R134).
    /// Until then the status item is always treated as visible, which is the
    /// conservative answer: it costs requests, never correctness.
    private func visibility() -> Visibility { .visible }

    /// Task 8 replaces this with the Core Animation strip. For now the first
    /// row is painted, static, into the button's title — the whole data path
    /// under a user's eye with none of Core Animation in the way.
    private func render() {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let layout = StripLayout.build(
            symbols: runner.symbols, quotes: runner.quotes,
            dead: runner.deadSymbols, rows: 1, gap: 20,
            measure: { ($0 as NSString).size(withAttributes: [.font: font]).width })

        let line = NSMutableAttributedString()
        for segment in layout.rows[0].segments {
            line.append(NSAttributedString(string: segment.text,
                                           attributes: [.font: font,
                                                        .foregroundColor: NSColor.labelColor]))
        }
        button.attributedTitle = line
    }
}
```

`.foregroundColor` is `labelColor` for every segment here — Task 12 is what makes `ColorRole` mean anything. Painting it monochrome now is not a stub: Monochrome is the default scheme (R119), so this is the app's actual default appearance.

- [ ] **Step 6: Wire it into the delegate**

Replace the body of `applicationDidFinishLaunching` in `Sources/Squiggle/AppDelegate.swift`, and add the property:

```swift
import AppKit
import TickerCore
import YahooFeed

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = FileWatchlistStore(url: FileWatchlistStore.defaultURL(applicationName: "Squiggle"))
        // A store that will not load is not a reason to refuse to launch: an
        // empty watchlist is a usable app with an empty strip, and spec §7
        // puts the explanation in the dropdown footer rather than an alert.
        // Task 11 carries the fault into that footer; this keeps the launch.
        let loaded = try? store.load()
        let settings = loaded?.settings ?? Settings()
        let symbols = loaded?.symbols ?? []

        let runner = TickerRunner(symbols: symbols,
                                  userIntervalSeconds: settings.refreshIntervalSeconds,
                                  fetcher: YahooClient())
        let controller = StatusItemController(runner: runner, settings: settings)
        self.controller = controller
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}
```

If `YahooClient`'s initialiser takes arguments, pass whatever `squigglectl`'s `Command` passes it — check with `grep -n "YahooClient(" Sources/squigglectl/`. It must not be given a new configuration here: one client, one set of headers, one timeout, shared between the CLI and the app.

- [ ] **Step 7: Build and run it by hand**

```bash
swift build --build-system native --product Squiggle
```

Then run the binary directly and watch the menu bar. There is no quit item yet (Task 11 adds it), so plan the exit:

```bash
.build/debug/Squiggle & echo $! > /tmp/squiggle.pid
```

`squigglectl` has no `add` command — its verbs are `quote`, `watch`, `search`, `doctor`, `probe` — and the symbol picker is Task 15, so seed the watchlist by writing the file, which is the whole of persistence (spec §6). Every field decodes leniently, so `"settings": {}` is a complete and valid settings block:

```bash
mkdir -p ~/Library/Application\ Support/Squiggle
cat > ~/Library/Application\ Support/Squiggle/squiggle.json <<'JSON'
{"schemaVersion": 1, "symbols": ["AAPL", "MSFT"], "settings": {}}
JSON
```

If that file already exists, back it up first — it is the user's real watchlist, not scratch. Expect a price in the menu bar within a few seconds, static. Then:

```bash
kill "$(cat /tmp/squiggle.pid)"
```

- [ ] **Step 8: Commit**

```bash
git add Sources/Squiggle Tests/SquiggleTests/TickerRunnerTests.swift
git commit -m "feat: put real prices in the menu bar, driven by one timer"
```

---

## Task 7: A real bundle, because `SMAppService` needs one

Build-order step 9 moved here by R123: `SMAppService.mainApp` registers the *bundle*, so Task 14 cannot be written, let alone tested, against a bare SwiftPM executable. The `LSUIElement` flag is the other reason to do it now — it is what stops a dock icon appearing, and every hand-run of the app between here and Task 15 is nicer without one.

SwiftPM has no concept of an app bundle and there is no Xcode on this machine, so the bundle is assembled by a script, exactly as `/Users/ben/Projects/Pitch` does it. `iconutil` ships with the Command Line Tools; `actool` and `xcrun notarytool` do not, which is why the icon is a `.iconset` rather than an asset catalogue and why R126 delivers an ad-hoc-signed bundle plus a Gatekeeper instruction instead of a notarised zip.

**Files:**
- Create: `Resources/Info.plist`
- Create: `Tools/GenerateIcon.swift`
- Create: `scripts/package-app.sh`
- Create: `Resources/AppIcon.icns` (generated by the script, committed)
- Create: `README.md` (the repo has none yet)

**Interfaces:**
- Consumes: the `Squiggle` product from Task 3.
- Produces: `build/Squiggle.app`, bundle identifier `com.houlanyit.Squiggle`. Task 14 registers exactly this bundle.

- [ ] **Step 1: Write the Info.plist**

`Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Squiggle</string>
	<key>CFBundleDisplayName</key>
	<string>Squiggle</string>
	<key>CFBundleExecutable</key>
	<string>Squiggle</string>
	<!-- An LSUIElement app has no dock tile, but Finder, System Settings >
	     Login Items, and any installer still ask for the icon, so it is not
	     optional just because the app is an agent. -->
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.houlanyit.Squiggle</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<!-- Squiggle's entire UI is one status item. No dock tile, no app
	     switcher entry, no menu bar menu of its own. `main.swift` sets the
	     matching activation policy for the case where the binary is run
	     without a bundle at all. -->
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
```

Tabs, not spaces, for the indentation — that is what `plutil` and Xcode both write, and a plist that differs from every other plist on the machine invites someone to "fix" it.

- [ ] **Step 2: Verify the plist parses**

```bash
plutil -lint Resources/Info.plist
```

Expected: `Resources/Info.plist: OK`.

- [ ] **Step 3: Write the icon generator**

`Tools/GenerateIcon.swift`:

```swift
// Renders the app icon into a .iconset directory, which `scripts/package-app.sh`
// then hands to `iconutil` to produce Resources/AppIcon.icns.
//
// A standalone script, not a target: it is build tooling, and adding it to
// Package.swift would put AppKit drawing code in the dependency graph of a
// package whose library target is forbidden from importing AppKit at all.
//
// The glyph is the `chart.line.uptrend.xyaxis` SF Symbol. Taken from the
// system rather than transcribed as a path, so it stays consistent with
// whatever the OS draws.

import AppKit
import Foundation

private enum Tile {
    /// Proportions of the macOS icon grid: the rounded square occupies the
    /// middle ~80% of the canvas, leaving the margin the system expects for
    /// shadows and optical alignment against other icons.
    static let inset: CGFloat = 100.0 / 1024.0
    static let cornerRadius: CGFloat = 185.0 / 1024.0
    /// Glyph size as a fraction of the tile. The chart symbol is wide and
    /// squat, so fitting it by its longest side leaves it reading small
    /// unless the nominal box is generous.
    static let glyphFraction: CGFloat = 0.66

    static let top = NSColor(srgbRed: 0.106, green: 0.184, blue: 0.290, alpha: 1)
    static let bottom = NSColor(srgbRed: 0.035, green: 0.055, blue: 0.098, alpha: 1)
    static let stroke = NSColor(srgbRed: 0.549, green: 0.867, blue: 0.678, alpha: 1)
}

private func render(pixels: Int) -> NSBitmapImageRep? {
    let side = CGFloat(pixels)
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: rep)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.shouldAntialias = true

    let inset = side * Tile.inset
    let tile = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = side * Tile.cornerRadius
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
    NSGradient(starting: Tile.bottom, ending: Tile.top)?.draw(in: tilePath, angle: 90)

    let box = tile.width * Tile.glyphFraction
    guard
        let symbol = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis",
                             accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: box, weight: .semibold))
    else { return nil }
    symbol.isTemplate = true

    // Fitted by whichever side runs out first, so the glyph keeps its own
    // aspect ratio instead of being stretched into a square.
    let fit = min(box / symbol.size.width, box / symbol.size.height)
    let drawn = NSSize(width: symbol.size.width * fit, height: symbol.size.height * fit)
    let frame = NSRect(
        x: tile.midX - drawn.width / 2,
        y: tile.midY - drawn.height / 2,
        width: drawn.width,
        height: drawn.height)

    // The transparency layer is load-bearing. `.sourceAtop` recolours whatever
    // it finds underneath it, so without a layer to scope it to, the fill would
    // land on the gradient tile as well and paint the whole icon flat green.
    // Inside the layer the only thing under the fill is the glyph's own alpha.
    context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
    symbol.draw(in: frame)
    Tile.stroke.setFill()
    frame.fill(using: .sourceAtop)
    context.cgContext.endTransparencyLayer()

    return rep
}

/// The exact set `iconutil` expects; anything missing makes it refuse the
/// directory outright.
private let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: GenerateIcon <output.iconset>\n".utf8))
    exit(2)
}

let directory = URL(fileURLWithPath: arguments[1])
try? FileManager.default.removeItem(at: directory)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

for variant in variants {
    guard
        let rep = render(pixels: variant.pixels),
        let data = rep.representation(using: .png, properties: [:])
    else {
        FileHandle.standardError.write(Data("failed to render \(variant.name)\n".utf8))
        exit(1)
    }
    try data.write(to: directory.appendingPathComponent(variant.name))
}

print("Wrote \(variants.count) images to \(directory.path)")
```

- [ ] **Step 4: Check the generator runs before wiring it into a script**

```bash
swift Tools/GenerateIcon.swift /tmp/squiggle-icon-check.iconset && ls /tmp/squiggle-icon-check.iconset
```

Expected: `Wrote 10 images…` and ten PNGs. If `NSImage(systemSymbolName:)` returns nil, the symbol name is wrong for this OS — pick another chart symbol from SF Symbols rather than hand-drawing a path, and change the comment to match the name you chose.

- [ ] **Step 5: Write the packaging script**

`scripts/package-app.sh`:

```bash
#!/bin/bash
# Assembles Squiggle.app from the SwiftPM release build.
#
# SwiftPM produces a bare Mach-O executable and has no concept of an
# application bundle, so the bundle is built by hand here. Everything below is
# the minimum macOS needs to treat the result as an app: the directory layout,
# an Info.plist, and a signature.
#
# The signature is ad-hoc (`-`). That is enough for a locally built app the
# user launches themselves, and enough for `SMAppService.mainApp` to register
# it (Task 14). It is NOT enough for distribution: a downloaded copy is
# quarantined, which the README's Gatekeeper note covers.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Squiggle.app"
ICONSET="$ROOT/build/AppIcon.iconset"
ICON="$ROOT/Resources/AppIcon.icns"

cd "$ROOT"
swift build --build-system native -c release --product Squiggle

# Regenerated every time rather than trusted from the repo, so the icon cannot
# drift from the generator that defines it. The .icns is committed all the same,
# for anything that wants the artwork without running a build.
swift Tools/GenerateIcon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ICON"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/.build/release/Squiggle" "$APP/Contents/MacOS/Squiggle"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --deep --sign - "$APP"
codesign --verify --strict "$APP"

echo "Built $APP"
```

Then:

```bash
chmod +x scripts/package-app.sh
```

- [ ] **Step 6: Build the bundle and check macOS accepts it**

```bash
scripts/package-app.sh
```

Expected: ends with `Built …/build/Squiggle.app`, and `codesign --verify --strict` says nothing (silence is success).

```bash
/usr/libexec/PlistBuddy -c 'Print :LSUIElement' build/Squiggle.app/Contents/Info.plist
```

Expected: `true`.

- [ ] **Step 7: Launch the bundle and confirm it is an agent**

```bash
open build/Squiggle.app
```

Expected: a price appears in the menu bar, **no dock icon**, and no Squiggle entry when you ⌘-Tab. A dock icon appearing means the plist was not copied or `LSUIElement` was not read — check the plist inside the bundle, not the one in `Resources/`.

```bash
pkill -x Squiggle
```

- [ ] **Step 8: Check the built bundle is out of git, and the icon is in**

```bash
git check-ignore build && git status --porcelain Resources/
```

Expected: `build` on the first line (`.gitignore` already carries `build/`), and `Resources/` showing two untracked files. If `git check-ignore` prints nothing, add `build/` to `.gitignore` before going further — a committed `Squiggle.app` is a 3MB binary in the history that nothing can take back out.

`Resources/AppIcon.icns` is committed deliberately — it is a generated file, but it is also the artwork, and a fresh clone should be able to show the icon without running a script that needs AppKit.

- [ ] **Step 9: Write the Gatekeeper note into the README**

There is no `README.md` in this repo yet, so create one. Above the Gatekeeper note put a short orientation — what the app is, what `squigglectl` is, how to run the tests:

```markdown
# Squiggle

A macOS menu bar stock ticker. Prices scroll in the menu bar; everything else
lives in the status item's dropdown. No dock icon, no notifications, no alerts.

- `Sources/TickerCore` — the pure decision core: refresh cadence, backoff,
  parsing, persistence. No AppKit, no networking, no clock.
- `Sources/YahooFeed` — the one network client.
- `Sources/Squiggle` — the menu bar app.
- `Sources/squigglectl` — a command-line harness for the same core, used to
  exercise the feed without a UI.

```bash
swift test --build-system native
```

## Installing
```

Then, under that `## Installing` heading:

> Build the app with `scripts/package-app.sh` and drag `build/Squiggle.app` to `/Applications`.
>
> The bundle is **ad-hoc signed**, not notarized. A copy you built yourself launches normally. A copy that arrives over the network — AirDrop, a download, a shared folder — is quarantined by macOS, and the first launch is refused with *"Squiggle is damaged and can't be opened."* The message is wrong; nothing is damaged. Clear the quarantine flag:
>
> ```bash
> xattr -dr com.apple.quarantine /Applications/Squiggle.app
> ```
>
> Squiggle has no dock icon and no app switcher entry by design (`LSUIElement`). Its whole interface is the menu bar item; quit it from the item's dropdown.

- [ ] **Step 10: Commit**

```bash
git add Resources/Info.plist Resources/AppIcon.icns Tools/GenerateIcon.swift scripts/package-app.sh README.md
git commit -m "build: assemble Squiggle.app as an ad-hoc-signed agent bundle"
```

---

## Task 8: The strip in motion

Task 5 turned the watchlist into geometry. This turns that geometry into layers and gives it the one animation spec §5.1 allows: a single repeating `CABasicAnimation`, no `CVDisplayLink`, no per-frame timer, `preferredFrameRateRange` capped at 30 fps.

Two rules from spec §5.2 land here rather than in Task 10, because they are properties of the animation rather than of the system:

- A strip that already fits the fixed width has its animation **removed**, not paused. This is the common 2–4 symbol case, and it is the difference between an idle app and one holding the GPU awake to move nothing.
- Pausing is `layer.speed = 0` with `timeOffset` captured. Removing and re-adding the animation makes the strip jump — the position snaps back to where the animation last started, which is a visible glitch every time the user unlocks their screen.

Task 10 supplies the *conditions*; this task supplies the mechanics, which is the half a test can reach.

**Files:**
- Create: `Sources/Squiggle/StripRenderer.swift`
- Create: `Sources/Squiggle/TickerView.swift`
- Modify: `Sources/Squiggle/StatusItemController.swift`
- Test: `Tests/SquiggleTests/StripRendererTests.swift`

**Interfaces:**
- Consumes: `StripLayout`, `StripLayout.Row`, `StripLayout.Segment`, `ColorRole` (Task 5); `StatusItemController` (Task 6).
- Produces:
  - `StripRenderer.Metrics` with `rowCount: Int`, `font: NSFont`, `rowHeight: Double`
  - `StripRenderer.metrics(rows: Int, barHeight: Double) -> Metrics`
  - `StripRenderer.duration(contentWidth: Double, pointsPerSecond: Double) -> Double`
  - `StripRenderer.fits(contentWidth: Double, visibleWidth: Double) -> Bool`
  - `StripRenderer.resumedBeginTime(nowInLayerTime: Double, pausedOffset: Double) -> Double`
  - `TickerView.apply(layout:metrics:visibleWidth:pointsPerSecond:color:)`, `TickerView.pause()`, `TickerView.resume()`, `TickerView.isPaused`

### R135 — the strip is set in a monospaced-digit face

`NSFont.monospacedDigitSystemFont(ofSize:weight:)`, not `NSFont.systemFont(ofSize:)`.

The system face gives digits proportional widths, so `1` is narrower than `8`. In a strip that re-renders on every successful quote, a price going from `178.11` to `178.88` changes the *width* of everything to its right, and the whole tail of the row shifts by a point or two. It reads as a flinch. Monospaced digits cost nothing, and the letters in a symbol keep their proportional spacing either way.

### R136 — the colour resolver is injected as `(ColorRole) -> CGColor`

The same shape as R131's measurement closure, and for the same reason: `StripRenderer` should not know what a colour scheme is, and — more pressingly — should not know that colours have to be resolved against `statusItem.button.effectiveAppearance` rather than the app's (spec §5.3). Task 12 supplies a closure that does that. Until then Task 8 supplies one that returns `NSColor.labelColor.cgColor`, which is the real Monochrome rendering under R119's default, not a stub.

`CGColor` and not `NSColor` because a `CATextLayer` takes a `CGColor`, and `NSColor.cgColor` is resolved against whatever appearance is current *at the moment you ask*. Doing that conversion at the boundary means there is exactly one place in the app where the appearance has to be right, and Task 12 owns it.

- [ ] **Step 1: Write the failing tests**

`Tests/SquiggleTests/StripRendererTests.swift`:

```swift
import AppKit
import Testing
@testable import Squiggle

@Suite("Strip renderer")
struct StripRendererTests {
    // The menu bar is 22pt on an ordinary display, 24 on some notched ones.
    // Hard-coded here rather than read from NSStatusBar so the arithmetic is
    // the thing under test and not the machine the test runs on.
    private let barHeight = 22.0

    @Test("one row uses the full bar at the larger size")
    func oneRowIsThirteenPoint() {
        let metrics = StripRenderer.metrics(rows: 1, barHeight: barHeight)
        #expect(metrics.rowCount == 1)
        #expect(metrics.font.pointSize == 13)
        #expect(metrics.rowHeight == 22.0)
    }

    @Test("two rows split the bar and drop to the smaller size")
    func twoRowsAreTenPoint() {
        let metrics = StripRenderer.metrics(rows: 2, barHeight: barHeight)
        #expect(metrics.rowCount == 2)
        #expect(metrics.font.pointSize == 10)
        #expect(metrics.rowHeight == 11.0)
    }

    // The same clamp `RowSplitter.split` applies. Two places agreeing by
    // accident is a bug waiting for someone to change one of them, so it is
    // asserted in both.
    @Test("row counts outside 1...2 are clamped, matching RowSplitter")
    func rowCountsAreClamped() {
        #expect(StripRenderer.metrics(rows: 0, barHeight: barHeight).rowCount == 1)
        #expect(StripRenderer.metrics(rows: -4, barHeight: barHeight).rowCount == 1)
        #expect(StripRenderer.metrics(rows: 7, barHeight: barHeight).rowCount == 2)
    }

    @Test("a strip takes its width divided by its speed to cross")
    func durationIsWidthOverSpeed() {
        #expect(StripRenderer.duration(contentWidth: 480, pointsPerSecond: 24) == 20)
        #expect(StripRenderer.duration(contentWidth: 48, pointsPerSecond: 24) == 2)
    }

    // A zero or negative speed divides to infinity or runs the strip
    // backwards; Core Animation accepts both and the result is a frozen or
    // reversed bar. The floor is the cheapest place to stop it.
    @Test("a speed of zero or less becomes the slowest sane speed, not a division by zero")
    func durationRefusesAZeroSpeed() {
        let stopped = StripRenderer.duration(contentWidth: 480, pointsPerSecond: 0)
        #expect(stopped.isFinite)
        #expect(stopped > 0)
        #expect(StripRenderer.duration(contentWidth: 480, pointsPerSecond: -24) == stopped)
    }

    @Test("an empty strip still reports a usable duration")
    func durationRefusesAZeroWidth() {
        let empty = StripRenderer.duration(contentWidth: 0, pointsPerSecond: 24)
        #expect(empty.isFinite)
        #expect(empty > 0)
    }

    // Spec §5.2: the animation is removed, not slowed, when the content
    // already fits. Equal widths fit — a strip exactly as wide as its window
    // has nothing to reveal by moving.
    @Test("content narrower than or equal to the window does not animate")
    func narrowContentFits() {
        #expect(StripRenderer.fits(contentWidth: 100, visibleWidth: 260))
        #expect(StripRenderer.fits(contentWidth: 260, visibleWidth: 260))
    }

    @Test("content wider than the window animates")
    func wideContentDoesNotFit() {
        let overflowing = StripRenderer.fits(contentWidth: 261, visibleWidth: 260)
        #expect(!overflowing)
    }

    // The Core Animation pause/resume recipe: on resume the layer's begin
    // time is pushed forward by exactly as much wall time as the pause
    // consumed, so the strip carries on from where it stopped instead of
    // snapping back to the animation's origin.
    @Test("resuming shifts the begin time by the paused interval")
    func resumingShiftsBeginTime() {
        #expect(StripRenderer.resumedBeginTime(nowInLayerTime: 100, pausedOffset: 40) == 60)
        #expect(StripRenderer.resumedBeginTime(nowInLayerTime: 40, pausedOffset: 40) == 0)
    }

    // Never negative: a layer whose beginTime is in the future is a layer
    // that renders nothing at all until that time arrives, which is a blank
    // menu bar for however far the clock went backwards.
    @Test("a clock that went backwards cannot push the begin time into the future")
    func resumingNeverGoesNegative() {
        #expect(StripRenderer.resumedBeginTime(nowInLayerTime: 10, pausedOffset: 40) == 0)
    }
}
```

Note: this suite is not marked `@MainActor` and must not be — every function it tests is a pure static on `StripRenderer`. `TickerView` is main-actor work and is exercised by hand in Step 6, not here; a test that stands up an `NSView` to check that Core Animation moved a layer is testing Core Animation.

- [ ] **Step 2: Run the tests and watch them fail**

```bash
swift test --build-system native --filter StripRendererTests
```

Expected: compile failure — `cannot find 'StripRenderer' in scope`.

- [ ] **Step 3: Write the renderer**

`Sources/Squiggle/StripRenderer.swift`:

```swift
import AppKit
import QuartzCore

/// Turns a `StripLayout` into layers, and owns the arithmetic behind the one
/// animation the app runs.
///
/// Split into pure statics and layer-building because the arithmetic is the
/// part that can be wrong in a way a test can see. Whether Core Animation
/// draws a `CATextLayer` where it was told to is not this project's problem;
/// whether a 480pt strip at 24pt/s takes 20 seconds to cross is.
enum StripRenderer {
    /// Capped at 30 fps by spec §5.1. The minimum is deliberately far below
    /// it: on a ProMotion display an unconstrained range lets Core Animation
    /// choose 120, and the floor lets it choose *less* than 30 when the
    /// system is busy, which for scrolling text nobody is reading is a
    /// trade the app should take every time.
    static let frameRate = CAFrameRateRange(minimum: 8, maximum: 30, preferred: 30)

    struct Metrics {
        let rowCount: Int
        let font: NSFont
        let rowHeight: Double
    }

    /// R135: monospaced digits, so a price changing from `178.11` to `178.88`
    /// does not shift everything to its right.
    static func metrics(rows: Int, barHeight: Double) -> Metrics {
        // The same 1...2 clamp `RowSplitter.split` applies. Duplicated rather
        // than shared because `RowSplitter` lives in TickerCore and takes no
        // interest in fonts; `StripRendererTests` asserts the two agree.
        let rowCount = max(1, min(rows, 2))
        let size: CGFloat = rowCount == 1 ? 13 : 10
        return Metrics(
            rowCount: rowCount,
            font: .monospacedDigitSystemFont(ofSize: size, weight: .regular),
            rowHeight: barHeight / Double(rowCount))
    }

    /// How long one full lap takes. Floored on both terms: Core Animation
    /// accepts a zero or infinite duration and renders a frozen strip, which
    /// spec §5.2 says explicitly must never happen — "a frozen bar reads as a
    /// crash".
    static func duration(contentWidth: Double, pointsPerSecond: Double) -> Double {
        let speed = max(1, pointsPerSecond)
        let width = max(1, contentWidth)
        return width / speed
    }

    /// Spec §5.2's first stopping condition. Equal widths fit: a strip exactly
    /// as wide as its window has nothing left to reveal.
    static func fits(contentWidth: Double, visibleWidth: Double) -> Bool {
        contentWidth <= visibleWidth
    }

    /// The resume half of the `speed = 0` / `timeOffset` recipe. Pushing the
    /// layer's begin time forward by the paused interval is what makes resume
    /// seamless — the animation carries on from where it stopped rather than
    /// snapping back to its origin.
    ///
    /// Clamped at zero. A begin time in the future means the layer renders
    /// nothing until that time arrives, and the only way to get one is a
    /// backwards jump in the media clock, which is not worth a blank menu bar.
    static func resumedBeginTime(nowInLayerTime: Double, pausedOffset: Double) -> Double {
        max(0, nowInLayerTime - pausedOffset)
    }

    /// One row's text, laid out twice end to end. The second copy is what
    /// makes the wrap seamless: by the time the first copy has scrolled fully
    /// out to the left, the second is exactly where the first began, so the
    /// animation can snap back to zero with nothing visibly changing.
    ///
    /// `Row.contentWidth` already includes the trailing gap (Task 5), which
    /// is what keeps the join from butting the last symbol against the first.
    static func rowLayer(_ row: StripLayout.Row,
                         metrics: Metrics,
                         scale: Double,
                         color: (ColorRole) -> CGColor) -> CALayer {
        let container = CALayer()
        container.contentsScale = scale
        container.bounds = CGRect(x: 0, y: 0,
                                  width: row.contentWidth * 2,
                                  height: metrics.rowHeight)
        container.anchorPoint = CGPoint(x: 0, y: 0)

        // Text sits on the baseline, not at the top of its box, so the
        // vertical centring is done against the font's own ascent and descent
        // rather than against the layer height.
        let textHeight = Double(metrics.font.ascender - metrics.font.descender)
        let y = (metrics.rowHeight - textHeight) / 2

        for copy in 0..<2 {
            let shift = Double(copy) * row.contentWidth
            for segment in row.segments {
                let text = CATextLayer()
                text.contentsScale = scale
                text.string = segment.text
                text.font = metrics.font
                text.fontSize = metrics.font.pointSize
                text.foregroundColor = color(segment.role)
                text.alignmentMode = .left
                // A ticker never wraps and never ellipsises: the strip is as
                // wide as it needs to be and the window is what clips it.
                text.isWrapped = false
                text.truncationMode = .none
                text.frame = CGRect(x: segment.x + shift, y: y,
                                    width: segment.width, height: textHeight)
                container.addSublayer(text)
            }
        }
        return container
    }
}
```

- [ ] **Step 4: Run the tests and watch them pass**

```bash
swift test --build-system native --filter StripRendererTests
```

Expected: 10 tests, 0 failures.

- [ ] **Step 5: Write the view that hosts it**

`Sources/Squiggle/TickerView.swift`:

```swift
import AppKit
import QuartzCore

/// The view the status item button hosts. It owns the row layers and the one
/// animation, and nothing else: no timers, no data, no opinions about when to
/// stop — Task 10 decides that and calls `pause()`.
@MainActor
final class TickerView: NSView {
    private var rowLayers: [CALayer] = []
    private(set) var isPaused = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The strip is wider than the window by design; this is what turns
        // that from a bug into a marquee.
        layer?.masksToBounds = true
        // Rows are numbered top-down by `RowSplitter`, and flipping the
        // container's geometry is what makes row 0 draw at the top instead of
        // needing every y computed backwards from the height.
        layer?.isGeometryFlipped = true
    }

    // `NSView` declares this required; nothing in Squiggle loads a nib, so
    // reaching it means something is very wrong rather than something needs
    // handling.
    required init?(coder: NSCoder) {
        fatalError("Squiggle builds its views in code")
    }

    /// Replaces the strip wholesale. Called on every successful refresh and on
    /// every settings change, which at one refresh every few minutes is rare
    /// enough that rebuilding beats diffing.
    func apply(layout: StripLayout,
               metrics: StripRenderer.Metrics,
               visibleWidth: Double,
               pointsPerSecond: Double,
               color: (ColorRole) -> CGColor) {
        guard let host = layer else { return }
        // Backing scale, so text is drawn for this display rather than at 1x
        // and stretched. `window` is nil before the view is installed; 2 is
        // the right guess on every Mac sold since 2012, and the next `apply`
        // after installation corrects it either way.
        let scale = Double(window?.backingScaleFactor ?? 2)

        for existing in rowLayers { existing.removeFromSuperlayer() }
        rowLayers = []
        isPaused = false

        for (index, row) in layout.rows.enumerated() {
            let rowLayer = StripRenderer.rowLayer(row, metrics: metrics,
                                                  scale: scale, color: color)
            rowLayer.position = CGPoint(x: 0, y: Double(index) * metrics.rowHeight)
            host.addSublayer(rowLayer)
            rowLayers.append(rowLayer)

            // Spec §5.2: content that already fits gets no animation at all —
            // removed, not paused, not slowed. Each row is judged on its own
            // width, so a short row stays still while a long one scrolls.
            guard StripRenderer.fits(contentWidth: row.contentWidth,
                                     visibleWidth: visibleWidth) == false
            else { continue }

            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = 0
            slide.toValue = -row.contentWidth
            slide.duration = StripRenderer.duration(contentWidth: row.contentWidth,
                                                    pointsPerSecond: pointsPerSecond)
            slide.repeatCount = .infinity
            // Linear, and it has to be: the default ease-in-out would make the
            // strip visibly accelerate and brake once per lap.
            slide.timingFunction = CAMediaTimingFunction(name: .linear)
            slide.preferredFrameRateRange = StripRenderer.frameRate
            rowLayer.add(slide, forKey: "scroll")
        }
    }

    /// Spec §5.2: `speed = 0` with the offset captured, never a removal.
    func pause() {
        guard isPaused == false else { return }
        isPaused = true
        for rowLayer in rowLayers {
            let stoppedAt = rowLayer.convertTime(CACurrentMediaTime(), from: nil)
            rowLayer.speed = 0
            rowLayer.timeOffset = stoppedAt
        }
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        for rowLayer in rowLayers {
            let pausedOffset = rowLayer.timeOffset
            rowLayer.speed = 1
            rowLayer.timeOffset = 0
            rowLayer.beginTime = 0
            let now = rowLayer.convertTime(CACurrentMediaTime(), from: nil)
            rowLayer.beginTime = StripRenderer.resumedBeginTime(nowInLayerTime: now,
                                                                pausedOffset: pausedOffset)
        }
    }
}
```

- [ ] **Step 6: Hand the status item its view**

In `Sources/Squiggle/StatusItemController.swift`, add a stored property beside the status item:

```swift
    private let tickerView = TickerView()
```

In `start()`, after the status item and its button exist, install the view. Add this immediately after the line that configures the button, and delete the `button.attributedTitle` assignment Task 6 put in `render()` — from here on the button draws nothing of its own:

```swift
        guard let button = statusItem.button else { return }
        // The button keeps its click handling (the dropdown, Task 11); the
        // view only draws. Replacing the button with a custom view would give
        // up the highlight and the menu behaviour, which is a poor trade for
        // one subview.
        //
        // `init` already cleared `title`; this clears the attributed one Task
        // 6's `render()` was setting, because an empty view over a stale
        // title shows the title.
        button.attributedTitle = NSAttributedString(string: "")
        tickerView.frame = button.bounds
        tickerView.autoresizingMask = [.width, .height]
        button.addSubview(tickerView)
```

Replace the body of `render()` with:

```swift
    private func render() {
        let metrics = StripRenderer.metrics(rows: settings.rows,
                                            barHeight: Double(NSStatusBar.system.thickness))
        // R131: the closure binds the font, so `StripLayout` never sees one.
        let font = metrics.font
        let measure: (String) -> Double = { text in
            Double((text as NSString).size(withAttributes: [.font: font]).width)
        }
        let layout = StripLayout.build(symbols: runner.symbols,
                                       quotes: runner.quotes,
                                       dead: runner.deadSymbols,
                                       rows: metrics.rowCount,
                                       gap: 20,
                                       measure: measure)
        // Spec §5.1: a *fixed*-width status item. Task 6 created it
        // `variableLength` because a button sized to its title was the honest
        // thing while a title was what it drew; a marquee needs a window that
        // does not resize itself to the content it is meant to clip.
        statusItem.length = settings.maxVisibleWidth
        // R136: Monochrome is the default scheme, so this is the app's real
        // default appearance rather than a placeholder. Task 12 replaces the
        // closure, not the call.
        tickerView.apply(layout: layout,
                         metrics: metrics,
                         visibleWidth: settings.maxVisibleWidth,
                         pointsPerSecond: settings.scrollPointsPerSecond,
                         color: { _ in NSColor.labelColor.cgColor })
    }
```

- [ ] **Step 7: Build and look at it**

```bash
scripts/package-app.sh && open build/Squiggle.app
```

Expected: two rows of prices in the menu bar, scrolling left at a steady pace, wrapping with no gap larger than the one between symbols and no jump at the seam. With only two symbols in the store the strip should fit and sit perfectly still.

```bash
pkill -x Squiggle
```

If the seam jumps, the fault is `Row.contentWidth` not including its trailing gap — check Task 5's `build`, not this task.

- [ ] **Step 8: Run the whole suite and commit**

```bash
swift test --build-system native
```

```bash
git add Sources/Squiggle/StripRenderer.swift Sources/Squiggle/TickerView.swift Sources/Squiggle/StatusItemController.swift Tests/SquiggleTests/StripRendererTests.swift
git commit -m "feat: scroll the strip with one capped Core Animation lap"
```

---

## Task 9: Step mode, and the accessibility setting that forces it

Two rows needs nothing new: Task 8's `render()` already reads `settings.rows`, `metrics(rows:)` sizes the font from it, `StripLayout.build` deals the watchlist across it, and `TickerView.apply` iterates however many rows it is given. Step 4 below is a verification that this is true rather than an implementation.

What is left is spec §5.1's second motion mode, and the sentence under it: *"Step is forced when Reduce Motion is enabled. Marquees are a vestibular trigger; this is an accessibility requirement, not a preference."* Forced, not defaulted — the Settings control (Task 13) shows Step selected and disabled while the system setting is on, and the user's stored choice is left untouched so it comes back when they turn Reduce Motion off.

**Files:**
- Create: `Sources/Squiggle/MotionPolicy.swift`
- Modify: `Sources/Squiggle/TickerView.swift`
- Modify: `Sources/Squiggle/StatusItemController.swift`
- Test: `Tests/SquiggleTests/MotionPolicyTests.swift`

**Interfaces:**
- Consumes: `TickerView.apply(layout:metrics:visibleWidth:pointsPerSecond:color:)` (Task 8), `Settings.motionMode` (Task 1, R120).
- Produces:
  - `enum MotionMode: String { case scroll, step }`
  - `MotionMode.init(setting: String)` — unknown strings become `.scroll`
  - `MotionPolicy.stepSeconds: Double`, `MotionPolicy.fadeSeconds: Double`
  - `MotionPolicy.effective(requested: MotionMode, reduceMotion: Bool) -> MotionMode`
  - `MotionPolicy.pageOffsets(contentWidth: Double, visibleWidth: Double) -> [Double]`
  - `MotionPolicy.pageKeyTimes(pageCount: Int) -> [Double]`
  - `MotionPolicy.fadeKeyframes(pageCount: Int) -> (values: [Double], keyTimes: [Double])`
  - `TickerView.apply` gains a `mode: MotionMode` parameter, placed after `visibleWidth:`

### R137 — Step is a dip through transparent on one layer, not a two-layer cross-fade

Spec §5.1 says "cross-fade". A literal cross-fade needs both pages on screen at once — two full copies of the row, each with its own text layers, one fading up as the other fades down. That doubles the layer count and the text rasterisation for a transition that lasts 0.35s out of every 4s and that nobody is watching closely enough to distinguish from a dip.

So: one layer, its position stepped **discretely** at the page boundary, its opacity dipping to zero across that boundary. The switch happens while the layer is invisible, which is the property that matters — the eye never sees text slide or jump.

The spec's stated reason for Step survives intact. "One composite per 4s rather than 30 per second" is about average cost, and a 0.35s fade at 30 fps is about eleven frames per four seconds — under three a second, against 120 for the scroll.

- [ ] **Step 1: Write the failing tests**

`Tests/SquiggleTests/MotionPolicyTests.swift`:

```swift
import Testing
@testable import Squiggle

@Suite("Motion policy")
struct MotionPolicyTests {
    @Test("the stored setting decodes to a mode, and nonsense becomes scroll")
    func modesDecodeFromSettings() {
        #expect(MotionMode(setting: "scroll") == .scroll)
        #expect(MotionMode(setting: "step") == .step)
        // R120's vocabulary is two words. Anything else is a file that was
        // hand-edited or written by a future version, and the default is the
        // safe answer in both cases.
        #expect(MotionMode(setting: "Step") == .scroll)
        #expect(MotionMode(setting: "") == .scroll)
        #expect(MotionMode(setting: "marquee") == .scroll)
    }

    @Test("without Reduce Motion the user gets what they asked for")
    func reduceMotionOffHonoursTheSetting() {
        #expect(MotionPolicy.effective(requested: .scroll, reduceMotion: false) == .scroll)
        #expect(MotionPolicy.effective(requested: .step, reduceMotion: false) == .step)
    }

    // Spec §5.1: forced, not defaulted. The stored setting is not consulted.
    @Test("Reduce Motion forces step whatever the setting says")
    func reduceMotionForcesStep() {
        #expect(MotionPolicy.effective(requested: .scroll, reduceMotion: true) == .step)
        #expect(MotionPolicy.effective(requested: .step, reduceMotion: true) == .step)
    }

    @Test("a strip that fits is one page and does not step")
    func contentThatFitsIsOnePage() {
        let offsets = MotionPolicy.pageOffsets(contentWidth: 150, visibleWidth: 260)
        #expect(offsets == [0])
    }

    @Test("pages are whole windows, and a remainder still gets its own page")
    func pagesAreWholeWindows() {
        #expect(MotionPolicy.pageOffsets(contentWidth: 520, visibleWidth: 260) == [0, -260])
        #expect(MotionPolicy.pageOffsets(contentWidth: 521, visibleWidth: 260) == [0, -260, -520])
    }

    // A zero width reaches here only from a settings file someone edited, but
    // `520 / 0` is `.infinity` and `Int(.infinity)` traps, so the guard is
    // cheaper than the crash report.
    @Test("a zero or negative window is one page, not a trap")
    func aZeroWindowIsOnePage() {
        #expect(MotionPolicy.pageOffsets(contentWidth: 520, visibleWidth: 0) == [0])
        #expect(MotionPolicy.pageOffsets(contentWidth: 520, visibleWidth: -260) == [0])
    }

    // Core Animation's contract for `.discrete` is not the same as for the
    // interpolating modes: a discrete keyframe animation wants ONE MORE key
    // time than it has values, because each value occupies the span between
    // consecutive times rather than sitting on one. Getting this wrong does
    // not raise — the animation silently plays at the wrong pace.
    @Test("discrete page key times bracket every page, one more than there are pages")
    func pageKeyTimesBracketEachPage() {
        #expect(MotionPolicy.pageKeyTimes(pageCount: 1) == [0, 1])
        #expect(MotionPolicy.pageKeyTimes(pageCount: 2) == [0, 0.5, 1])
        #expect(MotionPolicy.pageKeyTimes(pageCount: 4) == [0, 0.25, 0.5, 0.75, 1])
    }

    @Test("page key times match the offsets they bracket")
    func pageKeyTimesMatchTheOffsets() {
        let offsets = MotionPolicy.pageOffsets(contentWidth: 800, visibleWidth: 260)
        let times = MotionPolicy.pageKeyTimes(pageCount: offsets.count)
        #expect(times.count == offsets.count + 1)
    }

    @Test("the fade has one dip per page and returns to where it started")
    func fadeHasOneDipPerPage() {
        let frames = MotionPolicy.fadeKeyframes(pageCount: 3)
        #expect(frames.values.count == frames.keyTimes.count)
        // Three per page — invisible at the switch, up, held — plus the final
        // dip that the repeat wraps onto the first.
        #expect(frames.values.count == 10)
        #expect(frames.values.first == 0)
        #expect(frames.values.last == 0)
        #expect(frames.keyTimes.first == 0)
        #expect(frames.keyTimes.last == 1)
    }

    // Core Animation requires key times to be non-decreasing and in 0...1. It
    // does not check; it silently renders something else.
    @Test("key times strictly increase across the whole timeline")
    func keyTimesStrictlyIncrease() {
        for pages in 1...12 {
            let frames = MotionPolicy.fadeKeyframes(pageCount: pages)
            let ascending = zip(frames.keyTimes, frames.keyTimes.dropFirst())
            let isSorted = ascending.allSatisfy { $0 < $1 }
            #expect(isSorted, "pageCount \(pages)")
            let inRange = frames.keyTimes.allSatisfy { $0 >= 0 && $0 <= 1 }
            #expect(inRange, "pageCount \(pages)")
            let opacities = frames.values.allSatisfy { $0 >= 0 && $0 <= 1 }
            #expect(opacities, "pageCount \(pages)")
        }
    }

    @Test("a single page still produces a well-formed timeline")
    func onePageIsWellFormed() {
        let frames = MotionPolicy.fadeKeyframes(pageCount: 1)
        #expect(frames.values.count == 4)
        #expect(frames.keyTimes.last == 1)
    }

    // Nothing calls it with zero, but `0` pages divides by zero building the
    // key times, and a NaN key time is a layer that never appears.
    @Test("zero or negative pages are treated as one")
    func zeroPagesIsOnePage() {
        let frames = MotionPolicy.fadeKeyframes(pageCount: 0)
        let finite = frames.keyTimes.allSatisfy { $0.isFinite }
        #expect(finite)
        #expect(frames.keyTimes.last == 1)
    }
}
```

The three `allSatisfy` calls are hoisted into locals before the `#expect`, matching the rest of the suite: this codebase does not put trailing closures inside the macro, because the expansion misreports which sub-expression failed.

- [ ] **Step 2: Run the tests and watch them fail**

```bash
swift test --build-system native --filter MotionPolicyTests
```

Expected: compile failure — `cannot find 'MotionMode' in scope`.

- [ ] **Step 3: Write the policy**

`Sources/Squiggle/MotionPolicy.swift`:

```swift
import Foundation

/// How the strip moves. The raw values are R120's stored vocabulary, so the
/// settings file and this type cannot drift apart.
enum MotionMode: String, Equatable, Sendable {
    case scroll
    case step

    /// Decodes a stored setting. Anything outside the vocabulary becomes the
    /// default rather than failing: the file is the user's, it is editable by
    /// hand, and a ticker that refuses to start because a word is misspelled
    /// is worse than one that scrolls when it was asked to step.
    init(setting: String) {
        self = MotionMode(rawValue: setting) ?? .scroll
    }
}

enum MotionPolicy {
    /// Spec §5.1: one page every four seconds.
    static let stepSeconds: Double = 4
    /// R137: how long the dip through transparent takes, split either side of
    /// the page switch.
    static let fadeSeconds: Double = 0.35

    /// Spec §5.1: "Step is *forced* when Reduce Motion is enabled."
    ///
    /// The stored setting is not consulted and not changed. Turning the
    /// system setting off restores whatever the user had chosen, because
    /// their choice was never overwritten — only overruled.
    static func effective(requested: MotionMode, reduceMotion: Bool) -> MotionMode {
        reduceMotion ? .step : requested
    }

    /// The x positions the row layer steps through, one per page, starting at
    /// zero. A strip that fits its window is a single page and therefore does
    /// not move at all — the same rule scroll mode follows.
    static func pageOffsets(contentWidth: Double, visibleWidth: Double) -> [Double] {
        guard visibleWidth > 0 else { return [0] }
        let pages = max(1, Int((contentWidth / visibleWidth).rounded(.up)))
        return (0..<pages).map { -Double($0) * visibleWidth }
    }

    /// Key times for the discrete position animation: `pageCount + 1` of
    /// them, evenly spaced from 0 to 1.
    ///
    /// One more than there are values, because that is what Core Animation's
    /// `.discrete` calculation mode asks for — each value holds for the span
    /// between consecutive times, so N values need N+1 boundaries. The
    /// interpolating modes want an equal count, which is the mistake this
    /// function exists to stop someone making at the call site.
    static func pageKeyTimes(pageCount: Int) -> [Double] {
        let pages = max(1, pageCount)
        return (0...pages).map { Double($0) / Double(pages) }
    }

    /// The opacity timeline for one full cycle of `pageCount` pages.
    ///
    /// Each page contributes three frames — invisible at the moment the
    /// position switches, fully up a fraction later, held until just before
    /// the next switch — and one final zero closes the loop, so the repeat
    /// wraps onto a matching value instead of snapping from 1 to 0.
    ///
    /// Key times are fractions of the whole timeline, which is why the fade's
    /// share shrinks as pages are added: the fade is a fixed number of
    /// seconds, and the timeline it is a fraction of grows with the page
    /// count.
    static func fadeKeyframes(pageCount: Int) -> (values: [Double], keyTimes: [Double]) {
        let pages = max(1, pageCount)
        let total = stepSeconds * Double(pages)
        let half = (fadeSeconds / 2) / total

        var values: [Double] = []
        var keyTimes: [Double] = []
        for page in 0..<pages {
            let start = Double(page) / Double(pages)
            let end = Double(page + 1) / Double(pages)
            values.append(contentsOf: [0, 1, 1])
            keyTimes.append(contentsOf: [start, start + half, end - half])
        }
        values.append(0)
        keyTimes.append(1)
        return (values, keyTimes)
    }
}
```

- [ ] **Step 4: Run the tests and watch them pass**

```bash
swift test --build-system native --filter MotionPolicyTests
```

Expected: 12 tests, 0 failures.

- [ ] **Step 5: Teach the view to step**

In `Sources/Squiggle/TickerView.swift`, change `apply`'s signature to take the mode, and split the per-row animation. Replace the whole `for (index, row) in layout.rows.enumerated()` loop body's animation half — everything from `guard StripRenderer.fits(` to `rowLayer.add(slide, forKey: "scroll")` — with a call to a new private method, and add that method:

```swift
    func apply(layout: StripLayout,
               metrics: StripRenderer.Metrics,
               visibleWidth: Double,
               mode: MotionMode,
               pointsPerSecond: Double,
               color: (ColorRole) -> CGColor) {
```

```swift
            animate(rowLayer, row: row, visibleWidth: visibleWidth,
                    mode: mode, pointsPerSecond: pointsPerSecond)
```

```swift
    /// Spec §5.2's first stopping condition is checked here and in one place
    /// only, because it is the same rule in both modes: content that already
    /// fits gets no animation at all — removed, not paused, not slowed.
    private func animate(_ rowLayer: CALayer,
                         row: StripLayout.Row,
                         visibleWidth: Double,
                         mode: MotionMode,
                         pointsPerSecond: Double) {
        guard StripRenderer.fits(contentWidth: row.contentWidth,
                                 visibleWidth: visibleWidth) == false
        else { return }

        switch mode {
        case .scroll:
            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = 0
            slide.toValue = -row.contentWidth
            slide.duration = StripRenderer.duration(contentWidth: row.contentWidth,
                                                    pointsPerSecond: pointsPerSecond)
            slide.repeatCount = .infinity
            // Linear, and it has to be: the default ease-in-out would make the
            // strip visibly accelerate and brake once per lap.
            slide.timingFunction = CAMediaTimingFunction(name: .linear)
            slide.preferredFrameRateRange = StripRenderer.frameRate
            rowLayer.add(slide, forKey: "scroll")

        case .step:
            let offsets = MotionPolicy.pageOffsets(contentWidth: row.contentWidth,
                                                   visibleWidth: visibleWidth)
            let total = MotionPolicy.stepSeconds * Double(offsets.count)

            // Discrete, so the position never interpolates: the layer is at
            // page N and then it is at page N+1, with nothing in between for
            // the eye to track. That is the whole point of Step.
            let move = CAKeyframeAnimation(keyPath: "position.x")
            move.values = offsets
            move.keyTimes = MotionPolicy.pageKeyTimes(pageCount: offsets.count)
                .map { NSNumber(value: $0) }
            move.calculationMode = .discrete
            move.duration = total
            move.repeatCount = .infinity

            let frames = MotionPolicy.fadeKeyframes(pageCount: offsets.count)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = frames.values
            fade.keyTimes = frames.keyTimes.map { NSNumber(value: $0) }
            fade.duration = total
            fade.repeatCount = .infinity

            // Both under one group so `pause()` stops them together. Two
            // independent animations paused a frame apart would leave the
            // text half-faded on a page it had already left.
            //
            // The frame rate cap goes on the group and not on its children:
            // the group is what Core Animation schedules, and a range set on
            // a grouped child is not documented to be honoured.
            let both = CAAnimationGroup()
            both.animations = [move, fade]
            both.duration = total
            both.repeatCount = .infinity
            both.preferredFrameRateRange = StripRenderer.frameRate
            rowLayer.add(both, forKey: "step")
        }
    }
```

`pause()` and `resume()` need no change: they act on `rowLayer.speed` and `timeOffset`, which govern whatever animations the layer is running.

- [ ] **Step 6: Have the controller choose the mode, and react when the system changes it**

In `Sources/Squiggle/StatusItemController.swift`, inside `render()`, replace the `tickerView.apply(...)` call with:

```swift
        let requested = MotionMode(setting: settings.motionMode)
        let mode = MotionPolicy.effective(
            requested: requested,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        tickerView.apply(layout: layout,
                         metrics: metrics,
                         visibleWidth: settings.maxVisibleWidth,
                         mode: mode,
                         pointsPerSecond: settings.scrollPointsPerSecond,
                         color: { _ in NSColor.labelColor.cgColor })
```

And in `start()`, before `render()`, subscribe so a change to the system setting takes effect without a relaunch:

```swift
        // Reduce Motion can be toggled while Squiggle is running, and a user
        // who turns it on because a marquee is making them ill should not have
        // to quit the app to be rid of it.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.render() }
            }
```

`MainActor.assumeIsolated` and not a `Task`: the notification is already delivered on the main queue by `queue: .main`, and hopping through a `Task` would re-render one runloop turn later for no reason. Task 12 adds `differentiateWithoutColor` to the same handler — it is the same notification.

- [ ] **Step 7: Look at all four combinations**

```bash
scripts/package-app.sh && open build/Squiggle.app
```

Put enough symbols in the store that the strip overflows, then check, in order:

1. Default — two rows, both scrolling.
2. Set `"rows": 1` in `~/Library/Application Support/Squiggle/squiggle.json` and relaunch: one row, larger text, the whole watchlist in one strip.
3. Set `"motionMode": "step"` and relaunch: the strip holds still for four seconds, dips out, reappears one window further along.
4. Turn on System Settings › Accessibility › Display › Reduce Motion **while the app is running**, with `"motionMode": "scroll"`: the strip switches to stepping within a second, without a relaunch. Turn it off: it goes back to scrolling.

```bash
pkill -x Squiggle
```

- [ ] **Step 8: Run the whole suite and commit**

```bash
swift test --build-system native
```

```bash
git add Sources/Squiggle/MotionPolicy.swift Sources/Squiggle/TickerView.swift Sources/Squiggle/StatusItemController.swift Tests/SquiggleTests/MotionPolicyTests.swift
git commit -m "feat: add step motion, forced by Reduce Motion"
```

---

## Task 10: When the strip stops

Spec §5.2's remaining stopping conditions — the ones that are facts about the system rather than about the strip:

- `statusItem.button?.window?.occlusionState` is not `.visible`, which is one hook covering the notch, Bartender and Ice, full-screen apps, and Spaces;
- the screen is locked, the screensaver is running, or the display sleeps.

R134 settles how they arrive: notifications, not polling. `DistributedNotificationCenter` for lock and unlock, `NSWorkspace.shared.notificationCenter` for sleep and wake, and `NSWindow.didChangeOcclusionStateNotification` for occlusion. No timer asks "is the screen locked yet?" — which matters, because a timer that wakes the CPU to discover nothing has changed is precisely the cost this app was built to avoid.

These conditions do two jobs, and it is worth being explicit that they are the same condition doing both. They pause the animation, and they also report `Visibility.occluded` to `RefreshPolicy`, which stops fetching and waits one cycle. A locked Mac neither moves the strip nor spends requests on it, and the strip is current the moment it reappears because `.occluded` waits a cycle rather than sleeping indefinitely.

**Files:**
- Create: `Sources/Squiggle/PauseConditions.swift`
- Create: `Sources/Squiggle/PauseMonitor.swift`
- Modify: `Sources/Squiggle/StatusItemController.swift`
- Test: `Tests/SquiggleTests/PauseConditionsTests.swift`

**Interfaces:**
- Consumes: `Visibility` (TickerCore), `TickerView.pause()` / `.resume()` (Task 8), `StatusItemController.visibility()` (Task 6, replaced here).
- Produces:
  - `enum PauseEvent` with `init?(distributedName: String)` and `init?(workspaceName: Notification.Name)`
  - `struct PauseConditions` with `mutating func apply(_ event: PauseEvent)`, `var isPaused: Bool`, `var visibility: Visibility`
  - `@MainActor final class PauseMonitor` with `init(onChange: @MainActor @escaping (PauseConditions) -> Void)`, `func start(observing window: NSWindow?)`, `func stop()`, `var conditions: PauseConditions`

### R138 — the notification names are pinned by a test, because nothing else can pin them

`com.apple.screenIsLocked` is a string. Misspell it and `DistributedNotificationCenter` accepts the registration, delivers nothing, and the app runs its marquee on a locked Mac forever with no error anywhere. There is no compiler and no runtime check between the literal and the behaviour.

So the mapping from name to event is a pure function with its own test asserting every literal, and the observers register against `PauseEvent`'s own list rather than against strings written a second time at the call site. That does not make a typo impossible — it makes it a single typo, in a line a test reads.

- [ ] **Step 1: Write the failing tests**

`Tests/SquiggleTests/PauseConditionsTests.swift`:

```swift
import AppKit
import TickerCore
import Testing
@testable import Squiggle

@Suite("Pause conditions")
struct PauseConditionsTests {
    // R138: these five literals are the whole interface to the system, and
    // nothing but this test stands between a typo and a marquee that runs on
    // a locked Mac forever.
    @Test("the distributed notification names map to the events they name")
    func distributedNamesAreExact() {
        #expect(PauseEvent(distributedName: "com.apple.screenIsLocked") == .screenLocked)
        #expect(PauseEvent(distributedName: "com.apple.screenIsUnlocked") == .screenUnlocked)
        #expect(PauseEvent(distributedName: "com.apple.screensaver.didstart") == .screensaverStarted)
        #expect(PauseEvent(distributedName: "com.apple.screensaver.didstop") == .screensaverStopped)
        #expect(PauseEvent(distributedName: "com.apple.somethingElse") == nil)
    }

    @Test("the workspace notification names map to the events they name")
    func workspaceNamesAreExact() {
        #expect(PauseEvent(workspaceName: NSWorkspace.screensDidSleepNotification) == .displaysSlept)
        #expect(PauseEvent(workspaceName: NSWorkspace.screensDidWakeNotification) == .displaysWoke)
        #expect(PauseEvent(workspaceName: NSWorkspace.willSleepNotification) == .systemWillSleep)
        #expect(PauseEvent(workspaceName: NSWorkspace.didWakeNotification) == .systemDidWake)
        #expect(PauseEvent(workspaceName: NSWorkspace.didLaunchApplicationNotification) == nil)
    }

    // Every name the monitor registers has to be one the reducer recognises,
    // or the registration is dead weight.
    @Test("every observed name resolves to an event")
    func everyObservedNameResolves() {
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
    @Test("a fresh set of conditions is not paused")
    func nothingIsPausedAtLaunch() {
        let fresh = PauseConditions()
        #expect(!fresh.isPaused)
        #expect(fresh.visibility == .visible)
    }

    @Test("each condition alone is enough to pause")
    func eachConditionPausesOnItsOwn() {
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

    @Test("each condition's own end event clears it")
    func eachConditionClears() {
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
            #expect(conditions.isPaused == false, "\(start) then \(end)")
        }
    }

    // Waking the machine does not unlock it, and this is the bug the pairs
    // above would not catch: a wake that cleared everything would start the
    // marquee running behind the login window.
    @Test("waking the machine leaves the lock in place")
    func wakingDoesNotUnlock() {
        var conditions = PauseConditions()
        conditions.apply(.screenLocked)
        conditions.apply(.systemWillSleep)
        conditions.apply(.systemDidWake)
        conditions.apply(.displaysWoke)
        #expect(conditions.isPaused)
        conditions.apply(.screenUnlocked)
        #expect(!conditions.isPaused)
    }

    @Test("clearing one condition while another holds stays paused")
    func oneOfTwoClearingStaysPaused() {
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
    @Test("a repeated event is not a second lock to undo")
    func repeatedEventsAreIdempotent() {
        var conditions = PauseConditions()
        conditions.apply(.screenLocked)
        conditions.apply(.screenLocked)
        conditions.apply(.screenUnlocked)
        #expect(!conditions.isPaused)
    }
}
```

- [ ] **Step 2: Run the tests and watch them fail**

```bash
swift test --build-system native --filter PauseConditionsTests
```

Expected: compile failure — `cannot find 'PauseEvent' in scope`.

- [ ] **Step 3: Write the conditions**

`Sources/Squiggle/PauseConditions.swift`:

```swift
import AppKit
import TickerCore

/// Something the system told us that changes whether the strip should move.
///
/// A named event rather than a raw `Notification`, so the rule ("a locked
/// screen pauses") is testable without standing up a notification centre, and
/// so the five magic strings live in exactly one place (R138).
enum PauseEvent: Equatable, Sendable {
    case screenLocked
    case screenUnlocked
    case screensaverStarted
    case screensaverStopped
    case displaysSlept
    case displaysWoke
    case systemWillSleep
    case systemDidWake
    case occlusionChanged(isVisible: Bool)

    /// Lock and screensaver arrive on the *distributed* centre — they are
    /// broadcast by loginwindow to every process on the machine, not by our
    /// own `NSWorkspace`. This is also why the app must stay un-sandboxed:
    /// a sandboxed process registers successfully and receives nothing.
    ///
    /// These four names are undocumented but have been stable since 10.6.
    /// Being undocumented is exactly why the test asserts them character by
    /// character: nothing else will notice the day one of them changes.
    static let observedDistributedNames = [
        "com.apple.screenIsLocked",
        "com.apple.screenIsUnlocked",
        "com.apple.screensaver.didstart",
        "com.apple.screensaver.didstop",
    ]

    static let observedWorkspaceNames: [Notification.Name] = [
        NSWorkspace.screensDidSleepNotification,
        NSWorkspace.screensDidWakeNotification,
        NSWorkspace.willSleepNotification,
        NSWorkspace.didWakeNotification,
    ]

    init?(distributedName: String) {
        switch distributedName {
        case "com.apple.screenIsLocked": self = .screenLocked
        case "com.apple.screenIsUnlocked": self = .screenUnlocked
        case "com.apple.screensaver.didstart": self = .screensaverStarted
        case "com.apple.screensaver.didstop": self = .screensaverStopped
        default: return nil
        }
    }

    init?(workspaceName: Notification.Name) {
        switch workspaceName {
        case NSWorkspace.screensDidSleepNotification: self = .displaysSlept
        case NSWorkspace.screensDidWakeNotification: self = .displaysWoke
        case NSWorkspace.willSleepNotification: self = .systemWillSleep
        case NSWorkspace.didWakeNotification: self = .systemDidWake
        default: return nil
        }
    }
}

/// Which of spec §5.2's reasons to stop are currently true.
///
/// Flags, not a count. macOS sends `screenIsLocked` more than once in some
/// flows — locking and then letting the screensaver engage on top — and a
/// counter would come out of an unlock still positive, leaving the app
/// permanently paused with no way back short of a relaunch.
///
/// Everything starts false: at launch the app has been told nothing, and
/// assuming the strip is visible costs requests where the opposite assumption
/// would cost a user their prices.
struct PauseConditions: Equatable, Sendable {
    private(set) var screenIsLocked = false
    private(set) var screensaverIsRunning = false
    private(set) var displaysAreAsleep = false
    private(set) var systemIsAsleep = false
    private(set) var statusItemIsOccluded = false

    mutating func apply(_ event: PauseEvent) {
        // No `default:`. A tenth event has to be handled here rather than
        // silently doing nothing, which is the failure mode this whole type
        // exists to make impossible.
        switch event {
        case .screenLocked: screenIsLocked = true
        case .screenUnlocked: screenIsLocked = false
        case .screensaverStarted: screensaverIsRunning = true
        case .screensaverStopped: screensaverIsRunning = false
        case .displaysSlept: displaysAreAsleep = true
        case .displaysWoke: displaysAreAsleep = false
        // Deliberately narrow: waking the machine clears only the machine's
        // own flag. A wake that cleared the lock too would start the marquee
        // running behind the login window, and `screenIsUnlocked` is the
        // event that actually means what that would be claiming.
        case .systemWillSleep: systemIsAsleep = true
        case .systemDidWake: systemIsAsleep = false
        case .occlusionChanged(let isVisible): statusItemIsOccluded = (isVisible == false)
        }
    }

    var isPaused: Bool {
        screenIsLocked || screensaverIsRunning || displaysAreAsleep
            || systemIsAsleep || statusItemIsOccluded
    }

    /// The same state, as the engine reads it. `.occluded` does not mean
    /// "behind the notch" here so much as "nobody can see this" — and
    /// `RefreshPolicy` does the right thing with it either way: no fetch, and
    /// a wait of one cycle rather than an indefinite sleep, so the strip is
    /// current the moment it comes back.
    var visibility: Visibility {
        isPaused ? .occluded : .visible
    }
}
```

- [ ] **Step 4: Run the tests and watch them pass**

```bash
swift test --build-system native --filter PauseConditionsTests
```

Expected: 9 tests, 0 failures.

- [ ] **Step 5: Write the monitor**

`Sources/Squiggle/PauseMonitor.swift`:

```swift
import AppKit

/// Registers for the notifications spec §5.2 cares about and reduces them into
/// a `PauseConditions`, calling back whenever the answer changes.
///
/// Only when it *changes*: macOS is generous with these notifications, and
/// re-applying a pause that is already in effect would reset the animation's
/// captured `timeOffset` and make the strip jump on resume — the exact glitch
/// `speed = 0` exists to avoid.
@MainActor
final class PauseMonitor {
    private(set) var conditions = PauseConditions()
    private let onChange: @MainActor (PauseConditions) -> Void
    private var tokens: [any NSObjectProtocol] = []

    init(onChange: @MainActor @escaping (PauseConditions) -> Void) {
        self.onChange = onChange
    }

    /// `window` is the status item button's window. It is nil until the item
    /// has been placed in the bar, which is why this is a separate call rather
    /// than work done in `init`.
    func start(observing window: NSWindow?) {
        stop()

        for name in PauseEvent.observedDistributedNames {
            let token = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] note in
                guard let event = PauseEvent(distributedName: note.name.rawValue) else { return }
                MainActor.assumeIsolated { self?.handle(event) }
            }
            tokens.append(token)
        }

        for name in PauseEvent.observedWorkspaceNames {
            let token = NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] note in
                guard let event = PauseEvent(workspaceName: note.name) else { return }
                MainActor.assumeIsolated { self?.handle(event) }
            }
            tokens.append(token)
        }

        if let window {
            let token = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main
            ) { [weak self] note in
                let isVisible = (note.object as? NSWindow)?
                    .occlusionState.contains(.visible) ?? true
                MainActor.assumeIsolated {
                    self?.handle(.occlusionChanged(isVisible: isVisible))
                }
            }
            tokens.append(token)
            // The window already has an occlusion state by the time we get
            // here; waiting for it to *change* would leave a status item that
            // launched behind the notch animating until something moved.
            handle(.occlusionChanged(isVisible: window.occlusionState.contains(.visible)))
        }
    }

    func stop() {
        for token in tokens {
            DistributedNotificationCenter.default().removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
        tokens = []
    }

    private func handle(_ event: PauseEvent) {
        let before = conditions
        conditions.apply(event)
        guard conditions != before else { return }
        onChange(conditions)
    }
}
```

`MainActor.assumeIsolated` inside each block, for the reason Task 9 gave: the observers are registered with `queue: .main`, so the block already runs there, and a `Task` hop would only delay the pause by a runloop turn.

`stop()` offers each token to all three centres. A token belongs to exactly one of them and the other two ignore it; the alternative is three parallel arrays tracking which centre each came from, to save two no-op calls on quit.

- [ ] **Step 6: Wire it into the controller**

In `Sources/Squiggle/StatusItemController.swift`, add the stored properties:

```swift
    private var pauseMonitor: PauseMonitor?
    private var pauseConditions = PauseConditions()
```

Replace `visibility()` — Task 6 left it returning `.visible` with a comment saying this task replaces it:

```swift
    private func visibility() -> Visibility { pauseConditions.visibility }
```

In `start()`, after the ticker view is installed, build the monitor:

```swift
        let monitor = PauseMonitor { [weak self] conditions in
            self?.applyPause(conditions)
        }
        monitor.start(observing: button.window)
        pauseMonitor = monitor
```

And add:

```swift
    /// Spec §5.2: pausing is `speed = 0` with the offset captured, never a
    /// removal — removing and re-adding makes the strip jump.
    ///
    /// The refresh side needs nothing here. `visibility()` reads
    /// `pauseConditions` on the next scheduled step, and forcing a step now
    /// would turn every unlock into an unscheduled request.
    private func applyPause(_ conditions: PauseConditions) {
        pauseConditions = conditions
        if conditions.isPaused {
            tickerView.pause()
        } else {
            tickerView.resume()
        }
    }
```

In `stop()`, add:

```swift
        pauseMonitor?.stop()
        pauseMonitor = nil
```

- [ ] **Step 7: Check each condition by hand**

```bash
scripts/package-app.sh && open build/Squiggle.app
```

With a watchlist long enough to scroll, check all four. The test for each is the same: the strip must be *exactly* where it stopped when it comes back, not a frame earlier and not back at the start.

1. **Lock** — ⌃⌘Q, wait ten seconds, unlock.
2. **Screensaver** — trigger it from a hot corner, wait, dismiss.
3. **Display sleep** — System Settings › Lock Screen › turn the display off after 1 minute, wait, wake it.
4. **Occlusion** — open any app full-screen, which hides the menu bar, then move the pointer to the top of the screen to bring it back.

A jump on resume means `pause()` is removing the animation rather than setting `speed = 0`; a strip that never resumes means an end event is not mapping — check Step 3's `init?(distributedName:)` against the literal in Console.app.

```bash
pkill -x Squiggle
```

- [ ] **Step 8: Run the whole suite and commit**

```bash
swift test --build-system native
```

```bash
git add Sources/Squiggle/PauseConditions.swift Sources/Squiggle/PauseMonitor.swift Sources/Squiggle/StatusItemController.swift Tests/SquiggleTests/PauseConditionsTests.swift
git commit -m "feat: stop the strip when nobody can see it"
```

---

## Task 11: The dropdown

Spec §7 gives the dropdown three jobs: show every watched symbol with its number, carry the one line of error detail, and offer *Refresh now*. R132 settles the mechanism — an `NSMenu` rebuilt in `menuNeedsUpdate`, not a custom panel — so there is no view state to keep in sync and no window to manage.

This is also where the fault Task 6 deliberately swallowed comes back. `applicationDidFinishLaunching` does `try? store.load()`, with a comment saying Task 11 carries the fault into the footer. It does.

*Settings…* and *Add Symbol…* are not in this task. Tasks 13 and 15 own those windows and each adds its own item, which keeps a menu item and the thing it opens in one reviewable change.

**Files:**
- Create: `Sources/Squiggle/MenuModel.swift`
- Modify: `Sources/TickerCore/FeedEngine.swift`
- Modify: `Sources/Squiggle/Formatting.swift`
- Modify: `Sources/Squiggle/StripLayout.swift`
- Modify: `Sources/Squiggle/TickerRunner.swift`
- Modify: `Sources/Squiggle/TickerView.swift`
- Modify: `Sources/Squiggle/StatusItemController.swift`
- Modify: `Sources/Squiggle/AppDelegate.swift`
- Test: `Tests/SquiggleTests/MenuModelTests.swift`
- Test: `Tests/TickerCoreTests/FeedEngineTests.swift`

**Interfaces:**
- Consumes: `ErrorText.menuRow/footer/refreshNow/removeSymbol/quit` (Task 4), `Formatting.price/delta/percent/deadPlaceholder` (Task 3), `TickerRunner` (Task 6), `FileWatchlistStore`, `WatchlistStore`, `Store`, `Settings` (TickerCore).
- Produces:
  - `Formatting.change(_ quote: Quote, locale: Locale = .autoupdatingCurrent) -> String`
  - `enum MenuCommand: Equatable, Sendable { case refreshNow; case quit }` with `var title: String`
  - `struct MenuModel` with `enum Item`, `let items: [Item]`, and `static func build(symbols:quotes:dead:lastSuccessEpoch:lastError:storeFault:nowEpoch:nextStepEpoch:locale:) -> MenuModel`
  - `FeedEngine.requestImmediateCycle()` and `TickerRunner.requestImmediateCycle()`
  - `StatusItemController.init(runner:store:storeURL:document:storeFault:)` — replaces Task 6's `init(runner:settings:)`

### R139 — the controller owns the document, and one fault line is shared

Two things move into `StatusItemController` here, because Tasks 13 and 15 both need them and neither is worth building twice.

The first is the `Store` document. Task 6 read it in `AppDelegate` and passed only `Settings` along; from here the controller holds the whole value, and every change — a removed symbol now, a changed setting in Task 13, a new symbol in Task 15 — mutates that one value and calls one `persist()`. It is one JSON file (spec §6), so symbols and settings cannot be saved independently, and pretending otherwise would mean two writers racing over one document.

The second is the fault. The footer takes exactly one error, and there are now two sources: the feed, and the store. **The feed error wins when there is one.** A store fault is permanent for the session — `waitingHelps` returns false for all four of them — so it will be visible again the moment the network recovers. A feed error is transient, so a minute in which it is hidden is a minute it may never be shown at all. Ranking the permanent fault above the transient one would mean a user whose watchlist file is unreadable never learns their Wi-Fi is off.

### R140 — *Refresh now* retires the cycle deadline, and nothing else

Spec §7: *Refresh now* "still takes a token from the bucket". `FeedEngine` has nothing that expresses this today — `replaceWatchlist` and `setUserInterval` both reset `cycleDeadline` as a side effect of their real job, and reaching for one of those to get the side effect would be a caller depending on an undocumented detail.

So `FeedEngine` gains one line of public surface. It sets `cycleDeadline = 0` and touches nothing else, which is exactly the right amount of power: read `next()` top to bottom and every other gate is upstream of the deadline. `RefreshPolicy.decide` runs first and returns `.wait` for a cooldown, an open circuit, an occluded status item, a closed market or an empty watchlist; the token bucket runs after, and its own comment records that it is "the last word on *when*". A user who mashes *Refresh now* through a 429 gets the same cooldown they would have got in silence.

It is also deliberately a no-op mid-cycle. The deadline is only consulted when `cursor >= live.count`; with a cycle already in flight the engine is fetching as fast as the bucket allows, and there is nothing for this to hurry.

- [ ] **Step 1: Write the failing engine test**

Append to `Tests/TickerCoreTests/FeedEngineTests.swift`:

```swift
    // MARK: - Refresh now

    @Test func refreshNowRetiresTheCycleDeadline() throws {
        let clock = FakeClock()
        let one = try sym("AAPL")
        var e = engine(clock, [one])
        // A fresh engine fetches twice before it is holding a deadline at all:
        // the first call runs with `cursor == 0` and never reaches the deadline
        // block, and the second is the one that sets it.
        _ = e.next(openMarket())
        _ = e.next(openMarket())
        clock.advance(60)

        let waiting = e.next(openMarket())
        let isWaiting: Bool
        if case .sleep = waiting { isWaiting = true } else { isWaiting = false }
        #expect(isWaiting, "a 180s cycle 60s in should still be waiting, got \(waiting)")

        e.requestImmediateCycle()
        #expect(e.next(openMarket()) == .fetch(one))
    }

    @Test func refreshNowCannotWalkPastACooldown() throws {
        // Spec §4.3 and §7 together: the item still takes a token, so it must
        // not become a way around a 429 by clicking it enough times.
        let clock = FakeClock()
        let one = try sym("AAPL")
        var e = engine(clock, [one])
        e.record(.rateLimited(retryAfterSeconds: nil), for: one)

        e.requestImmediateCycle()
        let action = e.next(openMarket())
        let isWaiting: Bool
        if case .sleep = action { isWaiting = true } else { isWaiting = false }
        #expect(isWaiting, "the cooldown let a fetch through: \(action)")
    }
```

- [ ] **Step 2: Run them and watch them fail**

```bash
swift test --build-system native --filter refreshNow
```

Expected: compile failure — `value of type 'FeedEngine' has no member 'requestImmediateCycle'`.

- [ ] **Step 3: Add the one line of engine surface**

In `Sources/TickerCore/FeedEngine.swift`, beside `setUserInterval`:

```swift
    /// Retire the current cycle's deadline, so the next `next()` starts a new
    /// pass instead of sleeping out the remainder of this one. What the
    /// dropdown's *Refresh now* does (spec §7).
    ///
    /// This is the *only* gate it lifts, and that is the point. The cooldown
    /// ladder, both circuit breakers, the market calendar, the occlusion check
    /// and the token bucket all sit elsewhere in `next()` — the first five
    /// above this deadline in `RefreshPolicy.decide`, the bucket below it — so
    /// no amount of clicking can turn a 429 into a request.
    ///
    /// A no-op while a cycle is in flight: the deadline is only consulted once
    /// the cursor has been all the way round, and until then the engine is
    /// already fetching as fast as the bucket permits.
    public mutating func requestImmediateCycle() {
        cycleDeadline = 0
    }
```

- [ ] **Step 4: Run them and watch them pass**

```bash
swift test --build-system native --filter refreshNow
```

Expected: 2 tests, 0 failures.

- [ ] **Step 5: Write the failing menu-model tests**

`Tests/SquiggleTests/MenuModelTests.swift`:

```swift
import Foundation
import TickerCore
import Testing
@testable import Squiggle

@Suite("Menu model")
struct MenuModelTests {
    private let posix = Locale(identifier: "en_US_POSIX")
    private let now: Double = 1_757_000_000

    private func sym(_ raw: String) throws -> Symbol {
        try #require(Symbol(raw))
    }

    private func quote(_ symbol: Symbol, price: Double, previousClose: Double?,
                       currency: String?) -> Quote {
        Quote(symbol: symbol, shortName: nil, price: price,
              previousClose: previousClose, currency: currency, asOfEpoch: nil)
    }

    private func model(symbols: [Symbol] = [], quotes: [Symbol: Quote] = [:],
                       dead: Set<Symbol> = [], lastSuccessEpoch: Double? = nil,
                       lastError: TickerError? = nil, storeFault: TickerError? = nil,
                       nextStepEpoch: Double? = nil) -> MenuModel {
        MenuModel.build(symbols: symbols, quotes: quotes, dead: dead,
                        lastSuccessEpoch: lastSuccessEpoch, lastError: lastError,
                        storeFault: storeFault, nowEpoch: now,
                        nextStepEpoch: nextStepEpoch, locale: posix)
    }

    private func titles(_ model: MenuModel) -> [String] {
        model.items.compactMap {
            switch $0 {
            case .quote(let title, _): return title
            case .footer(let text): return text
            case .command(let command): return command.title
            case .separator: return nil
            }
        }
    }

    @Test("a symbol's row carries its price, its currency and its change")
    func aRowReadsLikeTheStrip() throws {
        let aapl = try sym("AAPL")
        let built = model(symbols: [aapl],
                          quotes: [aapl: quote(aapl, price: 178.11,
                                               previousClose: 176.87, currency: "USD")])
        let row = try #require(titles(built).first)
        #expect(row.contains("AAPL"))
        #expect(row.contains("178.11"))
        #expect(row.contains("USD"))
        #expect(row.contains("\u{25B2}"))
    }

    // The GBp rule. A London listing reports pence, and an upper-cased "GBP"
    // would claim the price was in pounds and be wrong by a factor of 100.
    @Test("a currency code is rendered exactly as it arrived")
    func theCurrencyCodeIsNotTouched() throws {
        let vod = try sym("VOD.L")
        let built = model(symbols: [vod],
                          quotes: [vod: quote(vod, price: 68.4,
                                              previousClose: 68.4, currency: "GBp")])
        let row = try #require(titles(built).first)
        #expect(row.contains("GBp"))
        #expect(!row.contains("GBP"))
    }

    @Test("a dead symbol keeps its row and shows the placeholder")
    func aDeadSymbolKeepsItsRow() throws {
        let bad = try sym("NOPE")
        let built = model(symbols: [bad], dead: [bad])
        let row = try #require(titles(built).first)
        #expect(row.contains("NOPE"))
        #expect(row.contains(Formatting.deadPlaceholder))
    }

    // Same rule as `StripLayout.pieces`: a symbol with no quote yet and a
    // symbol given up on both render the placeholder, and the difference
    // between them is the footer line, not a second glyph.
    @Test("a symbol with no quote yet looks the same as a dead one")
    func anUnfetchedSymbolShowsThePlaceholder() throws {
        let fresh = try sym("MSFT")
        let built = model(symbols: [fresh])
        let row = try #require(titles(built).first)
        #expect(row.contains(Formatting.deadPlaceholder))
    }

    @Test("every watched symbol gets a row, in watchlist order")
    func rowsFollowTheWatchlist() throws {
        let order = [try sym("AAPL"), try sym("MSFT"), try sym("^GSPC")]
        let built = model(symbols: order)
        let rows = built.items.compactMap { item -> Symbol? in
            if case .quote(_, let symbol) = item { return symbol }
            return nil
        }
        #expect(rows == order)
    }

    @Test("Refresh Now and Quit are always offered")
    func theCommandsAreAlwaysThere() {
        let commands = model().items.compactMap { item -> MenuCommand? in
            if case .command(let command) = item { return command }
            return nil
        }
        #expect(commands == [.refreshNow, .quit])
    }

    @Test("the commands take their wording from ErrorText")
    func commandTitlesComeFromOnePlace() {
        #expect(MenuCommand.refreshNow.title == ErrorText.refreshNow)
        #expect(MenuCommand.quit.title == ErrorText.quit)
    }

    @Test("the footer reports freshness when nothing is wrong")
    func aHealthyFooterSaysWhenItLastUpdated() throws {
        let built = model(lastSuccessEpoch: now - 180)
        let footer = try #require(built.items.compactMap { item -> String? in
            if case .footer(let text) = item { return text }
            return nil
        }.first)
        #expect(footer == "Updated 3 min ago")
    }

    // R139: the transient fault wins. A store fault is permanent for the
    // session and will be back the moment the feed recovers; a dropped
    // network is a minute long, and a minute spent hidden is a minute the
    // user never gets told.
    @Test("a feed error outranks a store fault in the one footer line")
    func theFeedErrorWins() throws {
        let built = model(lastSuccessEpoch: now - 60,
                          lastError: .offline,
                          storeFault: .storeSchemaUnsupported(found: 99, supported: 1))
        let footer = try #require(built.items.compactMap { item -> String? in
            if case .footer(let text) = item { return text }
            return nil
        }.first)
        #expect(footer == "No network connection.")
    }

    @Test("a store fault reaches the footer when the feed is healthy")
    func theStoreFaultIsNotLost() throws {
        let built = model(lastSuccessEpoch: now - 60,
                          storeFault: .storeSchemaUnsupported(found: 99, supported: 1))
        let footer = try #require(built.items.compactMap { item -> String? in
            if case .footer(let text) = item { return text }
            return nil
        }.first)
        #expect(footer.contains("newer Squiggle"))
    }

    @Test("the next scheduled step becomes the retry the footer promises")
    func theRetryComesFromTheRealSchedule() throws {
        let built = model(lastSuccessEpoch: now - 900,
                          lastError: .rateLimited(retryAfterSeconds: nil),
                          nextStepEpoch: now + 720)
        let footer = try #require(built.items.compactMap { item -> String? in
            if case .footer(let text) = item { return text }
            return nil
        }.first)
        #expect(footer.contains("12 min"))
    }

    // A separator either side of the footer, and one before Quit. Asserted as
    // a shape rather than by index so that Tasks 13 and 15 inserting their own
    // items cannot quietly turn this into a test of nothing.
    @Test("no separator sits at either end and none are doubled")
    func separatorsAreWhereSeparatorsBelong() throws {
        let built = model(symbols: [try sym("AAPL")])
        let isSeparator = built.items.map { item -> Bool in
            if case .separator = item { return true }
            return false
        }
        // `first`/`last` are `Bool?`, so `!` will not apply and `== false`
        // is the swallowed shape. Hoist, defaulting to `true` so an empty
        // menu — itself a bug — fails here rather than passing vacuously.
        let opensWithSeparator = isSeparator.first ?? true
        let endsWithSeparator = isSeparator.last ?? true
        #expect(!opensWithSeparator)
        #expect(!endsWithSeparator)
        let doubled = zip(isSeparator, isSeparator.dropFirst()).contains { $0 && $1 }
        #expect(!doubled)
    }
}
```

- [ ] **Step 6: Run them and watch them fail**

```bash
swift test --build-system native --filter MenuModelTests
```

Expected: compile failure — `cannot find 'MenuModel' in scope`.

- [ ] **Step 7: Give `Formatting` the change string, and make `StripLayout` use it**

The dropdown row and the strip segment are the same number in the same wording, so they are one function. Two copies of this composition would be a bug waiting for one of them to be edited: a strip reading `▲1.24 (0.70%)` beside a dropdown reading `+1.24 (+0.7%)` is worse than either.

Add to `Sources/Squiggle/Formatting.swift`:

```swift
    /// The change, as both the strip segment and the dropdown row render it:
    /// the direction glyph carrying the sign (R127), then the absolute delta,
    /// then the absolute percentage in brackets.
    ///
    /// Empty when the quote has neither a delta nor a percentage — the caller
    /// then shows the price alone, rather than a bare glyph or an empty pair
    /// of brackets.
    static func change(_ quote: Quote, locale: Locale = .autoupdatingCurrent) -> String {
        let delta = Self.delta(quote.change, locale: locale)
        let percent = Self.percent(quote.changePercent, locale: locale)
        guard !delta.isEmpty || !percent.isEmpty else { return "" }

        var text = quote.direction.glyph + delta
        if !percent.isEmpty {
            text += text.isEmpty ? "(\(percent))" : " (\(percent))"
        }
        return text
    }
```

`Formatting.swift` now needs `import TickerCore` for `Quote` if it does not already have it.

Then replace the tail of `StripLayout.pieces` — everything from `let delta = Formatting.delta(...)` to the closing `]` — with:

```swift
        let change = Formatting.change(quote, locale: locale)
        let price = Formatting.price(quote.price, locale: locale)

        // Nothing to say about the change: show the price alone rather than a
        // bare glyph or an empty pair of brackets.
        guard !change.isEmpty else {
            return [name, Piece(text: price, role: .label)]
        }

        return [
            name,
            Piece(text: price + " ", role: .label),
            Piece(text: change, role: .direction(quote.direction)),
        ]
```

- [ ] **Step 8: Write the menu model**

`Sources/Squiggle/MenuModel.swift`:

```swift
import Foundation
import TickerCore

/// A dropdown item that does something, as opposed to one that says something.
///
/// *Remove* is not here: it lives inside a symbol's own row, where it has a
/// symbol to act on. A command in this enum needs no argument, which is what
/// lets `StatusItemController` map it to a selector with a `switch` and no
/// `default:`.
enum MenuCommand: Equatable, Sendable {
    case refreshNow
    case quit

    /// All wording lives in `ErrorText` (spec §7). This property exists so the
    /// menu never spells a title itself and a test can say so.
    var title: String {
        switch self {
        case .refreshNow: return ErrorText.refreshNow
        case .quit: return ErrorText.quit
        }
    }
}

/// What the dropdown says, as a value.
///
/// The same split as `StripLayout` and `StripRenderer`: this decides the rows
/// and the wording, and `StatusItemController` turns it into `NSMenuItem`s.
/// The reason is the same too — every rule worth testing is in here, and none
/// of it needs a status bar, a window server or a run loop to exercise.
struct MenuModel: Equatable {
    enum Item: Equatable {
        /// One watchlist row. The symbol rides along because the row's submenu
        /// has a *Remove* item that needs to know what it is removing.
        case quote(title: String, symbol: Symbol)
        /// Spec §7's one line of detail, and the app's only error surface.
        case footer(String)
        case command(MenuCommand)
        case separator
    }

    let items: [Item]

    static func build(symbols: [Symbol],
                      quotes: [Symbol: Quote],
                      dead: Set<Symbol>,
                      lastSuccessEpoch: Double?,
                      lastError: TickerError?,
                      storeFault: TickerError?,
                      nowEpoch: Double,
                      nextStepEpoch: Double?,
                      locale: Locale = .autoupdatingCurrent) -> MenuModel {
        var items: [Item] = symbols.map { symbol in
            .quote(title: row(for: symbol, quotes: quotes, dead: dead, locale: locale),
                   symbol: symbol)
        }
        if !items.isEmpty { items.append(.separator) }

        // R139: the transient fault outranks the permanent one, because the
        // permanent one gets every other minute of the session to be read in.
        let footer = ErrorText.footer(
            lastSuccessAgoSeconds: lastSuccessEpoch.map { nowEpoch - $0 },
            lastError: lastError ?? storeFault,
            retryInSeconds: nextStepEpoch.map { max(0, $0 - nowEpoch) })
        items.append(.footer(footer))

        items.append(.separator)
        items.append(.command(.refreshNow))
        items.append(.separator)
        items.append(.command(.quit))
        return MenuModel(items: items)
    }

    private static func row(for symbol: Symbol,
                            quotes: [Symbol: Quote],
                            dead: Set<Symbol>,
                            locale: Locale) -> String {
        // Same rule as `StripLayout.pieces`, for the same reason: no quote yet
        // and given up on both mean "there is no number for this slot", and
        // which one it is belongs in the footer, not in a second glyph.
        guard !dead.contains(symbol), let quote = quotes[symbol] else {
            return ErrorText.menuRow(symbol: symbol.raw,
                                     price: Formatting.deadPlaceholder,
                                     change: "", currency: nil)
        }
        return ErrorText.menuRow(symbol: symbol.raw,
                                 price: Formatting.price(quote.price, locale: locale),
                                 change: Formatting.change(quote, locale: locale),
                                 currency: quote.currency)
    }
}
```

- [ ] **Step 9: Run them and watch them pass**

```bash
swift test --build-system native --filter MenuModelTests
```

Expected: 12 tests, 0 failures.

- [ ] **Step 10: Let the click through to the button**

In `Sources/Squiggle/TickerView.swift`, add:

```swift
    /// The ticker is a picture, not a control.
    ///
    /// A layer-backed `NSView` sitting inside `NSStatusBarButton` wins the hit
    /// test over the button beneath it, and `NSView`'s default `mouseDown` does
    /// nothing — so without this the strip would swallow every click and the
    /// dropdown would never open. Returning `nil` makes the view invisible to
    /// the mouse and leaves the button to do what a status item button does.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
```

- [ ] **Step 11: Wire the menu into the controller**

`Sources/Squiggle/StatusItemController.swift`. Five changes.

First, the declaration. Menu item actions are `@objc` selectors and `NSMenuDelegate` is an `NSObject` protocol, so the class needs an `NSObject` base:

```swift
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
```

Second, the stored state. Replace `private var settings: Settings` and the initialiser with:

```swift
    private let store: any WatchlistStore
    // `WatchlistStore` is a protocol and has no URL, and a save that fails for
    // a filesystem reason needs one to report. Carried beside the store rather
    // than reached for through a concrete type, so the controller still takes
    // any conforming store.
    private let storeURL: URL
    private var document: Store
    private var storeFault: TickerError?
    private var nextStepEpoch: Double?

    // R139: one document, one saver. `settings` is a view onto it rather than
    // a second copy, so Task 13 changing a setting and Task 15 adding a symbol
    // cannot end up writing over one another.
    private var settings: Settings { document.settings }

    init(runner: TickerRunner, store: any WatchlistStore, storeURL: URL,
         document: Store, storeFault: TickerError?) {
        self.runner = runner
        self.store = store
        self.storeURL = storeURL
        self.document = document
        self.storeFault = storeFault
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.title = ""
    }
```

Third, `start()` gains the menu, after the ticker view is installed and before the pause monitor:

```swift
        let menu = NSMenu()
        // Without this, AppKit decides for itself which items are enabled and
        // the footer — an item with no action, which is exactly what "is this
        // clickable" is judged on — would be greyed out along with everything
        // else that has no target.
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
```

Fourth, `scheduleStep(after:)` records when it will fire, one line after `let delay = ...`:

```swift
        // The footer's "retrying in" is this number and not an estimate of it.
        nextStepEpoch = Date().timeIntervalSince1970 + delay
```

Fifth, the menu itself:

```swift
    // MARK: - The dropdown

    // R132: rebuilt every time it opens rather than kept in sync. A menu that
    // is only visible for the second it is being read has no state worth
    // maintaining, and the timer is on `.common` (Task 6), so the prices
    // behind it keep arriving while it is up.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let model = MenuModel.build(symbols: runner.symbols,
                                    quotes: runner.quotes,
                                    dead: runner.deadSymbols,
                                    lastSuccessEpoch: runner.lastSuccessEpoch,
                                    lastError: runner.lastError,
                                    storeFault: storeFault,
                                    nowEpoch: Date().timeIntervalSince1970,
                                    nextStepEpoch: nextStepEpoch)
        for item in model.items {
            menu.addItem(menuItem(for: item))
        }
    }

    private func menuItem(for item: MenuModel.Item) -> NSMenuItem {
        // No `default:`: a fifth kind of item must fail the build here rather
        // than vanish from the menu.
        switch item {
        case .separator:
            return .separator()

        case .footer(let text):
            let entry = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            entry.isEnabled = false
            return entry

        case .quote(let title, let symbol):
            let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            // Enabled with no action of its own: a disabled parent will not
            // open its submenu, and the row itself does nothing when clicked.
            entry.isEnabled = true
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            let remove = NSMenuItem(title: ErrorText.removeSymbol,
                                    action: #selector(removeSymbol(_:)), keyEquivalent: "")
            remove.target = self
            remove.isEnabled = true
            remove.representedObject = symbol
            submenu.addItem(remove)
            entry.submenu = submenu
            return entry

        case .command(let command):
            let entry = NSMenuItem(title: command.title,
                                   action: selector(for: command), keyEquivalent: "")
            entry.target = self
            entry.isEnabled = true
            return entry
        }
    }

    private func selector(for command: MenuCommand) -> Selector {
        switch command {
        case .refreshNow: return #selector(refreshNow)
        case .quit: return #selector(quit)
        }
    }

    // MARK: - Menu actions

    @objc private func refreshNow() {
        // R140: this retires the cycle deadline. The cooldown, both circuits
        // and the token bucket all still get their say, so the click asks for
        // a refresh — it does not grant one.
        runner.requestImmediateCycle()
        scheduleStep(after: 0)
    }

    @objc private func removeSymbol(_ sender: NSMenuItem) {
        guard let symbol = sender.representedObject as? Symbol else { return }
        document.symbols.removeAll { $0 == symbol }
        runner.replaceWatchlist(document.symbols)
        persist()
        render()
    }

    @objc private func quit() {
        stop()
        NSApp.terminate(nil)
    }

    /// Writes the whole document. Never throws at a menu click: a failed save
    /// leaves the change in memory — the user asked for it and it is on the
    /// screen — and reports itself in the footer instead, which is the app's
    /// only error surface (spec §7, zero alerts).
    private func persist() {
        do {
            try store.save(document)
            storeFault = nil
        } catch let error as TickerError {
            storeFault = error
        } catch {
            // `FileWatchlistStore.save` can fail at `createDirectory` or at the
            // write itself with a raw `NSError`, which no `catch let e as
            // TickerError` would match. `storeQuarantineFailed` is the case
            // that already means "the file is where it was and Squiggle cannot
            // use it" — true here too, in the other direction.
            storeFault = .storeQuarantineFailed(at: storeURL)
        }
    }
```

- [ ] **Step 12: Forward it from the runner, and hand the controller the store**

In `Sources/Squiggle/TickerRunner.swift`, beside `setUserInterval`:

```swift
    func requestImmediateCycle() { engine.requestImmediateCycle() }
```

In `Sources/Squiggle/AppDelegate.swift`, `applicationDidFinishLaunching` keeps the launch and stops discarding the reason:

```swift
        let url = FileWatchlistStore.defaultURL(applicationName: "Squiggle")
        let store = FileWatchlistStore(url: url)

        // A store that will not load is not a reason to refuse to launch: an
        // empty watchlist is a usable app with an empty strip. Task 6 dropped
        // the fault on the floor with a `try?` and a note saying this task
        // would pick it up; this is that. Spec §7 puts it in the dropdown
        // footer, and nowhere else — no alert, no notification.
        var document = Store()
        var storeFault: TickerError?
        do {
            document = try store.load()
        } catch let error as TickerError {
            storeFault = error
        } catch {
            storeFault = .storeQuarantineFailed(at: url)
        }

        let runner = TickerRunner(symbols: document.symbols,
                                  userIntervalSeconds: document.settings.refreshIntervalSeconds,
                                  fetcher: YahooClient())
        let controller = StatusItemController(runner: runner, store: store, storeURL: url,
                                              document: document, storeFault: storeFault)
        self.controller = controller
        controller.start()
```

- [ ] **Step 13: Check it by hand**

```bash
swift build --build-system native --product Squiggle && .build/debug/Squiggle
```

Six things, in order:

1. Click the strip. The menu opens — if it does not, Step 10's `hitTest` is missing.
2. Every watched symbol has a row, with its price and its change. The prices in the rows match the prices in the strip.
3. The footer reads *Updated N min ago*, and is greyed out but present.
4. Hover a symbol row; its submenu offers *Remove*. Take one. The strip re-renders without it, the menu closes, and `cat ~/Library/Application\ Support/Squiggle/squiggle.json` shows the symbol gone.
5. Turn Wi-Fi off, wait for the next step, reopen the menu. The footer reads *No network connection.* Turn it back on.
6. *Quit Squiggle* quits it. There is no dock icon to quit from, so if this item does not work the only exit is `pkill`.

Then the fault path, which is the half Task 6 owed:

```bash
cp ~/Library/Application\ Support/Squiggle/squiggle.json /tmp/squiggle-backup.json
echo '{"schemaVersion": 99, "symbols": [], "settings": {}}' > ~/Library/Application\ Support/Squiggle/squiggle.json
.build/debug/Squiggle
```

The app launches with an empty strip, and the footer reads *Your watchlist was written by a newer Squiggle.* Quit it and put the real file back:

```bash
cp /tmp/squiggle-backup.json ~/Library/Application\ Support/Squiggle/squiggle.json
```

- [ ] **Step 14: Run the whole suite and commit**

```bash
swift test --build-system native
```

```bash
git add Sources/Squiggle/MenuModel.swift Sources/Squiggle/Formatting.swift Sources/Squiggle/StripLayout.swift Sources/Squiggle/TickerRunner.swift Sources/Squiggle/TickerView.swift Sources/Squiggle/StatusItemController.swift Sources/Squiggle/AppDelegate.swift Sources/TickerCore/FeedEngine.swift Tests/SquiggleTests/MenuModelTests.swift Tests/TickerCoreTests/FeedEngineTests.swift
git commit -m "feat: the dropdown, and the fault the launch used to swallow"
```

---

## Task 12: Colour, and the strip that goes quiet

Three things land together because they are one decision made in one place: which colour a `ColorRole` resolves to.

Spec §5.3 gives the scheme table and two overrides — `accessibilityDisplayShouldDifferentiateWithoutColor` forces Monochrome, and colours resolve against `statusItem.button.effectiveAppearance` rather than the app's. Spec §7 gives the third: a stale strip "dims to `tertiaryLabelColor`; prices still shown, still moving". All three are answered by the closure Task 8 has been passing as `{ _ in NSColor.labelColor.cgColor }` since it was written. This task replaces the closure and nothing else.

**Files:**
- Create: `Sources/Squiggle/ColorScheme.swift`
- Modify: `Sources/Squiggle/TickerRunner.swift`
- Modify: `Sources/Squiggle/StatusItemController.swift`
- Modify: `Tests/SquiggleTests/TickerRunnerTests.swift`
- Test: `Tests/SquiggleTests/ColorSchemeTests.swift`

**Interfaces:**
- Consumes: `ColorRole` (Task 5), `Direction`, `RefreshPolicy.isStale`, `MarketState` (TickerCore), `Settings.colorScheme` (Task 1), `TickerRunner.lastSuccessEpoch/userIntervalSeconds/symbols` (Task 6).
- Produces:
  - `enum ColorScheme: Equatable, Sendable { case monochrome, classic, accessible }` with `init(setting: String)`
  - `enum ColorPolicy` with `static func effective(requested: ColorScheme, differentiateWithoutColor: Bool) -> ColorScheme` and `static func color(for role: ColorRole, scheme: ColorScheme, isStale: Bool) -> NSColor`
  - `TickerRunner.marketState(atEpoch:) -> MarketState?` — renamed from `marketStateForTesting(atEpoch:)`

### R141 — Accessible is `systemBlue` / `systemOrange`

Spec §5.3 says two things that cannot both be taken literally: "Okabe–Ito blue / orange", and "System semantic colours only, never literal hex". Okabe–Ito *is* a list of hex values (`#0072B2`, `#E69F00`).

The semantic rule wins, because the spec states its reason and the reason still applies: system colours "are already tuned for appearance and Increase Contrast". A hard-coded `#0072B2` is one colour for both appearances and ignores Increase Contrast entirely — on a dark menu bar it is the wrong blue, and for the user most likely to have chosen the Accessible scheme it is the wrong blue with the contrast setting switched off.

What Okabe–Ito is actually specifying is the *axis*, and that survives the substitution intact: blue-versus-orange is the pair that stays separable under both deuteranopia and protanopia, which is the entire reason the scheme exists and the entire reason green-versus-red does not. `NSColor.systemBlue` and `NSColor.systemOrange` sit on that same axis. So Accessible is `.systemBlue` up, `.systemOrange` down, and the spec's "Okabe–Ito" is read as naming the axis rather than the two hex triples.

### R142 — the stale dim is a colour, not an opacity

Spec §7 dims the *whole* strip to `tertiaryLabelColor`. Two implementations suggest themselves and only one is right.

Setting the container layer's `opacity` is one line and is wrong. `labelColor` is already translucent — measured on this machine it resolves to white at **alpha 0.847** on a dark appearance — so multiplying by an opacity gives some third value that is not `tertiaryLabelColor` and does not track it across appearances. Worse, Increase Contrast exists to make these colours *more* opaque, and a hard-coded multiplier quietly cancels that: the user who most needs the strip legible gets the biggest reduction.

So staleness is an input to the colour resolution, and every role resolves to `tertiaryLabelColor` when it is set. That also settles what happens to a Classic-scheme user whose feed has gone stale: the deltas stop being green and red. They should. A coloured number inside a dimmed strip reads as the one live thing on it, which is the exact opposite of true.

Staleness is read at render time, and renders happen once per engine step — so the dim can arrive up to one sleep after the threshold is crossed. That is accepted rather than fixed with a second timer: a strip that has been stale for three cycles is not meaningfully worse for saying so at 3.2, and a timer whose only job is to make text grey would wake a sleeping Mac to do it.

- [ ] **Step 1: Write the failing tests**

`Tests/SquiggleTests/ColorSchemeTests.swift`:

```swift
import AppKit
import TickerCore
import Testing
@testable import Squiggle

@Suite("Colour schemes")
struct ColorSchemeTests {
    // `Direction` is not `CaseIterable`, and this list is the reason it does
    // not need to be: a fifth direction fails the exhaustive switch in
    // `ColorPolicy.color` at build time, which is a better guard than a sweep.
    private let everyDirection: [Direction] = [.up, .down, .flat, .unknown]
    private let everyScheme: [ColorScheme] = [.monochrome, .classic, .accessible]

    private func color(_ role: ColorRole, _ scheme: ColorScheme,
                       stale: Bool = false) -> NSColor {
        ColorPolicy.color(for: role, scheme: scheme, isStale: stale)
    }

    @Test("the spec's three scheme names are the whole vocabulary")
    func theVocabularyIsTheSpecs() {
        #expect(ColorScheme(setting: "monochrome") == .monochrome)
        #expect(ColorScheme(setting: "classic") == .classic)
        #expect(ColorScheme(setting: "accessible") == .accessible)
    }

    // R119: the field is a lenient `String` precisely so that an unknown value
    // is a rendering decision rather than a decode failure. Monochrome is the
    // right fallback because it is both the default and the accessible one.
    @Test("anything else is Monochrome")
    func anUnknownSettingFallsBackToMonochrome() {
        #expect(ColorScheme(setting: "auto") == .monochrome)
        #expect(ColorScheme(setting: "Classic") == .monochrome)
        #expect(ColorScheme(setting: "") == .monochrome)
    }

    @Test("Differentiate Without Color forces Monochrome over any scheme")
    func theAccessibilitySettingWins() {
        for scheme in everyScheme {
            let forced = ColorPolicy.effective(requested: scheme,
                                               differentiateWithoutColor: true)
            #expect(forced == .monochrome, "\(scheme) survived the override")
        }
    }

    @Test("with the setting off, the requested scheme is the effective one")
    func otherwiseTheUserChoiceStands() {
        for scheme in everyScheme {
            let effective = ColorPolicy.effective(requested: scheme,
                                                  differentiateWithoutColor: false)
            #expect(effective == scheme)
        }
    }

    // Spec §5.3: "the symbol is the anchor the eye lands on and must not move
    // in the colour space."
    @Test("the symbol and the price are never coloured, in any scheme")
    func theLabelRoleIsAlwaysTheLabelColour() {
        for scheme in everyScheme {
            #expect(color(.label, scheme) == NSColor.labelColor, "\(scheme)")
        }
    }

    @Test("Classic is systemGreen up and systemRed down")
    func classicIsTheFamiliarPair() {
        #expect(color(.direction(.up), .classic) == NSColor.systemGreen)
        #expect(color(.direction(.down), .classic) == NSColor.systemRed)
    }

    // R141: the blue/orange axis, taken from the system palette so that both
    // appearances and Increase Contrast keep working.
    @Test("Accessible is systemBlue up and systemOrange down")
    func accessibleIsTheColourblindSafeAxis() {
        #expect(color(.direction(.up), .accessible) == NSColor.systemBlue)
        #expect(color(.direction(.down), .accessible) == NSColor.systemOrange)
    }

    @Test("Monochrome colours nothing at all")
    func monochromeIsUniform() {
        for direction in everyDirection {
            #expect(color(.direction(direction), .monochrome) == NSColor.labelColor,
                    "\(direction) picked up a colour")
        }
    }

    // Spec §5.3: "`.flat` and `.unknown` are never coloured." A flat day is
    // not an event, and `.unknown` means Squiggle does not know which way it
    // went — colouring either would be an assertion it cannot make.
    @Test("flat and unknown are never coloured, even in a colour scheme")
    func theUneventfulDirectionsStayNeutral() {
        for scheme in [ColorScheme.classic, .accessible] {
            #expect(color(.direction(.flat), scheme) == NSColor.labelColor, "\(scheme)")
            #expect(color(.direction(.unknown), scheme) == NSColor.labelColor, "\(scheme)")
        }
    }

    // R142 and spec §7: the *whole* strip dims, which includes the deltas a
    // colour scheme would otherwise have coloured.
    @Test("a stale strip dims every role in every scheme")
    func stalenessOutranksEverything() {
        for scheme in everyScheme {
            #expect(color(.label, scheme, stale: true) == NSColor.tertiaryLabelColor,
                    "\(scheme) label")
            for direction in everyDirection {
                #expect(color(.direction(direction), scheme, stale: true)
                            == NSColor.tertiaryLabelColor,
                        "\(scheme) \(direction)")
            }
        }
    }

    @Test("a fresh strip is not dimmed")
    func freshIsNotDim() {
        let dimmed = color(.label, .monochrome, stale: false) == NSColor.tertiaryLabelColor
        #expect(!dimmed)
    }
}
```

- [ ] **Step 2: Run them and watch them fail**

```bash
swift test --build-system native --filter ColorSchemeTests
```

Expected: compile failure — `cannot find 'ColorScheme' in scope`.

- [ ] **Step 3: Write the scheme and the policy**

`Sources/Squiggle/ColorScheme.swift`:

```swift
import AppKit
import TickerCore

/// Spec §5.3's three schemes. The same shape as `MotionMode` (Task 9): a
/// lenient `init` from the stored string, because `Settings` keeps these as
/// `String` so that `TickerCore` never has to know what a colour is.
enum ColorScheme: Equatable, Sendable {
    case monochrome
    case classic
    case accessible

    /// Anything unrecognised is Monochrome — the default (R119) and the
    /// accessible answer, so an unreadable setting degrades toward safety
    /// rather than toward a red/green strip somebody cannot read.
    init(setting: String) {
        switch setting {
        case "classic": self = .classic
        case "accessible": self = .accessible
        default: self = .monochrome
        }
    }
}

/// Resolves a `ColorRole` to an `NSColor`. Pure, and deliberately so: every
/// rule spec §5.3 and §7 state about colour is decided here, with no status
/// item, no appearance and no clock in reach.
///
/// What is *not* here is the appearance resolution. `NSColor` is a recipe
/// rather than a colour — it becomes pixels only when something asks for its
/// `cgColor` under a particular appearance — and which appearance to ask under
/// is `StatusItemController`'s business, because the answer is the menu bar's
/// and not the app's.
enum ColorPolicy {
    /// Spec §5.3: `accessibilityDisplayShouldDifferentiateWithoutColor` forces
    /// Monochrome. The user has said, at the system level, that colour must
    /// not be the thing carrying meaning; the glyph already carries it.
    static func effective(requested: ColorScheme,
                          differentiateWithoutColor: Bool) -> ColorScheme {
        differentiateWithoutColor ? .monochrome : requested
    }

    static func color(for role: ColorRole, scheme: ColorScheme, isStale: Bool) -> NSColor {
        // R142 and spec §7: the whole strip dims, deltas included. Checked
        // before the scheme rather than after, because "stale" is a statement
        // about all of it and a green number inside a grey strip would read as
        // the one live thing on the row.
        guard !isStale else { return .tertiaryLabelColor }

        // Exhaustive, no `default:` — a third role must fail the build here.
        switch role {
        case .label:
            // Spec §5.3: colour applies to the delta and percentage only. The
            // symbol is the anchor the eye lands on and must not move in the
            // colour space.
            return .labelColor

        case .direction(let direction):
            switch scheme {
            case .monochrome:
                return .labelColor
            case .classic:
                return Self.pair(direction, up: .systemGreen, down: .systemRed)
            case .accessible:
                // R141: the blue/orange axis, which survives both deuteranopia
                // and protanopia — from the system palette, so both
                // appearances and Increase Contrast keep working.
                return Self.pair(direction, up: .systemBlue, down: .systemOrange)
            }
        }
    }

    /// Spec §5.3: "`.flat` and `.unknown` are never coloured." Written once
    /// here rather than twice in the switch above, so the two schemes cannot
    /// drift on the question of what an uneventful day looks like.
    private static func pair(_ direction: Direction,
                             up: NSColor, down: NSColor) -> NSColor {
        switch direction {
        case .up: return up
        case .down: return down
        case .flat, .unknown: return .labelColor
        }
    }
}
```

- [ ] **Step 4: Run them and watch them pass**

```bash
swift test --build-system native --filter ColorSchemeTests
```

Expected: 11 tests, 0 failures.

- [ ] **Step 5: Let the runner say what the market is doing**

The staleness check needs a `MarketState`, and `TickerRunner` already aggregates one per step — behind a method called `marketStateForTesting`. A production caller of a method named that way is a defect however well it works, and the name was only ever about its first caller, not about the method.

In `Sources/Squiggle/TickerRunner.swift`, replace the method and its doc comment:

```swift
    /// The aggregate trading state across the live watchlist, as of `epoch`.
    ///
    /// Read by `step` to build its `EngineContext`, and by
    /// `StatusItemController` for the staleness check spec §7 dims the strip
    /// on — `RefreshPolicy.isStale` needs it, because a closed market is never
    /// stale however old the last price is.
    ///
    /// `nil` before any quote has arrived. Both callers then assume `.regular`,
    /// and they must keep assuming the same thing: two different guesses about
    /// market hours in one app is the bug `TradingCalendars` exists to prevent.
    func marketState(atEpoch epoch: Double) -> MarketState? {
        calendars.aggregateState(atEpoch: epoch)
    }
```

And in `Tests/SquiggleTests/TickerRunnerTests.swift`, the single call site inside `theCalendarOutOfTheBodyIsWhatDrivesTheNextContext`:

```swift
    #expect(runner.marketState(atEpoch: 1_000) != nil)
```

- [ ] **Step 6: Resolve the colour against the menu bar's appearance**

In `Sources/Squiggle/StatusItemController.swift`, add the two methods:

```swift
    // MARK: - Colour

    /// Spec §7's stale state. Asks `RefreshPolicy`; never computes an age.
    ///
    /// The spec is explicit about this and the reason is arithmetic: the
    /// threshold is three *cycles*, and at twenty symbols the cycle floors at
    /// 1,440s — so "stale" is 72 minutes there and 9 at the same user setting
    /// with one symbol. Anything here that compared an age against the user's
    /// interval would dim a perfectly healthy strip eight times out of nine.
    private func isStale(atEpoch epoch: Double) -> Bool {
        RefreshPolicy.isStale(
            lastSuccessEpoch: runner.lastSuccessEpoch,
            nowEpoch: epoch,
            userIntervalSeconds: runner.userIntervalSeconds,
            watchlistCount: runner.symbols.count,
            // The same assumption `TickerRunner.step` makes before the first
            // quote arrives, and deliberately the same one: a second opinion
            // about market hours inside one app is a bug.
            marketState: runner.marketState(atEpoch: epoch) ?? .regular,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// The closure `TickerView` paints with (R136).
    ///
    /// The scheme and the staleness are decided once, here, and captured — the
    /// closure is called once per segment and neither answer can change
    /// between segments of one strip. What it does per call is resolve an
    /// `NSColor` into a `CGColor`, which is the part that genuinely depends on
    /// the appearance.
    private func colorResolver() -> (ColorRole) -> CGColor {
        let scheme = ColorPolicy.effective(
            requested: ColorScheme(setting: settings.colorScheme),
            differentiateWithoutColor:
                NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor)
        let stale = isStale(atEpoch: Date().timeIntervalSince1970)

        // Spec §5.3: the *button's* effective appearance, not the app's. The
        // menu bar can be dark while the app is light — that is the ordinary
        // state of a Mac with a dark wallpaper and a light system appearance —
        // and `NSColor.cgColor` resolves against whatever appearance happens
        // to be current, which during a timer callback is the app's. Measured:
        // `labelColor` is white at alpha 0.847 under `.darkAqua` and black at
        // the same alpha under `.aqua`. Getting this wrong paints black text
        // on a black menu bar.
        let appearance = statusItem.button?.effectiveAppearance
            ?? NSApp.effectiveAppearance

        return { role in
            let color = ColorPolicy.color(for: role, scheme: scheme, isStale: stale)
            // Seeded with the unresolved answer and overwritten inside the
            // block. `performAsCurrentDrawingAppearance` runs synchronously, so
            // the seed never survives — it is here because `CGColor` has no
            // sensible empty value and a force-unwrap would be worse.
            var resolved = color.cgColor
            appearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
            return resolved
        }
    }
```

Then in `render()`, replace the placeholder closure:

```swift
                         color: colorResolver())
```

- [ ] **Step 7: Re-render when the menu bar changes appearance**

Spec §5.3 requires it, and nothing so far does. Add the stored observation and register it in `start()`, after the ticker view is installed:

```swift
    private var appearanceObservation: NSKeyValueObservation?
```

```swift
        // Spec §5.3: "re-renders on appearance change". KVO rather than a
        // notification because `effectiveAppearance` is a property of this one
        // button and the interesting change is the menu bar's, which is not
        // what `NSApp.effectiveAppearance` reports. The observation is stored
        // because KVO stops the moment it is released.
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) {
            [weak self] _, _ in
            MainActor.assumeIsolated { self?.render() }
        }
```

And in `stop()`, beside the pause monitor teardown:

```swift
        appearanceObservation = nil
```

Nothing needs adding for Differentiate Without Color: Task 9 already observes `accessibilityDisplayOptionsDidChangeNotification` and its handler calls `render()`, which now reads the flag afresh through `colorResolver()`. Task 9's note that this task would extend that handler turns out to be wrong in a good way — the wiring was already general.

- [ ] **Step 8: Look at all of it**

```bash
scripts/package-app.sh && open build/Squiggle.app
```

Seven checks. The first four take a symbol that is up and one that is down, so both arms are on screen at once.

1. Default settings: every number in the menu bar's label colour, direction carried by `▲` and `▼` alone.
2. Set `"colorScheme": "classic"` and relaunch: the delta and percentage go green and red. **The symbol and the price do not.** If they do, the `.label` arm is picking up the scheme.
3. Set `"colorScheme": "accessible"` and relaunch: blue and orange, same two segments only.
4. With Classic still set, turn on System Settings › Accessibility › Display › **Differentiate Without Color** while the app is running. The colour drains within a second, with no relaunch. Turn it off; it comes back.
5. Switch System Settings › Appearance between Light and Dark. The strip stays legible through the change. If it goes invisible, `performAsCurrentDrawingAppearance` is not wrapping the `cgColor` call.
6. Turn on Increase Contrast. The strip gets more opaque rather than less — this is the check R142 is about, and an opacity-based dim would have failed it.
7. The stale state, which needs no market: turn Wi-Fi off and leave the app running past three cycles. With one or two symbols in the store that is nine minutes; `swift run --build-system native squigglectl doctor` prints the cycle if you would rather not guess. The **whole** strip fades to a dim grey — symbol, price and delta together — and keeps scrolling. Turn Wi-Fi back on; it comes back to full contrast at the next successful fetch.

```bash
pkill -x Squiggle
```

- [ ] **Step 9: Run the whole suite and commit**

```bash
swift test --build-system native
```

```bash
git add Sources/Squiggle/ColorScheme.swift Sources/Squiggle/TickerRunner.swift Sources/Squiggle/StatusItemController.swift Tests/SquiggleTests/ColorSchemeTests.swift Tests/SquiggleTests/TickerRunnerTests.swift
git commit -m "feat: colour the deltas, and dim the strip when it goes stale"
```

---

## Task 13: Settings

Spec build-order step 7: "Width slider, speed slider, refresh interval, row count, colour schemes, launch at login." Everything but the last one, which is Task 14 — `SMAppService` registration has its own failure modes and its own verification (log out, log back in, watch for the status item), and bolting it onto a task that is otherwise pure AppKit layout would give a reviewer one gate for two unrelated risks.

R133 settles the mechanism: an `NSWindow` built in code. No xib, no storyboard, no SwiftUI. Seven controls do not justify a second UI framework in a menu bar utility, and a storyboard is a file no test can read.

Every control applies immediately. There is no OK and no Cancel, because spec §4.1 requires the effective-interval line to update "live beside the choice", and a window that previews one setting live while queueing the other six behind a button would be lying about which of them had taken effect.

**Files:**
- Create: `Sources/Squiggle/SettingsForm.swift`
- Create: `Sources/Squiggle/SettingsWindow.swift`
- Modify: `Sources/TickerCore/Store.swift`
- Modify: `Sources/Squiggle/ErrorText.swift`
- Modify: `Sources/Squiggle/MenuModel.swift`
- Modify: `Sources/Squiggle/StatusItemController.swift`
- Test: `Tests/SquiggleTests/SettingsFormTests.swift`
- Test: `Tests/SquiggleTests/MenuModelTests.swift`

**Interfaces:**
- Consumes: `Settings`, `RateConstants.refreshIntervalChoices`, `RefreshPolicy.cycleInterval`, `Diagnosis.pacerThrottlesSettings` (TickerCore); `ErrorText` (Task 4); `MenuCommand` (Task 11); `TickerRunner.setUserInterval` (Task 6).
- Produces:
  - `Settings.speedRange`, `Settings.widthRange`, `Settings.rowChoices` — the bounds, named
  - `struct Choice<Value: Equatable>` with `values`, `titles`, `fallback`, `func index(of:) -> Int`, `func value(at:) -> Value`
  - `enum SettingsForm` with `static let rows/interval/scheme/motion: Choice<…>`
  - `@MainActor final class SettingsWindowController: NSWindowController` with `init(settings:onChange:)` and `func apply(_ settings: Settings)`
  - `MenuCommand.settings`
  - `ErrorText.settingsTitle`, `.rowTitles`, `.intervalTitles`, `.schemeTitles`, `.motionTitles`, the six field labels, and `ErrorText.effectiveInterval(userIntervalSeconds:watchlistCount:)`

### R143 — a slider's bounds are the decoder's clamps, named once

`Store.init(from:)` clamps `scrollPointsPerSecond` to `4...200` and `maxVisibleWidth` to `60...1200`, as literals. A slider built to any other range is a setting that appears to work and then silently reverts: drag the width to 1,400, the strip widens, quit, relaunch, and the decoder hands back 1,200 with nothing anywhere reporting that it moved.

So the bounds get names on `Settings` and the decoder uses them, and the window's sliders take their `minValue` and `maxValue` from the same two properties. This is the `Formatting.change` fix from Task 11 in a different costume — one rule, two call sites, and the failure mode of letting them drift is a user-visible lie.

`rowChoices` joins them for the same reason: `rows` is clamped to 1-or-2 on decode, and a segmented control with a third segment would be a control that cannot be used.

### R144 — the effective-interval line is computed, and the spec's example is stale

Spec §4.1 requires Settings to display the honoured cadence "live beside the choice", and gives an example: "Every 1 minute (10 min with 20 symbols)".

Take the requirement and not the number. That example was written when the cycle floored only at `n × 30s`, which is 600 seconds at twenty symbols. `RefreshPolicy.budgetFloor` landed afterwards and floors the same cycle at `20 × 72 = 1,440` seconds, and `cycleInterval`'s own doc comment now says so in as many words: "a 20-symbol watchlist needs ten minutes per pass whatever the user chose, and the budget floor means it needs twenty-four." The spec's parenthetical is the shape of the sentence, not a value to hard-code — and a hard-coded "10 min" would be this codebase's signature defect written deliberately.

So the window calls `RefreshPolicy.cycleInterval` and `ErrorText` phrases the result. Two further details:

- The parenthetical appears **only when the floor actually binds**, and `Diagnosis.pacerThrottlesSettings` is the existing function that answers exactly that question. Asking it rather than comparing two numbers here keeps the app and `squigglectl doctor` incapable of disagreeing about whether a user is throttled.
- The number is computed against `.regular` with Low Power Mode off — the same pair `pacerThrottlesSettings` uses, for the same reason it documents: the quiet multiplier scales the cycle without the user having changed anything, and a label that read "24 min" in the session and "72 min" after hours would look like a bug in the control the user was touching.

- [ ] **Step 1: Write the failing form tests**

`Tests/SquiggleTests/SettingsFormTests.swift`:

```swift
import Foundation
import TickerCore
import Testing
@testable import Squiggle

@Suite("Settings form")
struct SettingsFormTests {

    // MARK: - Choice

    // The whole point of this type: an off-by-one in a segmented control
    // silently swaps two schemes, and nothing else in the app would notice.
    // One round-trip test covers all four controls because there is one
    // mapping.
    @Test("every offered value survives a round trip through its index")
    func valuesRoundTrip() {
        for (index, value) in SettingsForm.interval.values.enumerated() {
            #expect(SettingsForm.interval.index(of: value) == index)
            #expect(SettingsForm.interval.value(at: index) == value)
        }
        for (index, value) in SettingsForm.scheme.values.enumerated() {
            #expect(SettingsForm.scheme.index(of: value) == index)
        }
        for (index, value) in SettingsForm.motion.values.enumerated() {
            #expect(SettingsForm.motion.index(of: value) == index)
        }
        for (index, value) in SettingsForm.rows.values.enumerated() {
            #expect(SettingsForm.rows.index(of: value) == index)
        }
    }

    @Test("a value that is not offered selects the fallback's row")
    func anUnknownValueLandsOnTheFallback() {
        // The hand-edited-file case. `Settings` carries an unknown scheme
        // through verbatim (R119), so the window has to be able to show one.
        let index = SettingsForm.scheme.index(of: "puce")
        #expect(index == SettingsForm.scheme.index(of: SettingsForm.scheme.fallback))
    }

    @Test("an index off the end yields the fallback rather than trapping")
    func anImpossibleIndexIsSurvivable() {
        #expect(SettingsForm.rows.value(at: 99) == SettingsForm.rows.fallback)
        #expect(SettingsForm.rows.value(at: -1) == SettingsForm.rows.fallback)
    }

    // A control whose titles and values have drifted apart shows the wrong
    // label on the right value, which is worse than either alone.
    @Test("every control has exactly as many titles as values")
    func titlesAndValuesAgree() {
        #expect(SettingsForm.rows.values.count == SettingsForm.rows.titles.count)
        #expect(SettingsForm.interval.values.count == SettingsForm.interval.titles.count)
        #expect(SettingsForm.scheme.values.count == SettingsForm.scheme.titles.count)
        #expect(SettingsForm.motion.values.count == SettingsForm.motion.titles.count)
    }

    @Test("every fallback is one of the values it falls back to")
    func theFallbacksAreReachable() {
        #expect(SettingsForm.rows.values.contains(SettingsForm.rows.fallback))
        #expect(SettingsForm.interval.values.contains(SettingsForm.interval.fallback))
        #expect(SettingsForm.scheme.values.contains(SettingsForm.scheme.fallback))
        #expect(SettingsForm.motion.values.contains(SettingsForm.motion.fallback))
    }

    // Spec §4.1 names the four; R119 and R120 name the vocabularies. If any
    // of these drift the control offers something the app cannot honour.
    @Test("the offered values are the ones the spec and the rulings name")
    func theMenusAreTheSpecs() {
        #expect(SettingsForm.interval.values == RateConstants.refreshIntervalChoices)
        #expect(SettingsForm.rows.values == [1, 2])
        #expect(SettingsForm.scheme.values == ["monochrome", "classic", "accessible"])
        #expect(SettingsForm.motion.values == ["scroll", "step"])
    }

    // R143: a slider that can reach a value the decoder clamps is a setting
    // that silently reverts on the next launch.
    @Test("the sliders cannot reach a value the decoder would clamp")
    func theSliderBoundsAreTheDecodersBounds() {
        var settings = Settings()
        settings.scrollPointsPerSecond = Settings.speedRange.upperBound
        settings.maxVisibleWidth = Settings.widthRange.upperBound
        let widest = try? roundTrip(settings)
        #expect(widest?.scrollPointsPerSecond == Settings.speedRange.upperBound)
        #expect(widest?.maxVisibleWidth == Settings.widthRange.upperBound)

        settings.scrollPointsPerSecond = Settings.speedRange.lowerBound
        settings.maxVisibleWidth = Settings.widthRange.lowerBound
        let narrowest = try? roundTrip(settings)
        #expect(narrowest?.scrollPointsPerSecond == Settings.speedRange.lowerBound)
        #expect(narrowest?.maxVisibleWidth == Settings.widthRange.lowerBound)
    }

    private func roundTrip(_ settings: Settings) throws -> Settings {
        let store = Store(schemaVersion: Store.currentSchemaVersion,
                          symbols: [], settings: settings, cooldownUntilEpoch: nil)
        let data = try JSONEncoder().encode(store)
        return try JSONDecoder().decode(Store.self, from: data).settings
    }

    // MARK: - The effective-interval line

    // R144. Not "10 min": `budgetFloor(20)` is 1,440 seconds.
    @Test("twenty symbols on the one-minute setting reports twenty-four minutes")
    func theFloorIsReportedAtItsRealValue() {
        let line = ErrorText.effectiveInterval(userIntervalSeconds: 60, watchlistCount: 20)
        #expect(line.contains("24 min"), line)
    }

    @Test("the parenthetical is absent when the floor does not bind")
    func anUnthrottledSettingReadsPlainly() {
        // One symbol at fifteen minutes: 900s beats both the 30s spacing floor
        // and the 72s budget floor, so the setting is honoured exactly.
        let line = ErrorText.effectiveInterval(userIntervalSeconds: 900, watchlistCount: 1)
        #expect(line.contains("(") == false, line)
    }

    @Test("an empty watchlist is not described as throttled")
    func nothingToFetchIsNotAFloor() {
        let line = ErrorText.effectiveInterval(userIntervalSeconds: 60, watchlistCount: 0)
        #expect(line.contains("(") == false, line)
    }

    @Test("the line names the setting the user chose, whatever the floor does")
    func theChosenIntervalIsAlwaysStated() {
        let line = ErrorText.effectiveInterval(userIntervalSeconds: 60, watchlistCount: 20)
        #expect(line.hasPrefix(ErrorText.intervalTitles[0]), line)
    }
}
```

- [ ] **Step 2: Run them and watch them fail**

```bash
swift test --build-system native --filter SettingsFormTests
```

Expected: compile failure — `cannot find 'SettingsForm' in scope`.

- [ ] **Step 3: Name the bounds in the core**

In `Sources/TickerCore/Store.swift`, add to `Settings` above `init`:

```swift
    /// The bounds `init(from:)` clamps to, named so that a control cannot be
    /// built with a different range (R143). A slider that reaches 1,400 points
    /// is a width the user sets, sees applied, and loses on the next launch,
    /// with nothing anywhere reporting the reversal.
    public static let speedRange: ClosedRange<Double> = 4...200
    public static let widthRange: ClosedRange<Double> = 60...1200
    /// Spec §5.1 offers one row or two. Anything else is a hand-edited file.
    public static let rowChoices: [Int] = [1, 2]
```

Then in `init(from:)`, replace the three clamping lines so they read from these:

```swift
        let speed = finiteOrDefault(.scrollPointsPerSecond, defaults.scrollPointsPerSecond)
        scrollPointsPerSecond = min(max(speed, Settings.speedRange.lowerBound),
                                    Settings.speedRange.upperBound)
```

```swift
        let width = finiteOrDefault(.maxVisibleWidth, defaults.maxVisibleWidth)
        maxVisibleWidth = min(max(width, Settings.widthRange.lowerBound),
                              Settings.widthRange.upperBound)
```

and replace the row clamp, which today reads `rows = (rawRows == 2) ? 2 : 1`:

```swift
        let rawRows = c.lenient(Int.self, .rows, default: defaults.rows)
        rows = Settings.rowChoices.contains(rawRows) ? rawRows : defaults.rows
```

That ternary is not just a hard-coded list — it is a hard-coded *answer*. It sends every unrecognised value to 1, which was the default when it was written and stopped being the default when R118 made it 2. A hand-edited `"rows": 3` therefore decodes to a one-row ticker while `Settings()` gives two, and no test in the suite compares those two paths. Reading the list from `rowChoices` and falling back to `defaults.rows` makes both facts come from one place.

- [ ] **Step 4: Write the form**

`Sources/Squiggle/SettingsForm.swift`:

```swift
import Foundation
import TickerCore

/// A control that offers a fixed list of values, and the two-way mapping
/// between the list and the stored setting.
///
/// One type for all four fixed-choice controls, because the bug these have is
/// always the same bug: an index and a list that disagree by one, which shows
/// the right label on the wrong value and is invisible until someone notices
/// their ticker is the wrong colour. Four controls sharing one mapping means
/// one test finds it.
struct Choice<Value: Equatable> {
    let values: [Value]
    let titles: [String]
    /// Used in both directions when the other side is unreachable: the row to
    /// select for a stored value that is not offered, and the value to report
    /// for an index that does not exist.
    let fallback: Value

    /// The row to select for a stored value. A value this control does not
    /// offer selects the fallback's row — `Settings` carries an unknown
    /// `colorScheme` through verbatim (R119), so the window has to be able to
    /// show a file it does not fully understand without refusing to open.
    func index(of value: Value) -> Int {
        values.firstIndex(of: value) ?? values.firstIndex(of: fallback) ?? 0
    }

    /// The value for a selected row. Total over every `Int`, including the
    /// `-1` an `NSSegmentedControl` reports when nothing is selected.
    func value(at index: Int) -> Value {
        values.indices.contains(index) ? values[index] : fallback
    }
}

/// The four fixed-choice controls in the Settings window, as data.
///
/// Each one's values come from the type that owns them — the spec's interval
/// menu from `RateConstants`, the row count from `Settings` — rather than
/// being listed again here, so that adding a fifth interval widens the popup
/// without anyone remembering to.
enum SettingsForm {
    static let rows = Choice(values: Settings.rowChoices,
                             titles: ErrorText.rowTitles,
                             fallback: 2)

    static let interval = Choice(values: RateConstants.refreshIntervalChoices,
                                 titles: ErrorText.intervalTitles,
                                 fallback: RateConstants.defaultRefreshInterval)

    // R119's vocabulary. Strings and not `ColorScheme`, because this is the
    // mapping to what `Settings` stores, and `Settings` stores a string so
    // that `TickerCore` never learns what a colour is.
    static let scheme = Choice(values: ["monochrome", "classic", "accessible"],
                               titles: ErrorText.schemeTitles,
                               fallback: "monochrome")

    static let motion = Choice(values: ["scroll", "step"],
                               titles: ErrorText.motionTitles,
                               fallback: "scroll")
}
```

- [ ] **Step 5: Give `ErrorText` the window's words**

R129: `ErrorText` owns every sentence, including the rounding inside one. Add to `Sources/Squiggle/ErrorText.swift`:

```swift
    // MARK: - Settings

    static let settingsTitle = "Squiggle Settings"

    static let rowsLabel = "Rows"
    static let intervalLabel = "Refresh"
    // The spec spells §5.3 "Colour", and so does the rest of this project's
    // prose. Deliberate, not an oversight.
    static let schemeLabel = "Colour"
    static let motionLabel = "Motion"
    static let widthLabel = "Width"
    static let speedLabel = "Speed"

    static let rowTitles = ["One", "Two"]
    /// In the order of `RateConstants.refreshIntervalChoices`. `SettingsFormTests`
    /// asserts the two have the same length; nothing can assert they mean the
    /// same thing, so keep them adjacent in any edit.
    static let intervalTitles = ["Every minute", "Every 3 minutes",
                                 "Every 5 minutes", "Every 15 minutes"]
    static let schemeTitles = ["Monochrome", "Classic", "Accessible"]
    static let motionTitles = ["Scroll", "Step"]

    /// Spec §4.1: the resulting cadence, live beside the choice, "so the floor
    /// is never a silent override".
    ///
    /// The parenthetical appears only when a floor actually binds, and
    /// `Diagnosis.pacerThrottlesSettings` is asked rather than re-derived —
    /// it is the same question `squigglectl doctor` reports on, and two
    /// answers to it would be one too many.
    static func effectiveInterval(userIntervalSeconds: Double,
                                  watchlistCount: Int) -> String {
        let chosen = intervalTitles[SettingsForm.interval.index(of: userIntervalSeconds)]
        guard Diagnosis.pacerThrottlesSettings(userIntervalSeconds: userIntervalSeconds,
                                               watchlistCount: watchlistCount) else {
            return chosen
        }
        // R144: `.regular` and Low Power off, matching `pacerThrottlesSettings`
        // exactly — a number that changed after hours would read as a fault in
        // whichever control the user had just touched.
        let cycle = RefreshPolicy.cycleInterval(userIntervalSeconds: userIntervalSeconds,
                                                watchlistCount: watchlistCount,
                                                marketState: .regular,
                                                lowPowerMode: false)
        let symbols = watchlistCount == 1 ? "1 symbol" : "\(watchlistCount) symbols"
        return "\(chosen) (\(minutes(cycle)) with \(symbols))"
    }
```

`ErrorText` already has the private `minutes(_:)` helper from Task 4; this is its second caller. The file needs `import TickerCore` if it does not already have it.

- [ ] **Step 6: Run them and watch them pass**

```bash
swift test --build-system native --filter SettingsFormTests
```

Expected: 11 tests, 0 failures.

- [ ] **Step 7: Build the window**

`Sources/Squiggle/SettingsWindow.swift`:

```swift
import AppKit
import TickerCore

/// Spec build-order step 7, minus launch-at-login (Task 14).
///
/// Built in code (R133). Seven controls do not justify a second UI framework
/// in a menu bar utility, and a storyboard is a file no test can read.
///
/// Every control applies immediately: there is no OK and no Cancel. Spec §4.1
/// requires the effective-interval line to update live beside the choice, and
/// a window that previewed one setting while queueing six others behind a
/// button would be lying about which of them had taken effect.
@MainActor
final class SettingsWindowController: NSWindowController {
    /// Called with the edited settings after every change. The controller
    /// re-renders immediately and persists on a short delay — see
    /// `StatusItemController.settingsChanged`.
    private let onChange: (Settings) -> Void
    private var settings: Settings

    private let rowsControl = NSSegmentedControl()
    private let intervalPopUp = NSPopUpButton()
    private let schemePopUp = NSPopUpButton()
    private let motionControl = NSSegmentedControl()
    private let widthSlider = NSSlider()
    private let speedSlider = NSSlider()
    private let effectiveLabel = NSTextField(labelWithString: "")
    /// The watchlist size the effective-interval line is computed against.
    /// Set by the controller, because the window does not own the watchlist
    /// and the number changes under it when Task 15 adds a symbol.
    var watchlistCount = 0 { didSet { refreshEffectiveLabel() } }

    init(settings: Settings, onChange: @escaping (Settings) -> Void) {
        self.settings = settings
        self.onChange = onChange

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 0),
            // No `.resizable`: an `NSGridView` of six rows has one correct
            // size and dragging its corner can only spoil it.
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = ErrorText.settingsTitle
        // The window is closed and reopened from the menu, not destroyed —
        // `NSWindowController` would otherwise release it out from under the
        // controller that is still holding this object.
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = makeContentView()
        window.center()
        apply(settings)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("R133: built in code, not a xib") }

    /// Push a settings value into the controls. Called at init and whenever
    /// something outside the window changes the document.
    func apply(_ settings: Settings) {
        self.settings = settings
        rowsControl.selectedSegment = SettingsForm.rows.index(of: settings.rows)
        intervalPopUp.selectItem(at:
            SettingsForm.interval.index(of: settings.refreshIntervalSeconds))
        schemePopUp.selectItem(at: SettingsForm.scheme.index(of: settings.colorScheme))
        motionControl.selectedSegment = SettingsForm.motion.index(of: settings.motionMode)
        widthSlider.doubleValue = settings.maxVisibleWidth
        speedSlider.doubleValue = settings.scrollPointsPerSecond
        refreshEffectiveLabel()
    }

    // MARK: - Layout

    private func makeContentView() -> NSView {
        rowsControl.segmentCount = SettingsForm.rows.titles.count
        rowsControl.segmentStyle = .rounded
        rowsControl.trackingMode = .selectOne
        for (index, title) in SettingsForm.rows.titles.enumerated() {
            rowsControl.setLabel(title, forSegment: index)
        }
        rowsControl.target = self
        rowsControl.action = #selector(controlChanged)

        motionControl.segmentCount = SettingsForm.motion.titles.count
        motionControl.segmentStyle = .rounded
        motionControl.trackingMode = .selectOne
        for (index, title) in SettingsForm.motion.titles.enumerated() {
            motionControl.setLabel(title, forSegment: index)
        }
        motionControl.target = self
        motionControl.action = #selector(controlChanged)

        for (popUp, titles) in [(intervalPopUp, SettingsForm.interval.titles),
                                (schemePopUp, SettingsForm.scheme.titles)] {
            popUp.removeAllItems()
            popUp.addItems(withTitles: titles)
            popUp.target = self
            popUp.action = #selector(controlChanged)
        }

        for (slider, range) in [(widthSlider, Settings.widthRange),
                                (speedSlider, Settings.speedRange)] {
            // R143: the decoder's clamps, not numbers typed again here.
            slider.minValue = range.lowerBound
            slider.maxValue = range.upperBound
            // Continuous so the strip previews as the handle moves. The write
            // to disk is coalesced by the controller, not by this.
            slider.isContinuous = true
            slider.target = self
            slider.action = #selector(controlChanged)
        }

        effectiveLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        effectiveLabel.textColor = .secondaryLabelColor

        let grid = NSGridView(views: [
            [label(ErrorText.rowsLabel), rowsControl],
            [label(ErrorText.intervalLabel), intervalPopUp],
            [NSGridCell.emptyContentView, effectiveLabel],
            [label(ErrorText.schemeLabel), schemePopUp],
            [label(ErrorText.motionLabel), motionControl],
            [label(ErrorText.widthLabel), widthSlider],
            [label(ErrorText.speedLabel), speedSlider],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 220
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            container.trailingAnchor.constraint(equalTo: grid.trailingAnchor, constant: 20),
            container.bottomAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
        ])
        return container
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    // MARK: - Changes

    /// One action for all six controls. Reading every control on every change
    /// rather than switching on the sender means a control that is wired up
    /// but forgotten here does nothing visible, instead of writing a stale
    /// value over a fresh one.
    @objc private func controlChanged() {
        settings.rows = SettingsForm.rows.value(at: rowsControl.selectedSegment)
        settings.refreshIntervalSeconds =
            SettingsForm.interval.value(at: intervalPopUp.indexOfSelectedItem)
        settings.colorScheme = SettingsForm.scheme.value(at: schemePopUp.indexOfSelectedItem)
        settings.motionMode = SettingsForm.motion.value(at: motionControl.selectedSegment)
        settings.maxVisibleWidth = widthSlider.doubleValue
        settings.scrollPointsPerSecond = speedSlider.doubleValue
        refreshEffectiveLabel()
        onChange(settings)
    }

    private func refreshEffectiveLabel() {
        effectiveLabel.stringValue = ErrorText.effectiveInterval(
            userIntervalSeconds: settings.refreshIntervalSeconds,
            watchlistCount: watchlistCount)
    }
}
```

- [ ] **Step 8: Add the menu item**

In `Sources/Squiggle/MenuModel.swift`, add the case and its title:

```swift
    case settings
```

```swift
        case .settings: return ErrorText.settings
```

and in `build`, between the two existing commands:

```swift
        items.append(.command(.refreshNow))
        items.append(.command(.settings))
```

In `Tests/SquiggleTests/MenuModelTests.swift`, update the one assertion:

```swift
        #expect(commands == [.refreshNow, .settings, .quit])
```

and add to `commandTitlesComeFromOnePlace`:

```swift
        #expect(MenuCommand.settings.title == ErrorText.settings)
```

- [ ] **Step 9: Open it from the controller**

In `Sources/Squiggle/StatusItemController.swift`:

```swift
    private var settingsWindow: SettingsWindowController?
    private var persistTimer: Timer?
```

Add the selector arm — the `switch` in `selector(for:)` is exhaustive, so it will not build until this is here, which is the point of R130's no-`default:` rule applied to commands:

```swift
        case .settings: return #selector(openSettings)
```

```swift
    @objc private func openSettings() {
        let controller = settingsWindow ?? SettingsWindowController(
            settings: document.settings,
            onChange: { [weak self] edited in self?.settingsChanged(edited) })
        settingsWindow = controller
        controller.watchlistCount = document.symbols.count
        controller.apply(document.settings)
        // An `LSUIElement` app is not in the Dock and is not activated by a
        // menu click, so `makeKeyAndOrderFront` alone puts the window behind
        // whatever the user was working in. This is the one place Squiggle
        // asks to come forward, and it is in direct response to a click.
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }

    private func settingsChanged(_ edited: Settings) {
        document.settings = edited
        // The interval is the one setting the engine holds a copy of.
        runner.setUserInterval(edited.refreshIntervalSeconds)
        render()
        schedulePersist()
    }

    /// A continuous slider fires its action on every pixel of a drag. The JSON
    /// file is the whole of this app's persistence (spec §6) and rewriting it
    /// forty times a second for a number the user is still choosing is a lot
    /// of disk for no benefit — so the write is coalesced to one per gesture.
    /// Half a second, and `stop()` flushes, so the only way to lose an edit is
    /// to kill the process mid-drag.
    private func schedulePersist() {
        persistTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.persist() }
        }
        persistTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
```

In `stop()`, before the other teardown:

```swift
        if persistTimer != nil {
            persistTimer?.invalidate()
            persistTimer = nil
            // An edit made in the last half-second is still only in memory.
            persist()
        }
```

- [ ] **Step 10: Drive every control by hand**

```bash
scripts/package-app.sh && open build/Squiggle.app
```

Open the menu, choose *Settings…*. The window comes to the front — if it opens behind your editor, `NSApp.activate` is missing.

Then, in order:

1. **Rows** — One, then Two. The strip switches between one 13pt row and two 10pt rows as you click, with no relaunch.
2. **Refresh** — step through all four. The grey line underneath changes with each. With one or two symbols it reads plainly; add symbols until it reads *Every minute (24 min with 20 symbols)* at the one-minute setting. It must say **24**, not 10 — that is R144, and a 10 means the number was copied from the spec instead of computed.
3. **Colour** — the three schemes, live, exactly as Task 12's step 8 checked them.
4. **Motion** — Scroll and Step.
5. **Width** — drag the slider. The status item's width follows the handle. Release it, wait a second, and `cat ~/Library/Application\ Support/Squiggle/squiggle.json` shows the new value once — not once per pixel.
6. **Speed** — drag it. The marquee speeds up and slows under the handle; at the far left it is slow but never stopped.
7. Close the window, reopen it. Every control shows what you last set. Quit and relaunch: the same, out of the file this time.

The reversion check R143 exists for:

```bash
pkill -x Squiggle
```

Drag Width fully right, quit the app, relaunch, and open Settings. The handle is still fully right. If it has jumped back a little, the slider's range is wider than the decoder's clamp.

- [ ] **Step 11: Run the whole suite and commit**

```bash
swift test --build-system native
```

```bash
git add Sources/Squiggle/SettingsForm.swift Sources/Squiggle/SettingsWindow.swift Sources/Squiggle/ErrorText.swift Sources/Squiggle/MenuModel.swift Sources/Squiggle/StatusItemController.swift Sources/TickerCore/Store.swift Tests/SquiggleTests/SettingsFormTests.swift Tests/SquiggleTests/MenuModelTests.swift
git commit -m "feat: a settings window that reports the cadence it will actually keep"
```

---

## Task 14: Launch at login

The last control in build-order step 7, and the only one whose value this app does not own.

**Files:**
- Create: `Sources/Squiggle/LaunchAtLogin.swift`
- Modify: `Sources/TickerCore/Store.swift`
- Modify: `Tests/TickerCoreTests/WatchlistStoreTests.swift`
- Modify: `Sources/Squiggle/ErrorText.swift`
- Modify: `Sources/Squiggle/SettingsWindow.swift`
- Test: `Tests/SquiggleTests/LaunchAtLoginTests.swift`

**Interfaces:**
- Consumes: `SettingsWindowController` (Task 13); `ErrorText` (Task 4); the bundle from Task 7.
- Produces:
  - `enum LoginItemState: Equatable, Sendable { case on, off, needsApproval, unavailable }` with `init(status: SMAppService.Status)`
  - `enum LoginItemAction: Equatable { case register, unregister, openSystemSettings, nothing }`
  - `struct LaunchAtLogin` with `read: () -> LoginItemState`, `apply: (LoginItemAction) -> LoginItemState`, `static let system`, `static func action(desired: Bool, current: LoginItemState) -> LoginItemAction`
  - `ErrorText.launchAtLoginLabel`, `.openLoginItems`, `.loginItemNote(for:)`
  - `SettingsWindowController.init(settings:launchAtLogin:onChange:)` — one parameter added

### R145 — `Settings.launchAtLogin` is deleted, not left unwired

Spec §6: launch-at-login "uses `SMAppService`, whose state is owned by the system and read back, not mirrored." `Settings` ships a `launchAtLogin: Bool` that is written to `squiggle.json` and read by nothing.

Leaving it there and simply not reading it is the worse option, because the field is an invitation. It is `Codable`, it is named exactly right, and the next person to touch this window — or this task's implementer on a tired afternoon — will bind the checkbox to it, which works perfectly until the user turns the login item off in System Settings and Squiggle's checkbox goes on claiming it is enabled. The system can change this value without telling the app; a persisted copy is a cache that is never invalidated.

Deleting it is not free, and the cost is worth stating because the implementer will hit it: `launchAtLogin` is the **witness field** in `aWrongTypeInAnySettingCostsThatSettingAndNothingElse`. That test writes one bad setting plus one good one and compares the whole `Settings` value, because without the good one it cannot tell per-field leniency from the container-level leniency wrapping it. Removing the field removes the witness. Use `motionMode` instead — it is orthogonal to every field the table tests, which `colorScheme` is not.

### R146 — the checkbox reports, and re-reports

The control's value is `SMAppService.mainApp.status`, read fresh every time the window becomes key. Not cached in a property, not remembered from what the user clicked.

There is no notification when someone flips Squiggle's switch in System Settings › General › Login Items, so the only honest options are polling and reading on focus. Reading on focus costs one call at the moment the user is looking at the control, and the gap it leaves — the window is already frontmost and they change it in System Settings at the same time — leaves a stale checkbox for as long as it takes to click away and back.

`.requiresApproval` gets its own sentence and its own button rather than being folded into "off". The two states differ in what fixes them: "off" is fixed by clicking the checkbox, and "registered but switched off by the user" is not fixable from inside this app at all — `register()` on an already-registered service does nothing an approval-blocked item needs. A checkbox that silently does nothing when clicked is the specific failure this split prevents.

### R147 — `@unknown default` here is not the banned `default:`

The project rule is no `default:` in a switch over one of this project's own enums, because the compiler should be the exhaustiveness checker when a case is added. `SMAppService.Status` is not ours and is not frozen: Swift *requires* an `@unknown default` arm, and it means the opposite of the banned one — every known case still has to be listed, and the arm catches only values from a future SDK. It is written once, in `LoginItemState.init(status:)`, and maps to `.unavailable`, which is the arm that disables the control rather than guessing.

- [ ] **Step 1: Write the failing tests**

`Tests/SquiggleTests/LaunchAtLoginTests.swift`:

```swift
import ServiceManagement
import Testing
@testable import Squiggle

@Suite("Launch at login")
struct LaunchAtLoginTests {

    @Test("every status the framework defines maps to a state")
    func statusesMap() {
        #expect(LoginItemState(status: .enabled) == .on)
        #expect(LoginItemState(status: .notRegistered) == .off)
        #expect(LoginItemState(status: .requiresApproval) == .needsApproval)
        // No bundle — `swift run`, or a test process. Not an error: the
        // control is simply not operable here.
        #expect(LoginItemState(status: .notFound) == .unavailable)
    }

    // R146: the two off-ish states differ in what fixes them, and the
    // difference is the whole reason they are separate cases.
    @Test("wanting it on registers when it is off and opens Settings when it is blocked")
    func turningItOn() {
        #expect(LaunchAtLogin.action(desired: true, current: .off) == .register)
        #expect(LaunchAtLogin.action(desired: true, current: .needsApproval)
                == .openSystemSettings)
    }

    @Test("wanting it off unregisters from either registered state")
    func turningItOff() {
        #expect(LaunchAtLogin.action(desired: false, current: .on) == .unregister)
        // Registered but switched off by the user: unchecking the box should
        // still remove the pending item, not leave it lying in Login Items.
        #expect(LaunchAtLogin.action(desired: false, current: .needsApproval) == .unregister)
    }

    // `register()` throws when the service is already registered, so asking
    // for what is already true has to be a no-op rather than a call.
    @Test("asking for the state it is already in does nothing")
    func idempotence() {
        #expect(LaunchAtLogin.action(desired: true, current: .on) == .nothing)
        #expect(LaunchAtLogin.action(desired: false, current: .off) == .nothing)
    }

    @Test("nothing is attempted when there is no bundle to register")
    func unavailableIsInert() {
        #expect(LaunchAtLogin.action(desired: true, current: .unavailable) == .nothing)
        #expect(LaunchAtLogin.action(desired: false, current: .unavailable) == .nothing)
    }

    // The checkbox shows what the system will actually do at the next login.
    // `.needsApproval` means it will not launch, so the box is not ticked —
    // the note and the button are what explain the difference.
    @Test("only the enabled state ticks the box")
    func theBoxFollowsTheSystem() {
        #expect(LoginItemState.on.isOn)
        #expect(!LoginItemState.off.isOn)
        #expect(!LoginItemState.needsApproval.isOn)
        #expect(!LoginItemState.unavailable.isOn)
    }

    @Test("the control is operable in every state but the one with no bundle")
    func onlyAMissingBundleDisablesIt() {
        #expect(LoginItemState.on.isEnabled)
        #expect(LoginItemState.off.isEnabled)
        #expect(LoginItemState.needsApproval.isEnabled)
        #expect(!LoginItemState.unavailable.isEnabled)
    }

    // R146: a state whose fix lives outside this app has to say so.
    @Test("the states that need explaining carry a sentence, and the plain ones do not")
    func onlyTheConfusingStatesExplainThemselves() {
        #expect(ErrorText.loginItemNote(for: .on) == nil)
        #expect(ErrorText.loginItemNote(for: .off) == nil)
        #expect(ErrorText.loginItemNote(for: .needsApproval) != nil)
        #expect(ErrorText.loginItemNote(for: .unavailable) != nil)
    }

    @Test("the button appears exactly where clicking the box cannot help")
    func theButtonIsWhereTheAppIsPowerless() {
        #expect(LoginItemState.needsApproval.showsSystemSettingsButton)
        #expect(!LoginItemState.on.showsSystemSettingsButton)
        #expect(!LoginItemState.off.showsSystemSettingsButton)
        #expect(!LoginItemState.unavailable.showsSystemSettingsButton)
    }
}
```

- [ ] **Step 2: Run them and watch them fail**

```bash
swift test --build-system native --filter LaunchAtLoginTests
```

Expected: compile failure — `cannot find 'LoginItemState' in scope`.

- [ ] **Step 3: Write the type**

`Sources/Squiggle/LaunchAtLogin.swift`:

```swift
import AppKit
import ServiceManagement

/// What the system will do at the next login, as this app is allowed to see it.
///
/// Four states and not a `Bool`, because two of them are not "off": one is
/// "registered, and the user has switched it off in System Settings", which
/// this app cannot change, and one is "there is no bundle to register", which
/// is what `swift run` gives you.
enum LoginItemState: Equatable, Sendable {
    case on
    case off
    /// Registered, but switched off by the user in System Settings. It will
    /// not launch, and no API here can change that.
    case needsApproval
    /// No bundle — running from `.build`, or a test process.
    case unavailable

    /// R147: `SMAppService.Status` is an imported, non-frozen enum, so Swift
    /// requires the `@unknown default`. It is the opposite of the `default:`
    /// this project bans: every known case is still listed by name, and this
    /// arm catches only values from an SDK that does not exist yet — for which
    /// "disable the control" is the honest answer.
    init(status: SMAppService.Status) {
        switch status {
        case .enabled: self = .on
        case .notRegistered: self = .off
        case .requiresApproval: self = .needsApproval
        case .notFound: self = .unavailable
        @unknown default: self = .unavailable
        }
    }

    /// Ticked only when the app will actually launch. See R146.
    var isOn: Bool { self == .on }

    var isEnabled: Bool { self != .unavailable }

    var showsSystemSettingsButton: Bool { self == .needsApproval }
}

enum LoginItemAction: Equatable {
    case register
    case unregister
    case openSystemSettings
    case nothing
}

/// The seam between the window and `SMAppService`.
///
/// A struct of closures rather than a protocol: there is exactly one real
/// implementation and the tests do not need a fake — every decision worth
/// testing is in `action(desired:current:)`, which is pure. This exists so
/// that the window never touches `SMAppService` directly, which keeps the
/// registration calls in one file next to the reasons they can fail.
struct LaunchAtLogin {
    var read: () -> LoginItemState
    /// Performs the action and returns the state afterwards, read back from
    /// the system rather than assumed from what was asked (spec §6).
    var apply: (LoginItemAction) -> LoginItemState

    static let system = LaunchAtLogin(
        read: { LoginItemState(status: SMAppService.mainApp.status) },
        apply: { action in
            switch action {
            case .register:
                // Throwing here is not exceptional: an unsigned bundle, a
                // translocated copy running from a quarantined download, or a
                // daemon that is already registered all land here. There is no
                // alert to show (spec §7 allows none), and the state read back
                // below is what the user sees — an unchanged checkbox, which
                // is the truth.
                try? SMAppService.mainApp.register()
            case .unregister:
                try? SMAppService.mainApp.unregister()
            case .openSystemSettings:
                SMAppService.openSystemSettingsLoginItems()
            case .nothing:
                break
            }
            return LoginItemState(status: SMAppService.mainApp.status)
        })

    /// What clicking the checkbox should do, given what the system currently
    /// says. Pure, and the only place the four states turn into calls.
    static func action(desired: Bool, current: LoginItemState) -> LoginItemAction {
        switch current {
        case .unavailable:
            return .nothing
        case .on:
            return desired ? .nothing : .unregister
        case .off:
            return desired ? .register : .nothing
        case .needsApproval:
            // `register()` on an already-registered service throws, and would
            // not clear the user's own switch even if it did not. The only
            // thing that helps is showing them where the switch is.
            return desired ? .openSystemSettings : .unregister
        }
    }
}
```

- [ ] **Step 4: Add the words**

In `Sources/Squiggle/ErrorText.swift`, below the Settings block from Task 13:

```swift
    static let launchAtLoginLabel = "Open at Login"
    static let openLoginItems = "Open Login Items…"

    /// `nil` for the two states a checkbox already explains. The other two
    /// need a sentence because their fix is not in this window (R146).
    static func loginItemNote(for state: LoginItemState) -> String? {
        switch state {
        case .on, .off:
            return nil
        case .needsApproval:
            return "Turned off in System Settings."
        case .unavailable:
            return "Available when Squiggle is running from an app bundle."
        }
    }
```

- [ ] **Step 5: Run them and watch them pass**

```bash
swift test --build-system native --filter LaunchAtLoginTests
```

Expected: 9 tests, 0 failures.

- [ ] **Step 6: Take the field out of the store**

In `Sources/TickerCore/Store.swift`, delete all four lines that mention `launchAtLogin` — the stored property, the `init` parameter, the assignment, and the `lenient` decode. `CodingKeys` is synthesised, so the key goes with the property.

An existing `squiggle.json` keeps working untouched: `init(from:)` reads named keys and ignores everything else, so an old file's `"launchAtLogin": true` is skipped, and the key disappears the next time the file is written. This is the same property R120 relied on to add `motionMode` without bumping the schema version, running in the other direction — so **do not** bump `Store.currentSchemaVersion` here either.

- [ ] **Step 7: Move the witness**

In `Tests/TickerCoreTests/WatchlistStoreTests.swift`, `aWrongTypeInAnySettingCostsThatSettingAndNothingElse` loses its witness field. Replace the table with:

```swift
    // `motionMode` is the witness: it is orthogonal to every field under test
    // here, which `colorScheme` is not, and unlike the `launchAtLogin` this
    // replaces (R145) it is a field the app actually reads.
    let witness = #""motionMode":"step""#
    let cases: [(String, String, Settings)] = [
        (#""refreshIntervalSeconds":"fast""#, witness, Settings(motionMode: "step")),
        (#""rows":"one""#, witness, Settings(motionMode: "step")),
        (#""scrollPointsPerSecond":"quick""#, witness, Settings(motionMode: "step")),
        (#""colorScheme":7"#, witness, Settings(motionMode: "step")),
        (#""maxVisibleWidth":"wide""#, witness, Settings(motionMode: "step")),
        // `motionMode` is the one under test here, so something else
        // witnesses for it.
        (#""motionMode":7"#, #""colorScheme":"classic""#, Settings(colorScheme: "classic")),
    ]
```

The comment above the table explaining what a witness is for stays exactly as it is — it is still true, and it is the reason this table cannot simply drop a column.

Then fix the two remaining constructions that name the field, at roughly `WatchlistStoreTests.swift:33` and `:186`: delete `launchAtLogin: true` from both argument lists. Both are round-trip tests where the field was only ever a non-default value to carry; `motionMode: "step"` does the same job:

```bash
grep -rn "launchAtLogin" Sources/ Tests/ ; echo "(empty is the goal)"
```

- [ ] **Step 8: Run the whole suite**

```bash
swift test --build-system native
```

Expected: PASS. A failure in `SettingsWindow` or `StatusItemController` means a positional `Settings(...)` construction, which is the hazard Task 1 flagged for the same reason — read every hit of `grep -rn "Settings(" Sources/ Tests/` rather than trusting the compiler, since a call passing only leading arguments still type-checks.

- [ ] **Step 9: Put the row in the window**

In `Sources/Squiggle/SettingsWindow.swift`, add the stored properties:

```swift
    private let launchAtLogin: LaunchAtLogin
    private let loginCheckbox = NSButton(checkboxWithTitle: ErrorText.launchAtLoginLabel,
                                         target: nil, action: nil)
    private let loginNote = NSTextField(labelWithString: "")
    private let loginSettingsButton = NSButton(title: ErrorText.openLoginItems,
                                               target: nil, action: nil)
```

Widen `init` to take it, defaulting to the real one so the tests and any future caller are not forced to supply it:

```swift
    init(settings: Settings,
         launchAtLogin: LaunchAtLogin = .system,
         onChange: @escaping (Settings) -> Void) {
        self.launchAtLogin = launchAtLogin
```

In `makeContentView()`, wire the two controls and append the rows:

```swift
        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginCheckboxChanged)
        loginNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        loginNote.textColor = .secondaryLabelColor
        loginSettingsButton.target = self
        loginSettingsButton.action = #selector(openLoginItems)
        loginSettingsButton.bezelStyle = .inline
```

```swift
            [label(ErrorText.speedLabel), speedSlider],
            [NSGridCell.emptyContentView, loginCheckbox],
            [NSGridCell.emptyContentView, loginNote],
            [NSGridCell.emptyContentView, loginSettingsButton],
```

and the behaviour:

```swift
    /// R146: read, never remember. The user can change this in System
    /// Settings while the window is open and nothing tells us.
    private func refreshLoginItem() {
        show(launchAtLogin.read())
    }

    private func show(_ state: LoginItemState) {
        loginCheckbox.state = state.isOn ? .on : .off
        loginCheckbox.isEnabled = state.isEnabled
        let note = ErrorText.loginItemNote(for: state)
        loginNote.stringValue = note ?? ""
        loginNote.isHidden = note == nil
        loginSettingsButton.isHidden = !state.showsSystemSettingsButton
    }

    @objc private func loginCheckboxChanged() {
        // The state is re-read rather than taken from the checkbox, because
        // the checkbox is a report and this is the moment it is most likely
        // to be out of date.
        let current = launchAtLogin.read()
        let wanted = loginCheckbox.state == .on
        show(launchAtLogin.apply(LaunchAtLogin.action(desired: wanted, current: current)))
    }

    @objc private func openLoginItems() {
        show(launchAtLogin.apply(.openSystemSettings))
    }
```

`show(_:)` runs at the end of `apply(_:)` in the same file, so opening the window paints the real state; and in `init`, after `apply(settings)`, add `refreshLoginItem()`.

Finally, re-read on focus. In `init`, after `window.center()`:

```swift
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowBecameKey),
            name: NSWindow.didBecomeKeyNotification, object: window)
```

```swift
    @objc private func windowBecameKey() { refreshLoginItem() }
```

The observer needs no `removeObserver`: the controller outlives the window for the life of the process, and `NotificationCenter` on macOS 11+ releases the registration when the observer deallocates. Filtering on `object: window` matters — without it every window in the app, including the symbol picker Task 15 adds, wakes this handler.

- [ ] **Step 10: Verify it against the real system**

This is the one control that cannot be proven by a test, so it gets the long check. Do it in order.

```bash
scripts/package-app.sh
cp -R build/Squiggle.app /Applications/
open /Applications/Squiggle.app
```

**Run it from `/Applications`, not from `build/`.** A bundle launched from a quarantined download is path-randomised by App Translocation and registers a login item pointing at a path that will not exist next time — the registration appears to succeed and silently never launches anything.

1. Open Settings. The checkbox is unticked and there is no note — status `.notRegistered`.
2. Tick it. Open System Settings › General › Login Items. **Squiggle** is listed under "Open at Login".
3. In System Settings, switch Squiggle **off**. Click back to Squiggle's Settings window. The checkbox is now unticked and the note reads *Turned off in System Settings.* with an *Open Login Items…* button underneath. That is `.requiresApproval`, and it is the state R146 exists for — if the checkbox still shows ticked, `refreshLoginItem()` is not running on focus.
4. Click the checkbox while it is in that state. System Settings comes forward at the Login Items pane. Nothing else changes, which is correct.
5. Untick it from Squiggle. The Login Items entry disappears.
6. Tick it again, then log out and log back in. Squiggle's ticker is in the menu bar without you launching it.

```bash
swift run --build-system native squigglectl doctor
```

7. Run the app from the command line instead of the bundle (`swift run --build-system native Squiggle`). The checkbox is greyed out with *Available when Squiggle is running from an app bundle.* — status `.notFound`. This is the state every developer on this project sees, and it must not look like a bug.

Finally, before deleting the bundle, untick the box. An unregistered-but-deleted login item leaves a ghost entry in System Settings that macOS cannot resolve and the user cannot easily remove.

- [ ] **Step 11: Commit**

```bash
git add Sources/Squiggle/LaunchAtLogin.swift Sources/Squiggle/ErrorText.swift Sources/Squiggle/SettingsWindow.swift Sources/TickerCore/Store.swift Tests/SquiggleTests/LaunchAtLoginTests.swift Tests/TickerCoreTests/WatchlistStoreTests.swift
git commit -m "feat: launch at login, owned by the system and read back"
```

---

## Task 15: The symbol picker

Build-order step 8: "Search-only symbol picker, falling back to trying the typed text as a literal symbol when search returns nothing." Task 11 gave the dropdown a *Remove*; this is the other half.

**Files:**
- Create: `Sources/Squiggle/SymbolPickerModel.swift`
- Create: `Sources/Squiggle/SymbolPickerWindow.swift`
- Modify: `Sources/Squiggle/ErrorText.swift`
- Modify: `Sources/Squiggle/MenuModel.swift`
- Modify: `Sources/Squiggle/StatusItemController.swift`
- Modify: `Sources/Squiggle/AppDelegate.swift`
- Test: `Tests/SquiggleTests/SymbolPickerTests.swift`
- Test: `Tests/SquiggleTests/MenuModelTests.swift`

**Interfaces:**
- Consumes: `SearchResult`, `Symbol`, `TickerError`, `RateConstants.maxWatchlistCount`, `RateConstants.maxSearchResultCount` (TickerCore); `YahooClient.searchResults(query:limit:)` (YahooFeed); `ErrorText.message(for:)` (Task 4 — this task drops its `private`); `MenuCommand` (Task 11); `StatusItemController.document` / `persist()` (R139).
- Produces:
  - `struct SearchSession` with `mutating func begin() -> Int` and `func accepts(_ generation: Int) -> Bool`
  - `struct SymbolPickerModel: Equatable` with `Row`, `rows`, `message`, `isFull`, and `static func build(query:results:error:watchlist:)`
  - `typealias SymbolSearch = @Sendable (String) async throws -> [SearchResult]`
  - `@MainActor final class SymbolPickerWindowController: NSWindowController` with `init(search:watchlist:onAdd:)` and `func setWatchlist(_:)`
  - `MenuCommand.addSymbol`
  - `ErrorText.searchPlaceholder`, `.searchRow(_:)`, `.literalRow(_:)`, `.alreadyWatching`, `.watchlistFull`, `.noMatches`, `.notASymbol`, and `message(for:)` made non-`private`
  - `ErrorText.addSymbol` is **not** new — Task 4 wrote the whole menu vocabulary in one go, this task finally uses it

### R148 — one search per pause, and the newest answer wins

Two rules, both about a text field that fires on every keystroke.

A search per keystroke turns "AAPL" into four requests against an endpoint that has rate-limited this project six times in one day. The field waits 300ms after the last keystroke before searching.

The second rule is the one that is easy to skip and impossible to see in testing: responses can arrive out of order. Type `AA`, then `AAPL`; if the `AA` request is slower, its results land last and the list fills with matches for a query the user has already finished changing. So every search takes a generation number, and a response is applied only if its generation is still the current one. `SearchSession` is that counter, and it is a separate type with its own tests because the bug it prevents shows up perhaps one time in fifty by hand.

The search itself reaches the window as a closure, `SymbolSearch`, not as a `YahooClient`. That keeps `SymbolPickerModel` testable with no transport at all, and it makes the tests structurally incapable of touching Yahoo — which this project's standing rule requires and which a concrete client in the initialiser would leave to the implementer's discipline.

### R149 — the literal candidate is the typed text, verbatim

Symbols are stored and transmitted exactly as Yahoo spells them: `^GSPC`, `BRK-B`, `VOD.L`, `EURUSD=X`. Never upper-cased, never normalised, never trimmed. That rule holds here with no exception, including the whitespace one an implementer will be tempted to carve out.

The temptation is that a pasted `" AAPL "` would become a symbol with spaces in it, which is certainly dead. It cannot happen. `YahooClient.searchResults(query:limit:)` trims the *query* before searching, so a padded `" AAPL "` searches for `AAPL` and comes back with results — and the literal row only appears when search comes back with **none**. Reaching the literal row at all means the trimmed text already matched nothing, so what remains is not a padded real symbol; it is something the user made up, and the honest thing is to try exactly what they typed.

Verbatim is not the same as unvalidated. `Symbol.init?` is failable, and its rejections are the validation: the empty string, anything over 32 characters, anything carrying whitespace, control characters or the URL-unsafe set, and the bare `.` and `..` — because a symbol is interpolated straight into a request path. So the literal row appears only when the typed text can be a symbol at all, and that judgement is the type's rather than a second opinion written here. Typing a company name in full therefore gets no literal row and a different sentence, `ErrorText.notASymbol`: telling someone to try their text as a symbol and then refusing to add it is worse than saying so in the first place.

Trimming the candidate would also break the case it exists for. The literal fallback is for instruments Yahoo's search index does not surface but its quote endpoint answers — index and FX tickers, mostly — and those are precisely the symbols with punctuation that a "clean it up first" step would eat.

### R150 — a full watchlist refuses; a duplicate is shown and inert

The cap is 20 and `Store.init(from:)` enforces it with `.prefix(RateConstants.maxWatchlistCount)`. So a 21st symbol added here would work, render, persist — and vanish at the next launch, silently, with the store deciding which twenty survived. Refusing the add is the only version of this that does not lie.

A symbol already on the watchlist is shown in the results and marked, not filtered out. Hiding it is indistinguishable from search being broken: the user searches for the symbol they are looking at in their own menu bar and gets an empty list.

Both refusals are states of the list, not alerts. Spec §7 allows zero alerts and zero notifications, and that applies to a picker window as much as to the strip.

- [ ] **Step 1: Write the failing tests**

`Tests/SquiggleTests/SymbolPickerTests.swift`:

```swift
import Foundation
import TickerCore
import Testing
@testable import Squiggle

@Suite("Symbol picker")
struct SymbolPickerTests {

    // `Symbol.init?` is failable. Force-unwrapped here and nowhere in the
    // app: every argument below is a literal this file controls, so a `nil`
    // is a typo in the test, and a crash names the line.
    private func result(_ symbol: String, _ name: String = "Some Company",
                        exchange: String = "NMS", kind: String = "EQUITY") -> SearchResult {
        SearchResult(symbol: Symbol(symbol)!, name: name, exchange: exchange, kind: kind)
    }

    // MARK: - SearchSession (R148)

    @Test("a response from the current search is applied")
    func theCurrentGenerationIsAccepted() {
        var session = SearchSession()
        let generation = session.begin()
        #expect(session.accepts(generation))
    }

    // The out-of-order case: `AA` is still in flight when `AAPL` starts, and
    // then answers second. Its results are for a query the user has already
    // moved past.
    @Test("a response from a superseded search is dropped")
    func anOlderGenerationIsRejected() {
        var session = SearchSession()
        let stale = session.begin()
        let current = session.begin()
        #expect(!session.accepts(stale))
        #expect(session.accepts(current))
    }

    // MARK: - Rows

    @Test("results become rows, in the order the search returned them")
    func resultsAreRows() {
        let found = [result("AAPL"), result("AAPU")]
        let model = SymbolPickerModel.build(query: "aap", results: found,
                                            error: nil, watchlist: [])
        #expect(model.rows == [.result(found[0], isAdded: false),
                               .result(found[1], isAdded: false)])
        #expect(model.message == nil)
    }

    // R150: shown, marked, and not addable.
    @Test("a symbol already being watched is listed and flagged")
    func aDuplicateIsVisibleButMarked() {
        let found = [result("AAPL")]
        let model = SymbolPickerModel.build(query: "aapl", results: found,
                                            error: nil, watchlist: [Symbol("AAPL")!])
        #expect(model.rows == [.result(found[0], isAdded: true)])
    }

    // R149. `Symbol` is not upper-cased, not trimmed, not touched.
    @Test("no matches offers the typed text exactly as typed")
    func theLiteralFallbackIsVerbatim() {
        let model = SymbolPickerModel.build(query: "eurusd=x", results: [],
                                            error: nil, watchlist: [])
        #expect(model.rows == [.literal(Symbol("eurusd=x")!)])
    }

    @Test("punctuation in the typed text survives")
    func theLiteralFallbackKeepsPunctuation() {
        let carets = SymbolPickerModel.build(query: "^GSPC", results: [],
                                             error: nil, watchlist: [])
        #expect(carets.rows == [.literal(Symbol("^GSPC")!)])
        let dotted = SymbolPickerModel.build(query: "VOD.L", results: [],
                                             error: nil, watchlist: [])
        #expect(dotted.rows == [.literal(Symbol("VOD.L")!)])
    }

    // `Symbol.init?` rejects whitespace, so a company name typed out in full
    // has no literal to fall back to.
    @Test("text that cannot be a symbol is not offered as one")
    func theLiteralFallbackRespectsSymbolValidation() {
        let model = SymbolPickerModel.build(query: "apple inc", results: [],
                                            error: nil, watchlist: [])
        #expect(model.rows.isEmpty)
        #expect(model.message == ErrorText.notASymbol)
    }

    @Test("an empty field offers nothing at all")
    func nothingTypedIsNotASymbol() {
        let model = SymbolPickerModel.build(query: "", results: [],
                                            error: nil, watchlist: [])
        #expect(model.rows.isEmpty)
        #expect(model.message == nil)
    }

    // Offline is exactly when a user who knows their symbol should still be
    // able to add it — the strip renders a dead symbol as `——` and recovers on
    // its own when the network comes back.
    @Test("a failed search says so and still offers the literal")
    func anErrorDoesNotBlockTheFallback() {
        let model = SymbolPickerModel.build(query: "AAPL", results: [],
                                            error: .offline, watchlist: [])
        #expect(model.rows == [.literal(Symbol("AAPL")!)])
        #expect(model.message == ErrorText.message(for: .offline))
    }

    @Test("no matches and no error says no matches")
    func anEmptyResultSetExplainsItself() {
        let model = SymbolPickerModel.build(query: "zzzz", results: [],
                                            error: nil, watchlist: [])
        #expect(model.message == ErrorText.noMatches)
    }

    // MARK: - The cap (R150)

    @Test("a full watchlist refuses, and says why")
    func twentyIsTheLimit() {
        let full = (0..<RateConstants.maxWatchlistCount).map { Symbol("S\($0)")! }
        let model = SymbolPickerModel.build(query: "aapl", results: [result("AAPL")],
                                            error: nil, watchlist: full)
        #expect(model.isFull)
        #expect(model.message == ErrorText.watchlistFull)
    }

    @Test("a full watchlist still shows what was searched for")
    func refusingIsNotHiding() {
        let full = (0..<RateConstants.maxWatchlistCount).map { Symbol("S\($0)")! }
        let found = [result("AAPL")]
        let model = SymbolPickerModel.build(query: "aapl", results: found,
                                            error: nil, watchlist: full)
        #expect(model.rows == [.result(found[0], isAdded: false)])
    }

    @Test("a watchlist below the cap is not full")
    func nineteenIsFine() {
        let nearly = (0..<(RateConstants.maxWatchlistCount - 1)).map { Symbol("S\($0)")! }
        let model = SymbolPickerModel.build(query: "aapl", results: [result("AAPL")],
                                            error: nil, watchlist: nearly)
        #expect(!model.isFull)
        #expect(model.message == nil)
    }
}
```

- [ ] **Step 2: Run them and watch them fail**

```bash
swift test --build-system native --filter SymbolPickerTests
```

Expected: compile failure — `cannot find 'SearchSession' in scope`.

- [ ] **Step 3: Write the model**

`Sources/Squiggle/SymbolPickerModel.swift`:

```swift
import Foundation
import TickerCore

/// Every search the window issues, so a slow old one cannot overwrite a fast
/// new one (R148).
///
/// Its own type rather than an `Int` on the window, because the rule is worth
/// a name and the race is worth a test: out-of-order responses reproduce by
/// hand perhaps one time in fifty, and never on a fast connection.
struct SearchSession {
    private var current = 0

    mutating func begin() -> Int {
        current += 1
        return current
    }

    func accepts(_ generation: Int) -> Bool { generation == current }
}

/// What the picker shows, given what the search returned.
///
/// Pure, so the whole of the picker's behaviour can be tested without a
/// window, a run loop, or a network — which is also why `SymbolPickerWindow`
/// takes its search as a closure rather than a client.
struct SymbolPickerModel: Equatable {
    enum Row: Equatable {
        case result(SearchResult, isAdded: Bool)
        /// Spec §9 step 8: the typed text, tried as a symbol. Verbatim (R149).
        case literal(Symbol)
    }

    let rows: [Row]
    /// The one line under the list. `nil` when the list speaks for itself.
    let message: String?
    /// The watchlist is at `RateConstants.maxWatchlistCount`; nothing can be
    /// added until something is removed.
    let isFull: Bool

    static func build(query: String,
                      results: [SearchResult],
                      error: TickerError?,
                      watchlist: [Symbol]) -> SymbolPickerModel {
        let full = watchlist.count >= RateConstants.maxWatchlistCount

        // Nothing typed is not a query, is not a symbol, and is not an error.
        guard !query.isEmpty else {
            return SymbolPickerModel(rows: [], message: full ? ErrorText.watchlistFull : nil,
                                     isFull: full)
        }

        if results.isEmpty {
            // R149: exactly what was typed. The trimming happened to the
            // query inside `searchResults`, and reaching here means that
            // trimmed query matched nothing.
            //
            // `Symbol.init?` is failable, and that failure is the whole
            // validation step: text with a space in it is not offered as a
            // symbol, because it cannot be one.
            let candidate = Symbol(query)
            let rows: [Row] = candidate.map { [Row.literal($0)] } ?? []
            let message: String?
            if full {
                message = ErrorText.watchlistFull
            } else if let error {
                // Not "no matches" — the search never ran to completion, and
                // saying otherwise would send the user hunting for a typo.
                message = ErrorText.message(for: error)
            } else {
                message = candidate == nil ? ErrorText.notASymbol : ErrorText.noMatches
            }
            return SymbolPickerModel(rows: rows, message: message, isFull: full)
        }

        let watched = Set(watchlist)
        let rows = results.map { Row.result($0, isAdded: watched.contains($0.symbol)) }
        return SymbolPickerModel(rows: rows,
                                 message: full ? ErrorText.watchlistFull : nil,
                                 isFull: full)
    }
}
```

`Symbol` must be `Hashable` for the `Set` — it is; `Store` already keys dictionaries by it in `WatchLoop.Calendars`.

- [ ] **Step 4: Add the words**

First, drop one keyword. `message(for:)` is `private`, and the picker needs exactly the sentence it produces — the error line without the footer's retry clause bolted on. Do **not** reach for `Rendering.diagnosis(_:)` to avoid this: that is `squigglectl`'s wording, it lives in a different target, and spec §7 gives the app one vocabulary file.

```swift
    static func message(for error: TickerError) -> String {
```

Then add the picker's own words. `addSymbol` is already there from Task 4 — this is the task that finally uses it.

```swift
    // MARK: - Symbol picker

    static let searchPlaceholder = "Company or symbol"
    static let alreadyWatching = "Already watching"
    static let noMatches = "No matches. You can still try it as a symbol."
    /// The sibling of `noMatches` for text `Symbol.init?` refuses outright.
    /// Offering "try it as a symbol" here would be an instruction the Add
    /// button then declines to carry out.
    static let notASymbol = "No matches, and that isn't a symbol Yahoo would accept."
    static let watchlistFull =
        "Watching \(RateConstants.maxWatchlistCount) symbols — remove one to add another."

    /// `AAPL — Apple Inc. (NASDAQ)`. The exchange is dropped rather than shown
    /// empty: Yahoo returns a blank one for some instruments and " ()" reads
    /// as a rendering fault.
    static func searchRow(_ result: SearchResult) -> String {
        let head = "\(result.symbol.raw) — \(result.name)"
        return result.exchange.isEmpty ? head : "\(head) (\(result.exchange))"
    }

    /// The typed text, quoted so its spacing and punctuation are visible —
    /// which is the point, since it is about to be used exactly as written.
    static func literalRow(_ symbol: Symbol) -> String {
        "Try “\(symbol.raw)” as a symbol"
    }
```

- [ ] **Step 5: Run them and watch them pass**

```bash
swift test --build-system native --filter SymbolPickerTests
```

Expected: 14 tests, 0 failures.

- [ ] **Step 6: Build the window**

`Sources/Squiggle/SymbolPickerWindow.swift`:

```swift
import AppKit
import TickerCore

/// The search seam (R148). A closure, so the picker can be built and tested
/// with no transport behind it.
typealias SymbolSearch = @Sendable (String) async throws -> [SearchResult]

/// Search-only, with a literal fallback. Built in code (R133).
@MainActor
final class SymbolPickerWindowController: NSWindowController,
                                          NSTableViewDataSource, NSTableViewDelegate,
                                          NSTextFieldDelegate {
    private let search: SymbolSearch
    private let onAdd: (Symbol) -> Void
    private var watchlist: [Symbol]

    private var session = SearchSession()
    private var debounce: Timer?
    private var model = SymbolPickerModel(rows: [], message: nil, isFull: false)

    private let field = NSTextField()
    private let table = NSTableView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let addButton = NSButton(title: "Add", target: nil, action: nil)

    init(search: @escaping SymbolSearch,
         watchlist: [Symbol],
         onAdd: @escaping (Symbol) -> Void) {
        self.search = search
        self.watchlist = watchlist
        self.onAdd = onAdd

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = ErrorText.addSymbol
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = makeContentView()
        window.center()
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("R133: built in code, not a xib") }

    /// The watchlist changes under this window — Task 11's *Remove* is two
    /// clicks away in the dropdown — and the cap and the "already watching"
    /// marks both depend on it.
    func setWatchlist(_ symbols: [Symbol]) {
        watchlist = symbols
        rebuild(results: lastResults, error: lastError)
    }

    private var lastResults: [SearchResult] = []
    private var lastError: TickerError?

    // MARK: - Layout

    private func makeContentView() -> NSView {
        field.placeholderString = ErrorText.searchPlaceholder
        field.delegate = self

        table.headerView = nil
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row")))
        table.target = self
        table.doubleAction = #selector(addSelected)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageLabel.textColor = .secondaryLabelColor
        addButton.target = self
        addButton.action = #selector(addSelected)
        addButton.keyEquivalent = "\r"

        let footer = NSStackView(views: [messageLabel, NSView(), addButton])
        footer.orientation = .horizontal

        let stack = NSStackView(views: [field, scroll, footer])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Without this the scroll view collapses to its intrinsic height,
        // which for an empty table is zero.
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    // MARK: - Searching

    func controlTextDidChange(_ notification: Notification) {
        // R148: one search per pause in typing, not one per keystroke.
        debounce?.invalidate()
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.runSearch() }
        }
        debounce = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func runSearch() {
        let query = field.stringValue
        guard !query.isEmpty else {
            rebuild(results: [], error: nil)
            return
        }
        let generation = session.begin()
        Task { [weak self] in
            guard let self else { return }
            var found: [SearchResult] = []
            var failure: TickerError?
            do {
                found = try await self.search(query)
            } catch let error as TickerError {
                failure = error
            } catch {
                failure = .offline
            }
            // R148: the query may have moved on while this was in flight.
            guard self.session.accepts(generation) else { return }
            self.rebuild(results: found, error: failure)
        }
    }

    private func rebuild(results: [SearchResult], error: TickerError?) {
        lastResults = results
        lastError = error
        model = SymbolPickerModel.build(query: field.stringValue, results: results,
                                        error: error, watchlist: watchlist)
        render()
    }

    private func render() {
        table.reloadData()
        messageLabel.stringValue = model.message ?? ""
        addButton.isEnabled = addableSymbol() != nil
    }

    /// The symbol the Add button would add, or `nil` when there is nothing to
    /// add — no selection, the cap is reached, or it is already watched.
    private func addableSymbol() -> Symbol? {
        guard !model.isFull else { return nil }
        guard model.rows.indices.contains(table.selectedRow) else { return nil }
        switch model.rows[table.selectedRow] {
        case .result(let found, let isAdded):
            return isAdded ? nil : found.symbol
        case .literal(let symbol):
            return watchlist.contains(symbol) ? nil : symbol
        }
    }

    @objc private func addSelected() {
        guard let symbol = addableSymbol() else { return }
        onAdd(symbol)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { model.rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let text: String
        let dimmed: Bool
        switch model.rows[row] {
        case .result(let found, let isAdded):
            text = isAdded ? "\(ErrorText.searchRow(found)) — \(ErrorText.alreadyWatching)"
                           : ErrorText.searchRow(found)
            dimmed = isAdded
        case .literal(let symbol):
            text = ErrorText.literalRow(symbol)
            dimmed = false
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = dimmed ? .tertiaryLabelColor : .labelColor
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        addButton.isEnabled = addableSymbol() != nil
    }
}
```

- [ ] **Step 7: Hang it off the menu**

In `Sources/Squiggle/MenuModel.swift`, add the case, its title, and the item:

```swift
    case addSymbol
```

```swift
        case .addSymbol: return ErrorText.addSymbol
```

```swift
        items.append(.command(.addSymbol))
        items.append(.command(.refreshNow))
```

In `Tests/SquiggleTests/MenuModelTests.swift`:

```swift
        #expect(commands == [.addSymbol, .refreshNow, .settings, .quit])
```

```swift
        #expect(MenuCommand.addSymbol.title == ErrorText.addSymbol)
```

In `Sources/Squiggle/StatusItemController.swift`, the selector arm and the handler:

```swift
        case .addSymbol: return #selector(openSymbolPicker)
```

```swift
    private var pickerWindow: SymbolPickerWindowController?
```

```swift
    @objc private func openSymbolPicker() {
        let controller = pickerWindow ?? SymbolPickerWindowController(
            search: search,
            watchlist: document.symbols,
            onAdd: { [weak self] symbol in self?.add(symbol) })
        pickerWindow = controller
        controller.setWatchlist(document.symbols)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }

    private func add(_ symbol: Symbol) {
        // The cap is enforced in the picker (R150), and again here, because
        // this is the method that writes the file and the store would
        // otherwise truncate at the next launch and pick the survivors itself.
        guard document.symbols.count < RateConstants.maxWatchlistCount,
              !document.symbols.contains(symbol) else { return }
        document.symbols.append(symbol)
        runner.replaceWatchlist(document.symbols)
        persist()
        pickerWindow?.setWatchlist(document.symbols)
        // A new symbol has no quote yet, so this repaints the strip with its
        // dead-symbol placeholder immediately rather than leaving a gap until
        // the next cycle.
        render()
        // R140's path: ask for a cycle now so the price arrives in seconds
        // rather than at the next deadline, which at 20 symbols is 24 minutes.
        runner.requestImmediateCycle()
        scheduleStep(after: 0)
    }
```

`removeSymbol` (Task 11) gains one line, so the open picker learns about it:

```swift
        pickerWindow?.setWatchlist(document.symbols)
```

The controller needs the search closure. Add `private let search: SymbolSearch` and a parameter on `init`, and in `AppDelegate.applicationDidFinishLaunching` build it from the client the runner already uses:

```swift
        let client = YahooClient()
        let runner = TickerRunner(symbols: document.symbols,
                                  userIntervalSeconds: document.settings.refreshIntervalSeconds,
                                  fetcher: client)
        let controller = StatusItemController(
            runner: runner, store: store, storeURL: url,
            document: document, storeFault: storeFault,
            search: { try await client.searchResults(query: $0,
                                                     limit: RateConstants.maxSearchResultCount) })
```

- [ ] **Step 8: Run the whole suite**

```bash
swift test --build-system native
```

Expected: PASS.

- [ ] **Step 9: Check it by hand**

```bash
scripts/package-app.sh && open build/Squiggle.app
```

This is the one task whose manual check makes real requests, so keep it short and deliberate — Yahoo has rate-limited this project six times in one day, and the debounce is the thing under test as much as the picker is.

1. Open the menu, choose *Add Symbol…*. The window comes forward with an empty list and no message.
2. Type `apple`, slowly. Results appear about a third of a second after you stop typing — **not** after each letter. Select `AAPL` and click *Add*. It appears in the strip within a few seconds, and in `squiggle.json`.
3. Open the picker again and search `apple` again. The `AAPL` row is dimmed and reads *— Already watching*, and *Add* stays disabled while it is selected. This is R150: visible and inert, not hidden.
4. Type `^GSPC`. Yahoo's search may return nothing for it; if so the single row reads *Try “^GSPC” as a symbol*. Add it. The S&P index price appears in the strip — which is the whole reason the literal fallback exists.
5. Type `zzzzqqq`. The message reads *No matches. You can still try it as a symbol.* and the literal row is offered anyway.
6. Turn Wi-Fi off and type something. The message is *No network connection.* and the literal row is still there. Turn Wi-Fi back on.
7. Add symbols until there are twenty. The message becomes *Watching 20 symbols — remove one to add another.*, *Add* is disabled, and searching still lists results. Remove one from the dropdown with the picker still open: the message clears without reopening the window — that is `setWatchlist` being called from `removeSymbol`.

Type quickly into the field and watch the list while you do. It must never flicker back to results for a prefix of what you typed; if it does, `SearchSession` is not being consulted.

- [ ] **Step 10: Commit**

```bash
git add Sources/Squiggle/SymbolPickerModel.swift Sources/Squiggle/SymbolPickerWindow.swift Sources/Squiggle/ErrorText.swift Sources/Squiggle/MenuModel.swift Sources/Squiggle/StatusItemController.swift Sources/Squiggle/AppDelegate.swift Tests/SquiggleTests/SymbolPickerTests.swift Tests/SquiggleTests/MenuModelTests.swift
git commit -m "feat: a search-only symbol picker that still lets you type a symbol"
```

---

## Task 16: Coming back

The obligation ruling R117 carried out of plan 1, discharged: **verify there is no request burst on wake from sleep.** The verification comes first, because what it finds decides whether the second half of this task is a fix or a feature.

**Files:**
- Create: `Tests/TickerCoreTests/MonotonicClockTests.swift`
- Create: `Tests/SquiggleTests/WakeTests.swift`
- Create: `docs/wake-from-sleep-log.md`
- Modify: `Sources/Squiggle/StatusItemController.swift`

**Interfaces:**
- Consumes: `SystemClock`, `RefreshPolicy.isStale`, `RateConstants` (TickerCore); `PauseConditions` (Task 10); `StatusItemController.isStale(atEpoch:)` (Task 12); `TickerRunner.requestImmediateCycle` (Task 11).
- Produces: `StatusItemController.catchUpIfStale()`, called from `applyPause`. No new public types.

### R151 — coming back is one question, and the dim already asks it

Four things put the ticker to sleep and four things wake it: the lid, the lock screen, the screensaver, the notch. Writing a wake-specific handler would be writing one of four, badly — the machine that slept nine hours and the status item that spent nine hours behind the notch present the app with the same problem, which is a price on screen that is older than it should be.

So the rule is: whenever `PauseConditions` stops being paused, ask whether the strip is stale, and if it is, ask for one cycle now. The predicate is `isStale(atEpoch:)` — the *same* call the colour resolver makes to decide whether to dim (Task 12). That identity is the point of the ruling and not an implementation detail. With one predicate the app cannot dim a price it is not also trying to replace, and cannot spend a request behind a strip that looks perfectly live. With two, it can do both, and the second one is invisible: nobody notices a request that did not need making.

It also defuses the objection `applyPause`'s own doc comment raises today, verbatim: *"forcing a step now would turn every unlock into an unscheduled request."* That was correct about an unconditional step and stops being correct here. Unlocking ten seconds after locking finds a strip that is not stale and forces nothing. Only an unlock that finds an already-dimmed strip spends anything, and at that point the user is looking at a number the app has itself marked as one it cannot vouch for. Step 5 rewrites that comment; leaving it to contradict the code beneath it is the single most reliable defect signature this codebase has.

One guard sits in front of the predicate: `lastSuccessEpoch == nil` returns early. `isStale` answers `true` when nothing has ever succeeded, which is true and useless — the ordinary schedule is already retrying as fast as the ladder allows, and a catch-up there would spend tokens against an endpoint that is not answering.

### R152 — the absence of a burst is a property of the clock, and it gets a test

The reason there is no wake burst is one line in `MonotonicClock.swift`:

```swift
    public var nowSeconds: Double { ProcessInfo.processInfo.systemUptime }
```

`systemUptime` stops while the machine is suspended. Everything that could burst is measured against it:

- `RequestPacer.refill()` credits `elapsed / spacing` tokens. Across a nine-hour sleep `elapsed` is a fraction of a second, so both buckets come back holding what they held going in — at most `bucketCapacity` (5) and `dailyBucketCapacity` (20).
- `FeedEngine.cycleDeadline` is a `clock.nowSeconds` value. It does not expire during the sleep, so the engine's first decision on wake is `.sleep`, not `.fetch`.
- `BackoffLadder` and both `CircuitBreaker`s run on the same clock, so a cooldown in force at sleep is still in force at wake. That is the conservative direction and needs no defence.

`RequestPacer`'s own doc comment already records the measurement this rests on, taken on 2026-09-08: across 14.37 hours of real sleep, `ProcessInfo.systemUptime` and `mach_absolute_time` both read 596,619s where `mach_continuous_time` read 648,346s. The clock stopped; the continuous counter did not.

A unit test cannot suspend a machine, so it cannot distinguish `systemUptime` from a `mach_continuous_time` reading — that stays Step 7's job. What a unit test *can* do is fail the day someone swaps the implementation for `Date()`, which is the substitution that actually turns up in a refactor, and which would make every one of the three bullets above false at once. That test is cheap and it is written below.

### R153 — the wake check is instrumented, and its log carries no prices

`squigglectl watch` prints `Rendering.stateLine` on every iteration: `requests N  tokens X.X  network …  contract …  cooldown Ns`. That running request total is exactly the instrument this verification needs, and it exists because plan 1's re-review made `watch` report its own total instead of leaving a reader counting arrow glyphs in the log.

So the check is: leave `watch` running, sleep the Mac, wake it, and read the two `requests` numbers either side of the gap. No new tooling, no new flag, no debug build.

The log file it produces is `docs/wake-from-sleep-log.md`, and it is governed by the same rule as `docs/fixture-capture-log.md`: **no prices, no request bodies, no URL with a query string.** What gets written down is the two request totals, the wall-clock gap, and the verdict. A log that recorded what the ticker was showing at the time would be a persisted quote, which this project does not do anywhere, for any reason.

- [ ] **Step 1: Write the clock test**

`SystemClock` has no test file of its own — plan 1 exercised it only indirectly,
through `RenderingTests`. Create `Tests/TickerCoreTests/MonotonicClockTests.swift`
whole. Free `@Test func`s at file scope, no `@Suite` wrapper: that is what every
one of the twenty-two existing test files in this target does, and a lone suite
struct here would be a new convention introduced by a two-test file.

```swift
import Foundation
import Testing
@testable import TickerCore

// R152. The whole no-burst-on-wake property rests on this clock being the
// one that stops while the machine is suspended. A unit test cannot sleep
// a Mac, so it pins the two things it can: that this is uptime, and that
// it is emphatically not the wall clock.
@Test("the system clock reads uptime, not the wall clock")
func theClockIsNotTheWallClock() {
    let reading = SystemClock().nowSeconds
    #expect(abs(reading - ProcessInfo.processInfo.systemUptime) < 1)
    // Unix epoch seconds are past 1.7 × 10⁹. Uptime reaching that would
    // be 54 years without a reboot.
    #expect(reading < 1_000_000_000)
}

@Test("the system clock moves forward")
func theClockAdvances() {
    let first = SystemClock().nowSeconds
    var spin = 0.0
    for i in 1...200_000 { spin += Double(i) }
    let second = SystemClock().nowSeconds
    #expect(second >= first)
    #expect(spin > 0)   // keeps the loop from being optimised away
}
```

- [ ] **Step 2: Write the catch-up test**

`Tests/SquiggleTests/WakeTests.swift`:

```swift
import Foundation
import TickerCore
import Testing
@testable import Squiggle

// R151's rule, tested where it lives: in `RefreshPolicy`, against the same
// arguments `StatusItemController.isStale(atEpoch:)` passes it.
//
// The controller itself needs a status bar and a run loop, so the assertion
// here is on the predicate rather than on the call — and that is the right
// place for it anyway, because the ruling is that the catch-up and the dim
// share one predicate. A test of the controller could show the catch-up
// firing; only this one shows the two agreeing.

private func wakeStale(agoSeconds: Double, symbols: Int,
                       marketState: MarketState = .regular) -> Bool {
    RefreshPolicy.isStale(lastSuccessEpoch: 10_000 - agoSeconds,
                          nowEpoch: 10_000,
                          userIntervalSeconds: RateConstants.defaultRefreshInterval,
                          watchlistCount: symbols,
                          marketState: marketState,
                          lowPowerMode: false)
}

// A lid closed over lunch. The strip is dimmed, so the catch-up fires.
@Test("an hour asleep leaves a one-symbol strip stale")
func anHourIsStaleAtOneSymbol() {
    #expect(wakeStale(agoSeconds: 3_600, symbols: 1))
}

// The unlock-ten-seconds-later case `applyPause`'s old comment worried about.
// Nothing is dimmed, so nothing is fetched. Negated with `!`, never
// `== false`: `#expect(x == false)` passes whatever `x` is (`ExpectMacroTests`).
@Test("a brief lock leaves nothing stale")
func tenSecondsIsNotStale() {
    #expect(!wakeStale(agoSeconds: 10, symbols: 1))
    #expect(!wakeStale(agoSeconds: 10, symbols: RateConstants.maxWatchlistCount))
}

// Three cycles, not three intervals. At twenty symbols the cycle floors at
// 1,440s, so the threshold is 72 minutes there and nine at one symbol — which
// is why the controller must never compute an age of its own.
@Test("the threshold is three cycles, so it moves with the watchlist")
func theThresholdScalesWithTheWatchlist() {
    #expect(wakeStale(agoSeconds: 1_800, symbols: 1))
    #expect(!wakeStale(agoSeconds: 1_800, symbols: RateConstants.maxWatchlistCount))
    #expect(wakeStale(agoSeconds: 5_000, symbols: RateConstants.maxWatchlistCount))
}

// Overnight, the last close is the right number however old it is — so a
// machine woken at 03:00 fetches nothing.
@Test("a closed market is never stale, however long the sleep")
func aClosedMarketWakesQuietly() {
    #expect(!wakeStale(agoSeconds: 50_000, symbols: 5, marketState: .closed))
}

// The R151 guard. Nothing has ever succeeded, so `isStale` says yes and the
// controller must still not ask for a cycle — the ordinary schedule is already
// retrying as fast as the ladder allows.
@Test("never having succeeded is stale, and is the case the guard catches")
func nothingFetchedYetIsStale() {
    let never = RefreshPolicy.isStale(lastSuccessEpoch: nil,
                                      nowEpoch: 10_000,
                                      userIntervalSeconds: RateConstants.defaultRefreshInterval,
                                      watchlistCount: 1,
                                      marketState: .regular,
                                      lowPowerMode: false)
    #expect(never)
}
```

- [ ] **Step 3: Run both and watch them fail**

Both files hold free `@Test func`s, so `--filter` matches function names rather than a suite name — filter on the names themselves:

```bash
swift test --build-system native --filter "theClock|Stale|Threshold|WakesQuietly"
```

Expected: all seven pass on the first run. Nothing here is red-first, and that is deliberate — both files assert on code plan 1 already built (`SystemClock`, `RefreshPolicy.isStale`), not on anything Step 4 adds.

That makes them characterisation tests rather than TDD, which is the right shape for this task and worth being explicit about: this is a *verification* task whose fix (Step 4) is one guard, and the guard is only safe because these thresholds are what they are. Pinning them first means a later change to `RateConstants.stalenessMultiplier`, `RefreshPolicy.budgetFloor`, or `SystemClock`'s backing call fails here, by name, instead of silently turning every unlock into a fetch.

If any of the seven fails on a clean tree, stop — plan 1 is not in the state this task assumes, and Step 4's guard is unsafe until it is.

- [ ] **Step 4: Write the catch-up**

In `Sources/Squiggle/StatusItemController.swift`, beside `isStale(atEpoch:)`:

```swift
    /// R151. Anything that un-pauses the strip asks the same question: is what
    /// is on screen older than the dim threshold? If it is, take one cycle
    /// now rather than waiting out a deadline measured on a clock that stopped
    /// while the machine was suspended.
    ///
    /// Deliberately the same predicate `colorResolver()` dims with. Two
    /// predicates would let the app dim a price it is not replacing, or fetch
    /// behind a strip that looks live — and the second of those is invisible,
    /// because nobody notices a request that did not need making.
    private func catchUpIfStale() {
        // `isStale` answers `true` when nothing has ever succeeded. True, and
        // useless: the ordinary schedule is already retrying at whatever pace
        // the ladder permits, and a second request would only spend a token.
        guard runner.lastSuccessEpoch != nil else { return }
        guard isStale(atEpoch: Date().timeIntervalSince1970) else { return }
        runner.requestImmediateCycle()
        scheduleStep(after: 0)
    }
```

- [ ] **Step 5: Call it, and rewrite the comment that says not to**

Task 10 gave `applyPause` a doc comment whose second paragraph reads, verbatim:

```
    /// The refresh side needs nothing here. `visibility()` reads
    /// `pauseConditions` on the next scheduled step, and forcing a step now
    /// would turn every unlock into an unscheduled request.
```

That paragraph is now false, and a doc comment contradicting the code beneath it is this codebase's most reliable defect signature — so it is replaced, not appended to. Its *argument* survives intact; what changes is that the argument no longer reaches an unconditional step:

```swift
    /// Spec §5.2: pausing is `speed = 0` with the offset captured, never a
    /// removal — removing and re-adding makes the strip jump.
    ///
    /// Un-pausing also asks the refresh side one question (R151): has the
    /// price on screen outlived the dim threshold? An *unconditional* step
    /// here would turn every unlock into an unscheduled request, which is why
    /// the step sits behind `isStale` rather than behind `isPaused` alone. A
    /// lock and an unlock ten seconds apart find nothing stale and cost
    /// nothing; only an unlock onto an already-dimmed strip spends a request,
    /// and there the app is looking at a number it has itself marked as one
    /// it cannot vouch for.
    private func applyPause(_ conditions: PauseConditions) {
        pauseConditions = conditions
        if conditions.isPaused {
            tickerView.pause()
        } else {
            tickerView.resume()
            catchUpIfStale()
        }
    }
```

- [ ] **Step 6: Run the whole suite**

```bash
swift test --build-system native
```

Expected: PASS.

- [ ] **Step 7: Sleep the machine and count the requests**

This is the verification ruling R117 deferred, and it is the deliverable of this task. It makes real requests, so run it once and write down what it says.

```bash
swift run --build-system native squigglectl watch --interval 60 2>&1 | tee /tmp/wake-audit.log
```

1. Let it run five minutes with a watchlist of three or more symbols. Note the last `requests N` figure and the wall-clock time.
2. Sleep the Mac — the Apple menu's *Sleep*, not just the display. Leave it asleep at least thirty minutes; an hour is better, and overnight is best because it crosses a market-state boundary.
3. Wake it. Do not touch the terminal for two minutes.
4. Read the log across the gap. Four things to check, in order:

   - **The request total.** It must rise by no more than one full pass over the watchlist — three symbols, at most three requests — in the first minute after wake. A jump of dozens is the burst this task exists to rule out, and it would mean the clock assumption in R152 is wrong on this hardware.
   - **The token line.** `tokens` must come back at or below what it read going into the sleep. A bucket that reads full after an hour asleep is `refill()` having credited time that did not pass, and it is the burst's direct cause.
   - **The iteration count.** Expect exactly one extra loop iteration at the moment of wake, and then normal spacing. `Task.sleep(for:)` measures on `ContinuousClock`, which *does* count through a suspend, while `FeedEngine.cycleDeadline` measures on `systemUptime`, which does not — so the sleep returns early, the engine says `.sleep` again for the time genuinely remaining, and the loop settles. One extra `sleep Ns` line is that, and is correct. A tight spin of them is not, and would mean `cycleDeadline` is being reset somewhere it should not be.
   - **The cooldown.** If a cooldown was in force going in, it must still be counting down coming out.

5. Now the app, which uses `Timer` rather than `Task.sleep` and so has the same shape for a different reason — a `Timer` whose fire date passed during the suspend fires once on wake, not once per interval missed. Run the bundle, note the dropdown's footer line, sleep the Mac for an hour, wake it, and open the dropdown immediately:

   - With one symbol the strip is dimmed on wake (an hour is past three cycles) and R151 fires: within a few seconds the dim clears and the footer's "updated" figure resets.
   - With twenty symbols an hour is *not* stale — three cycles is 72 minutes there — so nothing is dimmed and nothing is fetched. That is the ruling working, not a failure. Sleeping for two hours dims it and makes it fetch.
   - Sleep overnight and wake before the open: nothing dims and nothing fetches, because a closed market's last close is the right number however old it is.

- [ ] **Step 8: Write the log**

`docs/wake-from-sleep-log.md`. No prices, no bodies, no URLs with query strings (R153) — the same rule `docs/fixture-capture-log.md` keeps.

```markdown
# Wake-from-sleep audit

Discharges ruling R117's carried obligation: verify no request burst on wake.

## Run 1

- Date: <YYYY-MM-DD>
- Hardware / macOS: <model, version>
- Watchlist size: <n>
- `--interval`: 60

| | Before sleep | After wake |
|---|---|---|
| `requests` | | |
| `tokens` | | |
| `cooldown` | | |

- Wall-clock asleep: <h:mm>
- Extra loop iterations at wake: <count>
- Requests in the first minute after wake: <count>

**Verdict:** <no burst / burst observed — detail>

**App check (R151):** <what the strip and footer did on wake, at what
watchlist size>
```

Fill it in from the run. If the verdict is anything but "no burst", stop and say so — that finding outranks the rest of this plan, because every budget number in plan 1 assumes a clock that stops.

- [ ] **Step 9: Commit**

```bash
git add Sources/Squiggle/StatusItemController.swift Tests/SquiggleTests/WakeTests.swift Tests/TickerCoreTests/MonotonicClockTests.swift docs/wake-from-sleep-log.md
git commit -m "feat: catch up on wake, and prove there is no burst when we do"
```

---
