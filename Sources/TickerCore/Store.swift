import Foundation

/// The one decode this file uses, for every field in both structs.
///
/// The store file is user-editable **by design** — the support policy is
/// literally "email me your squiggle.json" — so a typo in a cosmetic setting
/// must never cost the user their watchlist. `decodeIfPresent` alone does not
/// give that: it returns `nil` only for an *absent* or *null* key, while a key
/// that is present with the wrong type throws `DecodingError.typeMismatch`,
/// which propagates out of the decode, into `FileWatchlistStore.load()`'s
/// `catch`, and renames the user's file away. `{"rows":"one"}` is a typo, not
/// a corrupt file.
///
/// So every field degrades a mismatch to its default instead. Structural, not
/// incidental: the asymmetry this replaced hardened only the three `Double`
/// fields, and only because they happened to need a `catch` for a different
/// reason.
extension KeyedDecodingContainer {
    /// `nil` when the key is absent, null, or unreadable as `T`.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        do {
            return try decodeIfPresent(type, forKey: key)
        } catch {
            return nil
        }
    }

    func lenient<T: Decodable>(_ type: T.Type, _ key: Key, default fallback: T) -> T {
        lenient(type, key) ?? fallback
    }
}

/// One watchlist entry as it appears on disk.
///
/// Decoding a single entry can never fail, so one non-string element in
/// `symbols` costs one entry rather than the whole array: `["AAPL", 7, "MSFT"]`
/// keeps AAPL and MSFT. Decoding `[String]` in one go is all-or-nothing and
/// would lose both.
private struct WatchlistEntry: Decodable {
    let raw: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        raw = try? c.decode(String.self)
    }
}

/// Everything the user can configure. Every field decodes through `lenient`
/// with a default, so a file written by any version of Squiggle loads in any
/// other, and a hand-edited value of the wrong type costs that one setting
/// rather than the file.
public struct Settings: Codable, Equatable, Sendable {
    public var refreshIntervalSeconds: Double
    /// "one" | "two" | "flip" (spec §5.1 plus Flip), stored verbatim with the
    /// same carry-through contract as `colorScheme`: an unknown word is kept
    /// rather than rejected, so a file written by a later Squiggle survives a
    /// downgrade unchanged.
    ///
    /// This is the display setting; `rows` is derived from it. The other way
    /// round would not work — "flip" is not a row count — and storing both
    /// independently would let them contradict each other in a file the user
    /// is invited to hand-edit.
    public var display: String
    public var scrollPointsPerSecond: Double
    /// "monochrome" | "classic" | "accessible" (spec §5.3), stored verbatim:
    /// an unknown value is carried through rather than rejected, so a file
    /// written by a future version survives a downgrade unchanged. The
    /// consumer maps the string to its own enum and defaults there — this type
    /// does not know the menu, and it must not learn `NSColor`.
    public var colorScheme: String
    /// "scroll" | "step" (spec §5.1). Same carry-through contract as
    /// `colorScheme`. Step is *forced* when Reduce Motion is on, which is a
    /// decision the renderer makes at draw time and never writes back here —
    /// the setting records what the user chose, not what accessibility
    /// overrode it with.
    public var motionMode: String
    public var maxVisibleWidth: Double

    /// The bounds `init(from:)` clamps to, named so that a control cannot be
    /// built with a different range (R143). A slider that reaches 1,400 points
    /// is a width the user sets, sees applied, and loses on the next launch,
    /// with nothing anywhere reporting the reversal.
    public static let speedRange: ClosedRange<Double> = 4...200
    public static let widthRange: ClosedRange<Double> = 60...1200
    /// Spec §5.1 offers one row or two; Flip is the third. Anything else is a
    /// hand-edited file or a later version's word.
    public static let displayChoices: [String] = ["one", "two", "flip"]

    /// How many strips a display mode draws. Two rows means two; one row and
    /// Flip — which shows a single stock at a time — both mean one, and so
    /// does a word this build does not recognise.
    ///
    /// The whole app asks `settings.rows` and gets this answer, which is what
    /// keeps Flip from needing its own guard in every place that cares about
    /// the row count: the dropdown's columns, the manual row split and the
    /// strip metrics all see one row and behave as they already did.
    public static func rowCount(for display: String) -> Int {
        display == "two" ? 2 : 1
    }

    /// 1 or 2, derived from `display` and never stored on its own. Still
    /// *written* to the file by `encode(to:)` so that a build which has never
    /// heard of `display` reads a row count it understands.
    public var rows: Int { Settings.rowCount(for: display) }

    public init(refreshIntervalSeconds: Double = RateConstants.defaultRefreshInterval,
                display: String = "two",
                scrollPointsPerSecond: Double = 24,
                colorScheme: String = "monochrome",
                motionMode: String = "scroll",
                maxVisibleWidth: Double = 260) {
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.display = display
        self.scrollPointsPerSecond = scrollPointsPerSecond
        self.colorScheme = colorScheme
        self.motionMode = motionMode
        self.maxVisibleWidth = maxVisibleWidth
    }

    /// Every number here is hostile input: the file is user-editable by
    /// design, and an infinite width becomes a status item that cannot lay out.
    ///
    /// A huge exponent (`1e400`) has no JSON `NaN`/`Infinity` literal, and
    /// `JSONDecoder` does not quietly hand back `.infinity` for one either —
    /// it throws `numberIsNotRepresentableInSwift`. `lenient` absorbs that per
    /// field, so one hostile number degrades only its own setting rather than
    /// costing the user every other one.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()

        func finiteOrDefault(_ key: CodingKeys, _ fallback: Double) -> Double {
            let value = c.lenient(Double.self, key, default: fallback)
            // Belt and braces. No JSON literal is non-finite and `1e400`
            // throws in `lenient` before it gets here, so nothing reachable
            // through this decoder fails this guard — it is here so that a
            // future caller handing `Settings` a decoder that *can* produce
            // `NaN` (a plist, a fuzz harness) still cannot hand `NaN` to
            // `min`/`max`, which propagate it silently.
            guard value.isFinite else { return fallback }
            return value
        }

        // Rejected at the input rather than clamped, and rejected against the
        // menu Settings actually offers, because `RefreshPolicy.cycleInterval`
        // does exactly that (`RateConstants.offeredRefreshIntervals`). A
        // second, different bound here would mean a file saying `7200` is
        // clamped to one number by the store, replaced by another in the
        // policy, and re-saved as a third — with the persisted one a lie about
        // what the app is running on.
        let interval = finiteOrDefault(.refreshIntervalSeconds, defaults.refreshIntervalSeconds)
        refreshIntervalSeconds = RateConstants.offeredRefreshIntervals.contains(interval)
            ? interval
            : RateConstants.defaultRefreshInterval

        // Carried through verbatim when present, migrated from the legacy
        // `rows` key when not: every file written before Flip existed says
        // `"rows": 1` or `"rows": 2` and nothing else, and reading those as
        // the default would silently move a one-row user to two.
        if let storedDisplay = c.lenient(String.self, .display) {
            display = storedDisplay
        } else {
            let rawRows = c.lenient(Int.self, .rows, default: defaults.rows)
            display = rawRows == 1 ? "one" : defaults.display
        }

        let speed = finiteOrDefault(.scrollPointsPerSecond, defaults.scrollPointsPerSecond)
        scrollPointsPerSecond = min(max(speed, Settings.speedRange.lowerBound),
                                    Settings.speedRange.upperBound)

        colorScheme = c.lenient(String.self, .colorScheme, default: defaults.colorScheme)
        motionMode = c.lenient(String.self, .motionMode, default: defaults.motionMode)

        let width = finiteOrDefault(.maxVisibleWidth, defaults.maxVisibleWidth)
        maxVisibleWidth = min(max(width, Settings.widthRange.lowerBound),
                              Settings.widthRange.upperBound)
    }

    /// Spelled out because `rows` is computed, and a synthesised enum lists
    /// stored properties only — `init(from:)` has to be able to read the
    /// legacy key, and `encode(to:)` has to be able to write it.
    enum CodingKeys: String, CodingKey {
        case refreshIntervalSeconds
        case display
        case rows
        case scrollPointsPerSecond
        case colorScheme
        case motionMode
        case maxVisibleWidth
    }

    /// Writes `rows` alongside `display` even though nothing here reads it
    /// back as state.
    ///
    /// It is there for the *other* Squiggle: the user who keeps 1.0.3 in
    /// /Applications and runs this build from a download. That version knows
    /// only `rows`, and a file without it would move them to two rows the
    /// first time they opened it. One derived key is a cheaper bargain than
    /// a settings file that reads differently depending on which copy of the
    /// app opens it.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(refreshIntervalSeconds, forKey: .refreshIntervalSeconds)
        try c.encode(display, forKey: .display)
        try c.encode(rows, forKey: .rows)
        try c.encode(scrollPointsPerSecond, forKey: .scrollPointsPerSecond)
        try c.encode(colorScheme, forKey: .colorScheme)
        try c.encode(motionMode, forKey: .motionMode)
        try c.encode(maxVisibleWidth, forKey: .maxVisibleWidth)
    }
}

/// The whole persisted document.
///
/// Note what is absent: no prices, no cached quotes, no cookies, no crumbs, no
/// tokens. The support policy (spec §6) is "email me your squiggle.json", and
/// anything secret in this file would become a leak channel the moment a user
/// followed that advice.
public struct Store: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var symbols: [Symbol]
    /// How many *leading* symbols the user put in the menu bar's first row,
    /// the rest being the second. `nil` means nobody has arranged this
    /// watchlist by hand and `RowSplitter` may still balance it by width.
    ///
    /// One integer, not a row per symbol, because the dropdown that sets this
    /// reorders `symbols` in the same gesture — see `RowSplitter.split`. The
    /// two fields therefore cannot contradict each other the way a parallel
    /// array of row numbers could.
    ///
    /// `schemaVersion` deliberately does not move for this, which is R120's
    /// ruling applied again: every field here decodes leniently with a
    /// default, so a file carrying this key loads in a build that has never
    /// heard of it. Bumping the version would instead make this build's file
    /// unreadable to the older Squiggle the user may still have on disk, which
    /// is a worse outcome than one ignored key.
    public var rowOneCount: Int?
    public var settings: Settings
    /// The single wall-clock value in the package: a backoff deadline that has
    /// to survive process termination, or a user could relaunch their way
    /// around a 429 and get their IP banned.
    public var cooldownUntilEpoch: Double?

    public init(schemaVersion: Int = Store.currentSchemaVersion,
                symbols: [Symbol] = [],
                rowOneCount: Int? = nil,
                settings: Settings = Settings(),
                cooldownUntilEpoch: Double? = nil) {
        self.schemaVersion = schemaVersion
        self.symbols = symbols
        self.rowOneCount = rowOneCount
        self.settings = settings
        self.cooldownUntilEpoch = cooldownUntilEpoch
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // Lenient here, strict in `FileWatchlistStore.load()`. The decoder's
        // job is never to destroy data: an unreadable version read here must
        // not throw, because a throw out of this initialiser is what sets the
        // file aside. Refusing a version this build cannot honour is the
        // gate's job, and the gate leaves the file exactly where it is.
        schemaVersion = c.lenient(Int.self, .schemaVersion, default: Store.currentSchemaVersion)

        // Symbols arrive as strings. An invalid one is dropped rather than
        // fatal: losing one bad entry beats losing the whole watchlist. That
        // holds for a wrong *type* too — see `WatchlistEntry`.
        let rawSymbols = c.lenient([WatchlistEntry].self, .symbols, default: [])
            .compactMap(\.raw)
        var seen = Set<String>()
        symbols = Array(rawSymbols
            .compactMap(Symbol.init)
            .filter { seen.insert($0.raw).inserted }
            .prefix(RateConstants.maxWatchlistCount))

        // Clamped against the watchlist that survived the lines above, not
        // against the one the file was written for: dropping an invalid symbol
        // shortens `symbols`, and a boundary past the end would send every
        // remaining symbol to row 1 and leave row 2 empty. Absent stays absent
        // — `nil` is "never arranged by hand", which is a different statement
        // from "arranged, with none in row 1".
        //
        // Written as a `let` and an `if`, not `.map`: inside `init(from:)` a
        // closure body mentioning `symbols` resolves it as `self.symbols` and
        // so captures a half-initialised `self`, which Swift rejects.
        let liveCount = symbols.count
        if let rawRowOne = c.lenient(Int.self, .rowOneCount) {
            rowOneCount = min(max(rawRowOne, 0), liveCount)
        } else {
            rowOneCount = nil
        }

        settings = c.lenient(Settings.self, .settings, default: Settings())

        // As in `Settings`: a huge exponent makes `JSONDecoder` throw
        // `numberIsNotRepresentableInSwift` rather than hand back `.infinity`,
        // so `lenient` treats it the same as an absent cooldown.
        let cooldown = c.lenient(Double.self, .cooldownUntilEpoch)
        // Belt and braces, exactly as in `Settings.finiteOrDefault`: nothing
        // reachable through JSON can be non-finite here, since `1e400` throws
        // in `lenient` above rather than arriving as `.infinity`.
        cooldownUntilEpoch = (cooldown?.isFinite ?? false) ? cooldown : nil
    }
}
