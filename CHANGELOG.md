# Changelog

All notable changes to Squiggle are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.4] — 2026-10-08

### Added

- A third display option, Flip. One stock at a time fills the menu bar and
  turns over to the next every two seconds, like a flip clock. The Motion
  choice is greyed out while Flip is on, because Flip is its own motion. With
  Reduce Motion enabled the card fades between stocks instead of turning.

### Changed

- One row and two rows now put an interpunct between one stock and the next,
  so the strip reads as a list rather than as a run of numbers. The dot sits
  inside the space that was already there, so nothing moved and the scroll
  takes exactly as long as it did.

## [1.0.3] — 2026-09-21

### Fixed

- Prices now arrive within seconds of logging in. The app used to open before
  the network was ready. Its first request then failed, and the app waited a
  full refresh interval before it tried again. When a request cannot leave
  the Mac, the app now tries again after 5 seconds. The wait doubles on each
  failure, up to a minute, and a no-internet failure no longer uses up any of
  the request budget.

## [1.0.2] — 2026-09-18

### Changed

- The Settings window is now a grouped form in the same style as the Sniffcast
  settings window. Open at Login is a switch, and the window's foot shows the
  version and where the prices come from.

## [1.0.1] — 2026-09-18

### Fixed

- The app icon no longer sits inside a grey frame on macOS 26 and later. It is
  now an Icon Composer icon, so the system draws the shape and the glass
  lighting itself, with a generated fallback for older systems.

## [1.0.0] — 2026-09-17

First public release.

### Added

- A menu bar ticker in one or two rows, each scrolling on its own, with the
  watchlist split between the rows by how wide each symbol draws.
- **Scroll** and **Step** motion modes. Step is used whenever Reduce Motion is
  on.
- **Monochrome**, **Classic**, and **Accessible** colour schemes. Direction is
  always shown by a glyph as well as colour.
- A dropdown with the watchlist in two columns, one for each menu bar row, and
  a footer with Refresh Now, Add Symbol…, Settings…, and Quit.
- A symbol picker you search, covering stocks, ETFs, indices, currency pairs,
  and crypto, with up to 20 symbols.
- Settings for rows, refresh interval, colour, motion, speed, width, and Open
  at Login.
- `squigglectl`, a command-line tool with `quote`, `watch`, `search`,
  `doctor`, and `probe`.

### Changed

- Quotes are fetched whether the market is open or closed. Earlier builds
  stopped polling overnight and on weekends and waited for the next session,
  and a cold launch on a closed market fetched one symbol and then stopped.
  The daily request cap holds without the overnight pause.
- A cold launch now fetches the whole watchlist in one burst, so the second
  row no longer waits on placeholders for minutes after the first row fills
  in. Requests are still spaced 30 seconds apart after the burst.
- The symbol is drawn a weight heavier than its price and change, both in the
  menu bar and in the dropdown.
