import Foundation

public protocol WatchlistStore: Sendable {
    func load() throws -> Store
    func save(_ store: Store) throws
}

/// One JSON file, written atomically (spec §6).
///
/// Three rules, each of which exists because the alternative loses the user's
/// data:
///
/// 1. **A missing file is not an error** — it is a first launch.
/// 2. **A newer schema is refused, not rewritten.** A future Squiggle's file
///    must survive a downgrade; saving over it discards whatever that version
///    knew and this one does not.
/// 3. **A corrupt file is set aside, not replaced in place.** The user gets a
///    working app back, and their old file is still there to recover from.
public struct FileWatchlistStore: WatchlistStore {
    private let url: URL

    public init(url: URL) { self.url = url }

    public static func defaultURL(applicationName: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent(applicationName, isDirectory: true)
            .appendingPathComponent("squiggle.json")
    }

    public func load() throws -> Store {
        guard let data = try? Data(contentsOf: url) else {
            return Store()          // first launch
        }

        // Read the version before decoding the body: a v99 file may contain
        // shapes this version would mangle, and refusing must not set it aside.
        if let probe = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = probe["schemaVersion"] as? Int,
           version > Store.currentSchemaVersion {
            throw TickerError.storeSchemaUnsupported(version: version)
        }

        do {
            return try JSONDecoder().decode(Store.self, from: data)
        } catch {
            throw TickerError.storeCorrupt(quarantinedAt: try setAside())
        }
    }

    public func save(_ store: Store) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // Readable, because the support policy is "email me your JSON";
        // sorted, because an unstable key order makes every diff noise.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(store).write(to: url, options: .atomic)
    }

    /// Renames the unreadable file out of the way and returns where it went.
    private func setAside() throws -> URL {
        // Colons are legal in HFS+ paths but Finder renders them as slashes,
        // which makes the saved file confusing to find and to describe
        // over email.
        let stamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")

        let directory = url.deletingLastPathComponent()
        let base = url.lastPathComponent

        // Two corruptions inside the same second must not land on the same
        // name — the first casualty is usually the more informative one.
        // Bounded rather than an unbounded `while`: a thousand collisions in
        // one second is not a case worth spinning for, and this project has
        // already been bitten once by an unbounded loop turning a failure
        // into a hang instead of a red test.
        var target = directory.appendingPathComponent("\(base).bad-\(stamp)")
        if FileManager.default.fileExists(atPath: target.path) {
            var found: URL?
            for suffix in 2...1_000 {
                let candidate = directory.appendingPathComponent("\(base).bad-\(stamp)-\(suffix)")
                if !FileManager.default.fileExists(atPath: candidate.path) {
                    found = candidate
                    break
                }
            }
            guard let resolved = found else {
                throw TickerError.storeCorrupt(quarantinedAt: target)
            }
            target = resolved
        }

        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
}
