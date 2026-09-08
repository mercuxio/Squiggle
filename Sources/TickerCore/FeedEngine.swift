/// Everything `FeedEngine.next()` needs to know about the world outside
/// itself, gathered into one value so the engine stays a pure decision core:
/// no clock, no `NSApplication`, no `NWPathMonitor` in sight.
public struct EngineContext: Sendable {
    /// Wall-clock seconds. `TradingPeriod` windows are epochs from the
    /// payload, so comparing against them needs one — as a parameter, not a
    /// dependency (see `RefreshInput.nowEpoch`).
    public var nowEpoch: Double
    public var marketState: MarketState
    public var visibility: Visibility
    public var lowPowerMode: Bool
    /// The next **session** open, not the next *regular* open — see
    /// `RefreshInput.nextSessionOpenEpoch`, which this is threaded straight
    /// into.
    public var nextSessionOpenEpoch: Double?

    public init(nowEpoch: Double, marketState: MarketState, visibility: Visibility,
                lowPowerMode: Bool, nextSessionOpenEpoch: Double?) {
        self.nowEpoch = nowEpoch
        self.marketState = marketState
        self.visibility = visibility
        self.lowPowerMode = lowPowerMode
        self.nextSessionOpenEpoch = nextSessionOpenEpoch
    }
}

/// What the caller should do this tick.
public enum EngineAction: Equatable, Sendable {
    case fetch(Symbol)
    case sleep(seconds: Double)
}

/// The pure decision core: on each tick, whether to fetch a symbol, sleep,
/// or stand down. Everything that reasons about *when* — the token bucket,
/// the backoff ladder, the two circuit breakers, `RefreshPolicy` — already
/// exists; this type is the one place that owns all of them together and
/// turns "what should happen now" into a single answer.
///
/// A `struct`, and every caller holds it as `var`: `next()`, `recordSuccess()`
/// and `record()` all mutate state (the round-robin cursor, the pacer, the
/// ladder, the breakers), and Swift's value semantics make that mutation
/// visible only through the variable the caller actually holds — there is no
/// way to mutate a copy by accident and have the caller's copy silently miss
/// it, the way a reference type would allow.
public struct FeedEngine {
    private let clock: any MonotonicClock

    private var symbols: [Symbol]
    private var dead: Set<Symbol> = []
    private var latestQuotes: [Symbol: Quote] = [:]
    /// Index into `liveSymbols` of the next symbol due. Wraps to the top once
    /// it reaches the end — see `next()`. Pacing across a full pass is the
    /// token bucket's job (`pacer`), not this cursor's.
    private var cursor: Int = 0
    /// The wall of the round-robin pass currently in progress, or the pass
    /// about to start once `cursor` wraps: `0` until the first wrap, then
    /// `now + RefreshPolicy.cycleInterval(...)` at every wrap after. This is
    /// the throttle `userIntervalSeconds` actually rides on — the token
    /// bucket alone floors at `RateConstants.spacingSeconds`, far faster than
    /// any offered interval, so without this gate the engine polls at the
    /// bucket's floor regardless of what the user chose (fix round 1,
    /// Finding 1). `0` reads as "already due", which is exactly right: the
    /// very first pass and a pass right after `replaceWatchlist` must not
    /// wait for a deadline that was never set for them.
    private var cycleDeadline: Double = 0

    private var userIntervalSeconds: Double

    private var pacer: RequestPacer
    private var ladder: BackoffLadder
    /// Five consecutive failed cycles, open 30 minutes (spec §4.3).
    private var networkCircuit: CircuitBreaker
    /// One parse failure, open one hour — its own circuit, independent of
    /// the network one, because retrying a parse failure faster buys nothing.
    private var contractCircuit: CircuitBreaker

    public init(clock: any MonotonicClock, random: any Randomizing = SystemRandom(),
                symbols: [Symbol], userIntervalSeconds: Double) {
        self.clock = clock
        self.symbols = symbols
        self.userIntervalSeconds = userIntervalSeconds
        self.pacer = RequestPacer(clock: clock)
        self.ladder = BackoffLadder(clock: clock, random: random)
        self.networkCircuit = CircuitBreaker(clock: clock,
                                             threshold: RateConstants.circuitFailureThreshold,
                                             openSeconds: RateConstants.circuitOpenSeconds)
        self.contractCircuit = CircuitBreaker(clock: clock, threshold: 1,
                                              openSeconds: RateConstants.contractFaultCooldown)
    }

    /// The watchlist with dead symbols removed, in their original order.
    private var liveSymbols: [Symbol] {
        symbols.filter { !dead.contains($0) }
    }

    /// Decides the one thing to do this tick.
    ///
    /// R57: the policy input's `circuitAllows` is built from
    /// `wouldAllowRequest()` — a **query** — never from `allowsRequest()`,
    /// the mutating command. Asking "would you let a request through" must
    /// never itself spend the one half-open probe permit on a decision that
    /// may not fetch at all (a closed market, an occluded menu bar, a live
    /// cooldown on the *other* circuit). Only the branch that is actually
    /// about to return `.fetch`, at the last possible moment, calls the
    /// command — see below.
    public mutating func next(_ context: EngineContext) -> EngineAction {
        let now = clock.nowSeconds
        let live = liveSymbols

        let decision = RefreshPolicy.decide(RefreshInput(
            nowMonotonic: now,
            nowEpoch: context.nowEpoch,
            marketState: context.marketState,
            visibility: context.visibility,
            lowPowerMode: context.lowPowerMode,
            userIntervalSeconds: userIntervalSeconds,
            watchlistCount: live.count,
            nextSessionOpenEpoch: context.nextSessionOpenEpoch,
            isCoolingDown: ladder.isCoolingDown(),
            cooldownRemaining: ladder.secondsRemaining(),
            circuitAllows: networkCircuit.wouldAllowRequest() && contractCircuit.wouldAllowRequest(),
            circuitOpenRemaining: max(networkCircuit.secondsRemaining(),
                                      contractCircuit.secondsRemaining())))

        if case .wait(let seconds) = decision {
            return .sleep(seconds: max(RateConstants.minimumWaitSeconds, seconds))
        }

        guard !live.isEmpty else {
            // Defensive: `RefreshPolicy.decide` already returns `.wait` when
            // `watchlistCount == 0`, so this is unreachable in practice, but
            // nothing about `next()`'s own contract should depend on that.
            return .sleep(seconds: RefreshPolicy.cycleInterval(
                userIntervalSeconds: userIntervalSeconds, watchlistCount: 0,
                marketState: context.marketState, lowPowerMode: context.lowPowerMode))
        }

        // Round-robin: once every live symbol has been asked for, start
        // again from the top. A dead symbol removed from `live` can leave
        // the cursor past the new end, which this also corrects.
        //
        // A cycle in progress finishes before a new one starts; otherwise a
        // long watchlist would restart from the top forever and the symbols
        // at the end would never update. `cycleDeadline` is what makes
        // `userIntervalSeconds` mean anything once the market is open and
        // visible: without it, nothing below this line gates on
        // `RefreshPolicy.cycleInterval` at all, and the token bucket becomes
        // the only throttle.
        if cursor >= live.count {
            guard now >= cycleDeadline else {
                return .sleep(seconds: max(RateConstants.minimumWaitSeconds, cycleDeadline - now))
            }
            cursor = 0
            cycleDeadline = now + RefreshPolicy.cycleInterval(
                userIntervalSeconds: userIntervalSeconds, watchlistCount: live.count,
                marketState: context.marketState, lowPowerMode: context.lowPowerMode)
        }

        // The bucket is the last word on *when*. Nothing below this line can
        // bypass it.
        guard pacer.take() else {
            return .sleep(seconds: max(RateConstants.minimumWaitSeconds,
                                       pacer.secondsUntilNextToken()))
        }

        // R57: only now, on the path that is actually about to fetch, do we
        // take the real permits. Both are evaluated — into separate `let`s,
        // never `&&`'d directly at the call site — so a refusal from the
        // first can never hide the second going untaken.
        let networkAllowed = networkCircuit.allowsRequest()
        let contractAllowed = contractCircuit.allowsRequest()
        guard networkAllowed && contractAllowed else {
            return .sleep(seconds: max(RateConstants.minimumWaitSeconds,
                                       max(networkCircuit.secondsRemaining(),
                                           contractCircuit.secondsRemaining())))
        }

        let symbol = live[cursor]
        cursor += 1
        return .fetch(symbol)
    }

    public mutating func recordSuccess(_ quote: Quote, for symbol: Symbol) {
        latestQuotes[symbol] = quote
        ladder.recordSuccess()
        networkCircuit.recordSuccess()
        contractCircuit.recordSuccess()
    }

    public mutating func record(_ error: TickerError, for symbol: Symbol) {
        let kind = FailureKind(error)
        switch kind {
        case .deadSymbol:
            dead.insert(symbol)
            // A dead symbol is a fact about that one symbol, not about the
            // network or the contract; it must never advance the ladder or
            // either circuit.
            return
        case .contractFault:
            contractCircuit.recordFailure()
        case .rateLimited:
            networkCircuit.trip()
            pacer.halveCapacity()
        case .offline:
            // `Failure.swift` documents this kind as "do not attempt, do not
            // advance the ladder". Sharing an arm with `.server` did the
            // opposite: five Wi-Fi drops tripped a breaker for thirty minutes,
            // and it kept running *after the network came back*, because a
            // circuit meant to protect Yahoo from us has no way to learn that
            // the fault was on our side of the router.
            //
            // Returning early rather than leaning on `BackoffLadder`'s own
            // `.offline` arm (which already returns 0): the rule belongs where
            // the circuits are, next to `.deadSymbol`'s identical one, so a
            // future kind added to the arm below cannot inherit this
            // behaviour by accident.
            //
            // There is no path-monitor edge to resume on. `TickerCore` takes
            // no `Network` dependency and the app layer that would own
            // `NWPathMonitor` does not exist yet — this is a plain statement
            // of fact, not a seam waiting for a call. Retrying on the next
            // cycle is the whole recovery story, and it is the right one:
            // asking again costs one token and finds out immediately.
            return
        case .server, .unauthorized:
            networkCircuit.recordFailure()
        }
        ladder.record(kind)
    }

    public mutating func replaceWatchlist(_ newSymbols: [Symbol]) {
        symbols = newSymbols
        let keep = Set(newSymbols)
        latestQuotes = latestQuotes.filter { keep.contains($0.key) }
        // A full reset, not an intersection: a symbol that came back dead
        // under the old list — even one still present in the new list — gets
        // a clean slate. Replacing the watchlist is the user's own
        // "try again" gesture; a symbol earlier marked dead is not
        // resurrected by anything else, so this is its only way back.
        dead = []
        cursor = 0
        // A watchlist edit invalidates whatever cycle was in progress: the
        // deadline was computed from the old watchlist's count, and letting
        // it stand would gate the new list's first pass on a number that no
        // longer describes it.
        cycleDeadline = 0
        // Deliberately untouched: `ladder` and the two circuits. A watchlist
        // edit is not a network event, and resetting a live cooldown here
        // would let a user dodge a 429 backoff by adding a symbol.
    }

    /// Invalidates the in-progress cycle's deadline so a new
    /// `userIntervalSeconds` takes effect starting at the *next* cycle,
    /// rather than either truncating one already underway or being ignored
    /// until whatever deadline the old interval happened to compute. Not
    /// currently called from `squigglectl watch`, which fixes its interval
    /// for the process's lifetime (`WatchLoop.intervalSeconds` is a `let`);
    /// it exists for plan 2's menu bar app, whose Settings refresh-interval
    /// control changes this while the engine keeps running.
    public mutating func setUserInterval(_ seconds: Double) {
        userIntervalSeconds = seconds
        cycleDeadline = 0
    }

    public var latest: [Symbol: Quote] { latestQuotes }

    public var deadSymbols: Set<Symbol> { dead }

    /// The cooldown deadline as a wall-clock epoch, for `Store` — or `nil`
    /// if nothing is currently cooling down. `nowEpoch` converts the
    /// ladder's monotonic remaining-seconds into the one wall-clock value
    /// `TickerCore` ever persists (spec §4.3).
    public func cooldownUntilEpoch(nowEpoch: Double) -> Double? {
        guard ladder.isCoolingDown() else { return nil }
        return nowEpoch + ladder.secondsRemaining()
    }

    /// Restores a cooldown that outlived the process — the single documented
    /// wall-clock exception (spec §4.3). Converts back to a monotonic
    /// remaining-seconds figure before handing it to `ladder`, which is the
    /// only place `TickerCore` performs that conversion.
    public mutating func adoptPersistedCooldown(untilEpoch: Double, nowEpoch: Double) {
        ladder.adoptPersistedCooldown(secondsRemaining: untilEpoch - nowEpoch)
    }

    /// The live state spec §7 asks a diagnostic to show, that only a running
    /// engine can answer: token bucket level, both circuit breakers, and the
    /// backoff ladder's remaining cooldown. Values only — `TickerCore` vends
    /// no user-facing strings, so `squigglectl` (`Rendering.stateLine`)
    /// supplies the wording.
    ///
    /// Not persisted anywhere: this state lives only in this process's
    /// memory. Writing it to the store file would turn `squiggle.json` into a
    /// request log, which is exactly what the "safe to email" rule forbids.
    public struct DiagnosticSnapshot: Equatable, Sendable {
        public let tokensAvailable: Double
        public let networkCircuit: CircuitState
        public let contractCircuit: CircuitState
        public let cooldownRemainingSeconds: Double
    }

    public var diagnosticSnapshot: DiagnosticSnapshot {
        DiagnosticSnapshot(tokensAvailable: pacer.availableTokens,
                           networkCircuit: networkCircuit.state(),
                           contractCircuit: contractCircuit.state(),
                           cooldownRemainingSeconds: ladder.secondsRemaining())
    }
}
