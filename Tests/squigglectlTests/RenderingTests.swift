import Foundation
import Testing
import TickerCore
@testable import squigglectl

/// `Rendering.diagnosis(_:)`'s own doc comment calls it the one place
/// `squigglectl watch` (and eventually `doctor`) translates a `TickerError`
/// into a line a person reads — and that output must be safe to paste into a
/// support email: no absolute filesystem paths.

@Test func aQuarantinedStoreReportsOnlyItsLastPathComponent() throws {
    let url = URL(fileURLWithPath: "/Users/example/Library/Application Support/Squiggle/watchlist.json")
    let text = Rendering.diagnosis(.storeCorrupt(quarantinedAt: url))
    #expect(!text.contains("/"), "leaked an absolute path: \(text)")
    #expect(text.contains("watchlist.json"))
}

/// Finding 3 (fix round 1): `.storeQuarantineFailed` rendered `url.path`
/// verbatim — a full absolute path through the user's home directory —
/// unlike its sibling case `.storeCorrupt` immediately above it, which
/// already redacts to `.lastPathComponent`. Asserted the same way: absence
/// of any `/`, which `url.path` could never pass.
@Test func aStoreThatCouldNotBeQuarantinedReportsOnlyItsLastPathComponent() throws {
    let url = URL(fileURLWithPath: "/Users/example/Library/Application Support/Squiggle/watchlist.json")
    let text = Rendering.diagnosis(.storeQuarantineFailed(at: url))
    #expect(!text.contains("/"), "leaked an absolute path: \(text)")
    #expect(text.contains("watchlist.json"))
}
