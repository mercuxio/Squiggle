# Fixture capture log

## Endpoint confirmation (build-order step 1)

- Date: 2026-09-08 12:22 local
- Command: `swift run --build-system native squigglectl quote AAPL --raw`
- Result: 200
- Body size: 1301 bytes
- Notes: No authentication, cookie, or crumb was required. Body began
  `{"chart":{"result":[{"meta":{"currency":"USD","symbol":"AAPL",...` and
  contained `regularMarketPrice`, `chartPreviousClose`, and
  `currentTradingPeriod` as expected. Spec §3.1's `v8/chart` choice is
  confirmed unauthenticated from this machine; nothing further to record.
