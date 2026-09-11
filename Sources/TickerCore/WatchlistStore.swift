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
/// 1. **A missing file is not an error** — it is a first launch. An
///    *unreadable* one is an error, and the two must never be conflated:
///    answering "first launch" to a file that is there but cannot be read
///    hands the app an empty watchlist and then invites it to save that over
///    the user's real one.
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
        guard let data = try readIfPresent() else {
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
        //
        // The read itself must not swallow either. `try? Data(contentsOf:)`
        // stood here, so a file that existed but could not be read looked
        // exactly like no file at all: the gate was skipped and this method
        // wrote over it. Paired with the same `try?` in `load()`, that was a
        // two-step data loss with no error reported at either step — load
        // returns empty, save overwrites. `readIfPresent` throws instead, and
        // the throw happens before the write.
        if let existing = try readIfPresent() {
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

    /// The file's bytes, or `nil` when there is no file.
    ///
    /// Absence is read from the error the filesystem actually reports rather
    /// than from a `fileExists` probe taken a moment earlier: the probe answers
    /// a different question than the read that follows it, and every other
    /// failure — a chmod 000 after a restore, wrong ownership, an unreadable
    /// mount, a directory where the file should be — has to come back as a
    /// fault and not as a first launch.
    ///
    /// The fault reuses `storeQuarantineFailed(at:)` rather than introducing a
    /// case of its own. That case already means "the file is unreadable and is
    /// still sitting exactly where it was", which is this situation precisely;
    /// its payload is documented as where the file *is*, not where it went; and
    /// `Diagnosis.status(for:)` and `DoctorRun.classifyStoreError` already route
    /// it to the diagnosis this deserves — the store file degraded, the schema
    /// check skipped, because nothing here ever got far enough to read a
    /// version. Nothing is quarantined on this path: a file that cannot be read
    /// might be the user's only copy of their watchlist, and moving it is a
    /// decision for a caller who knows the contents are unusable, not for one
    /// that could not get the contents at all.
    private func readIfPresent() throws -> Data? {
        // Bounded before the read, because `Data(contentsOf:)` has no bound of
        // its own and neither does the decoder behind it. The store lives at a
        // path anything on the machine may write to, and the app reads it at
        // launch and after every settings change.
        //
        // The bound is derived from the largest document this program can
        // legitimately produce, not guessed. `RateConstants.maxWatchlistCount`
        // symbols of at most `Symbol`'s 32 characters, plus `Settings`' fields,
        // plus a version and a cooldown, pretty-printed and sorted, comes to
        // well under two kilobytes — `theWorstLegitimateStoreIsFarInsideTheSizeBound`
        // measures that rather than asserting it from memory. A mebibyte leaves
        // that worst case three orders of magnitude of room for hand-editing
        // (the file is user-editable by design, spec §6) while still refusing
        // the case that motivated this: a multi-hundred-megabyte file, which
        // one measurement on 2026-09-08 took 97.9 seconds and 2.6 GB of peak
        // footprint to load before answering with the same 20 symbols the cap
        // allows. Removing the version probe's separate parse would not have
        // helped — it was 3% of that time.
        //
        // Over the bound is a refusal, not a truncation and not a quarantine:
        // a prefix of a JSON document is not a smaller JSON document, and a
        // file this program will not read is not a file it knows enough about
        // to move.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = (attributes?[.size] as? NSNumber)?.int64Value,
           size > Self.maximumStoreBytes {
            throw TickerError.storeQuarantineFailed(at: url)
        }

        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        } catch {
            // Never the underlying error: `NSError`'s description for a read
            // failure carries this machine's absolute path to the store (R44),
            // and `TickerError` is the vocabulary every caller catches.
            throw TickerError.storeQuarantineFailed(at: url)
        }
    }

    /// The largest store file this program will read. See `readIfPresent`.
    static let maximumStoreBytes: Int64 = 1 << 20

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
        // Bounded below as well as above. `version <= currentSchemaVersion`
        // alone waves through `0` and `-5`: no Squiggle ever wrote those, so
        // the file was written by something else or damaged, and treating it as
        // "old enough to be safe" is exactly backwards — it would load under v1
        // rules and the next `save()` would rewrite it in v1's understanding.
        // Reported as `storeVersionUnreadable` rather than
        // `storeSchemaUnsupported(version:)` because there is nothing to
        // report: `doctor` would print "store schema -5 is not supported",
        // naming a version that never existed as though it were a newer
        // Squiggle's. Like every other arm of this gate, refusing leaves the
        // file exactly where it is — never quarantined.
        guard version >= 1 else {
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
    ///
    /// **This is one of `TickerCore`'s two sanctioned clock reads** (the other
    /// is `SystemClock`, under controller ruling R10), and the module's only
    /// `Date()`. The plan's Global Constraints and spec §2 both name it. What
    /// makes it an exception rather than a breach of "reads no clock": the
    /// stamp becomes part of a *file name* and is never a value the app
    /// computes with — nothing schedules on it, compares it, or shows it — and
    /// `setAside(stamp:)` takes it as a parameter, so every test supplies its
    /// own and the clock is out of every asserted path. The default argument
    /// exists only because `load()`'s quarantine branch has no clock to reach
    /// for; giving `FileWatchlistStore` an injected clock would push one into
    /// the app and the CLI in order to serve a filename.
    ///
    /// A third such call site anywhere in the module is a defect, and
    /// `theOnlyImpureCallSitesInTickerCoreAreTheOnesTheRulesName` fails when
    /// one appears.
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
