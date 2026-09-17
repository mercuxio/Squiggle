# Squiggle

A macOS menu bar stock ticker. Quotes scroll past in one or two rows next to
the clock, and everything else is in the status item's dropdown.

Squiggle is built to show you prices, not to trade on. A quote a few minutes
old is fine, and whenever a choice comes down to freshness or cost, it picks
the cheaper option. The scrolling is a single Core Animation layer that the
window server drives, so the app uses no CPU while the strip moves. Nothing is
fetched while you can't see the menu bar, and no setting can push it past
about 1,200 requests a day.

Requires **macOS 14 or later** on **Apple silicon**.

---

## Install

**Download the release.** Get `Squiggle-1.0.0.zip` from
[Releases](https://github.com/mercuxio/Squiggle/releases), unzip it, and drag
`Squiggle.app` into `/Applications`.

The app is ad-hoc signed, not notarized, because I don't pay for an Apple
Developer account. macOS quarantines downloaded apps that aren't notarized, so
the first launch fails with "Squiggle is damaged and can't be opened" or
"cannot be verified". The app isn't damaged. Clear the quarantine flag once:

```bash
xattr -dr com.apple.quarantine /Applications/Squiggle.app
```

Then open it as usual. If you'd rather not run that on a stranger's app, which
is fair, you can build it yourself instead; see [Building](#building).

Squiggle has no Dock icon and doesn't appear in the app switcher. Its whole
interface is the menu bar item, and you quit it from the dropdown.

---

## What it does

- **One or two rows.** Two rows is the default: two stacked marquees about
  10pt tall, each scrolling on its own. One row fills the full menu bar height
  at 13pt. Squiggle splits the watchlist between the rows by how wide each
  symbol draws, not by how many symbols each row gets.
- **Symbol, price, and change.** Each quote shows the symbol, the price, and a
  change marked with `▲`, `▼`, or `–`. The symbol is drawn in a heavier weight
  so it's easy to spot. The arrow always shows the direction, so the colour
  scheme only reinforces it.
- **Motion that stops when nothing needs to move.** If the strip fits in the
  item's width, it doesn't animate at all. It also pauses while the menu bar
  item is hidden (behind the notch, by Bartender or Ice, or under a full-screen
  app), and while the screen is locked, the screensaver is on, or the display
  is asleep. When Reduce Motion is on, **Step** replaces the marquee: one
  cross-fade every four seconds.
- **A dropdown.** It shows your watchlist in two columns, one for each row of
  the menu bar, with the full details of every quote and a button to remove a
  symbol. The footer has Refresh Now, Add Symbol…, Settings…, a link to buy me
  a coffee, and Quit.
- **A symbol picker you search.** Type a company name or a ticker and pick a
  result. Stocks, ETFs, indices, currency pairs, and crypto all work. The
  watchlist holds up to 20 symbols.

Stale quotes are dimmed but keep scrolling, because a frozen bar looks like a
crash. There are no alerts and no notifications.

### Settings

- **Rows**: one or two.
- **Refresh**: every 1, 3 (the default), 5, or 15 minutes. Requests are
  always at least 30 seconds apart, so a long watchlist can stretch the
  interval you picked. The setting shows the interval you'll actually get
  right next to your choice, for example "10 min with 20 symbols".
- **Colour**: **Monochrome** (the default), **Classic** (green and red), or
  **Accessible** (blue and orange from the Okabe–Ito palette). Colour applies
  only to the change. The symbol and price always use the menu bar's own text
  colour. If *Differentiate without colour* is on, Squiggle uses Monochrome.
- **Motion**: **Scroll** or **Step**, plus a **Speed** slider.
- **Width**: how much menu bar space the ticker takes up.
- **Open at Login**, via `SMAppService`. If macOS is waiting for you to
  approve the login item, the setting says so and links to Login Items.

Settings and the watchlist are saved in one JSON file,
`~/Library/Application Support/Squiggle/squiggle.json`. Quotes are never
written to disk.

## Where the prices come from

Squiggle uses Yahoo Finance's public chart and search endpoints, which need no
API key and no account. They're also unofficial: Yahoo publishes no rate limit
and can change them without notice. Squiggle is careful with them for that
reason. A rate-limit block from Yahoo applies to your whole IP address and has
been seen to last over an hour.

- Requests go one at a time, spaced out through a token bucket that no code
  path can skip, with a hard daily cap.
- Nothing is fetched while the menu bar item is hidden, the screen is locked,
  or the display is asleep.
- Failures are handled by type. A rate limit (429) respects `Retry-After`,
  backs off with jitter for up to 30 minutes, and halves the request rate for
  the rest of the session. A server error backs off for up to 15 minutes. An
  authorization failure or a response Squiggle can't parse waits an hour. A
  symbol Yahoo doesn't recognize is dropped from the rotation.
- After five failed cycles in a row, Squiggle stops trying for 30 minutes.
- Nothing is retried per request; the next cycle is the retry.

Prices can be delayed, and they may be wrong. Don't trade on them.

## `squigglectl`

The same core as a command-line tool, for checking what the feed is doing
without the menu bar app.

```
squigglectl quote <symbol> [--raw]
squigglectl watch [SYMBOL...] [--interval N] [--cycles N]
squigglectl search <QUERY...> [--limit N]
squigglectl doctor
squigglectl probe <symbol> [--record NAME]
```

```bash
squigglectl quote AAPL
squigglectl watch AAPL MSFT --cycles 4
squigglectl search berkshire hathaway --limit 5
squigglectl doctor
```

`doctor` runs eight checks, sending at most two requests, and never prints
quotes, file contents, or paths. That makes its output safe to paste into an
issue. `watch` prints a live line with the backoff and circuit breaker state. `probe` sends one request and compares the
response with the recorded fixtures, to catch Yahoo changing its response
format.

Run `squigglectl help` for all the options.

## Building

```bash
swift build --build-system native -c release
./scripts/package-app.sh
```

`package-app.sh` puts together `build/Squiggle.app`. SwiftPM only produces a
bare executable and has no idea what an app bundle is, so the script builds
the folder layout, `Info.plist`, icon, and signature itself. The signature is
ad-hoc: good enough to run the app yourself, not good enough to distribute it.
Distribution would need a Developer ID and notarization.

Drag `build/Squiggle.app` into `/Applications` and launch it. There's no Dock
icon because the app is an `LSUIElement` agent; the menu bar item is the whole
interface.

## Layout

| Path | What lives there |
| --- | --- |
| `Sources/TickerCore` | The decision core: refresh policy, request pacing, backoff and circuit breakers, response parsing, row splitting, persistence. No AppKit, no networking, no wall clock, and no user-facing strings. |
| `Sources/YahooFeed` | The only `URLSession` in the package. |
| `Sources/Squiggle` | The menu bar app. Everything runs on `@MainActor`. |
| `Sources/squigglectl` | The CLI: hand-written argument parsing and text output. |
| `Tests/Fixtures` | Yahoo responses recorded live, used to test the parser offline. |
| `Tools/GenerateIcon.swift` | Draws the app icon. |
| `docs/specs/` | The design spec, which is the final word on behaviour. |

`TickerCore` never sleeps and never checks the time. Every decision is a pure
function that gets the current time from a monotonic clock passed in, so a
whole simulated trading day of requests runs in milliseconds. That's how the
request budget is tested rather than just promised.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md), especially the `--build-system native`
flag, which every `swift` command needs on a machine with only the Command
Line Tools, and a bug in the test framework that quietly turns assertions into
no-ops.

```bash
swift test --build-system native
```

## Status

Version 1.0.0. The test suite passes, and the app is in daily use against live
Yahoo data.

Releases include an ad-hoc signed `Squiggle.app` in a zip; see
[Install](#install) for the one command that gets it past Gatekeeper.

Squiggle isn't affiliated with or endorsed by Yahoo.

## License

[MIT](LICENSE).
