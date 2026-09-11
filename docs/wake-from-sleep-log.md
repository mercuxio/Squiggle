# Wake-from-sleep audit

Discharges ruling R117's carried obligation: verify no request burst on wake.

## Run 1 — NOT YET RUN

This run needs a real machine sleep of at least thirty minutes and makes real
network requests, so it is owed by a human operator rather than by the
implementation. The table below is the form the run fills in.

- Date: <YYYY-MM-DD>
- Hardware / macOS: <model, version>
- Watchlist size: <n>
- `--interval`: 60

| | Before sleep | After wake |
|---|---|---|
| `requests` | | |
| `tokens` | | |
| `cooldown` | | |

- Wall-clock asleep: <h:mm>
- Extra loop iterations at wake: <count>
- Requests in the first minute after wake: <count>

**Verdict:** <not yet run>

**App check (R151):** <not yet run>
