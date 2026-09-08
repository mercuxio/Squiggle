#!/usr/bin/env bash
# Capture one Yahoo body per symbol into the fixture corpus.
#
# Deliberately slow: 35 seconds between requests, above the 30s spacing floor.
# Yahoo's rate limit is IP-scoped and a 429 has been observed to outlast an
# hour, so a fast capture costs far more time than a slow one.
set -euo pipefail

DIR="${1:-Tests/Fixtures/yahoo-$(date +%Y-%m-%d)}"
mkdir -p "$DIR"

capture() {
  local symbol="$1" name="$2"
  echo "→ $name ($symbol)"
  swift run --build-system native squigglectl quote "$symbol" --raw > "$DIR/$name.json"
  echo "  $(wc -c < "$DIR/$name.json") bytes"
  sleep 35
}

capture "AAPL"      "regular-session"
capture "^GSPC"     "index"
capture "SPY"       "etf"
capture "EURUSD=X"  "currency-pair"
capture "BTC-USD"   "crypto"
capture "VOD.L"     "non-usd-listing"
