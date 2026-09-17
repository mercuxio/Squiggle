# Contributing to Squiggle

## Building and testing

**Every `swift` command needs `--build-system native`:**

```bash
swift build --build-system native
swift test  --build-system native
```

Squiggle is developed on a machine with the Command Line Tools and no Xcode,
where the default build system fails. SwiftPM prints a deprecation warning
telling you to drop the flag. On a Command Line Tools-only machine that advice
is wrong.

The same limitation is why the project has its one dependency. `swift-testing`
comes in as an SPM package rather than from the toolchain because, without
Xcode selected, SwiftPM can't find the bundled `Testing` module and
`import Testing` just fails. The project should never add a second dependency.
`squigglectl`'s argument parser stays hand-written rather than pulling in
`swift-argument-parser`.

`@testable import` works on an `executableTarget`, which is how both
`squigglectl` and the app target are tested.

## Don't hit Yahoo from the test suite

`swift test` makes no network requests. The parser is tested against the
responses recorded in `Tests/Fixtures/`, and the refresh policy is tested
against a simulated clock. Don't edit the fixtures by hand, because they're
evidence of what Yahoo actually sent. To capture a new one, use
`squigglectl probe <symbol> --record NAME`.

Go easy on the live endpoint while developing. A 429 from Yahoo applies to
your IP address, only took a few dozen requests over eight minutes to trigger,
and lasted over an hour. A `squigglectl watch` loop left running can lock you
out of your own ticker for the afternoon.

## Never write `== true` or `== false` inside `#expect`

The standalone `swift-testing` 0.99.0 release is built against swift-syntax
600. Under the current compiler, its `#expect` macro gets any comparison wrong
when the left operand is already a `Bool` or `Bool?`: it checks that operand
by itself and drops the comparison.

Nothing tells you this happened. `#expect(x == false)` compiles, reads
correctly, and passes whatever `x` holds.

```swift
#expect(flag == false)                  // never fails, whatever flag holds
#expect(row?.isStale == true)           // likewise
#expect(!flag)                          // checks
```

For an optional, or for anything involving `try`, assign the value to a local
first and assert on that plain name:

```swift
let isStale = rows.first?.isStale ?? true
#expect(!isStale)
```

The same macro also gets `??` wrong inside `#expect`, so do the coalescing in
the `let`, not in the expectation. Trailing closures inside `#expect` have the
same problem, so pass the closure in parentheses.

Only `Bool` and `Bool?` operands are affected. `Int?`, `String?`, enums, and
`nil` comparisons all evaluate correctly.
`boolComparisonsAreInvisibleToTheExpectMacro` in `Tests/TickerCoreTests` pins
the behaviour. If that test ever starts failing, the macro has been fixed and
the workarounds above can be removed.

## The request budget is a test, not a guideline

`RateConstants` holds every rate and timeout in the project, and a test
simulates a worst-case day against the 1,200-request budget. If you change a
constant, run the suite before you change anything else. The constants depend
on each other in ways that aren't obvious: for example, lowering
`spacingSeconds` below 25 pushes the simulated day over budget because of how
the extended-hours multiplier works. The comment on each constant explains
what depends on it.

The request pacer has no bypass. Refresh Now, a wake from sleep, and the menu
bar item becoming visible again all draw from the same bucket. Don't add a
path around it.

## Layering

`TickerCore` is a pure library: no AppKit, no networking, no `UserDefaults`,
and no user-facing strings. Time comes from an injected `MonotonicClock`, never
from `Date()`. The one documented exception is the backoff cooldown deadline,
which is saved as wall-clock time so it survives a relaunch, and is capped when
loaded.

`YahooFeed` holds the only `URLSession` in the package. Text the user sees
lives in `Sources/Squiggle/ErrorText.swift` and
`Sources/squigglectl/Rendering.swift`.

Some rules the app keeps:

- **No alerts, no notifications.** Errors show up in the strip and the
  dropdown.
- **Quotes and credentials are never written to disk.** `squiggle.json` holds
  settings and the watchlist, and nothing else.
- **`squigglectl doctor` never prints a quote, file contents, a URL with a
  query string, or an absolute path**, so its output is always safe to paste
  into an issue.
- **No `default:` in a `switch` over the project's own enums.** When a case is
  added, the compiler should point to every place that needs a decision.

## Style

The codebase has a lot of comments, and they do real work: they explain why a
line is written the way it is, usually because the obvious alternative is
wrong in a way that takes an afternoon to rediscover. Keep that up. A comment
that just repeats the code is noise; a comment that names the trap is the
point.

`docs/specs/2026-09-08-squiggle-design.md` is the final word on behaviour.
When the code and the spec disagree, the spec wins unless you change it
deliberately.

## Pull requests

- There's one branch, `main`. Keep it passing:
  `swift test --build-system native`.
- Say what you checked against the live app, if anything. Occlusion, sleep and
  wake, and the lock screen can't be fully tested by the suite.
- New behaviour needs a test. After writing it, break the code on purpose and
  watch the test fail. Because of the `#expect` bug above, a test you've never
  seen fail hasn't been shown to test anything.
