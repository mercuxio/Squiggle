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
