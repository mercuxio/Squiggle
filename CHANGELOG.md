# Changelog

All notable changes to Squiggle are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
