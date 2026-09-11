import AppKit
import TickerCore

/// The `NSStatusItem`, and the one real timer in the app (spec §2.2).
///
/// The timer is a one-shot, rescheduled after every step rather than a
/// repeating one: the interval `FeedEngine` asks for changes with the market
/// state, Low Power Mode, and the ladder's cooldown, so a repeating timer
/// would be answering a question that had already changed.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let runner: TickerRunner
    private var timer: Timer?
    private let tickerView = TickerView()
    /// The dropdown. One panel for the life of the app, its contents rebuilt
    /// on every open — see `presentDropdown`.
    private let dropdown = StatusPanel()
    /// The footer's coffee button. The address itself lives in `ErrorText`
    /// with the rest of the copy; force-unwrapped because a constant that
    /// fails to parse is a build-time mistake, not a runtime condition.
    private let coffeeURL = URL(string: ErrorText.coffeeURL)!
    // Retained by `NotificationCenter` until removed, same as `timer` is
    // retained by the run loop until invalidated — `stop()` tears both down
    // for the same reason.
    private var reduceMotionObserver: NSObjectProtocol?
    private var pauseMonitor: PauseMonitor?
    private var pauseConditions = PauseConditions()
    private var appearanceObservation: NSKeyValueObservation?

    private let store: any WatchlistStore
    // `WatchlistStore` is a protocol and has no URL, and a save that fails for
    // a filesystem reason needs one to report. Carried beside the store rather
    // than reached for through a concrete type, so the controller still takes
    // any conforming store.
    private let storeURL: URL
    private var document: Store
    private var storeFault: TickerError?
    private var nextStepEpoch: Double?
    private var settingsWindow: SettingsWindowController?
    private var pickerWindow: SymbolPickerWindowController?
    private var persistTimer: Timer?
    private let search: SymbolSearch

    // R139: one document, one saver. `settings` is a view onto it rather than
    // a second copy, so Task 13 changing a setting and Task 15 adding a symbol
    // cannot end up writing over one another.
    private var settings: Settings { document.settings }

    init(runner: TickerRunner, store: any WatchlistStore, storeURL: URL,
         document: Store, storeFault: TickerError?, search: @escaping SymbolSearch) {
        self.runner = runner
        self.store = store
        self.storeURL = storeURL
        self.document = document
        self.storeFault = storeFault
        self.search = search
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.title = ""
    }

    func start() {
        guard let button = statusItem.button else { return }
        // The button keeps its click handling (the dropdown, Task 11); the
        // view only draws. Replacing the button with a custom view would give
        // up the highlight and the menu behaviour, which is a poor trade for
        // one subview.
        //
        // `init` already cleared `title`; this clears the attributed one Task
        // 6's `render()` was setting, because an empty view over a stale
        // title shows the title.
        button.attributedTitle = NSAttributedString(string: "")
        tickerView.frame = button.bounds
        tickerView.autoresizingMask = [.width, .height]
        button.addSubview(tickerView)

        // No `statusItem.menu` any more. Assigning one makes AppKit swallow
        // the button's clicks to open the menu itself, so the panel and a menu
        // cannot both exist — and `NSMenu` cannot right-align the trash button
        // or the quit icon the user asked for.
        button.target = self
        button.action = #selector(toggleDropdown)

        // Reduce Motion can be toggled while Squiggle is running, and a user
        // who turns it on because a marquee is making them ill should not have
        // to quit the app to be rid of it.
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.render() }
            }

        let monitor = PauseMonitor { [weak self] conditions in
            self?.applyPause(conditions)
        }
        monitor.start(observing: button.window)
        pauseMonitor = monitor

        // Spec §5.3: "re-renders on appearance change". KVO rather than a
        // notification because `effectiveAppearance` is a property of this one
        // button and the interesting change is the menu bar's, which is not
        // what `NSApp.effectiveAppearance` reports. The observation is stored
        // because KVO stops the moment it is released.
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) {
            [weak self] _, _ in
            MainActor.assumeIsolated { self?.render() }
        }

        render()
        scheduleStep(after: 0)
    }

    func stop() {
        if persistTimer != nil {
            persistTimer?.invalidate()
            persistTimer = nil
            // An edit made in the last half-second is still only in memory.
            persist()
        }
        timer?.invalidate()
        timer = nil
        if let reduceMotionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(reduceMotionObserver)
        }
        reduceMotionObserver = nil
        pauseMonitor?.stop()
        pauseMonitor = nil
        appearanceObservation = nil
        // The panel installs two global event monitors while it is open, and
        // they outlive the panel unless it is closed. `close()` is where they
        // are removed.
        dropdown.close()
    }

    /// Spec §5.2: pausing is `speed = 0` with the offset captured, never a
    /// removal — removing and re-adding makes the strip jump.
    ///
    /// Un-pausing also asks the refresh side one question (R151): has the
    /// price on screen outlived the dim threshold? An *unconditional* step
    /// here would turn every unlock into an unscheduled request, which is why
    /// the step sits behind `isStale` rather than behind `isPaused` alone. A
    /// lock and an unlock ten seconds apart find nothing stale and cost
    /// nothing; only an unlock onto an already-dimmed strip spends a request,
    /// and there the app is looking at a number it has itself marked as one
    /// it cannot vouch for.
    private func applyPause(_ conditions: PauseConditions) {
        pauseConditions = conditions
        if conditions.isPaused {
            tickerView.pause()
        } else {
            tickerView.resume()
            catchUpIfStale()
        }
    }

    private func scheduleStep(after seconds: Double) {
        timer?.invalidate()
        let delay = max(seconds, RateConstants.minimumWaitSeconds)
        // The footer's "retrying in" is this number and not an estimate of it.
        nextStepEpoch = Date().timeIntervalSince1970 + delay
        let fired = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            // `Timer`'s block is not main-actor-isolated, so hop explicitly
            // rather than annotating the closure and hoping.
            Task { @MainActor in await self?.stepOnce() }
        }
        // R56: let the OS coalesce this wakeup with other system timers. The
        // app is explicitly not time-critical, and tolerance buys more
        // battery than any interval choice does.
        fired.tolerance = delay * RateConstants.timerLeewayFraction
        timer = fired
        RunLoop.main.add(fired, forMode: .common)
    }

    private func stepOnce() async {
        let wait = await runner.step(nowEpoch: Date().timeIntervalSince1970,
                                     visibility: visibility(),
                                     lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
        render()
        // The strip is not the only thing showing these numbers. An `NSMenu`
        // closed itself on almost any stray click, so a dropdown that never
        // updated was a dropdown alive for a second; this panel stays up until
        // it is dismissed, and *Refresh Now* is a footer button, so the one
        // control whose whole purpose is "show me new numbers" has to actually
        // show them.
        if dropdown.isShowing { rebuildDropdownContent() }
        scheduleStep(after: wait)
    }

    /// R134: reads the state `PauseMonitor` maintains rather than polling
    /// anything itself. `pauseConditions` is updated only when it changes, so
    /// this is always the answer as of the most recent notification, not a
    /// snapshot taken here.
    private func visibility() -> Visibility { pauseConditions.visibility }

    // MARK: - Colour

    /// Spec §7's stale state. Asks `RefreshPolicy`; never computes an age.
    ///
    /// The spec is explicit about this and the reason is arithmetic: the
    /// threshold is three *cycles*, and at twenty symbols the cycle floors at
    /// 1,440s — so "stale" is 72 minutes there and 9 at the same user setting
    /// with one symbol. Anything here that compared an age against the user's
    /// interval would dim a perfectly healthy strip eight times out of nine.
    private func isStale(atEpoch epoch: Double) -> Bool {
        RefreshPolicy.isStale(
            lastSuccessEpoch: runner.lastSuccessEpoch,
            nowEpoch: epoch,
            userIntervalSeconds: runner.userIntervalSeconds,
            watchlistCount: runner.symbols.count,
            // The same assumption `TickerRunner.step` makes before the first
            // quote arrives, and deliberately the same one: a second opinion
            // about market hours inside one app is a bug.
            marketState: runner.marketState(atEpoch: epoch) ?? .regular,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// R151. Anything that un-pauses the strip asks the same question: is what
    /// is on screen older than the dim threshold? If it is, take one cycle
    /// now rather than waiting out a deadline measured on a clock that stopped
    /// while the machine was suspended.
    ///
    /// Deliberately the same predicate `colorResolver()` dims with. Two
    /// predicates would let the app dim a price it is not replacing, or fetch
    /// behind a strip that looks live — and the second of those is invisible,
    /// because nobody notices a request that did not need making.
    private func catchUpIfStale() {
        // `isStale` answers `true` when nothing has ever succeeded. True, and
        // useless: the ordinary schedule is already retrying at whatever pace
        // the ladder permits, and a second request would only spend a token.
        guard runner.lastSuccessEpoch != nil else { return }
        guard isStale(atEpoch: Date().timeIntervalSince1970) else { return }
        runner.requestImmediateCycle()
        scheduleStep(after: 0)
    }

    /// The closure `TickerView` paints with (R136).
    ///
    /// The scheme and the staleness are decided once, here, and captured — the
    /// closure is called once per segment and neither answer can change
    /// between segments of one strip. What it does per call is resolve an
    /// `NSColor` into a `CGColor`, which is the part that genuinely depends on
    /// the appearance.
    private func colorResolver() -> (ColorRole) -> CGColor {
        let scheme = ColorPolicy.effective(
            requested: ColorScheme(setting: settings.colorScheme),
            differentiateWithoutColor:
                NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor)
        let stale = isStale(atEpoch: Date().timeIntervalSince1970)

        // Spec §5.3: the *button's* effective appearance, not the app's. The
        // menu bar can be dark while the app is light — that is the ordinary
        // state of a Mac with a dark wallpaper and a light system appearance —
        // and `NSColor.cgColor` resolves against whatever appearance happens
        // to be current, which during a timer callback is the app's. Measured:
        // `labelColor` is white at alpha 0.847 under `.darkAqua` and black at
        // the same alpha under `.aqua`. Getting this wrong paints black text
        // on a black menu bar.
        let appearance = statusItem.button?.effectiveAppearance
            ?? NSApp.effectiveAppearance

        return { role in
            let color = ColorPolicy.color(for: role, scheme: scheme, isStale: stale)
            // Seeded with the unresolved answer and overwritten inside the
            // block. `performAsCurrentDrawingAppearance` runs synchronously, so
            // the seed never survives — it is here because `CGColor` has no
            // sensible empty value and a force-unwrap would be worse.
            var resolved = color.cgColor
            appearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
            return resolved
        }
    }

    private func render() {
        let metrics = StripRenderer.metrics(rows: settings.rows,
                                            barHeight: Double(NSStatusBar.system.thickness))
        // R131: the closure binds the font, so `StripLayout` never sees one.
        let font = metrics.font
        let measure: (String) -> Double = { text in
            Double((text as NSString).size(withAttributes: [.font: font]).width)
        }
        let layout = StripLayout.build(symbols: runner.symbols,
                                       quotes: runner.quotes,
                                       dead: runner.deadSymbols,
                                       rows: metrics.rowCount,
                                       gap: 20,
                                       measure: measure)
        // Spec §5.1: a *fixed*-width status item. Task 6 created it
        // `variableLength` because a button sized to its title was the honest
        // thing while a title was what it drew; a marquee needs a window that
        // does not resize itself to the content it is meant to clip.
        statusItem.length = settings.maxVisibleWidth
        let requested = MotionMode(setting: settings.motionMode)
        let mode = MotionPolicy.effective(
            requested: requested,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        tickerView.apply(layout: layout,
                         metrics: metrics,
                         visibleWidth: settings.maxVisibleWidth,
                         mode: mode,
                         pointsPerSecond: settings.scrollPointsPerSecond,
                         // A rebuild starts from nothing, so the pause has to
                         // be re-asserted here or the next refresh tick,
                         // appearance change, settings edit, add or remove
                         // restarts the marquee behind a locked screen —
                         // `PauseMonitor` reports only *changes*, so no second
                         // notification would ever arrive to stop it again.
                         paused: pauseConditions.isPaused,
                         color: colorResolver())
    }

    // MARK: - The dropdown

    /// The status item's own action. A second click closes, the way a menu
    /// title does — and the panel's outside-click monitor deliberately ignores
    /// clicks on this button so the two do not fight over the same press.
    @objc private func toggleDropdown() {
        if dropdown.isShowing {
            dropdown.close()
        } else {
            presentDropdown()
        }
    }

    // R132 said this was rebuilt only on open, because a dropdown visible for
    // the second it is being read has no state worth maintaining. That was
    // true of `NSMenu` and its modal tracking loop; it is false of a panel the
    // user can leave open indefinitely, so `stepOnce` rebuilds it too.
    private func presentDropdown() {
        guard let button = statusItem.button else { return }
        rebuildDropdownContent()
        dropdown.show(under: button) { [weak self] in self?.quit() }
    }

    /// Also called after the watchlist changes, because removing a symbol
    /// happens *inside* the open dropdown — leaving the row of a symbol that
    /// is no longer watched on screen, with a live trash button, would be the
    /// one state this view must never be in.
    private func rebuildDropdownContent() {
        let model = MenuModel.build(symbols: runner.symbols,
                                    quotes: runner.quotes,
                                    dead: runner.deadSymbols,
                                    lastSuccessEpoch: runner.lastSuccessEpoch,
                                    lastError: runner.lastError,
                                    storeFault: storeFault,
                                    nowEpoch: Date().timeIntervalSince1970,
                                    nextStepEpoch: nextStepEpoch)
        // The closure is called during `init` and never stored, so `self` is
        // captured strongly on purpose: a weak capture here would need a
        // fallback selector for a case that cannot happen.
        dropdown.setContent(DropdownView(model: model,
                                         target: self,
                                         remove: #selector(removeSymbol(_:)),
                                         command: { self.selector(for: $0) }))
    }

    /// No `default:`: a sixth command must fail the build here rather than
    /// reach the footer as a button that does nothing.
    private func selector(for command: MenuCommand) -> Selector {
        switch command {
        case .addSymbol: return #selector(openSymbolPicker)
        case .refreshNow: return #selector(refreshNow)
        case .settings: return #selector(openSettings)
        case .buyCoffee: return #selector(openCoffee)
        case .quit: return #selector(quit)
        }
    }

    // MARK: - Dropdown actions

    @objc private func refreshNow() {
        // R140: this retires the cycle deadline. The cooldown, both circuits
        // and the token bucket all still get their say, so the click asks for
        // a refresh — it does not grant one.
        runner.requestImmediateCycle()
        scheduleStep(after: 0)
        // The dropdown stays open — the click came from inside it — so the
        // status line under the rows is rebuilt to say when the retry is due.
        rebuildDropdownContent()
    }

    @objc private func openSettings() {
        // The panel sits at `.popUpMenu` level, above every ordinary window,
        // so a settings window opened underneath it would be invisible.
        dropdown.close()
        let controller = settingsWindow ?? SettingsWindowController(
            settings: document.settings,
            onChange: { [weak self] edited in self?.settingsChanged(edited) })
        settingsWindow = controller
        controller.watchlistCount = document.symbols.count
        controller.apply(document.settings)
        // An `LSUIElement` app is not in the Dock and is not activated by a
        // menu click, so `makeKeyAndOrderFront` alone puts the window behind
        // whatever the user was working in. This is the one place Squiggle
        // asks to come forward, and it is in direct response to a click.
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }

    @objc private func openSymbolPicker() {
        // Same reason as `openSettings`.
        dropdown.close()
        let controller = pickerWindow ?? SymbolPickerWindowController(
            search: search,
            watchlist: document.symbols,
            onAdd: { [weak self] symbol in self?.add(symbol) })
        pickerWindow = controller
        controller.setWatchlist(document.symbols)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }

    private func add(_ symbol: Symbol) {
        // The cap is enforced in the picker (R150), and again here, because
        // this is the method that writes the file and the store would
        // otherwise truncate at the next launch and pick the survivors itself.
        guard document.symbols.count < RateConstants.maxWatchlistCount,
              !document.symbols.contains(symbol) else { return }
        document.symbols.append(symbol)
        runner.replaceWatchlist(document.symbols)
        persist()
        pickerWindow?.setWatchlist(document.symbols)
        // Spec §4.1: the effective-interval line is computed against the
        // watchlist size, and the settings window does not own the watchlist.
        // Optional-chained because the window is nil until it has been opened
        // once, and closed is not the same as gone — it keeps reporting.
        settingsWindow?.watchlistCount = document.symbols.count
        // A new symbol has no quote yet, so this repaints the strip with its
        // dead-symbol placeholder immediately rather than leaving a gap until
        // the next cycle.
        render()
        // R140's path: ask for a cycle now so the price arrives in seconds
        // rather than at the next deadline, which at 20 symbols is 24 minutes.
        runner.requestImmediateCycle()
        scheduleStep(after: 0)
    }

    private func settingsChanged(_ edited: Settings) {
        document.settings = edited
        // The interval is the one setting the engine holds a copy of.
        runner.setUserInterval(edited.refreshIntervalSeconds)
        render()
        schedulePersist()
    }

    /// A continuous slider fires its action on every pixel of a drag. The JSON
    /// file is the whole of this app's persistence (spec §6) and rewriting it
    /// forty times a second for a number the user is still choosing is a lot
    /// of disk for no benefit — so the write is coalesced to one per gesture.
    /// Half a second, and `stop()` flushes, so the only way to lose an edit is
    /// to kill the process mid-drag.
    private func schedulePersist() {
        persistTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.persist() }
        }
        persistTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The footer's coffee button.
    ///
    /// The dropdown is closed first, and not as a courtesy: a `.popUpMenu`
    /// panel stays above the browser window that is about to open, so leaving
    /// it up would park it on top of the page it just sent the user to.
    @objc private func openCoffee() {
        dropdown.close()
        NSWorkspace.shared.open(coffeeURL)
    }

    /// The user's item 2: one click, in the row, with no submenu.
    ///
    /// The symbol comes off the button rather than out of a row index, so a
    /// cycle that lands between the build and the click cannot make this
    /// remove the wrong one.
    @objc private func removeSymbol(_ sender: RemoveButton) {
        let symbol = sender.symbol
        document.symbols.removeAll { $0 == symbol }
        runner.replaceWatchlist(document.symbols)
        persist()
        pickerWindow?.setWatchlist(document.symbols)
        // The other half of the same rule: removing a symbol can lower the
        // effective interval just as adding one raises it.
        settingsWindow?.watchlistCount = document.symbols.count
        render()
        // The click came from a row of the panel that is still open. Rebuilding
        // is what takes that row away.
        rebuildDropdownContent()
    }

    @objc private func quit() {
        stop()
        NSApp.terminate(nil)
    }

    /// Writes the whole document. Never throws at a menu click: a failed save
    /// leaves the change in memory — the user asked for it and it is on the
    /// screen — and reports itself in the footer instead, which is the app's
    /// only error surface (spec §7, zero alerts).
    private func persist() {
        do {
            try store.save(document)
            storeFault = nil
        } catch let error as TickerError {
            storeFault = error
        } catch {
            // `FileWatchlistStore.save` can fail at `createDirectory` or at the
            // write itself with a raw `NSError`, which no `catch let e as
            // TickerError` would match. `storeQuarantineFailed` is the case
            // that already means "the file is where it was and Squiggle cannot
            // use it" — true here too, in the other direction.
            storeFault = .storeQuarantineFailed(at: storeURL)
        }
    }
}
