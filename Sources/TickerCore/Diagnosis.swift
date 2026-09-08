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
    /// **This number is not clamped, and must not be.** It used to end in
    /// `min(naive, pacerDailyCeiling)` — a cap derived from a 16-hour US equity
    /// day — which made it structurally incapable of returning a figure over
    /// spec §4.2's budget, for any input at all. That is the shape of the
    /// original defect: the overshoot was derived correctly three separate
    /// times in this file's own comments and then capped out of the report each
    /// time. An estimate that cannot express the condition it exists to reveal
    /// is not an estimate. The budget is now held by `RefreshPolicy.budgetFloor`
    /// and `RequestPacer`'s daily bucket, which are mechanisms; this is a
    /// report, and a report's job is to say what it sees.
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
    /// is 900s × 20, 40 requests over 760.
    public static func estimatedDailyRequests(userIntervalSeconds: Double,
                                              watchlistCount: Int) -> Int {
        guard watchlistCount > 0 else { return 0 }

        func requests(_ sessionSeconds: Double, marketState: MarketState) -> Int {
            let cycle = RefreshPolicy.cycleInterval(
                userIntervalSeconds: userIntervalSeconds,
                watchlistCount: watchlistCount,
                marketState: marketState,
                lowPowerMode: false)
            return Int((sessionSeconds / cycle).rounded(.up)) * watchlistCount
        }

        return requests(regularSeconds, marketState: .regular)
            + requests(preSeconds, marketState: .pre)
            + requests(postSeconds, marketState: .post)
    }

    // The three sessions `BudgetSweepTests`' `Day` model sweeps against —
    // 04:00 pre-open, 09:30-16:00 regular, 20:00 post-close. Hoisted out of
    // `estimatedDailyRequests` because all three arms need them.
    //
    // A `pacerDailyCeiling` constant used to live here, derived from these same
    // three spans and asserted to sit under the budget. It is gone with the
    // clamp that was its only caller: it described the pacer's day bound in
    // terms of a US equity calendar, which is the assumption that let the
    // budget be exceeded on an instrument that never closes. The pacer's real
    // day bound is `RateConstants.dailyRequestBudget` plus its burst, is stated
    // by `RequestPacer` itself, and is measured second-by-second in
    // `theDailyBucketHoldsAWholeDayToTheBudget` — a bound worth having is one
    // the type that enforces it can be asked for.
    private static let regularSeconds: Double = 6.5 * 3600
    private static let preSeconds: Double = 5.5 * 3600
    private static let postSeconds: Double = 4 * 3600

    /// Whether the pacer, rather than the user's chosen interval, is what sets
    /// how often Squiggle actually fetches (R79).
    ///
    /// `RefreshPolicy.cycleInterval` floors the cycle at both `n × 30s` and the
    /// budget-derived `n × 86_400 / dailyRequestBudget`. When either floor is
    /// the larger term the ticker is slower than its own settings claim — a 60s
    /// interval across 20 symbols runs a 1,440s cycle — and nothing else in the
    /// app says so.
    ///
    /// This reports *that* condition and nothing else. It is deliberately not
    /// the over-budget check: this returns true exactly when the floors bind,
    /// which after the budget floor landed is a common and entirely healthy
    /// state, whereas being over budget is now a genuine fault. The two used to
    /// be conflated here because the over-budget question was unanswerable —
    /// `estimatedDailyRequests` ended in `min(naive, pacerDailyCeiling)`, a
    /// constant below the budget, so "is the estimate over budget" was
    /// unreachable for every possible input and said `[ok]` to precisely the
    /// user it should have warned. That clamp is gone.
    ///
    /// It does **not** follow that comparing the estimate against the budget
    /// is now a useful check, and an earlier draft of this comment said it
    /// did. Measured instead of assumed: swept over every watchlist size 1...20
    /// against intervals from 0.1s to 3600s — far outside anything Settings
    /// offers — the largest figure `estimatedDailyRequests` returns is **741**,
    /// at 19 symbols. Against a budget of 1,200 the comparison is unreachable
    /// for every possible input, which is the same defect the clamp caused,
    /// relocated rather than removed. `theEstimatorCannotReachTheBudgetOnAnyInput`
    /// pins the 741 so this cannot quietly become true again unnoticed.
    ///
    /// The reason is structural, not a matter of the numbers happening to work
    /// out. This estimator prices a *US equity* day: 6.5h regular, 5.5h pre,
    /// 4h post, and eight hours shut. The budget is a claim about the app on
    /// *any* calendar, and the case that can exceed it is an instrument that
    /// never closes — which this function does not model and should not, since
    /// `doctor` reports on the user's stored settings and not on what their
    /// symbols trade as. The budget is enforced where the 24-hour case is
    /// visible: `RefreshPolicy.budgetFloor` and `RequestPacer`'s daily bucket,
    /// asserted on the continuous calendar in
    /// `theDailyBudgetHoldsAcrossEveryReachableConfiguration`.
    ///
    /// Compared against `.regular` with Low Power Mode off because the quiet
    /// multiplier scales the cycle and not the setting: including it would
    /// report every extended-hours user as throttled by the pacer when what is
    /// slowing them down is a deliberate, documented cadence.
    public static func pacerThrottlesSettings(userIntervalSeconds: Double,
                                              watchlistCount: Int) -> Bool {
        guard watchlistCount > 0 else { return false }
        let cycle = RefreshPolicy.cycleInterval(userIntervalSeconds: userIntervalSeconds,
                                                watchlistCount: watchlistCount,
                                                marketState: .regular,
                                                lowPowerMode: false)
        return cycle > RefreshPolicy.honouredInterval(userIntervalSeconds)
    }
}
