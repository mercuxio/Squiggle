# Squiggle

A macOS menu bar stock ticker. Prices scroll in the menu bar; everything else
lives in the status item's dropdown. No dock icon, no notifications, no alerts.

- `Sources/TickerCore` — the pure decision core: refresh cadence, backoff,
  parsing, persistence. No AppKit, no networking, no clock.
- `Sources/YahooFeed` — the one network client.
- `Sources/Squiggle` — the menu bar app.
- `Sources/squigglectl` — a command-line harness for the same core, used to
  exercise the feed without a UI.

```bash
swift test --build-system native
```

## Installing

> Build the app with `scripts/package-app.sh` and drag `build/Squiggle.app` to `/Applications`.
>
> The bundle is **ad-hoc signed**, not notarized. A copy you built yourself launches normally. A copy that arrives over the network — AirDrop, a download, a shared folder — is quarantined by macOS, and the first launch is refused with *"Squiggle is damaged and can't be opened."* The message is wrong; nothing is damaged. Clear the quarantine flag:
>
> ```bash
> xattr -dr com.apple.quarantine /Applications/Squiggle.app
> ```
>
> Squiggle has no dock icon and no app switcher entry by design (`LSUIElement`). Its whole interface is the menu bar item; quit it from the item's dropdown.
