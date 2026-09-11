import Foundation
import TickerCore
import YahooFeed

/// `squigglectl doctor` — one pass over eight checks, at most two network
/// requests, and output safe to paste into a support email (R44: no quote
/// values, no file contents, no URLs with query strings, no absolute
/// filesystem paths).
///
/// Deliberately does not report circuit/bucket state or recent status codes —
/// that state lives only in a running `FeedEngine`'s memory, and persisting
/// it to reach a separate process would turn the store file into a request
/// log. `squigglectl watch` reports it live instead (`Rendering.stateLine`).
struct DoctorRun {
    let client: YahooClient
    let store: FileWatchlistStore
    let storeURL: URL

    init(client: YahooClient = YahooClient(),
         storeURL: URL = FileWatchlistStore.defaultURL(applicationName: "Squiggle")) {
        self.client = client
        self.storeURL = storeURL
        self.store = FileWatchlistStore(url: storeURL)
    }

    func run() async -> Int32 {
        var checks: [Check] = []

        // The store is read first, before anything touches the network, and is
        // still *reported* in its own position further down — the printed
        // order of the eight checks is a contract with the user and does not
        // change here (R80).
        //
        // What changes is that checks 1 and 2 can now see `cooldownUntilEpoch`
        // before they spend a request. A user inside a 429 cooldown running
        // `doctor` because their ticker stopped — the natural and correct
        // thing to do — used to spend two more requests against the throttled
        // IP on every run. Yahoo has rate-limited this project six times in one
        // day; the verb whose job is to diagnose that condition must not deepen
        // it. The cost when the cooldown is a red herring is two `skip` lines
        // instead of two `FAIL` lines, and a wait to find out whether the
        // endpoint is also broken. That is the cheaper mistake.
        var loadedStore: Store?
        var storeFileStatus: CheckStatus = .ok
        var storeFileDetail: String?
        var storeSchemaStatus: CheckStatus = .ok
        var storeSchemaDetail: String?
        do {
            loadedStore = try store.load()
        } catch let error as TickerError {
            let classification = Self.classifyStoreError(error)
            storeFileStatus = classification.file
            storeSchemaStatus = classification.schema
            let detail = Rendering.diagnosis(error)
            if classification.file != .ok { storeFileDetail = detail }
            if classification.schema != .ok, classification.schema != .skipped {
                storeSchemaDetail = detail
            }
        } catch {
            storeFileStatus = .broken
            storeSchemaStatus = .skipped
            storeFileDetail = Rendering.diagnosis(.transport(Rendering.transportFault(for: error)))
        }

        // Read once, used twice: to gate the two network checks below and to
        // report the cooldown as check 7. Two reads of `Date()` could straddle
        // the deadline and have `doctor` skip a request it then reported no
        // cooldown for.
        //
        // The stored deadline is clamped to `RateConstants.maxCooldownSeconds`
        // before it gates anything, the same clamp
        // `BackoffLadder.adoptPersistedCooldown(secondsRemaining:)` applies to
        // the same value, so `doctor` and `watch` agree on what a persisted
        // deadline means. The clamp does not make a corrupt store harmless —
        // `doctor` does not write to the store, so a bad deadline still gates
        // every check below on every run — it only makes the number reported
        // one the app could actually have produced, and lets that corruption
        // be named on check 7 rather than repeated verbatim.
        let now = Date().timeIntervalSince1970
        var cooldownRemaining: Double?
        var cooldownExceededMax = false
        if let until = loadedStore?.cooldownUntilEpoch, until > now {
            let raw = until - now
            if raw > RateConstants.maxCooldownSeconds {
                cooldownRemaining = RateConstants.maxCooldownSeconds
                cooldownExceededMax = true
            } else {
                cooldownRemaining = raw
            }
        }
        let cooldownDetail = cooldownRemaining
            .map { "active for another \(Int($0.rounded(.up)))s" }

        // 1. quoteEndpoint — one request, unless a cooldown says not to.
        var snapshot: Snapshot?
        var quoteError: TickerError?
        var quoteStatus: CheckStatus?
        var quoteDetail: String?
        if let cooldownDetail {
            quoteStatus = .skipped
            quoteDetail = "not asked — backoff \(cooldownDetail)"
        } else if let aapl = Symbol("AAPL") {
            do {
                snapshot = try await client.snapshot(for: aapl)
            } catch let error as TickerError {
                quoteError = error
            } catch {
                quoteError = .transport(Rendering.transportFault(for: error))
            }
        } else {
            // Unreachable — "AAPL" always satisfies `Symbol`'s rules — but
            // `Symbol.init` is failable, so this stays a guard rather than a
            // force-unwrap. Reported as what it is, a symbol that would not
            // construct, rather than as a transport fault: `TransportFault`'s
            // vocabulary is about the network, and widening it to carry a
            // caller's one-off prose is how it stops being a vocabulary.
            quoteError = .invalidSymbol("AAPL")
        }
        let quoteResult = quoteStatus ?? Diagnosis.status(for: quoteError)
        checks.append(Check(id: .quoteEndpoint, status: quoteResult))
        print(Rendering.checkLine(Check(id: .quoteEndpoint, status: quoteResult),
                                  detail: quoteDetail ?? quoteError.map(Rendering.diagnosis)))

        // 2. searchEndpoint — skipped once the quote check is already broken;
        // a second request cannot add information once the API's shape is
        // known to have changed. Skipped under a cooldown for the opposite
        // reason: not because the answer would be uninformative, but because
        // asking is the one thing that makes a throttled IP worse.
        let searchStatus: CheckStatus
        var searchError: TickerError?
        var searchDetail: String?
        if let cooldownDetail {
            searchStatus = .skipped
            searchDetail = "not asked — backoff \(cooldownDetail)"
        } else if quoteResult == .broken {
            searchStatus = .skipped
        } else {
            do {
                _ = try await client.searchResults(query: "apple", limit: 1)
                searchStatus = .ok
            } catch let error as TickerError {
                searchError = error
                searchStatus = Diagnosis.status(for: error)
            } catch {
                let wrapped = TickerError.transport(Rendering.transportFault(for: error))
                searchError = wrapped
                searchStatus = Diagnosis.status(for: wrapped)
            }
        }
        checks.append(Check(id: .searchEndpoint, status: searchStatus))
        print(Rendering.checkLine(Check(id: .searchEndpoint, status: searchStatus),
                                  detail: searchDetail ?? searchError.map(Rendering.diagnosis)))

        // 3. tradingPeriods — free, from the snapshot check 1 already
        // fetched. No second request either way. `evaluateTradingPeriods`
        // only ever sees a real response: when check 1 was skipped (the
        // cooldown gate) or failed, `snapshot` is `nil` and there was no
        // response to have an opinion about, so this reports `.skipped`
        // rather than asking `evaluateTradingPeriods` to explain an absence
        // it never had a request behind.
        let tradingStatus: CheckStatus
        let tradingDetail: String?
        if let snapshot {
            (tradingStatus, tradingDetail) = Self.evaluateTradingPeriods(snapshot.tradingPeriod)
        } else {
            tradingStatus = .skipped
            tradingDetail = "no response to read — see the quote check above"
        }
        checks.append(Check(id: .tradingPeriods, status: tradingStatus))
        print(Rendering.checkLine(Check(id: .tradingPeriods, status: tradingStatus),
                                  detail: tradingDetail))

        // 4/5. storeFile / storeSchema — one `load()` classified both, up at
        // the top of this method where the two network checks could see its
        // cooldown. Only the reporting happens here.
        checks.append(Check(id: .storeFile, status: storeFileStatus))
        print(Rendering.checkLine(Check(id: .storeFile, status: storeFileStatus),
                                  detail: storeFileDetail))
        checks.append(Check(id: .storeSchema, status: storeSchemaStatus))
        print(Rendering.checkLine(Check(id: .storeSchema, status: storeSchemaStatus),
                                  detail: storeSchemaDetail))

        // 6. setAsideFiles — names only, never a path.
        let directory = storeURL.deletingLastPathComponent()
        let base = storeURL.lastPathComponent
        let setAsideNames: [String] = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))
            .map { entries in entries.filter { $0.hasPrefix("\(base).bad-") }.sorted() } ?? []
        let setAsideStatus: CheckStatus = setAsideNames.isEmpty ? .ok : .degraded
        checks.append(Check(id: .setAsideFiles, status: setAsideStatus))
        print(Rendering.checkLine(Check(id: .setAsideFiles, status: setAsideStatus),
                                  detail: setAsideNames.isEmpty ? nil : setAsideNames.joined(separator: ", ")))

        // 7. cooldown — the same deadline checks 1 and 2 were gated on, in the
        // position the brief fixed for it. When the stored deadline exceeded
        // `RateConstants.maxCooldownSeconds`, this is where that gets said:
        // not the raw stored value, not a path, not an epoch, just the fact
        // that the file holds a deadline `BackoffLadder` could not have
        // written and that it has been treated as the maximum instead.
        let cooldownStatus: CheckStatus
        var cooldownCheckDetail = cooldownDetail
        if loadedStore == nil {
            cooldownStatus = .skipped
        } else {
            cooldownStatus = cooldownRemaining == nil ? .ok : .degraded
            if cooldownExceededMax {
                let finding = "the stored deadline exceeds the longest cooldown the app can " +
                    "produce and has been treated as that maximum"
                cooldownCheckDetail = cooldownDetail.map { "\($0); \(finding)" } ?? finding
            }
        }
        checks.append(Check(id: .cooldown, status: cooldownStatus))
        print(Rendering.checkLine(Check(id: .cooldown, status: cooldownStatus), detail: cooldownCheckDetail))

        // 8. budget — the closed-form estimate for the stored settings, and
        // whether the pacer is quietly overriding them (R79).
        //
        // The warning used to read `estimate > 1_200`, which no input could
        // ever satisfy. This comment used to explain that by pointing at a
        // clamp at the end of `Diagnosis.estimatedDailyRequests`, and at the
        // ceiling constant behind it — both of which were deleted in 2861d8e.
        // The explanation outlived them, naming a symbol that no longer exists
        // and describing an implementation that is no longer there, which is
        // exactly the kind of stale cross-module claim that gets believed on
        // the next read. The comparison is still unreachable, for the reason
        // `estimatedDailyRequests` now gives itself: it prices a US equity
        // day, and swept over every reachable input the largest figure it
        // returns is 741 against a budget of 1,200
        // (`theEstimatorCannotReachTheBudgetOnAnyInput` pins that). The
        // condition that can actually occur — and that a support reader needs
        // — is the other one: the user asked for a cadence the floors will not
        // deliver, so their ticker is staler than their settings describe.
        let budgetStatus: CheckStatus
        var budgetDetail: String?
        if let loadedStore {
            let interval = loadedStore.settings.refreshIntervalSeconds
            let count = loadedStore.symbols.count
            let estimate = Diagnosis.estimatedDailyRequests(userIntervalSeconds: interval,
                                                            watchlistCount: count)
            let throttled = Diagnosis.pacerThrottlesSettings(userIntervalSeconds: interval,
                                                             watchlistCount: count)
            budgetStatus = throttled ? .degraded : .ok

            // The number stays either way: it is what the user came to see.
            // Neither branch names a symbol, a path or a URL.
            //
            // It is qualified, though, because the bare figure was a claim the
            // estimator does not make. `estimatedDailyRequests` prices three
            // fixed US equity sessions — 5.5h pre, 6.5h regular, 4h post, and
            // eight hours shut — so "~720 requests/day" printed beside a
            // watchlist of `BTC-USD` describes a day that symbol does not
            // have. Saying which calendar the figure assumes is the whole fix:
            // `doctor` reports on stored settings and cannot see what the
            // symbols trade as, and detecting crypto here would be a second
            // guess in the same place. The 24-hour case is held by mechanism
            // instead — `RefreshPolicy.budgetFloor` and `RequestPacer`'s daily
            // bucket — not by this line.
            let headline = "~\(estimate) requests/day on a US market calendar"

            // Named unconditionally, and named as the *budget* floor, because
            // the spacing floor cannot be the answer here. `cycleInterval`
            // takes `max(max(requested, n × 30), n × 72)`, and `n × 72 > n × 30`
            // for every n ≥ 1, so whenever the floors bind at all the binding
            // term is the budget floor and the cycle is exactly
            // `budgetFloor(n)`. The old wording said "the 30s spacing floor
            // sets the pace here" on every one of those lines — a fixed
            // sentence about a branch that no watchlist size, and no interval,
            // can reach. `theSpacingFloorCanNeverBeTheBindingTerm` sweeps that.
            let floorSeconds = Int(RefreshPolicy.budgetFloor(watchlistCount: count).rounded())
            budgetDetail = throttled
                ? "\(headline); the daily-budget floor holds a full pass to " +
                  "\(floorSeconds)s here, not the refresh interval"
                : headline
        } else {
            budgetStatus = .skipped
        }
        checks.append(Check(id: .budget, status: budgetStatus))
        print(Rendering.checkLine(Check(id: .budget, status: budgetStatus), detail: budgetDetail))

        return Diagnosis.exitCode(for: Diagnosis.overall(checks))
    }

    /// `.degraded` if the periods are absent or do not bracket each other —
    /// each present window non-degenerate (`start < end`) and the present
    /// windows chronologically ordered pre, regular, post.
    static func evaluateTradingPeriods(
        _ period: TradingPeriod?
    ) -> (CheckStatus, String?) {
        guard let period else {
            return (.degraded, "no trading calendar in this response")
        }
        let windows = [period.pre, period.regular, period.post].compactMap { $0 }
        guard !windows.isEmpty else {
            return (.degraded, "no trading calendar in this response")
        }
        for window in windows where window.startEpoch >= window.endEpoch {
            return (.degraded, "trading calendar windows are inconsistent")
        }
        for (earlier, later) in zip(windows, windows.dropFirst())
        where earlier.endEpoch > later.startEpoch {
            return (.degraded, "trading calendar windows are inconsistent")
        }
        let state = period.state(atEpoch: Date().timeIntervalSince1970)
        return (.ok, Rendering.describe(state))
    }

    /// Classifies a `TickerError` thrown by `FileWatchlistStore.load()` into
    /// `storeFile`'s and `storeSchema`'s statuses. Written out in full rather
    /// than defaulted — like `Diagnosis.status(for:)` — so a new
    /// `TickerError` case fails the build here too, not only there.
    static func classifyStoreError(
        _ error: TickerError
    ) -> (file: CheckStatus, schema: CheckStatus) {
        switch error {
        case .storeSchemaUnsupported, .storeVersionUnreadable:
            return (.ok, .degraded)
        case .storeCorrupt, .storeQuarantineFailed:
            return (.degraded, .skipped)
        case .invalidSymbol, .offline, .transport, .rateLimited, .serverError, .unauthorized,
             .symbolNotFound, .emptyBody, .notJSON, .noResult, .missingField, .wrongType,
             .nonFiniteNumber, .negativeValue:
            // `FileWatchlistStore.load()` never actually produces any of
            // these — they belong to the quote and search paths — but the
            // switch stays exhaustive rather than defaulted.
            return (Diagnosis.status(for: error), .skipped)
        }
    }
}
