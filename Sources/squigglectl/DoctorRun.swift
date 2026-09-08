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

        // 1. quoteEndpoint — one request, whatever else happens.
        var snapshot: Snapshot?
        var quoteError: TickerError?
        if let aapl = Symbol("AAPL") {
            do {
                snapshot = try await client.snapshot(for: aapl)
            } catch let error as TickerError {
                quoteError = error
            } catch {
                quoteError = .transport(String(describing: error))
            }
        } else {
            // Unreachable — "AAPL" always satisfies `Symbol`'s rules — but
            // `Symbol.init` is failable, so this stays a guard rather than a
            // force-unwrap.
            quoteError = .transport("could not construct the probe symbol")
        }
        let quoteStatus = Diagnosis.status(for: quoteError)
        checks.append(Check(id: .quoteEndpoint, status: quoteStatus))
        print(Rendering.checkLine(Check(id: .quoteEndpoint, status: quoteStatus),
                                  detail: quoteError.map(Rendering.diagnosis)))

        // 2. searchEndpoint — skipped once the quote check is already broken;
        // a second request cannot add information once the API's shape is
        // known to have changed.
        let searchStatus: CheckStatus
        var searchError: TickerError?
        if quoteStatus == .broken {
            searchStatus = .skipped
        } else {
            do {
                _ = try await client.searchResults(query: "apple", limit: 1)
                searchStatus = .ok
            } catch let error as TickerError {
                searchError = error
                searchStatus = Diagnosis.status(for: error)
            } catch {
                let wrapped = TickerError.transport(String(describing: error))
                searchError = wrapped
                searchStatus = Diagnosis.status(for: wrapped)
            }
        }
        checks.append(Check(id: .searchEndpoint, status: searchStatus))
        print(Rendering.checkLine(Check(id: .searchEndpoint, status: searchStatus),
                                  detail: searchError.map(Rendering.diagnosis)))

        // 3. tradingPeriods — free, from the snapshot check 1 already
        // fetched. No second request either way.
        let (tradingStatus, tradingDetail) = Self.evaluateTradingPeriods(snapshot?.tradingPeriod)
        checks.append(Check(id: .tradingPeriods, status: tradingStatus))
        print(Rendering.checkLine(Check(id: .tradingPeriods, status: tradingStatus),
                                  detail: tradingDetail))

        // 4/5. storeFile / storeSchema — one `load()` classifies both.
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
            storeFileDetail = Rendering.diagnosis(.transport(String(describing: error)))
        }
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

        // 7. cooldown — is `cooldownUntilEpoch` in the future?
        let cooldownStatus: CheckStatus
        var cooldownDetail: String?
        if let loadedStore {
            if let until = loadedStore.cooldownUntilEpoch,
               until > Date().timeIntervalSince1970 {
                cooldownStatus = .degraded
                let remaining = Int((until - Date().timeIntervalSince1970).rounded(.up))
                cooldownDetail = "active for another \(remaining)s"
            } else {
                cooldownStatus = .ok
            }
        } else {
            cooldownStatus = .skipped
        }
        checks.append(Check(id: .cooldown, status: cooldownStatus))
        print(Rendering.checkLine(Check(id: .cooldown, status: cooldownStatus), detail: cooldownDetail))

        // 8. budget — the closed-form estimate for the stored settings.
        let budgetStatus: CheckStatus
        var budgetDetail: String?
        if let loadedStore {
            let estimate = Diagnosis.estimatedDailyRequests(
                userIntervalSeconds: loadedStore.settings.refreshIntervalSeconds,
                watchlistCount: loadedStore.symbols.count)
            budgetStatus = estimate > 1_200 ? .degraded : .ok
            budgetDetail = "~\(estimate) requests/day"
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
    private static func evaluateTradingPeriods(
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
    private static func classifyStoreError(
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
