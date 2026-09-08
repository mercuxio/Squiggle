import Foundation

/// Everything the user can configure. Every field decodes with
/// `decodeIfPresent` and a default, so a file written by any version of
/// Squiggle loads in any other.
public struct Settings: Codable, Equatable, Sendable {
    public var refreshIntervalSeconds: Double
    /// 1 or 2. Anything else is nonsense from a hand-edited file.
    public var rows: Int
    public var scrollPointsPerSecond: Double
    /// "auto" | "monochrome" | "color". A string rather than an enum so an
    /// unknown value from a future version degrades to the default instead of
    /// failing the decode.
    public var colorScheme: String
    public var maxVisibleWidth: Double
    public var launchAtLogin: Bool

    public init(refreshIntervalSeconds: Double = RateConstants.defaultRefreshInterval,
                rows: Int = 1,
                scrollPointsPerSecond: Double = 24,
                colorScheme: String = "auto",
                maxVisibleWidth: Double = 260,
                launchAtLogin: Bool = false) {
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.rows = rows
        self.scrollPointsPerSecond = scrollPointsPerSecond
        self.colorScheme = colorScheme
        self.maxVisibleWidth = maxVisibleWidth
        self.launchAtLogin = launchAtLogin
    }

    /// Every number here is hostile input: the file is user-editable by
    /// design, and an infinite width becomes a status item that cannot lay out.
    ///
    /// A huge exponent (`1e400`) has no JSON `NaN`/`Infinity` literal, but
    /// `JSONDecoder` does not quietly hand back `.infinity` for one either —
    /// it throws `numberIsNotRepresentableInSwift`. That is caught per field
    /// here, not once for the whole decode, so one hostile number degrades
    /// only its own setting rather than costing the user every other one.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()

        func finiteOrDefault(_ key: CodingKeys, _ fallback: Double) -> Double {
            let value: Double?
            do {
                value = try c.decodeIfPresent(Double.self, forKey: key)
            } catch {
                value = nil
            }
            guard let value, value.isFinite else { return fallback }
            return value
        }

        let interval = finiteOrDefault(.refreshIntervalSeconds, defaults.refreshIntervalSeconds)
        refreshIntervalSeconds = min(max(interval, RateConstants.spacingSeconds), 3600)

        let rawRows = try c.decodeIfPresent(Int.self, forKey: .rows) ?? defaults.rows
        rows = (rawRows == 2) ? 2 : 1

        let speed = finiteOrDefault(.scrollPointsPerSecond, defaults.scrollPointsPerSecond)
        scrollPointsPerSecond = min(max(speed, 4), 200)

        colorScheme = try c.decodeIfPresent(String.self, forKey: .colorScheme)
            ?? defaults.colorScheme

        let width = finiteOrDefault(.maxVisibleWidth, defaults.maxVisibleWidth)
        maxVisibleWidth = min(max(width, 60), 1200)

        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)
            ?? defaults.launchAtLogin
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
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Store.currentSchemaVersion

        // Symbols arrive as strings. An invalid one is dropped rather than
        // fatal: losing one bad entry beats losing the whole watchlist.
        let rawSymbols = try c.decodeIfPresent([String].self, forKey: .symbols) ?? []
        var seen = Set<String>()
        symbols = Array(rawSymbols
            .compactMap(Symbol.init)
            .filter { seen.insert($0.raw).inserted }
            .prefix(RateConstants.maxWatchlistCount))

        settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()

        // As in `Settings`: a huge exponent makes `JSONDecoder` throw
        // `numberIsNotRepresentableInSwift` rather than hand back `.infinity`,
        // so that is caught here and treated the same as an absent cooldown.
        let cooldown: Double?
        do {
            cooldown = try c.decodeIfPresent(Double.self, forKey: .cooldownUntilEpoch)
        } catch {
            cooldown = nil
        }
        cooldownUntilEpoch = (cooldown?.isFinite ?? false) ? cooldown : nil
    }
}
