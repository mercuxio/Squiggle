# Squiggle — Design

Date: 2026-09-08
Status: Draft for review

A macOS menu bar stock ticker. One or two rows of scrolling quotes in a
fixed-width status item, a search-only symbol picker, and a settings window.
Self-distributed, not App Store.

## 1. Guiding constraint

Squiggle is a *view*, not a trading tool. It is explicitly not time-critical:
minute-scale staleness is acceptable (three minutes by default, user-
adjustable per §4.1); second-level updates are not a goal.
Every ambiguous decision resolves toward lower idle cost.

This constraint is stated as an assertable budget, not a sentiment:

- Zero network activity while the menu bar is not visible to the user.
- Zero network activity while the market is closed.
- Zero app-side frames during scrolling — Core Animation runs the strip in
  the window server; the app's CPU while animating reads 0.0%.
- Animation capped at 30 fps, so ProMotion does not run the marquee at 120.
- A simulated trading day must issue no more than 1,200 requests, asserted by
  a test (§8.4).

## 2. Architecture

Three targets, mirroring Pitch's layering.

| Target | Kind | Contains |
| --- | --- | --- |
| `TickerCore` | library | Quote model, parsing, scheduling policy, rate limiting, row layout, storage protocol |
| `Squiggle` | executable | AppKit menu bar app, Core Animation strip, settings, picker, all user-facing strings |
| `squigglectl` | executable | Diagnostic CLI: `quote`, `search`, `watch`, `doctor`, `probe --record` |

`TickerCore` rules, inherited from `DisplayCore`:

- No AppKit, SwiftUI, `UserDefaults`, `URLSession`, or user-facing strings.
- No timers and no clocks. Time enters through an injected `MonotonicClock`
  so every scheduling decision is testable in microseconds. Two call sites are
  sanctioned exceptions and nothing else is: `SystemClock`, the production
  conformer the protocol needs, and `FileWatchlistStore.freshStamp()`, which
  reads the wall clock to build the timestamp in a quarantine file's *name*.
  The stamp is never a value the app computes with, and `setAside(stamp:)`
  takes it as a parameter, so it is out of every asserted path — the rule is
  about scheduling reading a clock, and naming a file is not scheduling.
- Networking enters through a `QuoteFetching` seam that returns bytes. The
  core parses; it never fetches.

Dependencies: `swift-testing` only. `swift-tools-version: 6.0`, macOS 14+,
arm64. All builds use `swift build --build-system native` (this machine has
Command Line Tools, no Xcode).

### 2.1 Core types

```swift
protocol QuoteFetching  { func fetch(_ symbol: Symbol) async throws -> Data }
protocol SymbolSearching { func search(_ query: String) async throws -> Data }
protocol WatchlistStoring { func load() throws -> Store; func save(_: Store) throws }

struct Symbol           // Yahoo symbol, stored verbatim
struct Quote            // price, change, changePercent, currency, direction, asOf
enum   Direction        // .up .down .flat .unknown  — no NSColor in the core
struct TradingPeriod    // pre/regular/post windows, epoch-based
struct RefreshPolicy    // pure: (now, lastSuccess, period, visibility, power) -> Duration?
struct RequestPacer     // token bucket, pure, clock-injected
struct BackoffLadder    // decorrelated jitter, pure, clock-injected
struct CircuitBreaker   // pure, clock-injected
struct RowSplitter      // pure width-balanced dealing across rows
struct StripLayout      // segments, offsets, colour roles — a data structure, not pixels
```

### 2.2 App types

`StatusItemController`, `TickerView`, `StripRenderer`, `SettingsWindow`,
`SymbolPickerWindow`, `LaunchAtLogin`, `ErrorText.swift`, `Formatting.swift`.
The single real timer in the system lives in `StatusItemController` and asks
`RefreshPolicy` what to do next.

## 3. Data source

### 3.1 Endpoints

| Purpose | Endpoint |
| --- | --- |
| Quote | `query1.finance.yahoo.com/v8/finance/chart/{symbol}?range=1d&interval=1d` |
| Search | `query1.finance.yahoo.com/v1/finance/search?q={query}` |

`v8/chart` is used in preference to `v7/finance/quote`. Three council members
independently reported that `v7/quote` is now cookie-and-crumb gated and
returns 401 while `v8/chart` and `v1/search` succeed with no authentication.

**This was not independently confirmed.** A verification attempt on 2026-09-08
returned 429 for all three endpoints because prior probing had already
exhausted the IP's budget. The design therefore assumes no crumb handshake
exists, and carries no `CrumbSession` type. If `v8/chart` later requires
authentication, that is a `QuoteFetching` implementation change confined to one
file in the app target, not a core change.

Consequence: **there is no batching.** One request per symbol. Watchlist size
is a direct multiplier on request count, and the cadence in §4 is built around
that fact.

`v8/chart` returns, under `chart.result[0].meta`: `regularMarketPrice`,
`chartPreviousClose`, `regularMarketChangePercent`, `shortName`, `currency`,
`exchangeTimezoneName`, and `currentTradingPeriod.{pre,regular,post}` as epoch
start/end pairs.

### 3.2 Observed behaviour

Recorded 2026-09-08 against `query1.finance.yahoo.com`:

- Rate limiting is real, IP-scoped, and easy to trip — a few dozen requests
  over roughly eight minutes was sufficient.
- The 429 response is `content-type: text/html`, body `Too Many Requests`
  (19 bytes). **It is not JSON.** A parser that assumes a JSON body on error
  will throw the wrong error.
- The 429 response carries **no `Retry-After` header**. Honour it if present;
  do not depend on it.

No authoritative published rate limit exists. The `360/hr` figure circulating
in `yfinance` issues traces to YQL-era documentation, not current policy. All
rate constants live in one table in `TickerCore` commented as *borrowed and
unverified*, the same way Pitch documents its MonitorControl-derived debounce
values.

## 4. Refresh policy

### 4.1 Cadence

Fetch order is round-robin **in marquee order**, so the symbol about to scroll
into view is the freshest. Fetch pacing and display pacing are one schedule.

The refresh interval is a **user setting**, chosen from a fixed menu in
Settings: **1, 3 (default), 5, or 15 minutes.** No free-text field and no
slider — the value has a safety floor beneath it, and a control that silently
declines to honour what you typed is worse than one that offers four honest
choices.

```
spacing        = 30s                              // between any two requests, ever
cycleInterval  = max(userInterval, n × spacing)   // n = watchlist size
```

| Market state | Interval |
| --- | --- |
| Regular session | `cycleInterval` |
| Pre / post | `cycleInterval × 3` |
| Closed | **no polling** — one wake scheduled at `regular.start − 60s` |
| Low Power Mode | `× 3` |
| Menu bar occluded, screen locked, display asleep | **no polling** |

The 30-second spacing floor is a safety property of `RequestPacer`, not a
preference: a 429 from Yahoo was observed on 2026-09-08 to persist for over an
hour (§3.2), so exceeding the limit is far more costly than being slow. The
setting can therefore only ever make Squiggle *quieter* than the floor, never
louder. Settings displays the resulting effective interval live beside the
choice — "Every 1 minute (10 min with 20 symbols)" — so the floor is never a
silent override.

### 4.2 The budget is invariant

Watchlist capped at 20 symbols. Whenever the floor binds — every configuration
except a very short watchlist on the 1-minute setting — the cycle is `30n`
seconds and issues `n` requests, so the request *rate* is exactly one per 30
seconds regardless of both watchlist size and the user's choice:

| Setting | Watchlist | Effective cycle | Regular | Extended | Day total |
| --- | --- | --- | --- | --- | --- |
| 1 min | 1 symbol | 60s | 390 | 160 | ~550 |
| 1 min | 4 symbols | 120s | 780 | 320 | ~1,100 |
| 1 min | 20 symbols | 600s | 780 | 320 | ~1,100 |
| 3 min | 4 symbols | 180s | 520 | 212 | ~730 |
| 15 min | 20 symbols | 900s | 520 | 200 | ~720 |

(6.5-hour regular session, 8 hours combined pre/post.)

**No configuration can exceed ~1,100 requests/day**, or ~120/hour — an order
of magnitude below any plausible limit, arriving evenly spaced rather than in
the bursts that actually trigger a 429. This is what makes the §1 budget
assertable as a single test rather than a per-configuration one.

Market state is read from `currentTradingPeriod` in the payload, cached daily.
**No local exchange calendar ships with Squiggle.** Holidays, half-days, two
DST regimes, per-symbol venues, and crypto's 24-hour session all fall out of
the payload for free. A hand-maintained holiday table would be silently wrong
every Thanksgiving.

The timer is a `DispatchSourceTimer` with `leeway = 0.25 × interval` so macOS
coalesces the wakeup with other system work. The leeway is a larger battery
win than lengthening the interval. Timer phase is randomised per install so
the installed base does not synchronise on the minute.

Sleep cancels the timer; wake triggers one immediate fetch. Unocclusion
triggers one immediate fetch.

### 4.3 Rate limiting and backoff

A token bucket in `TickerCore` gates every request with no bypass — a safety
property, so no bug anywhere can flood. Capacity 5, refill 1 per 30s.

There is **no per-request retry.** The next cycle is the retry.

Failures are classified, not backed off uniformly:

| Failure | Response |
| --- | --- |
| Offline (`NWPathMonitor` unsatisfied) | Do not attempt, do not advance the ladder. Resume on the path edge. |
| 429 | Honour `Retry-After` if present; else decorrelated jitter from 60s, cap 30 min. Halve the bucket for the session (AIMD). |
| 5xx, timeout | Decorrelated jitter from 30s, cap 15 min. |
| 401 / 403 | Authentication assumption broken. 1-hour cooldown; backoff cannot fix it. |
| 200 with unparseable body | **Contract fault, not a network fault.** Separate 1-hour circuit; retrying a parse failure faster buys nothing. |
| 404 / unknown symbol | Symbol marked dead. Dropped from the rotation. Never retried on a timer. |

Decorrelated jitter is `min(cap, random(base, previous × 3))` — full jitter,
never equal jitter, because the whole installed base shares one upstream.

Circuit breaker: five consecutive failed cycles opens the circuit for 30
minutes, then one half-open probe of a single symbol.

**One documented exception to the monotonic-clock rule.** The cooldown
deadline is persisted as *wall-clock*, because it must survive process
termination — otherwise a user who relaunches repeatedly gets the installed
base's IP banned. It is clamped to `now + cap` on load, so a system clock
change cannot strand the app for a year. Everything else remains monotonic.

A plausible browser `User-Agent` is sent; an absent one is blocked.
`allowsExpensiveNetworkAccess = false`.

## 5. Presentation

### 5.1 The strip

One or two rows inside a fixed-width status item, the width set by a slider in
Settings. Two rows is the default: two stacked marquees of roughly 10pt, each
scrolling independently, like two separate tickers. One row uses the full menu
bar height at roughly 13pt and scrolls the whole watchlist as a single strip.

`RowSplitter` deals one watchlist across the available rows as a pure function
balancing them by **rendered width**, not by symbol count. With one row it is
the identity. The assignment is derived at render time and never persisted, so
changing the row count or the watchlist needs no migration.

The strip is pre-rendered into a `CALayer` and driven by a single repeating
`CABasicAnimation`. There is no `CVDisplayLink` and no per-frame timer.
`preferredFrameRateRange` is capped at 30 fps.

Two motion modes, selectable:

- **Scroll** (default) — continuous marquee, speed set by a slider.
- **Step** — cross-fade one page every 4 seconds. One composite per 4s rather
  than 30 per second, and more legible, because the eye does not track moving
  text.

Step is *forced* when Reduce Motion is enabled. Marquees are a vestibular
trigger; this is an accessibility requirement, not a preference.

### 5.2 When animation stops

Animation is the exception, not the default. It stops entirely when:

- the rendered strip already fits the fixed width (the common 2–4 symbol
  case) — the animation is **removed**, not paused;
- `statusItem.button?.window?.occlusionState` is not `.visible` — one hook
  covering the notch, Bartender/Ice, full-screen apps, and Spaces;
- the screen is locked, the screensaver is running, or the display sleeps.

Pausing is `layer.speed = 0` with `timeOffset` captured, so resume is seamless.
Removing and re-adding the animation makes the strip jump.

Animation never stops on a data failure — a frozen bar reads as a crash.
Stale data dims but keeps moving.

### 5.3 Colour

Direction is carried by a **glyph** (`▲ ▼ –`) in every scheme. Colour is
redundant reinforcement, never the sole carrier — WCAG 1.4.1, and red/green is
the canonical deuteranomaly failure. 10pt is where hue discrimination is worst
and the background is the user's wallpaper.

Colour applies to **the delta and percentage only**. The symbol and price
always render in the menu bar's label colour; the symbol is the anchor the eye
lands on and must not move in the colour space.

| Scheme | Up / Down |
| --- | --- |
| Monochrome (default) | label colour; glyph only |
| Classic | `NSColor.systemGreen` / `NSColor.systemRed` |
| Accessible | Okabe–Ito blue / orange |

System semantic colours only, never literal hex — they are already tuned for
appearance and Increase Contrast. `accessibilityDisplayShouldDifferentiateWithoutColor`
forces Monochrome.

`.flat` and `.unknown` are never coloured. `chartPreviousClose == 0` yields
`.unknown`, never `+Inf%`.

A coloured strip cannot be a template image, so the renderer resolves colours
through `statusItem.button.effectiveAppearance` — **not** the app's
appearance, which is independent of the menu bar's — and re-renders on
appearance change.

## 6. Persistence

One file: `~/Library/Application Support/Squiggle/squiggle.json`, holding both
the watchlist and the settings. They are coupled, and "send me your
squiggle.json" must be a complete support artifact.

Ported from Pitch's `FilePresetStore`:

- `schemaVersion: 1`, with the migration switch present and dead on day one.
- Hand-written `init(from:)` using `decodeIfPresent ?? default`.
- `.prettyPrinted` and `.sortedKeys`, written atomically.
- A file with `version > current` is **refused**, never overwritten.
- A corrupt file is moved to `squiggle.json.bad-<ISO8601>`, the session
  continues read-only with defaults, and the menu footer says so.

Symbols are stored verbatim as Yahoo spells them — `^GSPC`, `BRK-B`, `VOD.L`,
`BTC-USD`, `EURUSD=X`. Never normalised, never upper-cased.

Two things are never written to disk:

- **Quotes.** A 14-hour-old price painted as live at launch is the worst
  failure this app can have. Em-dashes for one second are honest.
- **Credentials of any kind** — cookies, crumbs, tokens. The "email me your
  JSON" support policy inherited from Pitch would otherwise become a
  credential-leak channel.

No `UserDefaults` anywhere, including in the app target. Launch-at-login uses
`SMAppService`, whose state is owned by the system and read back, not mirrored.

## 7. Errors

Nothing is at stake in this app. The user is looking at a number, not at an
unreadable screen. So: **zero alerts and zero notifications, ever.** This is a
deliberate break from Pitch, which alerts because a user may be staring at a
display they cannot see.

Three visual states in the bar, and no error text:

| State | Appearance |
| --- | --- |
| Fresh | Normal |
| Stale (> 3 × interval) | Whole strip dims to `tertiaryLabelColor`; prices still shown, still moving |
| Per-symbol dead | That symbol renders `——`, keeping its slot |

No warning badge. A glyph costs a column in a 10pt slot and reads as an alert
that cannot be dismissed.

Detail is one line at the foot of the dropdown, naming the user's move rather
than the diagnosis: "Updated 14 min ago — retrying in 4 min", "Yahoo is
rate-limiting Squiggle. Retrying in 12 min.", "No network connection." Plus a
*Refresh now* item, which still takes a token from the bucket. Offline and
Yahoo-is-failing are distinguished because they imply different user actions.

All wording lives in `Sources/Squiggle/ErrorText.swift`. The core emits typed
errors and carries no strings.

Diagnosis lives in `squigglectl doctor`, mirroring `displayctl doctor`:
resolved trading periods, circuit and bucket state, the last N status codes,
and per-symbol field presence. `squigglectl quote AAPL --raw` prints the body.
This is what makes a bug report actionable, and it is what justifies the third
target existing.

## 8. Testing

`TickerCore` performs no I/O. All four layers below run offline.

### 8.1 Recorded fixtures

`Tests/Fixtures/yahoo-2026-09-08/`, captured unedited: regular session,
pre-market, post-market, weekend, a halted symbol, an index (`^GSPC`), an ETF,
a currency pair, crypto (never CLOSED), a non-USD listing, a newly-listed
symbol with null `chartPreviousClose`, a delisted symbol, a 401 body, and the
**429 body, which is `text/html` and 19 bytes** — not JSON.

Every JSON key path is pinned in one `YahooQuoteDecoding.swift` annotated with
the observation date, so an upstream break is a one-file diff.

### 8.2 Mutation and truncation

Fixtures alone prove only that the payload of one particular day parses.
Shape drift, not downtime, is the real failure mode.

- **Mutation:** loop over every `CodingKey` and emit variants that are
  missing, null, wrong-type, `NaN`, negative, and zero. Each must produce a
  typed error or a well-formed partial — **never a plausible-but-wrong
  number.** `regularMarketPrice` decodes as *required*; a price defaulting to
  0 is exactly the class of silent wrong answer that Pitch's string-literal
  CG key bug was.
- **Truncation:** every truncated prefix of every fixture must throw a typed
  `TickerError` and never trap. A crashing menu bar app cannot be recovered
  without Terminal.
- A `LenientDouble` accepts a number, a string, and `{raw:, fmt:}`, because
  Yahoo returns all three shapes across fields.

### 8.3 Pure policy

`RefreshPolicy`, `RequestPacer`, `BackoffLadder`, `CircuitBreaker`, staleness,
and the pause predicates are all pure functions of `(MonotonicClock, [Outcome])`,
tested in microseconds against a fake clock. `RevertCoordinatorTests` is the
template.

Invariants asserted: never below the spacing floor, never above the cap,
resets on success, cooldown survives a simulated relaunch, clock-change
clamping holds.

### 8.4 Budget as an executable constraint

A test runs 24 simulated hours — including a closed market, an occluded menu
bar, and Low Power Mode — through the injected clock and asserts the total
request count is **≤ 1,200**.

Because the refresh interval is user-configurable, this runs as a **sweep over
the whole configuration space**: every interval choice (1, 3, 5, 15 min) × a
range of watchlist sizes (1, 2, 4, 10, 20). All twenty combinations must hold
the budget, which is the executable form of the §4.2 invariant. A future
setting that lets the user outrun the floor fails this test rather than
reaching a user.

The §1 budget is a test, not a paragraph.

### 8.5 Live verification, outside `swift test`

`squigglectl probe --record` performs one request per endpoint, diffs **key
paths and value types** rather than values, and writes a datestamped fixture.
Human-run, weekly and at release. It is never in the default test suite and
never in CI-on-push: a red build caused by Yahoo is a red build you learn to
ignore.

`StripLayout` is tested as a data structure — segments, offsets, colour roles.
Pixel comparison of macOS text rendering flakes across OS versions.

Pitch's `boolComparisonsAreInvisibleToTheExpectMacro` guard is ported on day
one. The pause predicates are all `Bool`, which is precisely the shape
`#expect(x == false)` silently passes on.

## 9. Build order

No UI until the feed has survived a real trading session.

1. `squigglectl quote AAPL` against `v8/chart` — confirms the endpoint,
   unauthenticated, from this machine.
2. Save the responses as the fixture corpus.
3. Pure `TickerCore`: parser, `RefreshPolicy`, pacer, ladder, breaker,
   `RowSplitter` — with the tests of §8.2–8.4.
4. `squigglectl watch` run across one full trading day, including the close
   and the next open.
5. Static status item — no animation, single row.
6. The Core Animation strip, one and two rows, both motion modes.
7. Width slider, speed slider, refresh interval, row count, colour schemes,
   launch at login.
8. Search-only symbol picker, falling back to trying the typed text as a
   literal symbol when search returns nothing.
9. Packaging: `Info.plist`, icon, `scripts/package-app.sh`, notarised zip.

## 10. Out of scope for 1.0

Company logos in the menu bar (illegible at 10pt, and the bar is a template
surface); logos in the dropdown; charts; alerts and price triggers; portfolio
quantities or P&L; multiple watchlists; a second data source. The
`QuoteFetching` seam exists so a second source is a later addition, not a
rewrite.
