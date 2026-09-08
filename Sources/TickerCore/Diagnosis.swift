/// Which check produced a result. A code, not a sentence: `TickerCore` vends
/// no user-facing strings, so `squigglectl` and the app each supply their own
/// wording for the same diagnosis.
public enum CheckID: String, CaseIterable, Sendable {
    case quoteEndpoint
    case searchEndpoint
    case tradingPeriods
    case storeFile
    case storeSchema
    case setAsideFiles
    case cooldown
    case budget
}

public enum CheckStatus: Equatable, Sendable {
    case ok
    /// Working, but not right now — throttled, offline, one bad symbol.
    /// Waiting or fixing the input resolves it.
    case degraded
    /// Waiting cannot help. Either the API changed shape or it started
    /// demanding credentials Squiggle deliberately does not hold.
    case broken
    /// Not run, usually because an earlier check made it pointless.
    case skipped
}

public struct Check: Equatable, Sendable {
    public let id: CheckID
    public let status: CheckStatus

    public init(id: CheckID, status: CheckStatus) {
        self.id = id
        self.status = status
    }
}

public enum Diagnosis {
    public static func status(for error: TickerError?) -> CheckStatus {
        guard let error else { return .ok }
        if error.isContractFault { return .broken }

        switch error {
        case .unauthorized:
            // Spec §3.1. If Yahoo starts demanding a crumb, Squiggle's whole
            // premise is gone; this is never a transient blip.
            return .broken
        case .offline, .transport, .rateLimited, .serverError,
             .symbolNotFound, .invalidSymbol:
            return .degraded
        case .storeSchemaUnsupported, .storeVersionUnreadable,
             .storeCorrupt, .storeQuarantineFailed:
            // Persistence faults. The watchlist is unreadable, but the feed
            // itself is answering — degraded, not broken.
            return .degraded
        case .emptyBody, .notJSON, .noResult, .missingField, .wrongType,
             .nonFiniteNumber, .negativeValue:
            // Every one of these was already returned above by the
            // `isContractFault` check, so this arm is unreachable by design.
            // It is written out anyway, in place of a `default:`, so that the
            // compiler is the exhaustiveness checker: the sweep test below
            // can only fail *after* someone adds a case, whereas a build
            // error arrives while they are still adding it.
            return .broken
        }
    }

    public static func overall(_ checks: [Check]) -> CheckStatus {
        // Zero checks means the run itself fell over. "ok" would be a lie.
        guard !checks.isEmpty else { return .broken }
        if checks.contains(where: { $0.status == .broken }) { return .broken }
        if checks.contains(where: { $0.status == .degraded }) { return .degraded }
        return .ok
    }

    public static func exitCode(for status: CheckStatus) -> Int32 {
        switch status {
        case .ok, .skipped: return 0
        case .degraded: return 1
        case .broken: return 2
        }
    }

    /// The closed-form version of Task 12's simulation, for showing the user
    /// what their settings cost. Both must agree: if the sweep's worst case
    /// ever exceeds this, one of the two is wrong.
    ///
    /// A single blanket "16 active hours at the regular rate" version of this
    /// (treating pre/regular/post as one undifferentiated stretch) over-counts
    /// badly: at 60s × 20 symbols it comes to 1,920 — over the 1,200/day budget
    /// spec §4.2 sets, and over what `BudgetSweepTests`' second-by-second
    /// simulation actually measures for the same inputs (1,160). The gap is
    /// the quiet multiplier: pre- and post-market run at a third of the
    /// regular cadence, and folding them into one undifferentiated span throws
    /// that away. So this splits the day into the same three sessions
    /// `BudgetSweepTests`' `Day` model sweeps against — 04:00 pre-open,
    /// 09:30-16:00 regular, 20:00 post-close — and prices each at its own
    /// cycle. `TickerCore` reads no clock and sees no real market calendar, so
    /// this assumes that schedule rather than the day's actual one; that is
    /// why this is an estimate and the sweep is the number actually asserted
    /// against.
    ///
    /// Each session's count rounds its `sessionSeconds / cycle` **up**, not
    /// down. `DaySimulation` runs one continuous timeline: a cycle already in
    /// flight when a session boundary passes carries its deadline across that
    /// boundary, so the next session does not always start counting from a
    /// clean zero the way this per-session split does. That phase shift can
    /// let the real simulation start one more cycle inside a session than a
    /// fresh-start `floor` would credit it — measured at 180s, where flooring
    /// under-reported the sweep by 1 request at one symbol, 2 at two, 4 at
    /// four. `ceil` accepts a partial final cycle as billable, which is the
    /// same assumption the pacer ceiling below already makes, and it is what
    /// keeps this a genuine upper bound rather than a number the sweep can
    /// walk under. It never widens the estimate by more than one session's
    /// worth of one cycle, so the overshoot stays small — worst measured case
    /// is 900s × 20, 40 requests over 760, and `min` with the pacer ceiling
    /// still holds it near the sweep everywhere the floor did.
    public static func estimatedDailyRequests(userIntervalSeconds: Double,
                                              watchlistCount: Int) -> Int {
        guard watchlistCount > 0 else { return 0 }

        let regularSeconds: Double = 6.5 * 3600
        let preSeconds: Double = 5.5 * 3600
        let postSeconds: Double = 4 * 3600

        func requests(_ sessionSeconds: Double, marketState: MarketState) -> Int {
            let cycle = RefreshPolicy.cycleInterval(
                userIntervalSeconds: userIntervalSeconds,
                watchlistCount: watchlistCount,
                marketState: marketState,
                lowPowerMode: false)
            return Int((sessionSeconds / cycle).rounded(.up)) * watchlistCount
        }

        let naive = requests(regularSeconds, marketState: .regular)
            + requests(preSeconds, marketState: .pre)
            + requests(postSeconds, marketState: .post)

        // Even split by session, the naive sum can still overshoot once the
        // spacing floor binds tighter than a session's own arithmetic implies.
        // The pacer's own ceiling — one request every `spacingSeconds` in the
        // regular session, one every `spacingSeconds × quietMultiplier` in the
        // quiet ones, full stop — is what actually bounds the day, so cap the
        // estimate there.
        let quietSpacing = RateConstants.spacingSeconds * RateConstants.quietMultiplier
        let pacerCeiling = Int(regularSeconds / RateConstants.spacingSeconds)
            + Int(preSeconds / quietSpacing)
            + Int(postSeconds / quietSpacing)
            + Int(RateConstants.bucketCapacity)

        return min(naive, pacerCeiling)
    }
}
