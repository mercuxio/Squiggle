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
    /// 1 or 2. Anything else is nonsense from a hand-edited file.
    public var rows: Int
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
    public var launchAtLogin: Bool

    /// The bounds `init(from:)` clamps to, named so that a control cannot be
    /// built with a different range (R143). A slider that reaches 1,400 points
    /// is a width the user sets, sees applied, and loses on the next launch,
    /// with nothing anywhere reporting the reversal.
    public static let speedRange: ClosedRange<Double> = 4...200
    public static let widthRange: ClosedRange<Double> = 60...1200
    /// Spec §5.1 offers one row or two. Anything else is a hand-edited file.
    public static let rowChoices: [Int] = [1, 2]

    public init(refreshIntervalSeconds: Double = RateConstants.defaultRefreshInterval,
                rows: Int = 2,
                scrollPointsPerSecond: Double = 24,
                colorScheme: String = "monochrome",
                motionMode: String = "scroll",
                maxVisibleWidth: Double = 260,
                launchAtLogin: Bool = false) {
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.rows = rows
        self.scrollPointsPerSecond = scrollPointsPerSecond
        self.colorScheme = colorScheme
        self.motionMode = motionMode
        self.maxVisibleWidth = maxVisibleWidth
        self.launchAtLogin = launchAtLogin
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

        let rawRows = c.lenient(Int.self, .rows, default: defaults.rows)
        rows = Settings.rowChoices.contains(rawRows) ? rawRows : defaults.rows

        let speed = finiteOrDefault(.scrollPointsPerSecond, defaults.scrollPointsPerSecond)
        scrollPointsPerSecond = min(max(speed, Settings.speedRange.lowerBound),
                                    Settings.speedRange.upperBound)

        colorScheme = c.lenient(String.self, .colorScheme, default: defaults.colorScheme)
        motionMode = c.lenient(String.self, .motionMode, default: defaults.motionMode)

        let width = finiteOrDefault(.maxVisibleWidth, defaults.maxVisibleWidth)
        maxVisibleWidth = min(max(width, Settings.widthRange.lowerBound),
                              Settings.widthRange.upperBound)

        launchAtLogin = c.lenient(Bool.self, .launchAtLogin, default: defaults.launchAtLogin)
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
    public var settings: Settings
    /// The single wall-clock value in the package: a backoff deadline that has
    /// to survive process termination, or a user could relaunch their way
    /// around a 429 and get their IP banned.
    public var cooldownUntilEpoch: Double?

    public init(schemaVersion: Int = Store.currentSchemaVersion,
                symbols: [Symbol] = [],
                settings: Settings = Settings(),
                cooldownUntilEpoch: Double? = nil) {
        self.schemaVersion = schemaVersion
        self.symbols = symbols
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
