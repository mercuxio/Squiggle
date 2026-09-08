# Synthetic fixtures

`search-apple-SYNTHETIC.json` is **hand-written**, not captured from Yahoo. It
stands in for `Tests/Fixtures/yahoo-2026-09-08/search-apple.json`, which
`v1/finance/search?q=` capture attempts could not produce on 2026-09-08 —
every attempt (six that day) returned HTTP 429.

This directory exists so that fact stays visible: nothing here is evidence of
what Yahoo actually sent, unlike `Tests/Fixtures/yahoo-2026-09-08/`, which is.
Do not add hand-written files to that directory, and do not mistake this one
for a capture.

Per Task 15 controller ruling R66, `Tests/TickerCoreTests/YahooSearchDecodingTests.swift`
reads its fixture from here. When a real `search-apple.json` capture lands in
`Tests/Fixtures/yahoo-2026-09-08/`, repoint `YahooSearchDecodingTests.swift`'s
`fixture(_:)` helper back at that directory and delete this one.
