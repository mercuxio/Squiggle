import Foundation
import Testing

/// F14. The purity rule is the oldest constraint in this project and it was
/// enforced entirely by everyone remembering it.
///
/// `TickerCore` is pure: no AppKit, no SwiftUI, no `UserDefaults`, no
/// `URLSession`, no `Network`, no timers, no clocks, no randomness, no
/// user-facing strings. Foundation value types and Foundation *file* APIs are
/// permitted, which is why `WatchlistStore` is allowed to live here. Every one
/// of those exclusions is written down in the plan's Global Constraints and in
/// the spec, and several are re-stated in a doc comment on the type they
/// constrain — and a rule that lives only in prose is exactly the defect
/// signature this review keeps finding. Nothing failed when the rule broke.
///
/// One boundary this scanner does not try to cross, and does not need to: a
/// block comment on the same line, as in `/* note */ import AppKit`, reads as a
/// first word of `/*` and is skipped. That is deliberate. Stripping block
/// comments to catch it would mean deciding whether `/* import AppKit */` is an
/// import, and a scanner that answers that wrong reports a violation where
/// there is none — a worse failure than missing a spelling nobody writes by
/// accident. This is a guard against a forbidden import arriving unnoticed, not
/// a defence against one being hidden on purpose.
///
/// The check is on `import` lines and nothing else, deliberately. A scanner
/// that also went looking for `Date()` or `Timer` or `random` in the body text
/// would be a grep with opinions: it would fire on the word inside a comment,
/// on `MonotonicClock`'s and `Randomizing`'s own protocol declarations — which
/// exist precisely so the impure thing is injected from outside, and are the
/// mechanism that keeps the rule rather than a breach of it — and on
/// `ISO8601DateFormatter`, a Foundation value type. Imports are different in
/// kind: a module is either linked into this target or it is not, the line
/// that links it is unambiguous, and every capability the rule excludes
/// arrives through one. AppKit, SwiftUI, Network, Dispatch and Combine cannot
/// be reached from `TickerCore` without one of these lines.
enum TickerCoreSource {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // TickerCoreTests
        .deletingLastPathComponent()      // Tests
        .deletingLastPathComponent()      // repository root
        .appendingPathComponent("Sources/TickerCore")

    /// The modules `text` imports, in the order the lines appear.
    ///
    /// One definition, used by both the production scan and the test that
    /// proves the scan can see a violation — a second copy would be free to
    /// drift into agreeing with the first about nothing.
    static func modules(in text: String) -> [String] {
        text.split(separator: "\n").compactMap { line -> String? in
            var rest = line.drop(while: { $0 == " " || $0 == "\t" })
            // `@preconcurrency import Foundation` and friends.
            while rest.hasPrefix("@") {
                rest = rest.drop(while: { !$0.isWhitespace })
                    .drop(while: { $0.isWhitespace })
            }
            var words = rest.split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
            // Not `hasPrefix("import ")`. Swift separates the keyword from the
            // module with any whitespace, so a literal space in the one gate
            // that decides whether a line is an import at all made
            // `import<TAB>AppKit` invisible to this scanner while `swiftc`
            // compiled it happily. Splitting on whitespace first and comparing
            // the whole first word costs nothing and cannot drift from what
            // the compiler accepts. `importantThing` is not `import`, and a
            // `//` line still yields `//` as its first word.
            guard words.first == "import" else { return nil }
            words.removeFirst()
            // `import struct Foundation.Data` — the kind, then the path.
            let kinds = ["typealias", "struct", "class", "enum", "protocol",
                         "var", "let", "func"]
            if let first = words.first, kinds.contains(first) { words.removeFirst() }
            guard let path = words.first else { return nil }
            return path.split(separator: ".").first.map(String.init)
        }
    }

    /// Every `.swift` file in a directory, paired with the modules it imports.
    static func importsByFile(in directory: URL = TickerCoreSource.directory) throws
        -> [(file: String, modules: [String])] {
        let names = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()

        return try names.map { name in
            let text = try String(contentsOf: directory.appendingPathComponent(name),
                                  encoding: .utf8)
            return (file: name, modules: modules(in: text))
        }
    }
}

/// The modules that would end the purity rule the moment one of them appeared.
/// Named individually as well as excluded by the allowlist below, so a failure
/// says *which* rule broke and not merely that something new arrived.
private let forbiddenModules: Set<String> = [
    "AppKit", "SwiftUI", "UIKit", "Cocoa", "Carbon",
    "Network", "CoreWLAN", "SystemConfiguration",
    "Dispatch", "Combine", "os", "OSLog",
    "ServiceManagement", "CoreGraphics", "QuartzCore",
    "Security", "CryptoKit", "Darwin", "Glibc",
]

/// The modules `TickerCore` is allowed to link. One entry, and that is the
/// point: the rule is not "avoid a list of bad modules", it is "Foundation
/// value types and Foundation file APIs, and nothing else". A new import is a
/// decision about the architecture and should cost a deliberate edit to this
/// line rather than passing unremarked.
private let permittedModules: Set<String> = ["Foundation"]

@Test func tickerCoreImportsNothingThatWouldMakeItImpure() throws {
    let scanned = try TickerCoreSource.importsByFile()

    // The scanner has to be shown to have looked before its silence means
    // anything: a parse that matched nothing, or a `directory` that stopped
    // resolving, would pass on an empty result and report the target as pure
    // forever. Two guards, because the interesting failure is vacuity.
    //
    // The file count is bounded below so a moved path fails here. The module
    // *set* is then pinned to exactly `["Foundation"]`, which is both the
    // liveness proof — a scan that matched nothing gives an empty set and
    // fails — and the rule itself, stated once over the whole target.
    //
    // Note what it is not: "every file imports Foundation". Most of this
    // target imports nothing at all, which is the purity rule at its strongest
    // rather than a gap in it — and since that is a statement about the code
    // and not about the scan, it is taken below rather than described here.
    #expect(scanned.count >= 20, "found only \(scanned.count) sources — did the path move?")
    let found = Set(scanned.flatMap(\.modules))
    #expect(found == permittedModules,
            "TickerCore links \(found.sorted()); it may link only \(permittedModules.sorted())")

    let importFree = scanned.filter { $0.modules.isEmpty }.count
    #expect(importFree > scanned.count / 2,
            "only \(importFree) of \(scanned.count) sources import nothing at all")

    for (file, modules) in scanned {
        for module in modules {
            #expect(!forbiddenModules.contains(module),
                    "TickerCore/\(file) imports \(module), which ends the purity rule")
            #expect(permittedModules.contains(module),
                    "TickerCore/\(file) imports \(module); TickerCore may link only Foundation")
        }
    }
}

/// The companion the test above needs to be worth anything: the scanner must
/// actually see a forbidden import when there is one, in each of the forms an
/// import can take. Run against a scratch directory rather than against
/// `Sources/TickerCore`, because the alternative is writing `import Network`
/// into the real target and trusting the cleanup.
@Test func theImportScannerSeesEveryFormAnImportCanTake() throws {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("tickercore-purity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    let sample = """
        @preconcurrency import Network
        import struct Foundation.Data
          import AppKit
        import\tCoreGraphics
        // import SwiftUI
        let importantThing = 1
        """
    try sample.write(to: scratch.appendingPathComponent("Sample.swift"),
                     atomically: true, encoding: .utf8)

    let scanned = try TickerCoreSource.importsByFile(in: scratch)
    let modules = try #require(scanned.first).modules
    #expect(modules == ["Network", "Foundation", "AppKit", "CoreGraphics"])

    // Both halves of the production assertion fire on this input.
    #expect(modules.contains(where: { forbiddenModules.contains($0) }))
    #expect(modules.contains(where: { !permittedModules.contains($0) }))

    // A commented-out import is not an import, and neither is an identifier
    // that merely begins with the word — the two ways a line-oriented scan
    // over-reports.
    #expect(!modules.contains("SwiftUI"))
    #expect(modules.count == 4)

    // The tab is the case this test did not cover and the scanner did not see:
    // `swiftc` compiles `import<TAB>CoreGraphics`, and a gate written as
    // `hasPrefix("import ")` returned nothing for it, so the purity suite
    // stayed green over a module that ends the purity rule. Verified by
    // mutation before the fix landed, by pasting exactly this line into
    // `Quote.swift` with an `NSColor` extension beneath it and watching the
    // production scan pass.
    #expect(modules.contains("CoreGraphics"))
}

/// F15. The clock and randomness rules name their sanctioned exceptions by
/// call site — "that call is the module's only clock read... adding a second
/// one is a defect" — and there were two clock reads, not one.
/// `FileWatchlistStore.freshStamp()` calls `Date()`, and the rule as written
/// said flatly that there is no `Date()` anywhere in the module. The ruling on
/// this review is that the stamp is a sanctioned exception rather than a
/// breach: it names a quarantine file and is never a value the app computes
/// with, `setAside(stamp:)` takes it as a parameter so every test supplies its
/// own, and the default argument exists only because `load()`'s quarantine
/// path has no clock to reach for. The plan and the spec now say so.
///
/// This is the sentence that made the omission survivable, so this is the
/// sentence that gets an executable form. A census, not a ban: the three call
/// sites are listed by name, and *both* directions fail — a fourth impure call
/// site appears in the diff, and a listed one that goes away stops being
/// listed. Line comments are stripped first, because `RequestPacer` discusses
/// `ProcessInfo.systemUptime` in prose and a scan that counted that would be
/// measuring the documentation it exists to hold honest.
@Test func theOnlyImpureCallSitesInTickerCoreAreTheOnesTheRulesName() throws {
    let names = try FileManager.default
        .contentsOfDirectory(atPath: TickerCoreSource.directory.path)
        .filter { $0.hasSuffix(".swift") }
        .sorted()

    // `Date()` is the wall clock, `systemUptime` the monotonic one,
    // `Double.random` the randomness — the three spellings the rules quote,
    // which is what keeps this a check on the rules rather than a second
    // opinion about them.
    //
    // The rest are the near-synonyms the final review demonstrated would pass
    // unseen: a fourth clock read spelled `Date.now` defeated the census while
    // reading identically to a human. They quote no rule, so they are listed
    // second and are expected to match nothing. That is the point — each one
    // is inert until the day someone reaches for it, and on that day the
    // census fails instead of shrugging.
    let impureCalls = ["Date()", "systemUptime", "Double.random(",
                       "Date.now", "Date.timeIntervalSinceNow",
                       "Int.random(", "arc4random", "ContinuousClock(",
                       "SuspendingClock(", "DispatchTime.now"]

    var offenders: [String: [String]] = [:]
    for name in names {
        let text = try String(contentsOf: TickerCoreSource.directory
            .appendingPathComponent(name), encoding: .utf8)
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.components(separatedBy: "//").first ?? "" }
            .joined(separator: "\n")
        let found = impureCalls.filter { code.contains($0) }
        if !found.isEmpty { offenders[name] = found }
    }

    #expect(offenders["MonotonicClock.swift"] == ["systemUptime"])
    #expect(offenders["Randomizing.swift"] == ["Double.random("])
    #expect(offenders["WatchlistStore.swift"] == ["Date()"])
    #expect(Set(offenders.keys) == ["MonotonicClock.swift",
                                    "Randomizing.swift",
                                    "WatchlistStore.swift"],
            "clock or randomness call sites TickerCore's rules do not sanction: \(offenders)")
}
