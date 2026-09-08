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
///    knew and this one does not. Refused on the way *in* and on the way
///    *out*: a gate on `load()` alone would let the app save over the very
///    file it just declined to read.
/// 3. **A corrupt file is set aside, not replaced in place.** The user gets a
///    working app back, and their old file is still there to recover from.
///    When it cannot be set aside, the caller is told that specifically —
///    `storeQuarantineFailed`, not a bare `NSError` no `catch let e as
///    TickerError` will match.
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
        try Self.refuseUnlessThisVersionCanHonour(data)

        do {
            return try JSONDecoder().decode(Store.self, from: data)
        } catch {
            // Hoisted out of the `throw`. Written as
            // `throw .storeCorrupt(quarantinedAt: try setAside())`, Swift
            // evaluates the `try` *first*, so a failed rename escaped as a raw
            // `NSError`: the decode error was lost, no `catch let e as
            // TickerError` matched, and the corrupt file stayed exactly where
            // it was to fail again on every relaunch. The quarantine path must
            // never be able to destroy the error that caused it.
            guard let quarantine = try? setAside() else {
                throw TickerError.storeQuarantineFailed(at: url)
            }
            throw TickerError.storeCorrupt(quarantinedAt: quarantine)
        }
    }

    public func save(_ store: Store) throws {
        // Rule 2 is only half a rule if it guards the read alone: `load()`
        // refuses a v99 file, and nothing stopped the app from calling `save()`
        // a moment later and destroying it anyway.
        if let existing = try? Data(contentsOf: url) {
            try Self.refuseUnlessThisVersionCanHonour(existing)
        }

        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // Readable, because the support policy is "email me your JSON";
        // sorted, because an unstable key order makes every diff noise.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(store).write(to: url, options: .atomic)
    }

    /// Throws unless the document's `schemaVersion` is one this build can read.
    /// Never touches the file: refusing is the whole point.
    ///
    /// An *unreadable* version is refused too, not only a readable-and-too-new
    /// one. A quoted `{"schemaVersion":"99"}` used to miss the `as? Int`, fall
    /// through to the decoder, fail the strict `Int` decode, and get the newer
    /// file **quarantined** — the exact outcome rule 2 exists to prevent,
    /// reached through a different door. A gate that fails open into a
    /// destructive path is worse than no gate.
    ///
    /// Silence about a version we cannot read would be no better: the file
    /// would load as v1 and the next `save()` would rewrite it in v1's
    /// understanding, discarding whatever wrote it.
    private static func refuseUnlessThisVersionCanHonour(_ data: Data) throws {
        guard let probe = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = probe["schemaVersion"] else {
            return          // absent, or not a JSON object at all
        }
        guard let version = raw as? Int else {
            throw TickerError.storeVersionUnreadable
        }
        guard version <= Store.currentSchemaVersion else {
            throw TickerError.storeSchemaUnsupported(version: version)
        }
    }

    /// Renames the unreadable file out of the way and returns where it went.
    ///
    /// Takes the stamp as a parameter, defaulted to the real clock for
    /// production callers, for the same reason `quarantineTarget` does: the
    /// exhaustion arm below is otherwise reachable only by racing a real
    /// second boundary with a thousand real files.
    func setAside(stamp: String = Self.freshStamp()) throws -> URL {
        guard let target = Self.quarantineTarget(directory: url.deletingLastPathComponent(),
                                                 base: url.lastPathComponent,
                                                 stamp: stamp) else {
            throw TickerError.storeQuarantineFailed(at: url)
        }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    /// Colons are legal in HFS+ paths but Finder renders them as slashes,
    /// which makes the saved file confusing to find and to describe over
    /// email.
    private static func freshStamp() -> String {
        ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
    }

    /// A name in `directory` that no earlier casualty already owns, or `nil`
    /// if the search gives up.
    ///
    /// Two corruptions inside the same second must not land on the same name —
    /// the first casualty is usually the more informative one. Bounded rather
    /// than an unbounded `while`: a thousand collisions in one second is not a
    /// case worth spinning for, and this project has already been bitten once
    /// by an unbounded loop turning a failure into a hang instead of a red
    /// test.
    ///
    /// On exhaustion it reports `nil` rather than the *unsuffixed* name it
    /// started from: that name belongs to a previous casualty, and returning
    /// it told the caller "your file is safely at X" while X was somebody
    /// else's data and the current file had not moved at all.
    ///
    /// Takes the stamp as an argument so the collision branch is reachable
    /// from a test without racing a second boundary.
    static func quarantineTarget(directory: URL, base: String, stamp: String) -> URL? {
        let first = directory.appendingPathComponent("\(base).bad-\(stamp)")
        guard FileManager.default.fileExists(atPath: first.path) else { return first }

        for suffix in 2...1_000 {
            let candidate = directory.appendingPathComponent("\(base).bad-\(stamp)-\(suffix)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
