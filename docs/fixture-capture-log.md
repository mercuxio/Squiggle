# Fixture capture log

## Endpoint confirmation (build-order step 1)

- Date: 2026-09-08 12:22 local
- Command: `swift run --build-system native squigglectl quote AAPL --raw`
- Result: 200
- Body size: 1301 bytes
- Notes: No authentication, cookie, or crumb was required. The body had the
  expected `chart.result[0].meta` shape and carried `regularMarketPrice`,
  `chartPreviousClose` and `currentTradingPeriod`. Spec §3.1's `v8/chart`
  choice is confirmed unauthenticated from this machine. Response content is
  deliberately described, not quoted: spec §6 keeps quote data out of the
  repository so this log stays safe to paste into a support email.

## Fixture corpus capture (build-order step 2)

- Date: 2026-09-08, 00:31–00:35 ET (local machine time 12:31–12:35)
- Command: `./scripts/capture-fixtures.sh`, run once, writing to
  `Tests/Fixtures/yahoo-2026-09-08/` — six sequential
  `swift run --build-system native squigglectl quote <SYMBOL> --raw` calls
  with 35s spacing between requests
- Market state: closed (00:3x ET is well before the 04:00 ET pre-market open)
- Results: 6/6 requests succeeded; every body began `{"chart":`; no 429 or
  other non-200 outcome was observed
- Byte counts: regular-session.json 1302, index.json 1295, etf.json 1327,
  currency-pair.json 1278, crypto.json 1281, non-usd-listing.json 1275
- `overnight-closed.json` (1302 bytes) is a `cp` of `regular-session.json`
  from that same AAPL request — not a second fetch — because the run fell
  outside 09:30–16:00 ET
- `regular-session.json` is therefore presently a closed-market stand-in, not
  a live regular-session capture; see "Corpus status" below for the
  recapture this owes
- `429-body.html` (17 bytes) and `401-body.json` (90 bytes) were hand-built
  from the shapes recorded in spec §3.2, not captured live; see
  `401-body.NOT-CAPTURED.md` for the latter's provenance note

## Search-endpoint capture attempts

- 2026-09-08, four attempts across the day (three during the Task 5 corpus
  run, one after Task 8). Every one returned HTTP 429 from
  `query1.finance.yahoo.com`. `search-apple.json` remains UNCAPTURED.
- The 429 is IP-scoped and has outlasted the whole working day. Retries are
  event-driven, not on a cadence: the next one happens before Task 15, which
  is the first task that needs the fixture. Task 15 blocks rather than
  fabricates it.

## Rate-limit body: reconstruction confirmed against a live capture

- Date: 2026-09-08, on the fourth search attempt above
- Result: 429 with a 19-byte `text/html` body
- The body is `Too Many Requests` followed by CRLF, byte for byte. The
  hand-built `429-body.html` (17 bytes, CRLF stripped) was therefore an
  accurate reconstruction of the content, and the plan's note that "the
  observed 19 included CRLF" is confirmed.
- The genuine bytes are now committed as `429-body-live.txt`. The
  reconstruction is left untouched: a fixture is a record of what arrived,
  and rewriting one in place destroys the record. Both files are decoded by
  tests, so a decoder that trims before deciding "is this JSON?" fails one.

## Corpus status

Captured:
- [x] regular-session (AAPL)
- [x] index (^GSPC)
- [x] etf (SPY)
- [x] currency-pair (EURUSD=X)
- [x] crypto (BTC-USD)
- [x] non-usd-listing (VOD.L)
- [x] 429-body.html — hand-built from the shape recorded in spec §3.2
- [x] 429-body-live.txt — captured live; confirms the reconstruction
- [x] overnight-closed.json — only if the capture ran outside 09:30-16:00 ET
- [ ] 401-body.json — RECONSTRUCTED, not captured

Still owed (rate-limit-gated, NOT clock-gated — retry it on its own):
- [ ] search-apple.json — `v1/finance/search?q=apple`. Six attempts across
      2026-09-08 returned 429 (see the retry log below); the endpoint
      remained rate-limited through Task 15's dispatch. Under ruling R66,
      Task 15 did **not** block on the missing capture: it proceeded against
      a clearly-labelled synthetic fixture in `Tests/Fixtures/synthetic/`
      (see that directory's README) rather than stalling the queue. That
      fixture is not evidence of what Yahoo sent and does not retire this
      line — `search-apple.json` stays owed until a real capture lands, at
      which point `YahooSearchDecodingTests.swift`'s `fixture(_:)` helper
      repoints at it and the synthetic file is deleted.

Still owed (clock-gated; collect during the Task 19 trading day):
- [ ] regular-session — RECAPTURE during a live session if the corpus was
      taken outside 09:30-16:00 ET; the held file is a closed-market stand-in
- [ ] pre-market — capture AAPL between 04:00 and 09:30 ET
- [ ] post-market — capture AAPL between 16:00 and 20:00 ET
- [ ] weekend — capture AAPL on a Saturday; `currentTradingPeriod` should
      still resolve and the market state should read closed
- [ ] crypto-while-equities-closed — capture BTC-USD on that same Saturday;
      it must NOT read closed. This is the fixture that proves no local
      exchange calendar is needed.
- [ ] newly-listed with null chartPreviousClose — opportunistic
- [ ] delisted symbol — opportunistic
- [ ] halted symbol — opportunistic; may never arrive

Tests must not skip on a missing owed fixture. They are written against the
captured set; each owed fixture gets its test when it lands.

## Search-endpoint retry #5 (controller, before Task 16)

- 2026-09-08, taken under ruling R13 immediately before the next dispatch.
  Same request the app builds: `query1.finance.yahoo.com`,
  `/v1/finance/search`, the single `q` item, `YahooClient.defaultUserAgent`,
  `Accept: application/json`. **HTTP 429.** `search-apple.json` remains
  UNCAPTURED after five attempts.
- The response body is byte-for-byte identical to `429-body-live.txt`
  (`Too Many Requests` followed by CRLF, 19 bytes). That earlier capture came
  from the `v8/finance/chart` endpoint; this one from `v1/finance/search`, on
  a later request. Yahoo's 429 body is therefore uniform across both endpoints
  Squiggle uses, not per-endpoint — which is what the rate-limit tests assume.
- Ruling R54: Task 16 runs before Task 15 rather than the queue stalling.
  Task 16 depends on nothing Task 15 produces. The next retry is taken
  immediately before Task 15, buying one task's elapsed time.

## Search-endpoint retry #6 (controller, before Task 15)

- 2026-09-08, taken under ruling R13. Same request the app builds:
  `query1.finance.yahoo.com`, `/v1/finance/search`, the single `q` item,
  `YahooClient.defaultUserAgent`, `Accept: application/json`. **HTTP 429**,
  19 bytes, identical in length to every prior 429 from both endpoints.
  `search-apple.json` remains UNCAPTURED after six attempts.
- Ruling R66: Task 15 proceeds against a clearly-labelled synthetic fixture in
  `Tests/Fixtures/synthetic/` rather than stalling the queue. R7's instruction
  to report BLOCKED rested on the claim that the task's tests assert on real
  Yahoo relevance ordering; an audit of all twelve found that none does.
- `search-apple.json` stays on the owed list below, to be captured during the
  Task 19 trading day from the user's own network.

## `squigglectl probe --record` supersedes ad hoc capture (Task 18)

- 2026-09-08. Every fixture above was captured by hand, one request at a
  time, outside the built tool. Task 18 adds `squigglectl probe <symbol>
  --record`, which fetches once, refuses to overwrite a directory that
  already holds a capture for the day, writes the body to
  `Tests/Fixtures/yahoo-<date>/chart-<symbol>.json`, and appends a bullet
  to this log itself — so this file no longer needs a human to remember to
  update it after a capture.
- Going forward, a fixture refresh (the recaptures still owed below, and any
  future one) should go through `--record` rather than a hand-run script,
  so the log entry and the file it describes are never out of sync.
- Ruling R76 (Task 18): this task implemented and tested `--record` entirely
  against the recorded fixtures already in `Tests/Fixtures/` — no network
  request was made while building it, and no fixture in this repository was
  captured, replaced, or otherwise touched. The first live use of
  `--record` is Task 19's human-run session.
