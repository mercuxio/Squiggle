import Foundation
import TickerCore

/// Every user-facing string in the app (spec §7). `TickerCore` emits typed
/// errors and carries no words; this is where they become sentences.
///
/// The rule the wording follows is spec §7's: name the user's move, not the
/// diagnosis. "Yahoo is rate-limiting Squiggle" tells someone to wait; "HTTP
/// 429" tells them to search the web. The one thing this file must never do is
/// print a value out of the error payload that is not the user's own input —
/// paths, statuses and field names belong in `squigglectl doctor`, whose
/// output is meant to be pasted into an email, not read in a menu bar.
enum ErrorText {
    // MARK: - Menu titles

    static let refreshNow = "Refresh Now"
    static let settings = "Settings…"
    static let addSymbol = "Add Symbol…"
    static let quit = "Quit Squiggle"
    static let buyCoffee = "Buy me a coffee"

    /// The one address in this app that is not Yahoo's, and the only one a
    /// click opens in a browser. Here rather than in the controller because it
    /// is user-facing copy by the same argument the titles above are: it is a
    /// thing the user reads, in their browser's address bar, after clicking a
    /// button in Squiggle.
    static let coffeeURL = "https://buymeacoffee.com/benjamintan"

    /// The trash button's only label. Icon-only controls are invisible to
    /// VoiceOver otherwise, and twenty rows of "Remove" would leave a screen
    /// reader user counting to work out which one they were on.
    ///
    /// The symbol is spelled exactly as Yahoo spells it and the user typed it —
    /// `^GSPC`, `BRK-B`, `VOD.L`. Case is significant everywhere else in this
    /// app and a label is no place to start normalising it.
    static func removeSymbol(_ symbol: String) -> String {
        "Remove \(symbol)"
    }

    // MARK: - The footer line

    /// The one line at the foot of the dropdown (spec §7). There is no other
    /// error surface in the app: no alerts, no notifications, no badge.
    static func footer(lastSuccessAgoSeconds: Double?,
                       lastError: TickerError?,
                       retryInSeconds: Double?) -> String {
        guard let lastError else {
            let updated = freshness(lastSuccessAgoSeconds)
            guard let retryInSeconds else { return updated }
            return updated + " — retrying in " + duration(retryInSeconds)
        }
        let sentence = message(for: lastError)
        guard waitingHelps(lastError), let retryInSeconds else { return sentence }
        return sentence + " Retrying in " + duration(retryInSeconds) + "."
    }

    /// One dropdown row. The currency code is rendered **verbatim** — a London
    /// listing reports `GBp`, meaning pence, and upper-casing it would claim
    /// the price was in pounds and be wrong by a factor of 100.
    static func menuRow(symbol: String, price: String,
                        change: String, currency: String?) -> String {
        let money = currency.map { "\(price) \($0)" } ?? price
        return change.isEmpty ? "\(symbol)  \(money)" : "\(symbol)  \(money)  \(change)"
    }

    // MARK: - Wording

    /// Exhaustive over `TickerError`, with no `default:`: a nineteenth case
    /// must fail the build here rather than reach a user as an empty line.
    static func message(for error: TickerError) -> String {
        switch error {
        case .offline:
            return "No network connection."
        case .rateLimited:
            return "Yahoo is rate-limiting Squiggle."
        case .serverError, .transport:
            return "Yahoo isn't responding."
        case .unauthorized:
            // Spec §3.1: the whole premise is that this endpoint needs no
            // credentials. If it starts to, waiting will not fix it and
            // Squiggle will not start holding a cookie.
            return "Yahoo now wants a sign-in that Squiggle doesn't do."
        case .invalidSymbol(let raw):
            // Echoing the user's own typed text back is sanctioned; it is the
            // only way to say which of twenty symbols is the problem.
            return "Squiggle can't read the symbol “\(raw)”."
        case .symbolNotFound(let symbol):
            return "Yahoo doesn't know “\(symbol.raw)”."
        case .emptyBody, .notJSON, .noResult, .missingField,
             .wrongType, .nonFiniteNumber, .negativeValue:
            // Every contract fault gets the same sentence on purpose. The user
            // can do exactly one thing about any of them, and which JSON key
            // path moved is a question for `squigglectl doctor`.
            return "Yahoo changed what it sends. Squiggle needs an update."
        case .storeSchemaUnsupported:
            return "Your watchlist was written by a newer Squiggle."
        case .storeVersionUnreadable, .storeCorrupt:
            return "Your watchlist couldn't be read, so Squiggle set it aside and started fresh."
        case .storeQuarantineFailed:
            return "Your watchlist couldn't be read and couldn't be set aside, so Squiggle isn't saving changes."
        }
    }

    /// Whether a retry is worth telling the user about. A contract fault, a
    /// credential demand or an unreadable file will look identical in four
    /// minutes, and promising otherwise is the one way a footer line can lie.
    private static func waitingHelps(_ error: TickerError) -> Bool {
        switch error {
        case .transport, .rateLimited, .serverError,
             .symbolNotFound, .invalidSymbol:
            return true
        case .offline, .unauthorized, .emptyBody, .notJSON, .noResult, .missingField,
             .wrongType, .nonFiniteNumber, .negativeValue,
             .storeSchemaUnsupported, .storeVersionUnreadable,
             .storeCorrupt, .storeQuarantineFailed:
            return false
        }
    }

    private static func freshness(_ agoSeconds: Double?) -> String {
        guard let agoSeconds, agoSeconds.isFinite else { return "Updating…" }
        if agoSeconds < 60 { return "Updated just now" }
        return "Updated \(minutes(agoSeconds)) min ago"
    }

    /// R129: the rounding is a wording decision, so it lives here rather than
    /// in `Formatting`. "under a minute" instead of "0 min" — a countdown that
    /// reaches zero and stays there reads as a stuck app.
    private static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 60 else { return "under a minute" }
        return "\(minutes(seconds)) min"
    }

    private static func minutes(_ seconds: Double) -> Int {
        max(1, Int((seconds / 60).rounded()))
    }

    // MARK: - Symbol picker

    static let searchPlaceholder = "Company or symbol"
    /// The picker's one button. Separate from `addSymbol`, which is the menu
    /// command and the window's title — this is the verb on the button.
    static let addButton = "Add"
    static let alreadyWatching = "Already watching"
    static let noMatches = "No matches. You can still try it as a symbol."
    /// The sibling of `noMatches` for text `Symbol.init?` refuses outright.
    /// Offering "try it as a symbol" here would be an instruction the Add
    /// button then declines to carry out.
    static let notASymbol = "No matches, and that isn't a symbol Yahoo would accept."
    static let watchlistFull =
        "Watching \(RateConstants.maxWatchlistCount) symbols — remove one to add another."

    /// `AAPL — Apple Inc. (NASDAQ)`. The exchange is dropped rather than shown
    /// empty: Yahoo returns a blank one for some instruments and " ()" reads
    /// as a rendering fault.
    static func searchRow(_ result: SearchResult) -> String {
        let head = "\(result.symbol.raw) — \(result.name)"
        return result.exchange.isEmpty ? head : "\(head) (\(result.exchange))"
    }

    /// The typed text, quoted so its spacing and punctuation are visible —
    /// which is the point, since it is about to be used exactly as written.
    static func literalRow(_ symbol: Symbol) -> String {
        "Try “\(symbol.raw)” as a symbol"
    }

    // MARK: - Settings

    static let settingsTitle = "Squiggle Settings"

    static let rowsLabel = "Rows"
    static let intervalLabel = "Refresh"
    // The spec spells §5.3 "Colour", and so does the rest of this project's
    // prose. Deliberate, not an oversight.
    static let schemeLabel = "Colour"
    static let motionLabel = "Motion"
    static let widthLabel = "Width"
    static let speedLabel = "Speed"

    static let rowTitles = ["One", "Two"]
    /// In the order of `RateConstants.refreshIntervalChoices`. `SettingsFormTests`
    /// asserts the two have the same length; nothing can assert they mean the
    /// same thing, so keep them adjacent in any edit.
    static let intervalTitles = ["Every minute", "Every 3 minutes",
                                 "Every 5 minutes", "Every 15 minutes"]
    static let schemeTitles = ["Monochrome", "Classic", "Accessible"]
    static let motionTitles = ["Scroll", "Step"]

    /// Spec §4.1: the resulting cadence, live beside the choice, "so the floor
    /// is never a silent override".
    ///
    /// The parenthetical appears only when a floor actually binds, and
    /// `Diagnosis.pacerThrottlesSettings` is asked rather than re-derived —
    /// it is the same question `squigglectl doctor` reports on, and two
    /// answers to it would be one too many.
    static func effectiveInterval(userIntervalSeconds: Double,
                                  watchlistCount: Int) -> String {
        let chosen = intervalTitles[SettingsForm.interval.index(of: userIntervalSeconds)]
        guard Diagnosis.pacerThrottlesSettings(userIntervalSeconds: userIntervalSeconds,
                                               watchlistCount: watchlistCount) else {
            return chosen
        }
        // R144: `.regular` and Low Power off, matching `pacerThrottlesSettings`
        // exactly — a number that changed after hours would read as a fault in
        // whichever control the user had just touched.
        let cycle = RefreshPolicy.cycleInterval(userIntervalSeconds: userIntervalSeconds,
                                                watchlistCount: watchlistCount,
                                                marketState: .regular,
                                                lowPowerMode: false)
        let symbols = watchlistCount == 1 ? "1 symbol" : "\(watchlistCount) symbols"
        return "\(chosen) (\(minutes(cycle)) min with \(symbols))"
    }

    static let launchAtLoginLabel = "Open at Login"
    static let openLoginItems = "Open Login Items…"

    /// The note under the checkbox. A refusal outranks the state, because the
    /// state is the same before and after one — that sameness is what made the
    /// old silent failure unreadable.
    ///
    /// Domain and code and nothing else: R44 wants this line safe to paste
    /// into a support email, and `LoginItemFailure` has already thrown away
    /// the parts of the error that name files.
    static func loginItemNote(for state: LoginItemState,
                              failure: LoginItemFailure?) -> String? {
        guard let failure else { return Self.loginItemNote(for: state) }
        let refusal = "macOS refused the change (\(failure.domain) \(failure.code))."
        // Joined, not replaced. `.needsApproval`'s sentence is the only thing
        // pointing at System Settings, and a domain and a code leave the user
        // holding a number with nowhere to take it.
        guard let existing = Self.loginItemNote(for: state) else { return refusal }
        return "\(refusal) \(existing)"
    }

    /// `nil` for the two states a checkbox already explains. The other two
    /// need a sentence because their fix is not in this window (R146).
    static func loginItemNote(for state: LoginItemState) -> String? {
        switch state {
        case .on, .off:
            return nil
        case .needsApproval:
            return "Turned off in System Settings."
        case .unavailable:
            return "Available when Squiggle is running from an app bundle."
        }
    }
}
