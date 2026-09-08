# Squiggle — TickerCore & squigglectl Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `TickerCore` (quote parsing, scheduling policy, rate limiting, persistence) and the `squigglectl` CLI that drives it, so that quotes can be fetched, watched across a full trading day, and diagnosed from the terminal — with a request budget that is asserted by a test rather than hoped for.

**Architecture:** A pure Swift library that performs no I/O and reads no clock. Time and randomness enter as injected parameters, so every scheduling decision is testable in microseconds against a fake clock. Networking enters through the `QuoteFetching` / `SymbolSearching` seams; the real `URLSession` implementation lives in a separate internal target so the CLI and (later) the app share exactly one copy of it. `squigglectl` is a thin, hand-rolled argument-parsing shell over the library.

**Tech Stack:** Swift 6, SwiftPM, swift-testing (as a package dependency), Foundation, Network (`NWPathMonitor`). No Xcode, no third-party runtime dependencies.

**Spec:** `docs/specs/2026-09-08-squiggle-design.md`

## Scope

This plan implements **steps 1–4 of the spec's build order (§9)**. It stops at a working CLI that has survived a real trading session. Steps 5–9 — the status item, the Core Animation strip, settings, the symbol picker, and packaging — are deliberately out of scope and get their own plan.

That boundary is the spec's own: *"No UI until the feed has survived a real trading session."* Task 19 is that session. Nothing in the app target may be written before it passes.

The deliverable is independently useful software: a `squigglectl` that fetches quotes, watches a watchlist across a market open and close, and produces an actionable diagnostic dump — plus the fully tested pure core the app will later sit on.

### Deferred to plan 2 (do not build here)

- `StripLayout` — spec §2.1 lists it as a core type, but its shape is determined by the renderer that consumes it. Building it before the renderer exists means guessing at an interface. `RowSplitter` **is** in this plan; it is named explicitly in build-order step 3 and its interface is fully determined (symbols and widths in, rows out).
- Everything in `Sources/Squiggle/`. The target is not even declared until plan 2.

### One flagged deviation from the spec

Spec §2 names three targets, and §3.1 says a change to the fetch implementation is *"confined to one file in the app target."* But `squigglectl quote` is build-order step **1** — the CLI needs that file long before the app target exists, and when the app arrives in plan 2 both executables would need identical copies of the one file most likely to need identical fixing.

This plan therefore adds a fourth target, `YahooFeed`: an **internal library target that is not a product**. The three shipping artifacts the spec names are unchanged, and every stated rule holds — `TickerCore` stays free of `URLSession`, the client remains one file, and both executables link the same copy.

**If you disagree with this, stop and say so before Task 1.** It is a structural decision and it is cheap to reverse only before the package manifest is written.

## Global Constraints

Every task's requirements implicitly include this section.

- **Platform floor:** macOS 14.0. Set `platforms: [.macOS(.v14)]` in `Package.swift`.
- **Architecture:** arm64 only. Do not add x86_64 handling anywhere.
- **Bundle identifier (fixed, permanent):** `com.houlanyit.Squiggle`. Not used in this plan — there is no app bundle yet — but do not invent a different one anywhere.
- **Toolchain:** Command Line Tools only — Xcode is **not** installed. `xcodebuild` and `actool` are unavailable. Do not write any step that calls them.
- **Every `swift build` / `swift test` / `swift run` invocation MUST pass `--build-system native`.** The default build system fails under Command Line Tools. It will print a deprecation warning about `native`; ignore it. This is not optional and applies to every command in every task.
- **Test framework:** swift-testing via the SPM dependency `https://github.com/swiftlang/swift-testing.git`. Neither `Testing` nor `XCTest` exists in the Command Line Tools SDK, so the dependency is mandatory. Use `import Testing`, `@Test`, `#expect`, `#require`.
- **Do not remove the swift-testing dependency, whatever the compiler says.** Every `@Test` emits a deprecation warning advising its removal. That advice is wrong on this machine: the toolchain ships the library but the CLT SDK does not expose the module, so removing the dependency turns every test file into `no such module 'Testing'`. The warnings are expected and are not a defect to fix.
- **It is the only dependency, and the only one that should ever be added.** `squigglectl` is the diagnostic path, so its argument parser stays hand-rolled rather than taking `swift-argument-parser`.
- **Never write `== true` or `== false` inside `#expect`.** The macro mis-resolves any comparison whose left operand is already `Bool` or `Bool?` — it checks that operand alone and discards the comparison, so `#expect(x == false)` compiles, reads correctly, and passes for every value of `x`. Write the plain condition (`#expect(x)`, `#expect(!x)`), supply a failing default for optionals (`#expect(x ?? false)`), or hoist the value into a `let` first. `??` inside `#expect` is mis-instrumented too. Task 1 pins this with a test.
- **`TickerCore` must not import AppKit, SwiftUI, `UserDefaults`, `URLSession`, or `Network`,** and must never produce user-facing strings. It vends typed errors; presentation is the caller's job. All CLI wording lives in `Sources/squigglectl/Rendering.swift`.
- **`TickerCore` reads no clock.** There is no `Date()` and no timer anywhere in it, and no logic anywhere in it reads the clock directly. **One sanctioned exception (controller ruling R10):** the three-line `SystemClock` adapter in `MonotonicClock.swift` calls `ProcessInfo.processInfo.systemUptime`, because a protocol needs a production conformer and `TickerCore` ships as a standalone library product. That call is the module's only clock read; everything else takes the injected protocol. Adding a second one is a defect. Monotonic time enters as an injected `MonotonicClock` **or** as a plain `Double` parameter; wall-clock epochs (trading periods, the persisted cooldown) enter as `Double` parameters supplied by the caller. This is how the epoch arithmetic the spec requires coexists with the no-clocks rule.
- **`TickerCore` generates no randomness.** `BackoffLadder` takes an injected `Randomizing`, so jitter is deterministic under test. Same sanctioned exception as the clock (R10): the `SystemRandom` adapter calls `Double.random(in:)` and is the module's only randomness source. It is also used as a *default argument* inside `TickerCore` (`BackoffLadder.init`, `FeedEngine.init`), so it cannot be moved to another module without breaking those signatures.
- **No `UserDefaults` anywhere, in any target.** One JSON file is the whole of persistence.
- **Never persist a quote and never persist a credential.** Not to the store, not to a cache, not to a log file, not to a fixture directory that ships. A 14-hour-old price painted as live at launch is the worst failure this app can have, and the "email me your JSON" support policy would turn any stored cookie into a leak channel.
- **Symbols are stored and transmitted verbatim** as Yahoo spells them — `^GSPC`, `BRK-B`, `VOD.L`, `BTC-USD`, `EURUSD=X`. Never normalised, never upper-cased, never trimmed of punctuation.
- **Watchlist cap: 20 symbols.** Enforced on decode, not only in the UI.
- **The 30-second request spacing floor is a safety property, not a preference.** No code path may bypass `RequestPacer`.
- **Commit after every task.** Conventional commit prefixes (`feat:`, `test:`, `chore:`, `docs:`).

---

## File Structure

```
Package.swift                              SPM manifest, 4 targets (3 products)
Sources/TickerCore/
  Symbol.swift               a Yahoo symbol, verbatim
  Quote.swift                Quote + Direction
  TradingPeriod.swift        pre/regular/post windows, MarketState
  TickerError.swift          the typed error surface
  LenientDouble.swift        number | string | {raw:,fmt:}
  YahooQuoteDecoding.swift   every pinned key path, dated
  YahooSearchDecoding.swift  search result parsing
  MonotonicClock.swift       injectable monotonic time
  Randomizing.swift          injectable randomness
  RateConstants.swift        the borrowed-and-unverified table, in one place
  RequestPacer.swift         token bucket — the floor
  Failure.swift              FailureKind: how a request went wrong
  BackoffLadder.swift        decorrelated jitter, per-class
  CircuitBreaker.swift       five strikes, half-open probe
  RefreshPolicy.swift        the whole scheduling decision, pure
  RowSplitter.swift          width-balanced dealing across rows
  WatchlistStore.swift       Store + Settings + WatchlistStoring + FileWatchlistStore
Sources/YahooFeed/
  YahooClient.swift          the only URLSession in the package
  NetworkReachability.swift  NWPathMonitor behind a protocol
Sources/squigglectl/
  main.swift                 entry point + dispatch
  Command.swift      the verb enum and hand-rolled parsing
  Commands.swift             quote / search / watch / doctor / probe
  Rendering.swift            every user-facing string in the CLI
Tests/TickerCoreTests/
  ExpectMacroTests.swift     the landmine, pinned
  Fakes.swift                FakeClock, FakeRandom, FakeFetcher, builders
  LenientDoubleTests.swift
  YahooQuoteDecodingTests.swift
  MutationTests.swift
  TruncationTests.swift
  TradingPeriodTests.swift
  RequestPacerTests.swift
  BackoffLadderTests.swift
  CircuitBreakerTests.swift
  RefreshPolicyTests.swift
  BudgetSweepTests.swift
  WatchlistStoreTests.swift
  RowSplitterTests.swift
  YahooSearchDecodingTests.swift
Tests/squigglectlTests/
  CommandTests.swift
  RenderingTests.swift
Tests/Fixtures/yahoo-2026-09-08/
  <captured bodies — see Task 3>
docs/fixture-capture-log.md  what is captured, what is still owed
```

---

## Task 1: Package skeleton and the `#expect` landmine

The spec (§8.5) says the `#expect` guard is ported *on day one*. This is day one. The guard goes in before any assertion that could be silently swallowed by it.

**Files:**
- Create: `Package.swift`
- Create: `Sources/TickerCore/TickerCore.swift`
- Create: `Sources/YahooFeed/YahooFeed.swift`
- Create: `Sources/squigglectl/main.swift`
- Test: `Tests/TickerCoreTests/ExpectMacroTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: the four targets `TickerCore`, `YahooFeed`, `squigglectl`, and the test targets `TickerCoreTests`, `squigglectlTests`.

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Squiggle",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TickerCore", targets: ["TickerCore"]),
        .executable(name: "squigglectl", targets: ["squigglectl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.10.0"),
    ],
    targets: [
        .target(name: "TickerCore"),
        // Not a product: the only URLSession in the package, shared by
        // squigglectl now and the Squiggle app later. See the plan's
        // "One flagged deviation from the spec".
        .target(name: "YahooFeed", dependencies: ["TickerCore"]),
        .executableTarget(name: "squigglectl", dependencies: ["TickerCore", "YahooFeed"]),
        .testTarget(
            name: "TickerCoreTests",
            dependencies: [
                "TickerCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "squigglectlTests",
            dependencies: [
                "squigglectl",
                "TickerCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
```

- [ ] **Step 2: Create placeholder sources so the targets compile**

`Sources/TickerCore/TickerCore.swift`:

```swift
/// Squiggle's pure core: parsing, scheduling policy, rate limiting, layout.
///
/// Performs no I/O, reads no clock, generates no randomness, and produces no
/// user-facing strings. Time and randomness are parameters.
public enum TickerCore {
    /// The date the Yahoo payload shape recorded in this package was observed.
    public static let payloadObservationDate = "2026-09-08"
}
```

`Sources/YahooFeed/YahooFeed.swift`:

```swift
/// The network edge. The only target in the package that imports URLSession.
public enum YahooFeed {}
```

`Sources/squigglectl/main.swift`:

```swift
// Dispatch arrives in Task 2. This exists so the target links.
print("squigglectl")
```

- [ ] **Step 3: Write the `#expect` landmine test**

`Tests/TickerCoreTests/ExpectMacroTests.swift`:

```swift
import Testing

/// A landmine in the test framework itself, pinned so it cannot be stepped on.
///
/// This package builds against the standalone `swift-testing` package rather
/// than the copy bundled with the toolchain, because the Command Line Tools
/// alone do not expose `Testing` to SwiftPM. That release's `#expect` macro
/// mis-resolves any comparison whose left operand is already a `Bool` or
/// `Bool?`: it checks that operand alone and discards the comparison.
///
/// The result is silent. `#expect(x == false)` compiles, reads correctly, and
/// passes for every value of `x`. Squiggle's pause predicates and market-state
/// checks are all `Bool`, which is precisely the shape this swallows.
///
/// So: never write `== true` or `== false` inside `#expect`. Write the plain
/// condition (`#expect(x)`, `#expect(!x)`), or for an optional supply the
/// failing default (`#expect(x ?? false)`), or hoist the value into a local.
///
/// If this test ever starts failing, that is good news: the macro has been
/// fixed, and the `??` gymnastics elsewhere in this suite can be unwound.
@Test func boolComparisonsAreInvisibleToTheExpectMacro() {
    var checked = false
    // A comparison the macro is expected to swallow. `alwaysTrue` is a `Bool`,
    // so the macro checks it instead of the `== false` around it — and passes.
    let alwaysTrue = true
    #expect(alwaysTrue == false)
    checked = true

    // The control: identical shape, `Int` operands, correctly evaluated. If
    // this were also swallowed the test above would prove nothing.
    #expect(1 == 1)
    #expect(checked)
}
```

- [ ] **Step 4: Run the suite**

Run: `swift test --build-system native`
Expected: PASS, 1 test. Deprecation warnings about the swift-testing dependency are expected; do not act on them.

- [ ] **Step 5: Add a `.gitignore` entry check and commit**

`.gitignore` already contains `.build/`. Verify, then:

```bash
git add Package.swift Sources Tests
git commit -m "chore: package skeleton and the #expect landmine guard"
```

---

## Task 2: `squigglectl quote --raw` against the live endpoint

**This is the risk-retiring task and the spec's build-order step 1.** Its whole purpose is to confirm, from this machine, that `v8/chart` answers without authentication. Everything downstream assumes it. No parsing yet — this task prints bytes.

**Files:**
- Create: `Sources/TickerCore/Symbol.swift`
- Create: `Sources/TickerCore/TickerError.swift`
- Create: `Sources/TickerCore/Fetching.swift`
- Create: `Sources/YahooFeed/YahooClient.swift`
- Modify: `Sources/squigglectl/main.swift`
- Create: `Sources/squigglectl/Command.swift`
- Create: `Sources/squigglectl/Rendering.swift`
- Test: `Tests/TickerCoreTests/SymbolTests.swift`
- Test: `Tests/squigglectlTests/CommandTests.swift`

**Interfaces:**
- Consumes: the targets from Task 1.
- Produces:
  - `TickerCore.Symbol` — `init?(_ raw: String)`, `var raw: String`, `Hashable`, `Codable` (single-value string), `Sendable`.
  - `TickerCore.TickerError` — `Error, Equatable, Sendable`, cases listed below.
  - `TickerCore.QuoteFetching` — `func fetch(_ symbol: Symbol) async throws -> Data`.
  - `TickerCore.SymbolSearching` — `func search(_ query: String) async throws -> Data`.
  - `YahooFeed.YahooClient` — `init(userAgent: String = YahooClient.defaultUserAgent)`, conforms to both.

- [ ] **Step 1: Write the failing tests**

`Tests/TickerCoreTests/SymbolTests.swift`:

```swift
import Testing
@testable import TickerCore

@Test func symbolsAreStoredExactlyAsYahooSpellsThem() throws {
    // Every one of these is a real Yahoo symbol whose punctuation or case is
    // load-bearing. Normalising any of them makes the request 404.
    for raw in ["AAPL", "^GSPC", "BRK-B", "VOD.L", "BTC-USD", "EURUSD=X"] {
        let symbol = try #require(Symbol(raw))
        #expect(symbol.raw == raw)
    }
}

@Test func lowercaseIsNotUppercased() throws {
    // Yahoo does accept "aapl", but round-tripping a symbol through the store
    // must return what the user typed. Upper-casing here would silently
    // rewrite a saved watchlist on first load.
    let symbol = try #require(Symbol("aapl"))
    #expect(symbol.raw == "aapl")
}

@Test func emptyAndWhitespaceOnlySymbolsAreRejected() {
    #expect(Symbol("") == nil)
    #expect(Symbol("   ") == nil)
    #expect(Symbol("\n") == nil)
}

@Test func symbolsWithControlCharactersOrSlashesAreRejected() {
    // Not politeness: these would be pasted straight into a URL path.
    #expect(Symbol("AA\u{0}PL") == nil)
    #expect(Symbol("../../etc/passwd") == nil)
    #expect(Symbol("A A") == nil)
}

@Test func aSymbolRoundTripsThroughJSONAsAPlainString() throws {
    let symbol = try #require(Symbol("^GSPC"))
    let data = try JSONEncoder().encode([symbol])
    #expect(String(decoding: data, as: UTF8.self) == "[\"^GSPC\"]")
    let back = try JSONDecoder().decode([Symbol].self, from: data)
    #expect(back == [symbol])
}
```

`Tests/squigglectlTests/CommandTests.swift`:

```swift
import Testing
@testable import squigglectl

@Test func quoteTakesASymbolAndOptionalRawFlag() throws {
    let parsed = try Command.parse(["quote", "AAPL"])
    #expect(parsed == .quote(symbol: "AAPL", raw: false, json: false))

    let rawForm = try Command.parse(["quote", "^GSPC", "--raw"])
    #expect(rawForm == .quote(symbol: "^GSPC", raw: true, json: false))
}

@Test func quoteWithoutASymbolIsAParseError() {
    #expect(throws: ParseError.self) { try Command.parse(["quote"]) }
}

@Test func anUnknownSubcommandIsAParseError() {
    #expect(throws: ParseError.self) { try Command.parse(["frobnicate"]) }
}

@Test func noArgumentsPrintsHelpRatherThanFailing() throws {
    let parsed = try Command.parse([])
    #expect(parsed == .help)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --build-system native`
Expected: FAIL — `cannot find 'Symbol' in scope`, `cannot find 'Command' in scope`.

- [ ] **Step 3: Write `Symbol`**

`Sources/TickerCore/Symbol.swift`:

```swift
/// A Yahoo ticker symbol, exactly as Yahoo spells it.
///
/// Deliberately not normalised. `^GSPC`, `BRK-B`, `VOD.L`, `BTC-USD` and
/// `EURUSD=X` all carry punctuation that is part of the identifier, and
/// upper-casing a user's stored watchlist on load rewrites their file for no
/// benefit. The initialiser rejects only what cannot be a symbol at all.
public struct Symbol: Hashable, Sendable, Comparable {
    public let raw: String

    public init?(_ raw: String) {
        guard !raw.isEmpty, raw.count <= 32 else { return nil }
        // Anything that would need percent-encoding in a URL path segment, or
        // that could traverse it, is not a symbol.
        let forbidden = CharacterSet.whitespacesAndNewlines
            .union(.controlCharacters)
            .union(CharacterSet(charactersIn: "/?#%&+ "))
        guard raw.rangeOfCharacter(from: forbidden) == nil else { return nil }
        self.raw = raw
    }

    public static func < (lhs: Symbol, rhs: Symbol) -> Bool { lhs.raw < rhs.raw }
}

extension Symbol: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let symbol = Symbol(raw) else {
            throw TickerError.invalidSymbol(raw)
        }
        self = symbol
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}
```

Note: `CharacterSet` lives in Foundation. `import Foundation` at the top of this file — Foundation is permitted in `TickerCore`; `UserDefaults`, `URLSession` and `Date()` are not.

- [ ] **Step 4: Write `TickerError`**

`Sources/TickerCore/TickerError.swift`:

```swift
/// Every way this package can fail, as data.
///
/// No case carries a user-facing sentence. The `path` strings are JSON key
/// paths for diagnostics — `squigglectl doctor` prints them, the app never
/// does. Wording lives in the caller.
public enum TickerError: Error, Equatable, Sendable {
    case invalidSymbol(String)

    // Transport and status, classified by how Squiggle must respond (spec §4.3).
    case offline
    case transport(String)
    case rateLimited(retryAfterSeconds: Double?)
    case serverError(status: Int)
    case unauthorized(status: Int)
    case symbolNotFound(Symbol)

    // Contract faults: a 200 whose body is not what we agreed on. Separate
    // from network faults because retrying a parse failure faster buys nothing.
    case emptyBody
    case notJSON
    case noResult
    case missingField(path: String)
    case wrongType(path: String, expected: String)
    case nonFiniteNumber(path: String)
    case negativeValue(path: String, value: Double)

    // Persistence.
    case storeSchemaUnsupported(version: Int)
    case storeCorrupt(quarantinedAt: String)

    /// Whether this is a fault in the agreement rather than in the network.
    /// Drives the separate one-hour contract circuit (spec §4.3).
    public var isContractFault: Bool {
        switch self {
        case .emptyBody, .notJSON, .noResult, .missingField,
             .wrongType, .nonFiniteNumber, .negativeValue:
            return true
        default:
            return false
        }
    }
}
```

- [ ] **Step 5: Write the fetch seams**

`Sources/TickerCore/Fetching.swift`:

```swift
/// The network seam. The core parses; it never fetches.
///
/// Bytes in, so that every implementation — URLSession, a fixture reader, a
/// fake that returns a truncated body — is interchangeable in tests.
public protocol QuoteFetching: Sendable {
    func fetch(_ symbol: Symbol) async throws -> Data
}

public protocol SymbolSearching: Sendable {
    func search(_ query: String) async throws -> Data
}
```

- [ ] **Step 6: Write `YahooClient`**

`Sources/YahooFeed/YahooClient.swift`:

```swift
import Foundation
import TickerCore

/// The only `URLSession` in the package.
///
/// Endpoint choice is spec §3.1: `v8/chart` in preference to `v7/quote`,
/// because `v7` is reported to be cookie-and-crumb gated. **That report was
/// never independently confirmed** — confirming it is the point of this task.
/// If `v8` turns out to need authentication, this file is where that lands;
/// nothing in `TickerCore` changes.
public struct YahooClient: QuoteFetching, SymbolSearching {
    /// An absent User-Agent is blocked outright by Yahoo (spec §4.3).
    public static let defaultUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private let session: URLSession
    private let userAgent: String

    public init(userAgent: String = YahooClient.defaultUserAgent) {
        let configuration = URLSessionConfiguration.ephemeral
        // Never persist a credential: an ephemeral configuration keeps no
        // cookie jar and no disk cache, so there is nothing to leak into a
        // support bundle (spec §6).
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // A price is not worth a roaming charge or a tethered connection.
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        configuration.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: configuration)
        self.userAgent = userAgent
    }

    public func fetch(_ symbol: Symbol) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "query1.finance.yahoo.com"
        // `Symbol` has already rejected anything needing escaping in a path.
        components.path = "/v8/finance/chart/\(symbol.raw)"
        components.queryItems = [
            URLQueryItem(name: "range", value: "1d"),
            URLQueryItem(name: "interval", value: "1d"),
        ]
        return try await body(of: components, symbol: symbol)
    }

    public func search(_ query: String) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "query1.finance.yahoo.com"
        components.path = "/v1/finance/search"
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return try await body(of: components, symbol: nil)
    }

    private func body(of components: URLComponents, symbol: Symbol?) async throws -> Data {
        guard let url = components.url else { throw TickerError.transport("bad URL") }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw TickerError.offline
        } catch {
            throw TickerError.transport(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw TickerError.transport("non-HTTP response")
        }

        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw TickerError.unauthorized(status: http.statusCode)
        case 404:
            if let symbol { throw TickerError.symbolNotFound(symbol) }
            throw TickerError.serverError(status: 404)
        case 429:
            // Observed 2026-09-08: this body is `text/html`, 19 bytes, and
            // carries NO Retry-After. Honour the header if it appears; never
            // depend on it, and never try to parse the body as JSON.
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
            throw TickerError.rateLimited(retryAfterSeconds: retryAfter)
        default:
            throw TickerError.serverError(status: http.statusCode)
        }
    }
}
```

- [ ] **Step 7: Write the argument parser and dispatch**

`Sources/squigglectl/Command.swift`:

```swift
public struct ParseError: Error, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Hand-rolled on purpose. `squigglectl` is the diagnostic path — the thing
/// you reach for when the app is misbehaving — so it takes no dependency that
/// could itself be the problem.
public enum Command: Equatable {
    case help
    case quote(symbol: String, raw: Bool, json: Bool)

    public static func parse(_ arguments: [String]) throws -> Command {
        guard let subcommand = arguments.first else { return .help }
        var rest = Array(arguments.dropFirst())

        func takeFlag(_ name: String) -> Bool {
            guard let index = rest.firstIndex(of: name) else { return false }
            rest.remove(at: index)
            return true
        }

        switch subcommand {
        case "help", "--help", "-h":
            return .help
        case "quote":
            let raw = takeFlag("--raw")
            let json = takeFlag("--json")
            guard let symbol = rest.first else {
                throw ParseError("quote needs a symbol, e.g. `squigglectl quote AAPL`")
            }
            return .quote(symbol: symbol, raw: raw, json: json)
        default:
            throw ParseError("unknown command: \(subcommand)")
        }
    }
}
```

`Sources/squigglectl/Rendering.swift`:

```swift
/// Every string a human reads from this tool. `TickerCore` has none.
public enum Rendering {
    public static let usage = """
        squigglectl — diagnostics for Squiggle

        USAGE
          squigglectl quote <symbol> [--raw] [--json]

        EXAMPLES
          squigglectl quote AAPL --raw
        """
}
```

`Sources/squigglectl/main.swift`:

```swift
import Foundation
import TickerCore
import YahooFeed

// A top-level `await` needs a task; `main.swift` allows top-level code, and a
// semaphore keeps the process alive until the async work finishes.
func run() async -> Int32 {
    let command: Command
    do {
        command = try Command.parse(Array(CommandLine.arguments.dropFirst()))
    } catch let error as ParseError {
        FileHandle.standardError.write(Data((error.message + "\n").utf8))
        return 2
    } catch {
        FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
        return 2
    }

    switch command {
    case .help:
        print(Rendering.usage)
        return 0
    case .quote(let raw, let printRaw, _):
        guard let symbol = Symbol(raw) else {
            FileHandle.standardError.write(Data("not a usable symbol: \(raw)\n".utf8))
            return 2
        }
        do {
            let body = try await YahooClient().fetch(symbol)
            if printRaw {
                FileHandle.standardOutput.write(body)
                print()
            } else {
                print("\(body.count) bytes")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            return 1
        }
    }
}

let status = await run()
exit(status)
```

- [ ] **Step 8: Run the unit tests**

Run: `swift test --build-system native`
Expected: PASS.

- [ ] **Step 9: THE LIVE CHECK — run one real request**

```bash
swift run --build-system native squigglectl quote AAPL --raw
```

Expected on success: a JSON body beginning `{"chart":{"result":[{"meta":{`. Confirm by eye that it contains `regularMarketPrice`, `chartPreviousClose`, and `currentTradingPeriod`.

**If it returns `rateLimited`:** this is the state the spec was written in (§3.2 — a 429 observed on 2026-09-08 outlasted an hour). Do **not** loop, do not retry in a script, and do not lower the spacing to "test faster". Wait at least one hour, or run the command once from a different network, and try again. A second 429 from a fresh IP would be new information and would mean revisiting §3.1 before continuing.

**If it returns `unauthorized`:** the spec's central unconfirmed assumption is wrong. **Stop the plan.** `v8/chart` needing a crumb changes §3.1, reinstates the `CrumbSession` the design deleted, and must go back through the design before any more code is written.

- [ ] **Step 10: Record the outcome and commit**

Append to `docs/fixture-capture-log.md` (create it):

```markdown
# Fixture capture log

## Endpoint confirmation (build-order step 1)

- Date: <YYYY-MM-DD HH:MM local>
- Command: `swift run --build-system native squigglectl quote AAPL --raw`
- Result: <200 / 429 / 401>
- Body size: <n> bytes
- Notes: <anything surprising>
```

```bash
git add Sources Tests docs/fixture-capture-log.md
git commit -m "feat: squigglectl quote, and the live confirmation that v8/chart is unauthenticated"
```

---

## Task 3: The fixture corpus

Build-order step 2. Spec §8.1 lists fourteen fixtures. Some can be captured right now; some are gated on the clock (pre-market, post-market, weekend) or on an event nobody schedules (a halted symbol). This task captures what is capturable, hand-builds the two error bodies whose exact shape the spec already records, and writes down what is still owed so Task 19 can collect it.

**Every capture takes a token from nobody — there is no pacer in this path.** Capture deliberately, one symbol at a time, with a pause between. Trip the rate limit here and you lose the next hour of the plan.

**Files:**
- Create: `Tests/Fixtures/yahoo-2026-09-08/*.json` and `*.html`
- Create: `scripts/capture-fixtures.sh`
- Modify: `docs/fixture-capture-log.md`

**Interfaces:**
- Consumes: `squigglectl quote --raw` from Task 2.
- Produces: a fixture directory that Tasks 5, 6 and 15 read by filename. **The filenames below are the interface** — later tasks reference them literally.

- [ ] **Step 1: Write the capture script**

`scripts/capture-fixtures.sh`:

```bash
#!/usr/bin/env bash
# Capture one Yahoo body per symbol into the fixture corpus.
#
# Deliberately slow: 35 seconds between requests, above the 30s spacing floor.
# Yahoo's rate limit is IP-scoped and a 429 has been observed to outlast an
# hour, so a fast capture costs far more time than a slow one.
set -euo pipefail

DIR="${1:-Tests/Fixtures/yahoo-$(date +%Y-%m-%d)}"
mkdir -p "$DIR"

capture() {
  local symbol="$1" name="$2"
  echo "→ $name ($symbol)"
  swift run --build-system native squigglectl quote "$symbol" --raw > "$DIR/$name.json"
  echo "  $(wc -c < "$DIR/$name.json") bytes"
  sleep 35
}

capture "AAPL"      "regular-session"
capture "^GSPC"     "index"
capture "SPY"       "etf"
capture "EURUSD=X"  "currency-pair"
capture "BTC-USD"   "crypto"
capture "VOD.L"     "non-usd-listing"
```

```bash
chmod +x scripts/capture-fixtures.sh
```

- [ ] **Step 2: Run it, and be honest about which session you ran it in**

`regular-session.json` is consumed by Tasks 5, 6, 7 and 18, so its **name is
an interface** and must not change. Its *content* only has to satisfy what
those tests actually assert: a positive price, a currency, a short name, a
non-nil change whose sign agrees with the arithmetic, and a
`currentTradingPeriod.regular` window no longer than 6.5 hours. Every one of
those holds for a body fetched while the market is closed — none of them
assert the session is live.

So: run the capture whenever you are running it. If that is outside 09:30–16:00
ET, **also** write the AAPL body to `overnight-closed.json` from the *same*
request (`cp`, not a second fetch — a second fetch buys nothing and spends a
token), and record in the log that `regular-session.json` is presently a
stand-in awaiting the live recapture Task 19 already schedules for ~10:30 ET.

```bash
./scripts/capture-fixtures.sh
```

Expected: six files under `Tests/Fixtures/yahoo-<today>/`, each starting `{"chart":`. Six requests spread over ~3 minutes is well inside any plausible limit.

If the directory name is not `yahoo-2026-09-08`, that is fine and correct — the date is the observation date. Update the path in Tasks 5, 6 and 15 to match what you actually captured, and record it in the log.

- [ ] **Step 3: Hand-build the two error fixtures**

These are not guesses. Spec §3.2 records the 429 body exactly: `content-type: text/html`, the 19 bytes `Too Many Requests`, no `Retry-After`.

```bash
DIR=Tests/Fixtures/yahoo-2026-09-08
printf 'Too Many Requests' > "$DIR/429-body.html"
test "$(wc -c < "$DIR/429-body.html")" -eq 17 || echo "NOTE: 17 bytes without a trailing newline; the observed 19 included CRLF"
```

For the 401 body, capture it if a 401 is ever seen; until then create a placeholder that is honest about being one:

```bash
cat > "$DIR/401-body.json" <<'JSON'
{"finance":{"result":null,"error":{"code":"Unauthorized","description":"Invalid Crumb"}}}
JSON
```

Add a sibling note so nobody later mistakes it for a recording:

```bash
cat > "$DIR/401-body.NOT-CAPTURED.md" <<'MD'
This 401 body is **reconstructed from documentation, not captured**. Squiggle
has never received a 401 from `v8/chart` — if it had, the design's central
assumption (§3.1) would be wrong and the plan would have stopped.

Its only job is to prove the parser classifies a 401 body as
`unauthorized` rather than as a contract fault. Replace it the first time a
real one is seen.
MD
```

- [ ] **Step 4: Record what is still owed**

Append to `docs/fixture-capture-log.md`:

```markdown
## Corpus status

Captured:
- [x] regular-session (AAPL)
- [x] index (^GSPC)
- [x] etf (SPY)
- [x] currency-pair (EURUSD=X)
- [x] crypto (BTC-USD)
- [x] non-usd-listing (VOD.L)
- [x] 429-body.html — hand-built from the shape recorded in spec §3.2
- [x] overnight-closed.json — only if the capture ran outside 09:30-16:00 ET
- [ ] 401-body.json — RECONSTRUCTED, not captured

Still owed (clock-gated; collect during the Task 19 trading day):
- [ ] regular-session — RECAPTURE during a live session if the corpus was
      taken outside 09:30-16:00 ET; the held file is a closed-market stand-in
- [ ] pre-market — capture AAPL between 04:00 and 09:30 ET
- [ ] post-market — capture AAPL between 16:00 and 20:00 ET
- [ ] weekend — capture AAPL on a Saturday; `currentTradingPeriod` should
      still resolve and the market state should read closed
- [ ] crypto-while-equities-closed — capture BTC-USD on that same Saturday;
      it must NOT read closed. This is the fixture that proves no local
      exchange calendar is needed.
- [ ] newly-listed with null chartPreviousClose — opportunistic
- [ ] delisted symbol — opportunistic
- [ ] halted symbol — opportunistic; may never arrive

Tests must not skip on a missing owed fixture. They are written against the
captured set; each owed fixture gets its test when it lands.
```

- [ ] **Step 5: Commit**

```bash
git add Tests/Fixtures scripts/capture-fixtures.sh docs/fixture-capture-log.md
git commit -m "test: Yahoo fixture corpus, captured 2026-09-08"
```

---

## Task 4: `LenientDouble`

Yahoo returns numbers as a bare number, as a string, and as `{"raw": 1.23, "fmt": "1.23"}` — all three shapes across different fields of the same payload (spec §8.2). One decoder handles all three and rejects the rest.

**Files:**
- Create: `Sources/TickerCore/LenientDouble.swift`
- Test: `Tests/TickerCoreTests/LenientDoubleTests.swift`

**Interfaces:**
- Consumes: `TickerError` (Task 2).
- Produces: `TickerCore.LenientDouble` — `Decodable, Sendable, Equatable`, `var value: Double`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import TickerCore

private func decode(_ json: String) throws -> LenientDouble {
    try JSONDecoder().decode(LenientDouble.self, from: Data(json.utf8))
}

@Test func aBareNumberDecodes() throws {
    #expect(try decode("1.25").value == 1.25)
    #expect(try decode("0").value == 0)
    #expect(try decode("-3.5").value == -3.5)
}

@Test func aNumericStringDecodes() throws {
    #expect(try decode("\"1.25\"").value == 1.25)
    #expect(try decode("\"-3.5\"").value == -3.5)
}

@Test func aRawFmtObjectDecodesToItsRawValue() throws {
    // The `fmt` string is localised and lossy — "1.23B" is not a number.
    // Only `raw` is ever read.
    #expect(try decode("{\"raw\": 1.25, \"fmt\": \"1.25\"}").value == 1.25)
}

@Test func anUnparseableStringThrowsRatherThanBecomingZero() {
    // The whole point. A field that silently becomes 0 is exactly the class of
    // plausible-but-wrong number spec §8.2 forbids.
    #expect(throws: (any Error).self) { try decode("\"n/a\"") }
    #expect(throws: (any Error).self) { try decode("\"\"") }
}

@Test func nonFiniteValuesAreRejected() {
    // JSON has no NaN literal, but a string "NaN" parses to a Double NaN, and
    // an overflowing literal parses to infinity. Both must be refused: a NaN
    // price renders as "nan" in the menu bar and an infinite change percent
    // renders as "+Inf%".
    #expect(throws: (any Error).self) { try decode("\"NaN\"") }
    #expect(throws: (any Error).self) { try decode("\"inf\"") }
    #expect(throws: (any Error).self) { try decode("1e400") }
}

@Test func nullAndBooleansAndArraysAreRejected() {
    #expect(throws: (any Error).self) { try decode("null") }
    #expect(throws: (any Error).self) { try decode("true") }
    #expect(throws: (any Error).self) { try decode("[1]") }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --build-system native --filter LenientDouble`
Expected: FAIL — `cannot find 'LenientDouble' in scope`.

- [ ] **Step 3: Implement**

`Sources/TickerCore/LenientDouble.swift`:

```swift
import Foundation

/// A number as Yahoo variously spells it.
///
/// Observed 2026-09-08: the same payload carries bare numbers
/// (`regularMarketPrice`), numeric strings, and `{raw:, fmt:}` objects
/// depending on the field and the endpoint. `fmt` is a localised display
/// string — "1.23B" — and is never read.
///
/// Everything else throws. There is deliberately no fallback to zero: a field
/// that quietly becomes 0 produces a plausible wrong price, which is the one
/// failure mode this app must not have.
public struct LenientDouble: Decodable, Sendable, Equatable {
    public let value: Double

    private enum ObjectKeys: String, CodingKey { case raw }

    public init(from decoder: Decoder) throws {
        let path = decoder.codingPath.map(\.stringValue).joined(separator: ".")

        if let single = try? decoder.singleValueContainer(), !single.decodeNil() {
            if let number = try? single.decode(Double.self) {
                try LenientDouble.requireFinite(number, path: path)
                self.value = number
                return
            }
            if let text = try? single.decode(String.self) {
                guard let number = Double(text) else {
                    throw TickerError.wrongType(path: path, expected: "number")
                }
                try LenientDouble.requireFinite(number, path: path)
                self.value = number
                return
            }
        }

        let object = try decoder.container(keyedBy: ObjectKeys.self)
        let nested = try object.decode(LenientDouble.self, forKey: .raw)
        self.value = nested.value
    }

    private static func requireFinite(_ number: Double, path: String) throws {
        guard number.isFinite else { throw TickerError.nonFiniteNumber(path: path) }
    }
}
```

Note on `1e400`: `JSONDecoder` yields `+infinity` for it, which `requireFinite` rejects. If a toolchain change makes it throw earlier instead, the test still passes — it asserts *that it throws*, not which error.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --build-system native --filter LenientDouble`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TickerCore/LenientDouble.swift Tests/TickerCoreTests/LenientDoubleTests.swift
git commit -m "feat: LenientDouble, which refuses to invent a zero"
```

---

## Task 5: Quote decoding

One file holds every JSON key path, annotated with the date it was observed, so an upstream break is a one-file diff (spec §8.1).

**Files:**
- Create: `Sources/TickerCore/Quote.swift`
- Create: `Sources/TickerCore/YahooQuoteDecoding.swift`
- Test: `Tests/TickerCoreTests/YahooQuoteDecodingTests.swift`

**Interfaces:**
- Consumes: `Symbol`, `TickerError`, `LenientDouble`.
- Produces:
  - `TickerCore.Direction` — `enum { case up, down, flat, unknown }`, `Equatable, Sendable`.
  - `TickerCore.Quote` — the fields listed below, `Equatable, Sendable`.
  - `TickerCore.YahooQuoteDecoding.quote(from: Data, symbol: Symbol) throws -> Quote`.
  - `TickerCore.YahooQuoteDecoding.tradingPeriod(from: Data) throws -> TradingPeriod` **arrives in Task 7** — not here.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import TickerCore

enum Fixture {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // TickerCoreTests
        .deletingLastPathComponent()      // Tests
        .appendingPathComponent("Fixtures/yahoo-2026-09-08")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }
}

@Test func theRegularSessionFixtureParses() throws {
    let symbol = try #require(Symbol("AAPL"))
    let quote = try YahooQuoteDecoding.quote(from: Fixture.data("regular-session.json"), symbol: symbol)

    #expect(quote.symbol == symbol)
    #expect(quote.price > 0)
    #expect(quote.currency == "USD")
    #expect(quote.shortName != nil)
    // Direction must agree with the arithmetic, whichever way the day went.
    let change = try #require(quote.change)
    switch quote.direction {
    case .up:      #expect(change > 0)
    case .down:    #expect(change < 0)
    case .flat:    #expect(change == 0)
    case .unknown: Issue.record("a regular-session fixture should have a previous close")
    }
}

@Test func everyCapturedInstrumentKindParses() throws {
    // Indices, ETFs, currency pairs, crypto and a non-USD listing all come
    // back through the same endpoint. If any of them needed special handling,
    // this is where it would show up.
    for (name, raw) in [
        ("index.json", "^GSPC"),
        ("etf.json", "SPY"),
        ("currency-pair.json", "EURUSD=X"),
        ("crypto.json", "BTC-USD"),
        ("non-usd-listing.json", "VOD.L"),
    ] {
        let symbol = try #require(Symbol(raw))
        let quote = try YahooQuoteDecoding.quote(from: Fixture.data(name), symbol: symbol)
        #expect(quote.price > 0, "\(raw) produced no price")
    }
}

@Test func aNonUSDListingKeepsItsOwnCurrency() throws {
    let symbol = try #require(Symbol("VOD.L"))
    let quote = try YahooQuoteDecoding.quote(from: Fixture.data("non-usd-listing.json"), symbol: symbol)
    #expect(quote.currency != "USD")
}

@Test func aZeroPreviousCloseYieldsUnknownRatherThanInfinity() throws {
    // The newly-listed case. Dividing by zero here would render "+Inf%" in a
    // 10pt slot in the menu bar (spec §5.3).
    let json = """
        {"chart":{"result":[{"meta":{
          "regularMarketPrice":42.0,
          "chartPreviousClose":0,
          "currency":"USD",
          "symbol":"NEW"
        }}],"error":null}}
        """
    let symbol = try #require(Symbol("NEW"))
    let quote = try YahooQuoteDecoding.quote(from: Data(json.utf8), symbol: symbol)
    #expect(quote.direction == .unknown)
    #expect(quote.changePercent == nil)
    #expect(quote.price == 42.0)
}

@Test func aMissingPreviousCloseYieldsUnknownButKeepsThePrice() throws {
    let json = """
        {"chart":{"result":[{"meta":{"regularMarketPrice":42.0,"currency":"USD"}}],"error":null}}
        """
    let symbol = try #require(Symbol("NEW"))
    let quote = try YahooQuoteDecoding.quote(from: Data(json.utf8), symbol: symbol)
    #expect(quote.direction == .unknown)
    #expect(quote.change == nil)
    #expect(quote.price == 42.0)
}

@Test func aMissingPriceIsAnErrorAndNeverAZero() throws {
    // `regularMarketPrice` decodes as REQUIRED. A price defaulting to 0 is the
    // exact class of silent wrong answer spec §8.2 names.
    let json = """
        {"chart":{"result":[{"meta":{"chartPreviousClose":10.0,"currency":"USD"}}],"error":null}}
        """
    let symbol = try #require(Symbol("AAPL"))
    #expect(throws: TickerError.self) {
        try YahooQuoteDecoding.quote(from: Data(json.utf8), symbol: symbol)
    }
}

@Test func anEmptyResultArrayIsNoResultNotACrash() throws {
    let json = "{\"chart\":{\"result\":[],\"error\":null}}"
    let symbol = try #require(Symbol("AAPL"))
    #expect(throws: TickerError.noResult) {
        try YahooQuoteDecoding.quote(from: Data(json.utf8), symbol: symbol)
    }
}

@Test func theRateLimitBodyIsNotMistakenForJSON() throws {
    // Observed 2026-09-08: `text/html`, 19 bytes, not JSON. A parser that
    // assumes a JSON body on error throws the wrong error — and the wrong
    // error means the wrong backoff ladder.
    let symbol = try #require(Symbol("AAPL"))
    let error = #expect(throws: TickerError.self) {
        try YahooQuoteDecoding.quote(from: try Fixture.data("429-body.html"), symbol: symbol)
    }
    #expect(error == .notJSON)
}

@Test func anEmptyBodyIsItsOwnError() throws {
    let symbol = try #require(Symbol("AAPL"))
    #expect(throws: TickerError.emptyBody) {
        try YahooQuoteDecoding.quote(from: Data(), symbol: symbol)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --build-system native --filter YahooQuoteDecoding`
Expected: FAIL — `cannot find 'YahooQuoteDecoding' in scope`.

- [ ] **Step 3: Write `Quote` and `Direction`**

`Sources/TickerCore/Quote.swift`:

```swift
/// Which way the number went. No `NSColor` here — the core does not know what
/// a colour is, and colour is redundant reinforcement anyway (spec §5.3).
public enum Direction: Equatable, Sendable {
    case up
    case down
    case flat
    /// No usable previous close: newly listed, or a zero that would otherwise
    /// divide into infinity. Never coloured, never given an arrow.
    case unknown

    /// The glyph that carries direction in every colour scheme.
    /// A glyph, not a colour, is the primary carrier — WCAG 1.4.1.
    public var glyph: String {
        switch self {
        case .up: return "\u{25B2}"     // ▲
        case .down: return "\u{25BC}"   // ▼
        case .flat: return "\u{2013}"   // –
        case .unknown: return ""
        }
    }
}

/// One instrument, as of one moment. Never written to disk (spec §6).
public struct Quote: Equatable, Sendable {
    public let symbol: Symbol
    /// Yahoo's own display name. Data from the network, not app copy.
    public let shortName: String?
    public let price: Double
    public let previousClose: Double?
    public let change: Double?
    public let changePercent: Double?
    public let currency: String?
    public let direction: Direction
    /// Wall-clock epoch seconds, from the payload — not from a local clock.
    public let asOfEpoch: Double?

    public init(
        symbol: Symbol,
        shortName: String?,
        price: Double,
        previousClose: Double?,
        currency: String?,
        asOfEpoch: Double?
    ) {
        self.symbol = symbol
        self.shortName = shortName
        self.price = price
        self.previousClose = previousClose
        self.currency = currency
        self.asOfEpoch = asOfEpoch

        // A previous close of zero is not a previous close. Guarding here
        // rather than at each use site means no caller can reintroduce the
        // division.
        if let base = previousClose, base != 0 {
            let delta = price - base
            self.change = delta
            self.changePercent = delta / base * 100
            self.direction = delta > 0 ? .up : (delta < 0 ? .down : .flat)
        } else {
            self.change = nil
            self.changePercent = nil
            self.direction = .unknown
        }
    }
}
```

- [ ] **Step 4: Write the decoder**

`Sources/TickerCore/YahooQuoteDecoding.swift`:

```swift
import Foundation

/// Every Yahoo key path Squiggle depends on, in one file.
///
/// Observed against `query1.finance.yahoo.com/v8/finance/chart/{symbol}` on
/// **2026-09-08**. When Yahoo changes shape, this file is the whole diff.
///
/// Path: chart.result[0].meta.{regularMarketPrice, chartPreviousClose,
/// shortName, currency, exchangeTimezoneName, regularMarketTime,
/// currentTradingPeriod.{pre,regular,post}.{start,end}}
public enum YahooQuoteDecoding {
    private struct Envelope: Decodable {
        struct Chart: Decodable {
            let result: [Result]?
            struct Result: Decodable {
                let meta: Meta
            }
        }
        struct Meta: Decodable {
            let regularMarketPrice: LenientDouble?
            let chartPreviousClose: LenientDouble?
            let previousClose: LenientDouble?
            let shortName: String?
            let currency: String?
            let exchangeTimezoneName: String?
            let regularMarketTime: LenientDouble?
            let currentTradingPeriod: TradingPeriodPayload?
        }
        let chart: Chart
    }

    /// Decoded here but only interpreted in `TradingPeriod` (Task 7).
    struct TradingPeriodPayload: Decodable {
        struct Window: Decodable {
            let start: LenientDouble?
            let end: LenientDouble?
        }
        let pre: Window?
        let regular: Window?
        let post: Window?
    }

    public static func quote(from data: Data, symbol: Symbol) throws -> Quote {
        let meta = try self.meta(from: data)

        guard let price = meta.regularMarketPrice?.value else {
            throw TickerError.missingField(path: "chart.result[0].meta.regularMarketPrice")
        }
        guard price >= 0 else {
            throw TickerError.negativeValue(
                path: "chart.result[0].meta.regularMarketPrice", value: price)
        }

        // `chartPreviousClose` is the documented field; `previousClose` appears
        // on some instruments. Neither is required — a newly-listed symbol has
        // no previous close, and that is `.unknown`, not an error.
        let base = meta.chartPreviousClose?.value ?? meta.previousClose?.value

        return Quote(
            symbol: symbol,
            shortName: meta.shortName,
            price: price,
            previousClose: base,
            currency: meta.currency,
            asOfEpoch: meta.regularMarketTime?.value)
    }

    static func meta(from data: Data) throws -> Envelope.Meta {
        guard !data.isEmpty else { throw TickerError.emptyBody }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch let error as TickerError {
            // LenientDouble's own typed errors pass through unchanged.
            throw error
        } catch let error as DecodingError {
            throw translate(error)
        } catch {
            throw TickerError.notJSON
        }

        guard let first = envelope.chart.result?.first else {
            throw TickerError.noResult
        }
        return first.meta
    }

    /// Turns a `DecodingError` into a `TickerError` that names the JSON path.
    ///
    /// Not `private`: Task 15's `YahooSearchDecoding` calls this same
    /// translator, which is what makes a malformed search body and a
    /// malformed quote body fail with the identical case — the property
    /// `doctor` relies on when it classifies the two endpoints alike.
    static func translate(_ error: DecodingError) -> TickerError {
        switch error {
        case .dataCorrupted(let context) where context.codingPath.isEmpty:
            // Not JSON at all. The 429 body — `text/html`, 19 bytes — lands
            // here, and it must not be reported as a missing field.
            return .notJSON
        case .keyNotFound(let key, let context):
            return .missingField(path: path(context.codingPath + [key]))
        case .valueNotFound(let type, let context):
            return .missingField(path: path(context.codingPath) + " (\(type))")
        case .typeMismatch(let type, let context):
            return .wrongType(path: path(context.codingPath), expected: "\(type)")
        case .dataCorrupted(let context):
            return .wrongType(path: path(context.codingPath), expected: "well-formed value")
        @unknown default:
            return .notJSON
        }
    }

    private static func path(_ keys: [any CodingKey]) -> String {
        keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            .joined(separator: ".")
            .replacingOccurrences(of: ".[", with: "[")
    }
}
```

- [ ] **Step 5: Run to verify they pass**

Run: `swift test --build-system native --filter YahooQuoteDecoding`
Expected: PASS.

If `theRegularSessionFixtureParses` fails on `currency == "USD"` or `shortName != nil`, read the actual fixture before changing the decoder — the fixture is the authority on what Yahoo sent.

- [ ] **Step 6: Commit**

```bash
git add Sources/TickerCore/Quote.swift Sources/TickerCore/YahooQuoteDecoding.swift \
        Tests/TickerCoreTests/YahooQuoteDecodingTests.swift
git commit -m "feat: quote decoding, with every Yahoo key path pinned in one file"
```

---

## Task 6: Mutation and truncation

Fixtures alone prove that one particular day's payload parses. Shape drift, not downtime, is the real failure mode (spec §8.2). These two suites are generated, not hand-written: they walk the fixture and mutate it, so they keep working when the payload changes.

**Files:**
- Create: `Tests/TickerCoreTests/MutationTests.swift`
- Create: `Tests/TickerCoreTests/TruncationTests.swift`

**Interfaces:**
- Consumes: `YahooQuoteDecoding.quote(from:symbol:)`, `Fixture` (Task 5).
- Produces: nothing the source depends on. This task adds no production code — if it *needs* production code, the decoder has a defect and fixing it is part of this task.

- [ ] **Step 1: Write the mutation suite**

`Tests/TickerCoreTests/MutationTests.swift`:

```swift
import Testing
import Foundation
@testable import TickerCore

/// Rewrite one key path in a JSON object tree.
/// Returns nil when the path does not exist in this fixture.
private func mutate(
    _ data: Data,
    at path: [String],
    to replacement: Any?
) throws -> Data? {
    guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }

    func rewrite(_ container: Any, _ remaining: ArraySlice<String>) -> Any? {
        guard let key = remaining.first else { return nil }
        if var dictionary = container as? [String: Any] {
            guard dictionary.keys.contains(key) else { return nil }
            if remaining.count == 1 {
                if let replacement { dictionary[key] = replacement }
                else { dictionary.removeValue(forKey: key) }
                return dictionary
            }
            guard let child = rewrite(dictionary[key]!, remaining.dropFirst()) else { return nil }
            dictionary[key] = child
            return dictionary
        }
        if var array = container as? [Any], let index = Int(key), array.indices.contains(index) {
            if remaining.count == 1 {
                if let replacement { array[index] = replacement } else { array.remove(at: index) }
                return array
            }
            guard let child = rewrite(array[index], remaining.dropFirst()) else { return nil }
            array[index] = child
            return array
        }
        return nil
    }

    guard let rewritten = rewrite(root, path[...]) as? [String: Any] else { return nil }
    root = rewritten
    return try JSONSerialization.data(withJSONObject: root)
}

/// Every field the decoder reads, by path from the document root.
///
/// Not `private`: Task 18 cross-checks this against `ShapeDigest.readPaths`,
/// which spells the same fact differently. Change one and that test tells you
/// to change the other.
let readFields: [[String]] = [
    ["chart"],
    ["chart", "result"],
    ["chart", "result", "0"],
    ["chart", "result", "0", "meta"],
    ["chart", "result", "0", "meta", "regularMarketPrice"],
    ["chart", "result", "0", "meta", "chartPreviousClose"],
    ["chart", "result", "0", "meta", "previousClose"],
    ["chart", "result", "0", "meta", "shortName"],
    ["chart", "result", "0", "meta", "currency"],
    ["chart", "result", "0", "meta", "exchangeTimezoneName"],
    ["chart", "result", "0", "meta", "regularMarketTime"],
    ["chart", "result", "0", "meta", "currentTradingPeriod"],
]

/// The shapes an upstream change actually takes.
private let mutations: [(name: String, value: Any?)] = [
    ("missing", nil),
    ("null", NSNull()),
    ("wrong-type-string", "banana"),
    ("wrong-type-object", ["unexpected": 1]),
    ("wrong-type-array", [1, 2, 3]),
    ("nan", "NaN"),
    ("infinity", "inf"),
    ("negative", -1),
    ("zero", 0),
    ("huge", 1e308),
]

@Test func everyMutationOfEveryReadFieldIsHandledOrRejected() throws {
    let symbol = try #require(Symbol("AAPL"))
    let original = try Fixture.data("regular-session.json")
    var exercised = 0

    for field in readFields {
        for mutation in mutations {
            guard let mutated = try mutate(original, at: field, to: mutation.value) else {
                continue  // this fixture does not carry that path; nothing to test
            }
            exercised += 1
            let label = "\(field.joined(separator: ".")) → \(mutation.name)"

            do {
                let quote = try YahooQuoteDecoding.quote(from: mutated, symbol: symbol)
                // Parsing is allowed to succeed — but only into a quote that is
                // internally honest. This is the assertion that catches a
                // plausible-but-wrong number.
                #expect(quote.price.isFinite, "\(label): non-finite price survived")
                #expect(quote.price >= 0, "\(label): negative price survived")
                if let percent = quote.changePercent {
                    #expect(percent.isFinite, "\(label): non-finite change percent survived")
                }
                if quote.change == nil {
                    #expect(quote.direction == .unknown,
                            "\(label): a direction was claimed with no change to justify it")
                }
                if mutation.name == "zero", field.last == "chartPreviousClose" {
                    #expect(quote.direction == .unknown, "\(label): divided by a zero close")
                }
            } catch is TickerError {
                // A typed error is the other acceptable outcome.
            } catch {
                Issue.record("\(label): threw an untyped \(type(of: error)): \(error)")
            }
        }
    }

    // If the fixture stops carrying these paths, the loop above silently tests
    // nothing. Pin the fact that it did real work.
    #expect(exercised > 40, "only \(exercised) mutations were exercised")
}

@Test func aMutatedPriceNeverSilentlyBecomesZero() throws {
    let symbol = try #require(Symbol("AAPL"))
    let original = try Fixture.data("regular-session.json")
    let path = ["chart", "result", "0", "meta", "regularMarketPrice"]

    for mutation in [("missing", nil as Any?), ("null", NSNull()), ("wrong-type", "banana")] {
        let mutated = try #require(try mutate(original, at: path, to: mutation.1))
        #expect(throws: TickerError.self, "\(mutation.0) price should throw") {
            try YahooQuoteDecoding.quote(from: mutated, symbol: symbol)
        }
    }
}
```

- [ ] **Step 2: Run the mutation suite**

Run: `swift test --build-system native --filter Mutation`
Expected: PASS. Any failure here is a decoder defect — fix `YahooQuoteDecoding`, not the test. The likely one is a `nan`/`infinity` string reaching a field that does not go through `LenientDouble`.

- [ ] **Step 3: Write the truncation suite**

`Tests/TickerCoreTests/TruncationTests.swift`:

```swift
import Testing
import Foundation
@testable import TickerCore

@Test func everyTruncatedPrefixOfEveryFixtureThrowsRatherThanTraps() throws {
    // A crashing menu bar agent cannot be recovered without Terminal. A
    // truncated body is what a dropped connection mid-response looks like, and
    // it must be a typed error every single time.
    let symbol = try #require(Symbol("AAPL"))
    let names = ["regular-session.json", "index.json", "etf.json",
                 "currency-pair.json", "crypto.json", "non-usd-listing.json"]

    for name in names {
        let full = try Fixture.data(name)
        #expect(full.count > 100, "\(name) is suspiciously small")

        // Every prefix, thinned to keep the suite fast on large bodies: every
        // byte for the first 512, then every 17th. 17 is coprime with any
        // plausible token length, so the sampling does not align with the
        // payload's structure and skip a whole class of boundary.
        var lengths = Array(0..<min(512, full.count))
        lengths += stride(from: 512, to: full.count, by: 17)

        for length in lengths {
            let prefix = full.prefix(length)
            do {
                _ = try YahooQuoteDecoding.quote(from: Data(prefix), symbol: symbol)
                // Succeeding on a prefix is fine and even likely for a body
                // whose trailing fields are all optional.
            } catch is TickerError {
                // Expected.
            } catch {
                Issue.record("\(name) truncated to \(length): untyped \(type(of: error))")
            }
        }
    }
}

@Test func aTruncatedBodyNeverProducesAQuoteWithADishonestNumber() throws {
    let symbol = try #require(Symbol("AAPL"))
    let full = try Fixture.data("regular-session.json")

    // Every strict prefix of this fixture is invalid JSON, so as of
    // 2026-09-08 the only length that ever decodes is the full document —
    // the honesty assertions below are a latent guard, not a live one. They
    // are kept anyway: if a future decoder ever grows lenient enough to
    // salvage a partial body, `decoded` rises above 1, the pin right after
    // this loop fails loudly, and these assertions start doing real work on
    // the very change that made them relevant.
    //
    // Append the full length explicitly rather than using `stride(through:)`:
    // `through:` only lands on the endpoint because this fixture's byte count
    // happens to divide by 7, and a recapture at any other size would
    // silently drop it.
    let lengths = Array(stride(from: 0, to: full.count, by: 7)) + [full.count]
    var attempted = 0
    var decoded = 0

    for length in lengths {
        attempted += 1
        guard let quote = try? YahooQuoteDecoding.quote(
            from: Data(full.prefix(length)), symbol: symbol) else { continue }
        decoded += 1
        #expect(quote.price.isFinite && quote.price >= 0,
                "truncation to \(length) produced price \(quote.price)")
        if let percent = quote.changePercent {
            #expect(percent.isFinite, "truncation to \(length) produced \(percent)%")
        }
    }

    // If the loop above stopped doing real work, it would prove nothing.
    #expect(attempted > 100, "only \(attempted) lengths were attempted")
    // Exactly the complete body should decode — nothing less than it.
    #expect(decoded == 1, "expected only the full body to decode, but \(decoded) lengths did")
}
```

- [ ] **Step 4: Run the truncation suite**

Run: `swift test --build-system native --filter Truncation`
Expected: PASS. It is the slowest suite in the package; a few seconds is normal.

- [ ] **Step 5: Run everything and commit**

Run: `swift test --build-system native`
Expected: PASS.

```bash
git add Tests/TickerCoreTests/MutationTests.swift Tests/TickerCoreTests/TruncationTests.swift
git commit -m "test: mutation over every read field, and truncation over every prefix"
```

---

## Task 7: Trading periods and market state

The market-hours oracle is the payload, not a calendar. Holidays, half-days, two DST regimes, per-symbol venues and crypto's 24-hour session all fall out of `currentTradingPeriod` for free (spec §4.2).

**Files:**
- Create: `Sources/TickerCore/TradingPeriod.swift`
- Modify: `Sources/TickerCore/YahooQuoteDecoding.swift` (add `tradingPeriod(from:)`)
- Test: `Tests/TickerCoreTests/TradingPeriodTests.swift`

**Interfaces:**
- Consumes: `YahooQuoteDecoding.meta(from:)`, `TickerError`.
- Produces:
  - `TickerCore.MarketState` — `enum { case pre, regular, post, closed }`, `Equatable, Sendable`.
  - `TickerCore.TradingPeriod` — `struct` with `pre`, `regular`, `post` of type `Window?`; `Window` has `startEpoch`/`endEpoch` `Double`.
  - `TradingPeriod.state(atEpoch: Double) -> MarketState`
  - `TradingPeriod.nextRegularOpenEpoch(after: Double) -> Double?`
  - `YahooQuoteDecoding.tradingPeriod(from: Data) throws -> TradingPeriod`

**Ordering note (controller ruling R9).** `state(atEpoch:)` checks `regular`
first, so that an overlap Yahoo emits for some venues resolves to the busier
session. That rule is load-bearing and easy to lose: the other tests here use
*contiguous* windows (pre 100-200, regular 200-300, post 300-400), and under
half-open `contains` no epoch is ever inside two of them — so reordering the
checks passes every one of them. `regularWinsWhenYahooEmitsOverlappingWindows`
is the only test that can see the difference, and it must keep genuinely
overlapping windows on **both** sides. Verified by mutation, not by reading:
checking `pre` first fails it at epoch 220, checking `post` first at 320.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import TickerCore

private func period(
    pre: (Double, Double)? = (100, 200),
    regular: (Double, Double)? = (200, 300),
    post: (Double, Double)? = (300, 400)
) -> TradingPeriod {
    TradingPeriod(
        pre: pre.map { TradingPeriod.Window(startEpoch: $0.0, endEpoch: $0.1) },
        regular: regular.map { TradingPeriod.Window(startEpoch: $0.0, endEpoch: $0.1) },
        post: post.map { TradingPeriod.Window(startEpoch: $0.0, endEpoch: $0.1) })
}

@Test func stateIsReadFromTheWindowsAndNotFromACalendar() {
    let p = period()
    #expect(p.state(atEpoch: 50) == .closed)
    #expect(p.state(atEpoch: 150) == .pre)
    #expect(p.state(atEpoch: 250) == .regular)
    #expect(p.state(atEpoch: 350) == .post)
    #expect(p.state(atEpoch: 450) == .closed)
}

@Test func windowsAreHalfOpenSoTheBoundaryBelongsToExactlyOneState() {
    let p = period()
    // 200 is regular's start and pre's end. Without a rule, a poll landing
    // exactly on the bell reads as both or neither.
    #expect(p.state(atEpoch: 200) == .regular)
    #expect(p.state(atEpoch: 300) == .post)
    #expect(p.state(atEpoch: 400) == .closed)
}

@Test func cryptoIsNeverClosed() {
    // A 24-hour session arrives as a regular window spanning the whole day.
    // This is the case a hand-maintained holiday table gets wrong.
    let p = period(pre: nil, regular: (0, 86_400), post: nil)
    #expect(p.state(atEpoch: 1) == .regular)
    #expect(p.state(atEpoch: 43_200) == .regular)
    #expect(p.state(atEpoch: 86_399) == .regular)
}

@Test func aPeriodWithNoWindowsAtAllReadsClosedRatherThanCrashing() {
    let p = period(pre: nil, regular: nil, post: nil)
    #expect(p.state(atEpoch: 250) == .closed)
    #expect(p.nextRegularOpenEpoch(after: 0) == nil)
}

@Test func aZeroLengthOrInvertedWindowIsIgnored() {
    // Yahoo has been seen to emit start == end on a holiday.
    let p = period(pre: nil, regular: (200, 200), post: nil)
    #expect(p.state(atEpoch: 200) == .closed)

    let inverted = period(pre: nil, regular: (300, 200), post: nil)
    #expect(inverted.state(atEpoch: 250) == .closed)
}

@Test func regularWinsWhenYahooEmitsOverlappingWindows() {
    // Some venues arrive with real overlap, not just shared boundaries.
    // pre 100-250 and regular 200-350 share [200, 250); regular and
    // post 300-450 share [300, 350). Either overlap must resolve to
    // .regular, not to whichever window happens to be checked first.
    let p = period(pre: (100, 250), regular: (200, 350), post: (300, 450))
    #expect(p.state(atEpoch: 220) == .regular)
    #expect(p.state(atEpoch: 320) == .regular)
}

@Test func theNextOpenIsOnlyReportedWhenItIsStillAhead() {
    let p = period()
    #expect(p.nextRegularOpenEpoch(after: 100) == 200)
    #expect(p.nextRegularOpenEpoch(after: 250) == nil)
}

@Test func theTradingPeriodParsesOutOfARealFixture() throws {
    let parsed = try YahooQuoteDecoding.tradingPeriod(from: Fixture.data("regular-session.json"))
    let regular = try #require(parsed.regular)
    #expect(regular.endEpoch > regular.startEpoch)
    // A US regular session is 6.5 hours. Allow slack for a half-day.
    #expect(regular.endEpoch - regular.startEpoch <= 6.5 * 3600 + 60)
}

@Test func aPayloadWithNoTradingPeriodIsAMissingFieldNotAGuess() throws {
    let json = "{\"chart\":{\"result\":[{\"meta\":{\"regularMarketPrice\":1.0}}],\"error\":null}}"
    #expect(throws: TickerError.self) {
        try YahooQuoteDecoding.tradingPeriod(from: Data(json.utf8))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --build-system native --filter TradingPeriod`
Expected: FAIL — `cannot find 'TradingPeriod' in scope`.

- [ ] **Step 3: Implement `TradingPeriod`**

`Sources/TickerCore/TradingPeriod.swift`:

```swift
/// Where the market is right now.
public enum MarketState: Equatable, Sendable {
    case pre
    case regular
    case post
    case closed
}

/// The session windows for one instrument, straight from the payload.
///
/// **No local exchange calendar ships with Squiggle** (spec §4.2). Holidays,
/// half-days, both DST regimes, per-symbol venues and crypto's 24-hour session
/// all fall out of this for free. A hand-maintained holiday table would be
/// silently wrong every Thanksgiving.
///
/// Epochs are wall-clock seconds and enter as parameters. The core still reads
/// no clock: `state(atEpoch:)` is a pure function of its argument.
public struct TradingPeriod: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        public let startEpoch: Double
        public let endEpoch: Double

        public init(startEpoch: Double, endEpoch: Double) {
            self.startEpoch = startEpoch
            self.endEpoch = endEpoch
        }

        /// Half-open: `[start, end)`. The boundary belongs to exactly one
        /// window, so a poll landing on the opening bell has one answer.
        /// A zero-length or inverted window contains nothing — Yahoo emits
        /// `start == end` on some holidays.
        public func contains(_ epoch: Double) -> Bool {
            startEpoch < endEpoch && epoch >= startEpoch && epoch < endEpoch
        }
    }

    public let pre: Window?
    public let regular: Window?
    public let post: Window?

    public init(pre: Window?, regular: Window?, post: Window?) {
        self.pre = pre
        self.regular = regular
        self.post = post
    }

    /// Regular is checked first so that an overlap — which Yahoo does emit
    /// for some venues — resolves to the busier session rather than to
    /// whichever happens to be tested first.
    public func state(atEpoch epoch: Double) -> MarketState {
        if regular?.contains(epoch) ?? false { return .regular }
        if pre?.contains(epoch) ?? false { return .pre }
        if post?.contains(epoch) ?? false { return .post }
        return .closed
    }

    /// When to set the single wake while the market is closed, or nil if this
    /// payload does not describe a future open.
    public func nextRegularOpenEpoch(after epoch: Double) -> Double? {
        guard let regular, regular.startEpoch < regular.endEpoch,
              regular.startEpoch > epoch else { return nil }
        return regular.startEpoch
    }
}
```

- [ ] **Step 4: Add the decoder entry point**

Append to `Sources/TickerCore/YahooQuoteDecoding.swift`, inside `enum YahooQuoteDecoding`:

```swift
    public static func tradingPeriod(from data: Data) throws -> TradingPeriod {
        let meta = try self.meta(from: data)
        guard let payload = meta.currentTradingPeriod else {
            throw TickerError.missingField(
                path: "chart.result[0].meta.currentTradingPeriod")
        }

        func window(_ raw: TradingPeriodPayload.Window?) -> TradingPeriod.Window? {
            guard let start = raw?.start?.value, let end = raw?.end?.value else { return nil }
            return TradingPeriod.Window(startEpoch: start, endEpoch: end)
        }

        return TradingPeriod(
            pre: window(payload.pre),
            regular: window(payload.regular),
            post: window(payload.post))
    }
```

- [ ] **Step 5: Run to verify they pass**

Run: `swift test --build-system native --filter TradingPeriod`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/TickerCore/TradingPeriod.swift Sources/TickerCore/YahooQuoteDecoding.swift \
        Tests/TickerCoreTests/TradingPeriodTests.swift
git commit -m "feat: trading periods read from the payload, not from a calendar"
```

---

## Task 8: Injected time, injected randomness, and the token bucket

`RequestPacer` is a safety property, not a preference. No code path may bypass it — a bug anywhere else must not be able to flood.

**Files:**
- Create: `Sources/TickerCore/MonotonicClock.swift`
- Create: `Sources/TickerCore/Randomizing.swift`
- Create: `Sources/TickerCore/RateConstants.swift`
- Create: `Sources/TickerCore/RequestPacer.swift`
- Create: `Tests/TickerCoreTests/Fakes.swift`
- Test: `Tests/TickerCoreTests/RequestPacerTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `TickerCore.MonotonicClock` — `protocol { var nowSeconds: Double { get } }`; `SystemClock` conforms.
  - `TickerCore.Randomizing` — `protocol { func double(in: ClosedRange<Double>) -> Double }`; `SystemRandom` conforms.
  - `TickerCore.RateConstants` — `enum` of static `Double`s: `spacingSeconds`, `bucketCapacity`, `rateLimitBackoffBase/Cap`, `serverBackoffBase/Cap`, `unauthorizedCooldown`, `contractFaultCooldown`, `circuitOpenSeconds`, `circuitFailureThreshold`, `maxWatchlistCount`, `jitterGrowthFactor`, `timerLeewayFraction`, `stalenessMultiplier`.
  - `TickerCore.RequestPacer` — `struct`, `init(clock:)`, `mutating func take() -> Bool`, `mutating func halveCapacity()`, `var availableTokens: Double`, `func secondsUntilNextToken() -> Double`.
  - Test helpers: `FakeClock` (class, `var nowSeconds`, `func advance(_:)`), `FakeRandom` (returns the upper bound by default, configurable).

- [ ] **Step 1: Write the failing tests**

`Tests/TickerCoreTests/Fakes.swift`:

```swift
import Foundation
@testable import TickerCore

/// Time under the test's control. A class so that advancing it is visible to
/// every holder without threading a value back.
final class FakeClock: MonotonicClock, @unchecked Sendable {
    private(set) var nowSeconds: Double
    init(_ start: Double = 0) { nowSeconds = start }
    func advance(_ seconds: Double) { nowSeconds += seconds }
    func advance(minutes: Double) { advance(minutes * 60) }
    func advance(hours: Double) { advance(hours * 3600) }
}

/// Deterministic jitter. Defaults to the top of the range, which is the
/// worst case for a backoff cap and the best case for catching an overflow.
final class FakeRandom: Randomizing, @unchecked Sendable {
    /// 0 picks the low bound, 1 the high bound.
    var position: Double
    private(set) var calls: [ClosedRange<Double>] = []

    init(position: Double = 1.0) { self.position = position }

    func double(in range: ClosedRange<Double>) -> Double {
        calls.append(range)
        return range.lowerBound + (range.upperBound - range.lowerBound) * position
    }
}
```

`Tests/TickerCoreTests/RequestPacerTests.swift`:

```swift
import Testing
@testable import TickerCore

// NOTE: this suite's standalone `swift-testing` package (see
// ExpectMacroTests.swift) also mis-compiles `#expect(...)` whenever the
// checked expression is a direct call to a `mutating` method on a `var` —
// its call-capturing expansion binds the receiver as an immutable `$0`.
// `RequestPacer.take()` is exactly that shape, so every such call is hoisted
// into a `let` before the `#expect` rather than written inline.

@Test func aFreshPacerAllowsABurstUpToCapacityAndNoMore() {
    let clock = FakeClock()
    var pacer = RequestPacer(clock: clock)

    // Capacity 5 exists so a launch, an unocclusion and a manual refresh do
    // not each have to wait 30 seconds. It is a burst allowance, not a rate.
    for attempt in 1...Int(RateConstants.bucketCapacity) {
        let granted = pacer.take()
        #expect(granted, "token \(attempt) should have been available")
    }
    let extra = pacer.take()
    #expect(!extra)
}

@Test func theBucketRefillsAtExactlyOnePerSpacingInterval() {
    let clock = FakeClock()
    var pacer = RequestPacer(clock: clock)
    var drained = 0
    while pacer.take() {
        drained += 1
        if drained >= 100 { break }
    }
    #expect(drained < 100, "take() never returned false")

    clock.advance(RateConstants.spacingSeconds - 0.001)
    let tooEarly = pacer.take()
    #expect(!tooEarly, "a token appeared before the spacing floor elapsed")

    clock.advance(0.002)
    let onTime = pacer.take()
    #expect(onTime)
    let secondInARow = pacer.take()
    #expect(!secondInARow, "two tokens appeared for one interval")
}

@Test func theBucketNeverAccumulatesMoreThanCapacity() {
    // A machine asleep for a week must not wake with a week of tokens. This
    // is the invariant that makes the daily budget hold across a lid-open.
    let clock = FakeClock()
    var pacer = RequestPacer(clock: clock)
    var initialDrain = 0
    while pacer.take() {
        initialDrain += 1
        if initialDrain >= 100 { break }
    }
    #expect(initialDrain < 100, "take() never returned false")

    clock.advance(hours: 168)
    var granted = 0
    while pacer.take() {
        granted += 1
        if granted >= 100 { break }
    }
    #expect(granted < 100, "take() never returned false")
    #expect(granted == Int(RateConstants.bucketCapacity))
}

@Test func theLongRunRateIsOnePerSpacingIntervalNoMatterHowOftenItIsAsked() {
    // Poll it every second for a simulated day. The bucket, not the caller,
    // decides the rate.
    let clock = FakeClock()
    var pacer = RequestPacer(clock: clock)
    var granted = 0
    for _ in 0..<86_400 {
        if pacer.take() { granted += 1 }
        clock.advance(1)
    }
    let ceiling = Int(86_400 / RateConstants.spacingSeconds + RateConstants.bucketCapacity)
    #expect(granted <= ceiling, "granted \(granted), ceiling \(ceiling)")
    #expect(granted >= ceiling - 2, "granted \(granted); the bucket is throttling below its rate")
}

@Test func halvingTheCapacityHalvesTheBurstAndTheRate() {
    // AIMD on a 429 (spec §4.3): back off multiplicatively, recover additively
    // — which here means not recovering at all within the session.
    let clock = FakeClock()
    var pacer = RequestPacer(clock: clock)
    pacer.halveCapacity()

    var granted = 0
    while pacer.take() {
        granted += 1
        if granted >= 100 { break }
    }
    #expect(granted < 100, "take() never returned false")
    #expect(granted == Int(RateConstants.bucketCapacity / 2))

    clock.advance(RateConstants.spacingSeconds * 2)
    let refilled = pacer.take()
    #expect(refilled)
    let second = pacer.take()
    #expect(!second, "halving did not slow the refill")
}

@Test func capacityNeverHalvesBelowOne() {
    // Repeated 429s must leave the app able to make progress eventually;
    // a capacity of zero is a permanent outage that no success can clear.
    let clock = FakeClock()
    var pacer = RequestPacer(clock: clock)
    for _ in 0..<10 { pacer.halveCapacity() }
    clock.advance(RateConstants.spacingSeconds * 10)
    let granted = pacer.take()
    #expect(granted)
}

@Test func timeGoingBackwardsDoesNotMintTokens() {
    // A monotonic clock should not go backwards, but a fake, a suspended
    // process, or a future refactor to a wall clock could. Never trust it.
    let clock = FakeClock(1000)
    var pacer = RequestPacer(clock: clock)
    var drained = 0
    while pacer.take() {
        drained += 1
        if drained >= 100 { break }
    }
    #expect(drained < 100, "take() never returned false")

    let rewound = FakeClock(0)
    var rewoundPacer = RequestPacer(clock: rewound)
    var rewoundDrained = 0
    while rewoundPacer.take() {
        rewoundDrained += 1
        if rewoundDrained >= 100 { break }
    }
    #expect(rewoundDrained < 100, "take() never returned false")
    rewound.advance(-500)
    let mintedFromRewind = rewoundPacer.take()
    #expect(!mintedFromRewind)
}

@Test func anOscillatingClockDoesNotMintTokens() {
    // A clock that jumps backward and then returns to (or through) a point
    // it has already visited must not be credited twice for a span of time
    // that never actually elapsed. Drain the bucket, then oscillate several
    // times and confirm no tokens appeared.
    let clock = FakeClock(0)
    var pacer = RequestPacer(clock: clock)
    var drained = 0
    while pacer.take() {
        drained += 1
        if drained >= 100 { break }
    }
    #expect(drained < 100, "take() never returned false")
    #expect(pacer.availableTokens == 0)

    for _ in 0..<5 {
        clock.advance(-100)
        _ = pacer.secondsUntilNextToken() // forces a refill() without spending a token
        clock.advance(100)
        _ = pacer.secondsUntilNextToken()
    }

    #expect(
        pacer.availableTokens == 0,
        "oscillating the clock back to its starting point minted \(pacer.availableTokens) tokens"
    )

    // A genuine forward advance past the high-water mark must still credit
    // correctly — exactly one token for one spacing interval, not more.
    clock.advance(RateConstants.spacingSeconds)
    let earned = pacer.take()
    #expect(earned, "a real spacing interval should have earned a token")
    let extra = pacer.take()
    #expect(!extra, "the oscillation should not have earned a bonus token")
}

@Test func theWaitReportedMatchesTheWaitEnforced() {
    let clock = FakeClock()
    var pacer = RequestPacer(clock: clock)
    var drained = 0
    while pacer.take() {
        drained += 1
        if drained >= 100 { break }
    }
    #expect(drained < 100, "take() never returned false")

    let wait = pacer.secondsUntilNextToken()
    #expect(wait > 0)
    clock.advance(wait)
    let granted = pacer.take()
    #expect(granted, "the pacer reported a wait of \(wait) and then refused")
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --build-system native --filter RequestPacer`
Expected: FAIL — `cannot find 'RequestPacer' in scope`.

- [ ] **Step 3: Write the injected seams**

`Sources/TickerCore/MonotonicClock.swift`:

```swift
import Foundation

/// Time, injected.
///
/// A monotonic source specifically: a backoff deadline must not move when the
/// wall clock is adjusted, or an NTP correction mid-cooldown either resumes
/// polling early or strands the app for hours.
///
/// The one documented exception is the persisted cooldown (spec §4.3), which
/// is wall-clock because it must survive process termination. It enters
/// `TickerCore` as a `Double` parameter, never as a clock read.
public protocol MonotonicClock: Sendable {
    var nowSeconds: Double { get }
}

public struct SystemClock: MonotonicClock {
    public init() {}
    /// Time since boot; unaffected by wall-clock adjustments.
    public var nowSeconds: Double { ProcessInfo.processInfo.systemUptime }
}
```

`Sources/TickerCore/Randomizing.swift`:

```swift
/// Randomness, injected, so jitter is reproducible under test.
public protocol Randomizing: Sendable {
    func double(in range: ClosedRange<Double>) -> Double
}

public struct SystemRandom: Randomizing {
    public init() {}
    public func double(in range: ClosedRange<Double>) -> Double {
        guard range.lowerBound < range.upperBound else { return range.lowerBound }
        return Double.random(in: range)
    }
}
```

- [ ] **Step 4: Write `RateConstants`**

`Sources/TickerCore/RateConstants.swift`:

```swift
/// Every rate and timeout in Squiggle, in one table.
///
/// **Borrowed and unverified.** No authoritative published Yahoo rate limit
/// exists; the `360/hr` figure circulating in `yfinance` issues traces to
/// YQL-era documentation, not to current policy. These values are chosen to
/// sit an order of magnitude below any plausible limit, and to arrive evenly
/// spaced rather than in the bursts that actually trigger a 429.
///
/// The one hard datum (observed 2026-09-08): a 429 from
/// `query1.finance.yahoo.com` is IP-scoped, took only a few dozen requests
/// over eight minutes to trip, and persisted for over an hour. Being slow is
/// far cheaper than being blocked.
public enum RateConstants {
    /// The floor between any two requests, ever. A safety property.
    public static let spacingSeconds: Double = 30

    /// Burst allowance: a launch, an unocclusion and a manual refresh should
    /// not each wait 30 seconds. Does not raise the long-run rate.
    public static let bucketCapacity: Double = 5

    /// Decorrelated jitter: min(cap, random(base, previous × growth)).
    public static let jitterGrowthFactor: Double = 3

    public static let rateLimitBackoffBase: Double = 60
    public static let rateLimitBackoffCap: Double = 30 * 60

    public static let serverBackoffBase: Double = 30
    public static let serverBackoffCap: Double = 15 * 60

    /// Backoff cannot fix a broken authentication assumption.
    public static let unauthorizedCooldown: Double = 60 * 60

    /// A 200 with an unparseable body is a contract fault, not a network
    /// fault. Retrying a parse failure faster buys nothing.
    public static let contractFaultCooldown: Double = 60 * 60

    public static let circuitFailureThreshold: Int = 5
    public static let circuitOpenSeconds: Double = 30 * 60

    public static let maxWatchlistCount: Int = 20

    /// The refresh intervals offered in Settings (spec §4.1). A fixed menu,
    /// not a slider: the floor sits underneath, and a control that silently
    /// declines to honour what you typed is worse than four honest choices.
    public static let refreshIntervalChoices: [Double] = [60, 180, 300, 900]
    public static let defaultRefreshInterval: Double = 180

    /// Extended-hours and Low Power Mode both stretch the cycle by this.
    public static let quietMultiplier: Double = 3

    /// Wake this long before the open, while closed.
    public static let preOpenWakeLead: Double = 60

    /// Dim the strip once data is older than this multiple of the interval.
    public static let stalenessMultiplier: Double = 3

    /// Fraction of the interval handed to the OS as timer leeway, so wakeups
    /// coalesce with other system work. A larger battery win than lengthening
    /// the interval.
    public static let timerLeewayFraction: Double = 0.25
}
```

**Two defects were found here in review and are already fixed in the code below
(controller rulings R11 and R12) — do not "simplify" either one back out.**

1. *The refill rate must scale with capacity.* The original `refill()` added
   `elapsed / spacingSeconds`, a flat rate independent of `capacity`, so
   `halveCapacity()` shrank only the burst and left the sustained rate to Yahoo
   untouched — contradicting this task's own test name
   (`halvingTheCapacityHalvesTheBurstAndTheRate`) and the AIMD doc comment.
   `effectiveSpacingSeconds` fixes it. Reachable capacities are 5 / 2.5 / 1.25 / 1,
   giving 30s / 60s / 120s / 150s: bounded, never zero.
2. *`lastRefill` must be a high-water mark.* Clamping `elapsed` to zero is not enough.
   Assigning `lastRefill = now` on a backward reading lets an oscillating clock credit
   the same interval repeatedly — measured, not theorised: a drained bucket refilled
   0 -> 5.0 tokens over five oscillations of a clock with **zero** net progress. That is
   an unbounded minting path in the one type the spec calls a safety property.
   `lastRefill = max(lastRefill, now)` credits only genuine progress past the highest
   point ever seen. `anOscillatingClockDoesNotMintTokens` pins it and fails if the
   high-water mark is removed.

Note also that the loops in the tests above are bounded with an explicit ceiling and a
`"take() never returned false"` assertion. That is not decoration: with unbounded
`while pacer.take()` loops, a `take()` that wrongly returns `true` makes the suite
**hang** rather than fail — an ambiguous ten-minute CPU peg instead of a red test.

- [ ] **Step 5: Write `RequestPacer`**

`Sources/TickerCore/RequestPacer.swift`:

```swift
/// The token bucket every request passes through. There is no bypass.
///
/// This is a safety property rather than a policy: no bug elsewhere in
/// Squiggle — a runaway retry, a UI action wired to the wrong handler, a
/// future feature — can flood Yahoo, because nothing else holds the tokens.
///
/// Capacity is a *burst* allowance; the long-run rate is one request per
/// the current effective spacing — `spacingSeconds` at full capacity, longer
/// once `halveCapacity()` has scaled it back — regardless of how often
/// `take()` is called.
public struct RequestPacer {
    private let clock: any MonotonicClock
    private var capacity: Double
    private var tokens: Double
    private var lastRefill: Double

    public init(clock: any MonotonicClock) {
        self.clock = clock
        self.capacity = RateConstants.bucketCapacity
        self.tokens = RateConstants.bucketCapacity
        self.lastRefill = clock.nowSeconds
    }

    public var availableTokens: Double { tokens }

    /// Multiplicative decrease on a 429 (AIMD, spec §4.3). Never reaches zero:
    /// a capacity of nought is a permanent outage no success could clear.
    /// There is no increase — recovery is a relaunch, which is honest about
    /// the fact that we do not know Yahoo's real limit.
    public mutating func halveCapacity() {
        capacity = max(1, capacity / 2)
        tokens = min(tokens, capacity)
    }

    public mutating func take() -> Bool {
        refill()
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }

    public mutating func secondsUntilNextToken() -> Double {
        refill()
        guard tokens < 1 else { return 0 }
        return (1 - tokens) * effectiveSpacingSeconds
    }

    /// Seconds to accrue one token at the current capacity. Halving capacity
    /// must also halve the sustained rate — a halved burst allowance that
    /// still refills at the un-throttled rate would leave the long-run rate
    /// to Yahoo untouched by the one signal (a 429) telling us to slow down.
    /// Scales `spacingSeconds` by how far `capacity` has fallen from the
    /// un-throttled `bucketCapacity`.
    private var effectiveSpacingSeconds: Double {
        RateConstants.spacingSeconds * (RateConstants.bucketCapacity / capacity)
    }

    private mutating func refill() {
        let now = clock.nowSeconds
        // Never trust time to move forward. A suspended process, a fake, or a
        // future refactor could hand us a smaller number. The real danger
        // isn't the backward reading itself (that credits nothing — elapsed
        // clamps to zero) but letting lastRefill regress to it: a clock that
        // later returns to where it already was would then look like it
        // travelled forward from the dip, minting tokens for time that never
        // passed. Keeping lastRefill a high-water mark closes that path.
        let elapsed = max(0, now - lastRefill)
        lastRefill = max(lastRefill, now)
        tokens = min(capacity, tokens + elapsed / effectiveSpacingSeconds)
    }
}
```

- [ ] **Step 6: Run to verify they pass**

Run: `swift test --build-system native --filter RequestPacer`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/TickerCore/MonotonicClock.swift Sources/TickerCore/Randomizing.swift \
        Sources/TickerCore/RateConstants.swift Sources/TickerCore/RequestPacer.swift \
        Tests/TickerCoreTests/Fakes.swift Tests/TickerCoreTests/RequestPacerTests.swift
git commit -m "feat: the token bucket that no code path may bypass"
```

---

## Task 9: Failure classification and the backoff ladder

Failures are classified, not backed off uniformly (spec §4.3). There is **no per-request retry** — the next cycle is the retry.

**Files:**
- Create: `Sources/TickerCore/Failure.swift`
- Create: `Sources/TickerCore/BackoffLadder.swift`
- Test: `Tests/TickerCoreTests/BackoffLadderTests.swift`

**Interfaces:**
- Consumes: `TickerError`, `RateConstants`, `MonotonicClock`, `Randomizing`.
- Produces:
  - `TickerCore.FailureKind` — `enum { case offline, rateLimited(retryAfterSeconds: Double?), server, unauthorized, contractFault, deadSymbol }`, `Equatable, Sendable`, plus `init(_ error: TickerError)`.
  - `TickerCore.BackoffLadder` — `init(clock:random:)`, `mutating func record(_ kind: FailureKind) -> Double` (returns the cooldown just applied), `mutating func recordSuccess()`, `func isCoolingDown() -> Bool`, `func secondsRemaining() -> Double`, `var cooldownUntilMonotonic: Double?`, `mutating func adoptPersistedCooldown(secondsRemaining: Double)`.

**Rulings R14-R17, recorded here because a re-run that "simplifies" any of
them re-opens a hole a reviewer already found.** The code below is the
shipped, reviewed source, not a sketch — transcribe it.

- **R15.** A `mutating` method cannot be called inside `#expect`: the
  swift-testing macro binds the receiver immutably and you get `cannot use
  mutating member on immutable value: '$0' is immutable`. An earlier draft of
  this task called `ladder.record(...)` inside `#expect` in eight places and
  none of it compiled. Every such assertion is hoisted: `let applied =
  l.record(...)` then `#expect(applied == ...)`.
- **R14.** `FailureKind.init(_ error: TickerError)` switches with **no
  `default:` clause**, so the compiler — not a test — enforces that every
  error is classified. `.invalidSymbol`, `.storeSchemaUnsupported` and
  `.storeCorrupt` map to `.server` on purpose: they cannot arise from a
  fetch, and routing an unreachable case into the one-hour contract circuit
  would turn a local bug into an hour of silence.
- **R16.** The rate-limit ladder and the server ladder keep **separate**
  growth state. One shared field let a 3600s unauthorized cooldown send the
  very next server failure straight to its 900s cap. `eachFailureClassClimbsItsOwnLadder`
  fails if the fields are merged again.
- **R17.** `adoptPersistedCooldown` clamps to `RateConstants.maxCooldownSeconds`,
  not to `rateLimitBackoffCap` — the old bound silently halved the 3600s
  cooldowns this same ladder produces. Add the constant to
  `Sources/TickerCore/RateConstants.swift` first, derived rather than written
  down twice:

```swift
    /// The longest cooldown `BackoffLadder` can legitimately produce, and so
    /// the only defensible clamp for a deadline read back from disk. Derived,
    /// not hardcoded: a bound that drifts from the constants it bounds is
    /// worse than no bound at all.
    public static let maxCooldownSeconds: Double =
        max(rateLimitBackoffCap, max(unauthorizedCooldown, contractFaultCooldown))
```

The tests below are the strengthened set. Six of the original ones passed
against deliberately broken code: `recordSuccess` could stop clearing the
cooldown entirely, `.offline` could advance the ladder, `secondsRemaining`
could lose its `max(0,)` clamp, `cooldownUntilMonotonic` could return a
constant `nil`, `isCoolingDown` could flip `<` to `<=`, and the jitter cap
could be removed — all with a green suite. Do not thin them out.

Note also that `jittered` caps the **range handed to the randomizer**, not
the draw that comes back. Capping the draw instead lets a real RNG sample
from `[base, ∞)` and land on the cap almost surely, collapsing the jitter to
a constant — which is the thundering herd this type exists to prevent.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import TickerCore

// NOTE: as in RequestPacerTests.swift, this suite's `#expect(...)` macro
// mis-compiles whenever the checked expression is a direct call to a
// `mutating` method on a `var` — its call-capturing expansion binds the
// receiver as an immutable `$0`, producing "cannot use mutating member on
// immutable value". `BackoffLadder.record(_:)` is exactly that shape, so
// every such call is hoisted into a `let` before the `#expect` rather than
// written inline.

private func ladder(_ clock: FakeClock, _ random: FakeRandom = FakeRandom()) -> BackoffLadder {
    BackoffLadder(clock: clock, random: random)
}

@Test func everyTickerErrorClassifiesIntoExactlyOneFailureKind() throws {
    let symbol = try #require(Symbol("AAPL"))
    #expect(FailureKind(.offline) == .offline)
    #expect(FailureKind(.rateLimited(retryAfterSeconds: nil)) == .rateLimited(retryAfterSeconds: nil))
    #expect(FailureKind(.rateLimited(retryAfterSeconds: 90)) == .rateLimited(retryAfterSeconds: 90))
    #expect(FailureKind(.serverError(status: 503)) == .server)
    #expect(FailureKind(.transport("timeout")) == .server)
    #expect(FailureKind(.unauthorized(status: 401)) == .unauthorized)
    #expect(FailureKind(.symbolNotFound(symbol)) == .deadSymbol)
    // Every contract fault, one kind. Spec §4.3 gives them their own circuit.
    #expect(FailureKind(.notJSON) == .contractFault)
    #expect(FailureKind(.noResult) == .contractFault)
    #expect(FailureKind(.missingField(path: "x")) == .contractFault)
    #expect(FailureKind(.nonFiniteNumber(path: "x")) == .contractFault)
    // The remaining contract faults from `TickerError.isContractFault`.
    #expect(FailureKind(.emptyBody) == .contractFault)
    #expect(FailureKind(.wrongType(path: "x", expected: "number")) == .contractFault)
    #expect(FailureKind(.negativeValue(path: "x", value: -1)) == .contractFault)
    // These three cannot arise from a fetch at all (a rejected symbol never
    // reaches the network; the other two are storage faults). Mapped to the
    // mildest, shortest, self-correcting rung deliberately: routing an
    // unreachable case into the hour-long contract circuit would turn a
    // local bug into an hour of silence.
    #expect(FailureKind(.invalidSymbol("not a symbol")) == .server)
    #expect(FailureKind(.storeSchemaUnsupported(version: 99)) == .server)
    #expect(FailureKind(.storeCorrupt(quarantinedAt: "2026-09-08")) == .server)
}

@Test func beingOfflineDoesNotAdvanceTheLadder() {
    // Spec §4.3: do not attempt, do not advance. Punishing the user's flaky
    // wifi with a 30-minute cooldown means the ticker is dead long after the
    // network comes back.
    let clock = FakeClock()
    var l = ladder(clock, FakeRandom(position: 1.0))
    for _ in 0..<10 { _ = l.record(.offline) }

    // "Do not attempt" — no cooldown was applied.
    #expect(!l.isCoolingDown())
    #expect(l.cooldownUntilMonotonic == nil)

    // "Do not advance" — the other half of the sentence, and the half a
    // cooldown assertion cannot see. After ten offline cycles the first real
    // failure of each class must still arrive at that class's base, not one
    // rung up. `position: 1.0` means any advance at all would show.
    let firstServer = l.record(.server)
    #expect(firstServer == RateConstants.serverBackoffBase)
    clock.advance(firstServer)
    let firstRateLimit = l.record(.rateLimited(retryAfterSeconds: nil))
    #expect(firstRateLimit == RateConstants.rateLimitBackoffBase)
}

@Test func aDeadSymbolDoesNotAdvanceTheLadderEither() {
    // Same shape as offline: the symbol leaves the rotation, the other
    // nineteen are unaffected, and nothing about the ladder moves.
    let clock = FakeClock()
    var l = ladder(clock, FakeRandom(position: 1.0))
    for _ in 0..<10 { _ = l.record(.deadSymbol) }
    #expect(l.cooldownUntilMonotonic == nil)

    let firstServer = l.record(.server)
    #expect(firstServer == RateConstants.serverBackoffBase)
    clock.advance(firstServer)
    let firstRateLimit = l.record(.rateLimited(retryAfterSeconds: nil))
    #expect(firstRateLimit == RateConstants.rateLimitBackoffBase)
}

@Test func eachFailureClassClimbsItsOwnLadder() {
    // "Decorrelated jitter, per failure class" is the type's headline claim,
    // and a single shared growth field makes it false in the one direction
    // that matters. The realistic sequence is the damaging one: an hour-long
    // circuit expires, the very next cycle hits a transient 503, and instead
    // of the documented thirty-second rung the app goes silent for the full
    // fifteen-minute cap.
    let clock = FakeClock()
    var l = ladder(clock, FakeRandom(position: 1.0))

    let rate1 = l.record(.rateLimited(retryAfterSeconds: nil))
    #expect(rate1 == RateConstants.rateLimitBackoffBase)          // 60
    clock.advance(rate1)

    // A rate limit must not push the server ladder off its own base.
    let server1 = l.record(.server)
    #expect(server1 == RateConstants.serverBackoffBase)           // 30
    clock.advance(server1)

    // Interleaved, each class resumes from where *it* left off.
    let rate2 = l.record(.rateLimited(retryAfterSeconds: nil))
    #expect(rate2 == rate1 * RateConstants.jitterGrowthFactor)    // 180
    clock.advance(rate2)
    let server2 = l.record(.server)
    #expect(server2 == server1 * RateConstants.jitterGrowthFactor) // 90
    clock.advance(server2)

    // The two flat cooldowns are not rungs on anything. They must feed
    // neither ladder's growth.
    let auth = l.record(.unauthorized)
    #expect(auth == RateConstants.unauthorizedCooldown)           // 3600
    clock.advance(auth)
    let contract = l.record(.contractFault)
    #expect(contract == RateConstants.contractFaultCooldown)      // 3600
    clock.advance(contract)

    let server3 = l.record(.server)
    #expect(server3 == server2 * RateConstants.jitterGrowthFactor) // 270
    clock.advance(server3)
    let rate3 = l.record(.rateLimited(retryAfterSeconds: nil))
    #expect(rate3 == rate2 * RateConstants.jitterGrowthFactor)     // 540
}

@Test func aRateLimitStartsAtItsBaseAndGrowsByTheJitterFactor() {
    let clock = FakeClock()
    let random = FakeRandom(position: 1.0)   // always the top of the range
    var l = ladder(clock, random)

    let first = l.record(.rateLimited(retryAfterSeconds: nil))
    #expect(first == RateConstants.rateLimitBackoffBase)

    clock.advance(first)
    let second = l.record(.rateLimited(retryAfterSeconds: nil))
    #expect(second == first * RateConstants.jitterGrowthFactor)
}

@Test func backoffNeverExceedsItsCapHoweverManyFailuresArrive() {
    let clock = FakeClock()
    var l = ladder(clock, FakeRandom(position: 1.0))
    var last: Double = 0
    for _ in 0..<20 {
        last = l.record(.rateLimited(retryAfterSeconds: nil))
        clock.advance(last)
    }
    #expect(last == RateConstants.rateLimitBackoffCap)
}

@Test func backoffNeverFallsBelowItsBase() {
    // Full jitter, never equal jitter — but the low bound is the base, so a
    // random draw can never produce a cooldown shorter than one base period.
    let clock = FakeClock()
    var l = ladder(clock, FakeRandom(position: 0.0))   // always the bottom
    for _ in 0..<10 {
        let wait = l.record(.rateLimited(retryAfterSeconds: nil))
        #expect(wait >= RateConstants.rateLimitBackoffBase)
        clock.advance(wait)
    }
}

@Test func jitterIsDrawnFromTheFullRangeAndNotJustItsEndpoints() throws {
    // Equal jitter would leave the installed base synchronised, which is the
    // failure the jitter exists to prevent — every Squiggle shares one
    // upstream.
    let clock = FakeClock()
    let random = FakeRandom(position: 0.5)
    var l = ladder(clock, random)
    let first = l.record(.rateLimited(retryAfterSeconds: nil))
    #expect(first == RateConstants.rateLimitBackoffBase)
    clock.advance(1000)
    let second = l.record(.rateLimited(retryAfterSeconds: nil))

    let range = try #require(random.calls.last)
    #expect(range.lowerBound == RateConstants.rateLimitBackoffBase)
    #expect(range.upperBound == first * RateConstants.jitterGrowthFactor)

    // A draw from the middle of 60...180 lands at 120: neither endpoint, and
    // nowhere near the cap. Asserting only the endpoints of the range would
    // let a collapsed distribution through.
    #expect(second == 120)
    #expect(second > range.lowerBound)
    #expect(second < range.upperBound)
}

@Test func theRangeHandedToTheRandomizerIsItselfCappedNotJustTheDrawThatComesBack() throws {
    // The distinction is not cosmetic. Clamp only the returned value and a
    // real `SystemRandom` is handed [base, 10^10] and lands on the cap almost
    // surely — the jitter distribution collapses to a constant while every
    // assertion about the returned value still passes, and the whole
    // installed base retries in lockstep again.
    let clock = FakeClock()
    let random = FakeRandom(position: 0.5)
    var l = ladder(clock, random)
    for _ in 0..<20 {
        let wait = l.record(.rateLimited(retryAfterSeconds: nil))
        clock.advance(wait)
    }
    let rateRange = try #require(random.calls.last)
    #expect(rateRange.lowerBound == RateConstants.rateLimitBackoffBase)
    #expect(rateRange.upperBound == RateConstants.rateLimitBackoffCap)

    let serverClock = FakeClock()
    let serverRandom = FakeRandom(position: 0.5)
    var s = ladder(serverClock, serverRandom)
    for _ in 0..<20 {
        let wait = s.record(.server)
        serverClock.advance(wait)
    }
    let serverRange = try #require(serverRandom.calls.last)
    #expect(serverRange.lowerBound == RateConstants.serverBackoffBase)
    #expect(serverRange.upperBound == RateConstants.serverBackoffCap)
}

@Test func aRetryAfterHeaderIsHonouredWhenItIsPresent() {
    let clock = FakeClock()
    var l = ladder(clock)
    let applied = l.record(.rateLimited(retryAfterSeconds: 90))
    #expect(applied == 90)
}

@Test func anAbsurdRetryAfterIsClampedToTheCap() {
    // A header is a hint from a service that is already misbehaving.
    let clock = FakeClock()
    var l = ladder(clock)
    let tooLong = l.record(.rateLimited(retryAfterSeconds: 86_400))
    #expect(tooLong == RateConstants.rateLimitBackoffCap)
    let negative = l.record(.rateLimited(retryAfterSeconds: -5))
    #expect(negative == RateConstants.rateLimitBackoffBase)
}

@Test func serverFailuresUseTheirOwnShorterLadder() {
    let clock = FakeClock()
    var l = ladder(clock, FakeRandom(position: 1.0))
    let first = l.record(.server)
    #expect(first == RateConstants.serverBackoffBase)
    var last: Double = 0
    for _ in 0..<20 { last = l.record(.server); clock.advance(last) }
    #expect(last == RateConstants.serverBackoffCap)
}

@Test func unauthorizedAndContractFaultsBothCoolDownForAnHourImmediately() {
    // Neither is something backoff can fix, so neither climbs a ladder.
    let clock = FakeClock()
    var authLadder = ladder(clock)
    let authDelay = authLadder.record(.unauthorized)
    #expect(authDelay == RateConstants.unauthorizedCooldown)

    var contractLadder = ladder(FakeClock())
    let contractDelay = contractLadder.record(.contractFault)
    #expect(contractDelay == RateConstants.contractFaultCooldown)
}

@Test func aDeadSymbolCoolsDownNothing() {
    // The symbol is dropped from the rotation; the other nineteen are fine.
    let clock = FakeClock()
    var l = ladder(clock)
    let applied = l.record(.deadSymbol)
    #expect(applied == 0)
    #expect(!l.isCoolingDown())
}

@Test func aSuccessResetsTheLadderCompletely() {
    let clock = FakeClock()
    var l = ladder(clock, FakeRandom(position: 1.0))
    for _ in 0..<5 { let w = l.record(.rateLimited(retryAfterSeconds: nil)); clock.advance(w) }
    for _ in 0..<5 { let w = l.record(.server); clock.advance(w) }
    l.recordSuccess()
    #expect(!l.isCoolingDown())
    // Both ladders, not just the one the loop happened to end on. One
    // `recordSuccess()` has to have cleared both growth fields.
    let afterReset = l.record(.rateLimited(retryAfterSeconds: nil))
    #expect(afterReset == RateConstants.rateLimitBackoffBase)
    clock.advance(afterReset)
    let serverAfterReset = l.record(.server)
    #expect(serverAfterReset == RateConstants.serverBackoffBase)
}

@Test func aSuccessClearsACooldownThatIsStillInForce() {
    // The reset must be tested while there is genuinely something to reset.
    // Advancing the clock to the deadline first and *then* calling
    // `recordSuccess()` asserts nothing: the cooldown has already expired on
    // its own, so deleting the clearing line from `recordSuccess()` still
    // leaves every assertion true.
    let clock = FakeClock()
    var l = ladder(clock)
    let wait = l.record(.rateLimited(retryAfterSeconds: 600))
    #expect(wait == 600)

    clock.advance(1)                    // nowhere near the deadline
    #expect(l.isCoolingDown())          // the cooldown is live right now
    #expect(l.secondsRemaining() == 599)

    l.recordSuccess()
    #expect(!l.isCoolingDown())
    #expect(l.cooldownUntilMonotonic == nil)
    #expect(l.secondsRemaining() == 0)
}

@Test func theCooldownDeadlineIsReadableForPersistence() throws {
    // `cooldownUntilMonotonic` is the value the persistence layer writes out.
    // A property that always answers nil loses the circuit across every
    // relaunch, and does so silently.
    let clock = FakeClock(1_000)
    var l = ladder(clock)
    #expect(l.cooldownUntilMonotonic == nil)

    let wait = l.record(.rateLimited(retryAfterSeconds: 600))
    let deadline = try #require(l.cooldownUntilMonotonic)
    #expect(deadline == 1_000 + wait)

    // It tracks the deadline, not merely "some cooldown happened".
    clock.advance(100)
    let unchanged = try #require(l.cooldownUntilMonotonic)
    #expect(unchanged == deadline)
    #expect(l.secondsRemaining() == deadline - clock.nowSeconds)

    let auth = l.record(.unauthorized)
    let authDeadline = try #require(l.cooldownUntilMonotonic)
    #expect(authDeadline == 1_100 + auth)

    l.recordSuccess()
    #expect(l.cooldownUntilMonotonic == nil)
}

@Test func aCooldownExpiresExactlyWhenItSaidItWould() {
    // Half-open, as everywhere else in TickerCore (see TradingPeriodTests):
    // the deadline instant itself is already *out* of the cooldown. Sampling
    // only ±1 ms leaves that convention unpinned, and `FakeClock` can land on
    // the instant exactly — 0 + 120 is exact in binary floating point.
    let clock = FakeClock()
    var l = ladder(clock)
    let wait = l.record(.rateLimited(retryAfterSeconds: 120))
    #expect(wait == 120)
    clock.advance(wait)
    #expect(clock.nowSeconds == 120)
    #expect(l.secondsRemaining() == 0)
    #expect(!l.isCoolingDown())
    clock.advance(0.001)
    #expect(!l.isCoolingDown())

    // And one millisecond earlier, on a clock that has not been nudged twice,
    // it is still in force.
    let justBefore = FakeClock()
    var m = ladder(justBefore)
    let sameWait = m.record(.rateLimited(retryAfterSeconds: 120))
    justBefore.advance(sameWait - 0.001)
    #expect(m.isCoolingDown())
    #expect(m.secondsRemaining() > 0)
}

@Test func aPersistedCooldownSurvivesASimulatedRelaunch() {
    // The reason the deadline is persisted at all: a user who relaunches
    // repeatedly during a 429 would otherwise get the installed base's IP
    // banned (spec §4.3).
    let clock = FakeClock()
    var l = ladder(clock)
    _ = l.record(.rateLimited(retryAfterSeconds: 600))
    let remaining = l.secondsRemaining()
    #expect(remaining > 599)

    // Relaunch: a brand-new ladder on a brand-new monotonic clock.
    let afterRelaunch = FakeClock(0)
    var revived = ladder(afterRelaunch)
    revived.adoptPersistedCooldown(secondsRemaining: remaining)
    #expect(revived.isCoolingDown())
    afterRelaunch.advance(remaining + 1)
    #expect(!revived.isCoolingDown())
}

@Test func secondsRemainingNeverGoesNegativeOnceTheDeadlineHasPassed() {
    // Callers schedule from this interval. A negative one is not "expired",
    // it is a timer in the past, and nothing else in the file ever reads the
    // value after its deadline.
    let clock = FakeClock()
    var l = ladder(clock)
    let wait = l.record(.rateLimited(retryAfterSeconds: 300))
    clock.advance(wait / 2)
    #expect(l.secondsRemaining() == 150)

    clock.advance(wait)                 // 450s in, 150s past the deadline
    #expect(!l.isCoolingDown())
    #expect(l.secondsRemaining() == 0)

    // Far past it, too — the floor is a floor, not an off-by-one.
    clock.advance(RateConstants.maxCooldownSeconds)
    #expect(l.secondsRemaining() == 0)
}

@Test func aPersistedCooldownFromAChangedSystemClockIsClamped() {
    // A wall-clock deadline read back after the user set their date to 2099
    // must not strand the app for a year. The bound is the longest cooldown
    // the ladder itself can produce — clamping to the rate-limit cap instead
    // would silently halve the two hour-long circuits below.
    let clock = FakeClock()
    var l = ladder(clock)
    l.adoptPersistedCooldown(secondsRemaining: 365 * 24 * 3600)
    #expect(l.secondsRemaining() == RateConstants.maxCooldownSeconds)

    var negative = ladder(FakeClock())
    negative.adoptPersistedCooldown(secondsRemaining: -1000)
    #expect(!negative.isCoolingDown())
    #expect(negative.cooldownUntilMonotonic == nil)

    var notANumber = ladder(FakeClock())
    notANumber.adoptPersistedCooldown(secondsRemaining: .nan)
    #expect(!notANumber.isCoolingDown())
    #expect(notANumber.cooldownUntilMonotonic == nil)

    var infinite = ladder(FakeClock())
    infinite.adoptPersistedCooldown(secondsRemaining: .infinity)
    #expect(infinite.secondsRemaining() == RateConstants.maxCooldownSeconds)
}

@Test func aPersistedHourLongCircuitComesBackWhole() {
    // The clamp cannot be shorter than the longest cooldown this same ladder
    // emits, or the restore path silently halves exactly the two circuits
    // that backoff cannot fix — an hour of deliberate silence read back as
    // thirty minutes.
    let clock = FakeClock()
    var l = ladder(clock)
    let applied = l.record(.unauthorized)
    #expect(applied == RateConstants.unauthorizedCooldown)
    let remaining = l.secondsRemaining()
    #expect(remaining == applied)

    let afterRelaunch = FakeClock(0)
    var revived = ladder(afterRelaunch)
    revived.adoptPersistedCooldown(secondsRemaining: remaining)
    #expect(revived.secondsRemaining() == remaining)
    #expect(revived.isCoolingDown())

    var afterContractFault = ladder(FakeClock())
    let contract = afterContractFault.record(.contractFault)
    var revivedContract = ladder(FakeClock())
    revivedContract.adoptPersistedCooldown(secondsRemaining: contract)
    #expect(revivedContract.secondsRemaining() == contract)
}

@Test func aRestoredCooldownRestoresTheLadderItWasClimbing() throws {
    // Persistence exists so that relaunching repeatedly during a 429 does not
    // hand the user a fresh ladder and get the installed base's IP banned
    // (spec §4.3). A restored deadline that quietly resets the growth state
    // defeats the only reason the deadline is written out at all.
    let clock = FakeClock()
    let random = FakeRandom(position: 1.0)
    var l = ladder(clock, random)
    l.adoptPersistedCooldown(secondsRemaining: 200)
    clock.advance(200)
    #expect(!l.isCoolingDown())

    let next = l.record(.rateLimited(retryAfterSeconds: nil))
    #expect(next > RateConstants.rateLimitBackoffBase)
    #expect(next == 200 * RateConstants.jitterGrowthFactor)      // 600, mid-ladder
    let range = try #require(random.calls.last)
    #expect(range.lowerBound == RateConstants.rateLimitBackoffBase)
    #expect(range.upperBound == 600)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --build-system native --filter BackoffLadder`
Expected: FAIL — `cannot find 'FailureKind' in scope`.

- [ ] **Step 3: Write `FailureKind`**

`Sources/TickerCore/Failure.swift`:

```swift
/// How a request went wrong, reduced to the six shapes Squiggle responds to
/// differently (spec §4.3). Classification, not uniform backoff: punishing a
/// flaky wifi connection with a thirty-minute cooldown leaves the ticker dead
/// long after the network returns.
public enum FailureKind: Equatable, Sendable {
    /// The path monitor says there is no network. Do not attempt, do not
    /// advance the ladder; resume on the path edge.
    case offline
    case rateLimited(retryAfterSeconds: Double?)
    /// 5xx or a timeout. Yahoo's problem, and usually brief.
    case server
    /// 401/403. The authentication assumption is broken; backoff cannot fix it.
    case unauthorized
    /// A 200 whose body is not what we agreed on. Its own circuit.
    case contractFault
    /// 404. This symbol is gone; the rest of the watchlist is fine.
    case deadSymbol

    public init(_ error: TickerError) {
        switch error {
        case .offline:
            self = .offline

        case .rateLimited(let retryAfter):
            self = .rateLimited(retryAfterSeconds: retryAfter)

        case .serverError, .transport:
            self = .server

        case .unauthorized:
            self = .unauthorized

        case .symbolNotFound:
            self = .deadSymbol

        // These four are the contract-fault group exactly as
        // `TickerError.isContractFault` defines it: a 200 whose body is not
        // what we agreed on. Its own one-hour circuit, separate from network
        // faults, because retrying a parse failure faster buys nothing.
        case .emptyBody, .notJSON, .noResult, .missingField,
             .wrongType, .nonFiniteNumber, .negativeValue:
            self = .contractFault

        // None of these three can arise from a fetch at all — `invalidSymbol`
        // is rejected before a request is ever built, and the store errors
        // are persistence faults, not network ones. They are classified here
        // only so this switch is total (no `default`, so the compiler is the
        // exhaustiveness checker). Mapped to `.server` — the mildest,
        // shortest, self-correcting rung — *deliberately*: routing an
        // unreachable case into the one-hour contract or unauthorized
        // circuit would turn a local bug into an hour of silence, which is
        // the worst outcome available for something that isn't even a live
        // failure mode.
        case .invalidSymbol, .storeSchemaUnsupported, .storeCorrupt:
            self = .server
        }
    }
}
```

- [ ] **Step 4: Write `BackoffLadder`**

`Sources/TickerCore/BackoffLadder.swift`:

```swift
/// Decorrelated jitter, per failure class.
///
/// `min(cap, random(base, previous × growth))` — **full** jitter, never equal
/// jitter, because the whole installed base shares one upstream. Equal jitter
/// keeps everyone's retries in lockstep, which is the thundering herd the
/// jitter exists to break up.
///
/// There is no per-request retry anywhere in Squiggle. The next cycle is the
/// retry, and this type decides when that cycle may run.
public struct BackoffLadder {
    private let clock: any MonotonicClock
    private let random: any Randomizing

    /// Growth state, one field per ladder. Sharing a single field would make
    /// "per failure class" a lie in the one direction that matters: an
    /// hour-long unauthorized or contract circuit would hand the very next
    /// transient 503 the fifteen-minute cap instead of the documented
    /// thirty-second base.
    private var previousRateLimitDelay: Double = 0
    private var previousServerDelay: Double = 0
    private var cooldownUntil: Double?

    public init(clock: any MonotonicClock, random: any Randomizing = SystemRandom()) {
        self.clock = clock
        self.random = random
    }

    public var cooldownUntilMonotonic: Double? { cooldownUntil }

    public func isCoolingDown() -> Bool {
        guard let cooldownUntil else { return false }
        return clock.nowSeconds < cooldownUntil
    }

    public func secondsRemaining() -> Double {
        guard let cooldownUntil else { return 0 }
        return max(0, cooldownUntil - clock.nowSeconds)
    }

    public mutating func recordSuccess() {
        previousRateLimitDelay = 0
        previousServerDelay = 0
        cooldownUntil = nil
    }

    /// Applies the cooldown for this failure and returns its length in seconds.
    @discardableResult
    public mutating func record(_ kind: FailureKind) -> Double {
        let delay: Double

        switch kind {
        case .offline, .deadSymbol:
            // Neither is a reason to stop asking about everything else.
            return 0

        case .rateLimited(let retryAfter):
            if let retryAfter {
                // A hint from a service that is already misbehaving: honour it,
                // but inside our own bounds.
                delay = min(RateConstants.rateLimitBackoffCap,
                            max(RateConstants.rateLimitBackoffBase, retryAfter))
            } else {
                delay = jittered(base: RateConstants.rateLimitBackoffBase,
                                 cap: RateConstants.rateLimitBackoffCap,
                                 previous: previousRateLimitDelay)
            }
            previousRateLimitDelay = delay

        case .server:
            delay = jittered(base: RateConstants.serverBackoffBase,
                             cap: RateConstants.serverBackoffCap,
                             previous: previousServerDelay)
            previousServerDelay = delay

        case .unauthorized:
            // Flat, not a rung. Neither cooldown climbs, so neither may feed
            // a ladder it is not part of.
            delay = RateConstants.unauthorizedCooldown

        case .contractFault:
            delay = RateConstants.contractFaultCooldown
        }

        cooldownUntil = clock.nowSeconds + delay
        return delay
    }

    /// Restore a cooldown that outlived the process (spec §4.3, the single
    /// documented wall-clock exception). Clamped on the way in to the longest
    /// cooldown this type can itself produce, so a system clock change cannot
    /// strand the app for a year — and so a persisted hour-long circuit is not
    /// silently halved on the way back in. NaN and negatives fail the `> 0`
    /// guard and clear the cooldown outright.
    public mutating func adoptPersistedCooldown(secondsRemaining: Double) {
        let clamped = min(secondsRemaining, RateConstants.maxCooldownSeconds)
        guard clamped > 0 else {
            cooldownUntil = nil
            return
        }
        cooldownUntil = clock.nowSeconds + clamped
        // Persistence exists so that relaunching during a 429 does not hand
        // the user a fresh ladder (spec §4.3) — resetting the growth state
        // here would defeat the only reason the deadline is written out. The
        // class that produced the deadline is not recorded, so only the
        // rate-limit ladder is seeded: it is the one persistence protects,
        // and it is seeded no higher than its own cap.
        previousRateLimitDelay = min(clamped, RateConstants.rateLimitBackoffCap)
    }

    private func jittered(base: Double, cap: Double, previous: Double) -> Double {
        // The cap is applied once, to the range handed to the randomizer, and
        // not to the draw that comes back. Capping the draw instead would let
        // a real RNG draw from [base, ∞) and land on the cap almost surely —
        // a jitter distribution collapsed to a constant, which is precisely
        // the thundering herd this type exists to break up.
        let upper = min(cap, max(base, previous * RateConstants.jitterGrowthFactor))
        guard upper > base else { return base }
        return random.double(in: base...upper)
    }
}
```

- [ ] **Step 5: Run to verify they pass**

Run: `swift test --build-system native --filter BackoffLadder`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/TickerCore/Failure.swift Sources/TickerCore/BackoffLadder.swift \
        Tests/TickerCoreTests/BackoffLadderTests.swift
git commit -m "feat: failure classification and decorrelated-jitter backoff"
```

---

## Task 10: The circuit breakers

Two independent circuits (spec §4.3). The **network circuit** trips after five consecutive failed cycles and stays open 30 minutes, then closes on a single-symbol half-open probe. The **contract circuit** trips on the first parse failure and stays open an hour, because a schema change will not fix itself in thirty seconds.

Keeping them separate matters: a flaky connection must not be able to silence the schema alarm, and a schema change must not be laundered into "the network is down".

> **Corrected after review (rulings R18–R23).** The version of this task that
> was first written shipped a breaker that could **wedge permanently**: its
> half-open permit was a bare `probeInFlight: Bool` latch, so a probe that was
> granted and never resolved — process suspended, app quit mid-request, caller
> simply forgets — left the breaker refusing every request for the rest of the
> process's life, while `secondsRemaining()` cheerfully answered `0`. A caller
> told "ask now" and then refused spins. Seven of this task's original tests
> passed against that code. The blocks below are the shipped source, not the
> original draft. What changed, and why:
>
> - **R18** — `allowsRequest()` is a *command*, not a query: it issues the
>   probe as a side effect. Its doc puts the matching obligation on the caller
>   — report the outcome with `recordSuccess()`/`recordFailure()`.
> - **R19** — the probe must expire. `probeInFlight: Bool` became
>   `probeIssuedAt: Double?`, and a probe older than
>   `RateConstants.probeTimeoutSeconds` (60s — four times `YahooClient`'s
>   15-second request timeout) is presumed lost and reissued.
> - **R20** — a stated invariant, tested across the reachable state space:
>   **`secondsRemaining()` is never zero at a moment when `allowsRequest()`
>   would refuse.** While a probe is outstanding the answer is the probe's
>   remaining life, not zero.
> - **R21** — `recordFailure()` while genuinely `.open` must **not** extend the
>   deadline; a stream of stale reports would otherwise multiply the outage
>   without bound. A failure while *half-open* — a failed probe — still reopens
>   for the full duration. The state is therefore read *before* the failure is
>   counted.
> - **R22** — `trip()` no longer fabricates failure history
>   (`failures = max(failures, threshold)` is gone). One 429 is one piece of
>   bad news, not five. Because the reopen is now carried by the observed
>   `.halfOpen` state rather than by the failure count, `state()` and
>   `secondsRemaining()` are no longer `mutating`; only `allowsRequest()` is.
> - **R23** — two clamps were **deleted rather than tested**, because both
>   proved unreachable in the fixed implementation and a clamp that cannot
>   fire advertises a hazard it does not guard. `max(1, threshold)` guarded
>   nothing (`recordFailure()` compares only *after* incrementing, so a
>   threshold of zero or less already behaves exactly as one), and
>   `max(0, expiry - now)` guarded nothing once `secondsRemaining()` took a
>   single clock read shared by the state decision and the arithmetic.

**Files:**
- Create: `Sources/TickerCore/CircuitBreaker.swift`
- Test: `Tests/TickerCoreTests/CircuitBreakerTests.swift`

**Interfaces:**
- Consumes: `RateConstants`, `MonotonicClock`.
- Produces:
  - `TickerCore.CircuitState` — `enum { case closed, open(untilMonotonic: Double), halfOpen }`, `Equatable, Sendable`.
  - `TickerCore.CircuitBreaker` — `init(clock:threshold:openSeconds:)`, `mutating func recordFailure()`, `mutating func recordSuccess()`, `mutating func trip()`, `func state() -> CircuitState`, `mutating func allowsRequest() -> Bool`, `func secondsRemaining() -> Double`, `var consecutiveFailures: Int`.
  - `RateConstants.probeTimeoutSeconds: Double` — 60.

**A landmine before you start.** `#expect` binds its operands immutably, so a
`mutating` method cannot be called inside one: `#expect(b.allowsRequest())` is
`cannot use mutating member on immutable value: '$0' is immutable`. Hoist every
such call into its own `let` first — and hoist **call by call**, in the original
order. `allowsRequest()` has a side effect (it consumes the probe), so binding
once and asserting twice silently destroys the test that matters most:

```swift
// RIGHT — two calls, two bindings, the second observes the consumed probe.
let firstProbe = b.allowsRequest()
#expect(firstProbe)
let secondProbe = b.allowsRequest()
#expect(!secondProbe, "half-open handed out a second concurrent probe")

// WRONG — one call, asserted twice. Always passes. Tests nothing.
let probe = b.allowsRequest()
#expect(probe)
#expect(!probe)   // ← this is now just `!probe`, not a second request
```

- [ ] **Step 1: Add the constant**

In `Sources/TickerCore/RateConstants.swift`:

```swift
    /// How long a half-open probe may stay unresolved before it is presumed
    /// lost and reissued. Four times `YahooClient`'s 15-second request
    /// timeout: a probe still outstanding after a minute cannot be in flight,
    /// and a probe that is never reissued wedges the breaker permanently.
    public static let probeTimeoutSeconds: Double = 60
```

- [ ] **Step 2: Write the failing tests**

`Tests/TickerCoreTests/CircuitBreakerTests.swift`:

```swift
import Testing
@testable import TickerCore

// NOTE: as in BackoffLadderTests.swift, this suite's `#expect(...)` macro
// mis-compiles whenever the checked expression is a direct call to a
// `mutating` method on a `var` — its call-capturing expansion binds the
// receiver as an immutable `$0`, producing "cannot use mutating member on
// immutable value". `allowsRequest()` is the only such method on
// `CircuitBreaker`, so it — and only it — is hoisted into its own `let`
// before the `#expect` that checks it: one `let` per original call site, in
// the original order, because issuing the half-open probe is a side effect
// and collapsing two calls into one binding would silently change what is
// being tested. `state()` and `secondsRemaining()` are non-mutating and are
// written inline, which is also where a reader should be able to stop
// thinking about it.

private func networkBreaker(_ clock: FakeClock) -> CircuitBreaker {
    CircuitBreaker(clock: clock,
                   threshold: RateConstants.circuitFailureThreshold,
                   openSeconds: RateConstants.circuitOpenSeconds)
}

/// A breaker driven to `.open` by real failures, at the clock's current time.
private func openedBreaker(_ clock: FakeClock) -> CircuitBreaker {
    var b = networkBreaker(clock)
    for _ in 0..<RateConstants.circuitFailureThreshold { b.recordFailure() }
    return b
}

@Test func aFreshBreakerIsClosedAndAllowsRequests() {
    var b = networkBreaker(FakeClock())
    #expect(b.state() == .closed)
    let allowed = b.allowsRequest()
    #expect(allowed)
}

@Test func theBreakerTripsOnTheThresholdFailureAndNotBefore() {
    let clock = FakeClock()
    var b = networkBreaker(clock)
    for _ in 0..<(RateConstants.circuitFailureThreshold - 1) {
        b.recordFailure()
        let allowed = b.allowsRequest()
        #expect(allowed, "tripped early at \(b.consecutiveFailures) failures")
    }
    b.recordFailure()
    let allowed = b.allowsRequest()
    #expect(!allowed)
}

@Test func oneSuccessAnywhereInTheRunResetsTheCount() {
    // "Consecutive" is the whole point: an outage that alternates
    // success/failure is a working connection, not a dead one.
    let clock = FakeClock()
    var b = networkBreaker(clock)
    for _ in 0..<20 {
        for _ in 0..<(RateConstants.circuitFailureThreshold - 1) { b.recordFailure() }
        b.recordSuccess()
    }
    #expect(b.consecutiveFailures == 0)
    let allowed = b.allowsRequest()
    #expect(allowed)
}

@Test func consecutiveFailuresReportsTheRunningCountAndNotAConstant() {
    // The only assertion this member used to carry was `== 0`, which a
    // hard-coded zero satisfies by construction: a required public accessor
    // with no positive coverage at all. Pin it at every intermediate count,
    // across a reset, and past the threshold.
    let clock = FakeClock()
    var b = networkBreaker(clock)
    #expect(b.consecutiveFailures == 0)

    for expected in 1..<RateConstants.circuitFailureThreshold {
        b.recordFailure()
        #expect(b.consecutiveFailures == expected)
    }

    b.recordSuccess()
    #expect(b.consecutiveFailures == 0, "a success must clear the run, not decrement it")

    // It keeps counting past the threshold — it is a count of failures
    // recorded, not a latch that stops at the number that opened the circuit.
    for expected in 1...(RateConstants.circuitFailureThreshold + 3) {
        b.recordFailure()
        #expect(b.consecutiveFailures == expected)
    }

    // And `trip()` invents none of them: one 429 is one piece of bad news.
    var tripped = networkBreaker(FakeClock())
    tripped.trip()
    #expect(tripped.consecutiveFailures == 0,
            "trip() reported failures that never happened")
    tripped.recordSuccess()
    #expect(tripped.consecutiveFailures == 0)
}

@Test func anOpenBreakerStaysOpenForItsFullDurationThenGoesHalfOpen() {
    let clock = FakeClock()
    var b = openedBreaker(clock)

    clock.advance(RateConstants.circuitOpenSeconds - 1)
    let stillBlocked = b.allowsRequest()
    #expect(!stillBlocked)
    #expect(b.state() == .open(untilMonotonic: RateConstants.circuitOpenSeconds))

    clock.advance(2)
    #expect(b.state() == .halfOpen)
    let probe = b.allowsRequest()
    #expect(probe, "half-open must permit the probe")
}

@Test func theDeadlineInstantItselfIsAlreadyHalfOpen() {
    // The `<` in `state()` carries a comment calling itself deliberate, and
    // nothing pinned it: the countdown test lands on the deadline but reads
    // only `secondsRemaining()`, which answers 0 under both `<` and `<=`.
    // These two assertions are the ones that can tell them apart.
    let atDeadline = FakeClock(0)
    var b = networkBreaker(atDeadline)
    b.trip()
    atDeadline.advance(RateConstants.circuitOpenSeconds)
    #expect(atDeadline.nowSeconds == RateConstants.circuitOpenSeconds)
    #expect(b.state() == .halfOpen,
            "the deadline instant is out of the open window, not in it")
    let allowedAtDeadline = b.allowsRequest()
    #expect(allowedAtDeadline, "the breaker refused a probe at its own deadline")

    // One millisecond earlier, on a clock that has not been nudged twice, it
    // is still shut — and still says how long for.
    let justBefore = FakeClock(0)
    var m = networkBreaker(justBefore)
    m.trip()
    justBefore.advance(RateConstants.circuitOpenSeconds - 0.001)
    #expect(m.state() == .open(untilMonotonic: RateConstants.circuitOpenSeconds))
    let refusedJustBefore = m.allowsRequest()
    #expect(!refusedJustBefore)
    #expect(m.secondsRemaining() > 0)
}

@Test func aHalfOpenBreakerPermitsExactlyOneProbe() {
    // The probe is one request for one symbol. If half-open let the whole
    // watchlist through, a still-down upstream would get twenty requests as
    // its reward for the outage.
    let clock = FakeClock()
    var b = openedBreaker(clock)
    clock.advance(RateConstants.circuitOpenSeconds + 1)

    let firstProbe = b.allowsRequest()
    #expect(firstProbe)
    let secondProbe = b.allowsRequest()
    #expect(!secondProbe, "half-open handed out a second concurrent probe")
}

@Test func anUnresolvedProbeIsPresumedLostAndAFreshOneIsIssued() {
    // The probe is taken and its outcome never reported — the process was
    // suspended, the app was quit mid-request, the caller forgot. Without a
    // lifetime on the probe the breaker is wedged for the rest of the
    // process: half-open, refusing everything, and answering "wait zero
    // seconds" to anyone who asks how long. That is a hot loop on a battery.
    let clock = FakeClock()
    var b = openedBreaker(clock)
    clock.advance(RateConstants.circuitOpenSeconds + 1)
    let probe = b.allowsRequest()
    #expect(probe)

    // Neither recordSuccess() nor recordFailure(). Ever.
    clock.advance(RateConstants.probeTimeoutSeconds - 1)
    let tooSoon = b.allowsRequest()
    #expect(!tooSoon, "the probe was reissued before it could have timed out")
    #expect(b.secondsRemaining() == 1,
            "a refused breaker must name the interval it is refusing for")

    clock.advance(1)   // exactly `probeTimeoutSeconds` after it was issued
    let reissued = b.allowsRequest()
    #expect(reissued, "an unresolved probe wedged the breaker")

    // And the shape the wedge was first found in: leave the reissued probe
    // unresolved too, then wait an absurdly long time.
    clock.advance(1_000_000)
    #expect(b.state() == .halfOpen)
    #expect(b.secondsRemaining() == 0)
    let afterAnAge = b.allowsRequest()
    #expect(afterAnAge, "the breaker never recovered from a lost probe")
}

@Test func aRefusedRequestAlwaysComesWithAnIntervalToWait() {
    // The invariant, walked across every reachable state. `secondsRemaining()`
    // is a promise that a request would be let through once it elapses; a
    // breaker that answers zero and then refuses leaves its caller nothing to
    // sleep on, and it spins. This is stronger than any single boundary
    // assertion, and it is the one that would have caught the wedge above.
    func check(_ b: inout CircuitBreaker, _ at: String) {
        let remaining = b.secondsRemaining()
        let allowed = b.allowsRequest()
        #expect(allowed || remaining > 0,
                "\(at): refused a request while reporting a zero wait")
    }

    // Closed.
    var fresh = networkBreaker(FakeClock())
    check(&fresh, "closed")

    // Open, well before the deadline.
    let early = FakeClock()
    var earlyBreaker = openedBreaker(early)
    early.advance(1)
    check(&earlyBreaker, "open, one second in")

    // Open, one millisecond before the deadline.
    let late = FakeClock()
    var lateBreaker = openedBreaker(late)
    late.advance(RateConstants.circuitOpenSeconds - 0.001)
    check(&lateBreaker, "open, a millisecond from expiry")

    // Exactly at the deadline: half-open, probe available.
    let atExpiry = FakeClock()
    var atExpiryBreaker = openedBreaker(atExpiry)
    atExpiry.advance(RateConstants.circuitOpenSeconds)
    check(&atExpiryBreaker, "the deadline instant")

    // Half-open with the probe in flight — the state that used to answer
    // zero while refusing.
    let inFlight = FakeClock()
    var inFlightBreaker = openedBreaker(inFlight)
    inFlight.advance(RateConstants.circuitOpenSeconds + 1)
    let taken = inFlightBreaker.allowsRequest()
    #expect(taken)
    check(&inFlightBreaker, "half-open, probe in flight")

    // Half-open with the probe in flight, a millisecond from its timeout.
    let nearlyLost = FakeClock()
    var nearlyLostBreaker = openedBreaker(nearlyLost)
    nearlyLost.advance(RateConstants.circuitOpenSeconds + 1)
    let takenAgain = nearlyLostBreaker.allowsRequest()
    #expect(takenAgain)
    nearlyLost.advance(RateConstants.probeTimeoutSeconds - 0.001)
    check(&nearlyLostBreaker, "half-open, probe about to time out")

    // Half-open with an expired probe.
    let lost = FakeClock()
    var lostBreaker = openedBreaker(lost)
    lost.advance(RateConstants.circuitOpenSeconds + 1)
    let abandoned = lostBreaker.allowsRequest()
    #expect(abandoned)
    lost.advance(RateConstants.probeTimeoutSeconds)
    check(&lostBreaker, "half-open, probe presumed lost")

    // And an abandoned probe an age later, which is where the wedge lived.
    let ancient = FakeClock()
    var ancientBreaker = openedBreaker(ancient)
    ancient.advance(RateConstants.circuitOpenSeconds + 1)
    let ancientProbe = ancientBreaker.allowsRequest()
    #expect(ancientProbe)
    ancient.advance(1_000_000)
    check(&ancientBreaker, "half-open, probe abandoned long ago")
}

@Test func aFailedProbeReopensTheBreakerForTheFullDuration() {
    let clock = FakeClock()
    var b = openedBreaker(clock)
    clock.advance(RateConstants.circuitOpenSeconds + 1)
    let probe = b.allowsRequest()
    #expect(probe)

    b.recordFailure()
    let afterFailedProbe = b.allowsRequest()
    #expect(!afterFailedProbe)
    clock.advance(RateConstants.circuitOpenSeconds - 1)
    let stillOpen = b.allowsRequest()
    #expect(!stillOpen, "the probe failure did not restart the full timer")
    clock.advance(2)
    let reopened = b.allowsRequest()
    #expect(reopened)
}

@Test func aProbeThatFailsAfterAnExplicitTripAlsoReopensForTheFullDuration() {
    // `trip()` records no failures at all, so the reopen here cannot be
    // carried by the failure count reaching the threshold — it rests entirely
    // on the breaker noticing that it was half-open when the request went
    // out. Nothing tested trip() together with a failing probe, and the two
    // guards that used to hold this path up were each sufficient on their
    // own, so neither was pinned: dropping both granted five consecutive
    // probes with no time passing at all.
    let clock = FakeClock()
    var b = networkBreaker(clock)
    b.trip()
    #expect(b.consecutiveFailures == 0)
    clock.advance(RateConstants.circuitOpenSeconds + 1)

    let probe = b.allowsRequest()
    #expect(probe)
    b.recordFailure()
    #expect(b.consecutiveFailures == 1, "one failed probe is one failure")

    // No time has passed. A breaker that hands out a second probe here is
    // handing the still-broken upstream its whole watchlist back.
    var granted = 0
    for _ in 0..<RateConstants.circuitFailureThreshold {
        let allowed = b.allowsRequest()
        if allowed { granted += 1 }
    }
    #expect(granted == 0, "a failed probe after trip() left the breaker open for business")

    clock.advance(RateConstants.circuitOpenSeconds - 1)
    let stillOpen = b.allowsRequest()
    #expect(!stillOpen, "the failed probe did not restart the full timer")
    clock.advance(2)
    let reopened = b.allowsRequest()
    #expect(reopened)
}

@Test func aFailureRecordedWhileOpenDoesNotExtendTheOutage() {
    // `.open(untilMonotonic:)` publishes a deadline. A caller that reports
    // failures for requests the breaker had already refused — or one that
    // never consulted it — must not be able to push that deadline forward,
    // or a thirty-minute outage silently becomes fifty. A failed *probe* is
    // the opposite case and still reopens in full; the two are distinct.
    let clock = FakeClock(0)
    var b = networkBreaker(clock)
    b.trip()
    let deadline = RateConstants.circuitOpenSeconds
    #expect(b.state() == .open(untilMonotonic: deadline))

    for _ in 0..<10 {
        clock.advance(60)
        b.recordFailure()
        #expect(b.state() == .open(untilMonotonic: deadline),
                "a failure recorded while open moved the deadline")
        #expect(b.secondsRemaining() == deadline - clock.nowSeconds)
    }

    clock.advance(deadline - clock.nowSeconds)
    #expect(b.state() == .halfOpen)
    let probe = b.allowsRequest()
    #expect(probe, "ten stray failure reports extended a thirty-minute outage")
}

@Test func aNewOpenEpisodeStartsWithAProbeOfItsOwn() {
    // A probe token that survives the cycle that issued it refuses the *next*
    // cycle's probe. The open window here is deliberately shorter than
    // `probeTimeoutSeconds`, so the next half-open cycle arrives while a
    // stale token would still be live: with a thirty-minute window the probe
    // timeout would quietly rescue the bug and the test would assert nothing.
    let shortWindow = RateConstants.probeTimeoutSeconds / 6   // 10s
    #expect(shortWindow * 2 < RateConstants.probeTimeoutSeconds)

    func breaker(_ clock: FakeClock) -> CircuitBreaker {
        CircuitBreaker(clock: clock, threshold: 1, openSeconds: shortWindow)
    }

    // A cycle that ended in success, then a fresh one.
    let successClock = FakeClock()
    var afterSuccess = breaker(successClock)
    afterSuccess.recordFailure()
    successClock.advance(shortWindow + 1)
    let firstProbe = afterSuccess.allowsRequest()
    #expect(firstProbe)
    afterSuccess.recordSuccess()
    afterSuccess.recordFailure()
    successClock.advance(shortWindow + 1)
    let afterSuccessProbe = afterSuccess.allowsRequest()
    #expect(afterSuccessProbe, "the episode after a success reused a stale probe token")

    // A cycle reopened by a failed probe.
    let failureClock = FakeClock()
    var afterFailure = breaker(failureClock)
    afterFailure.recordFailure()
    failureClock.advance(shortWindow + 1)
    let failureProbe = afterFailure.allowsRequest()
    #expect(failureProbe)
    afterFailure.recordFailure()
    failureClock.advance(shortWindow + 1)
    let afterFailureProbe = afterFailure.allowsRequest()
    #expect(afterFailureProbe, "a failed probe left its token behind for the next episode")

    // A cycle reopened by an explicit trip.
    let tripClock = FakeClock()
    var afterTrip = breaker(tripClock)
    afterTrip.recordFailure()
    tripClock.advance(shortWindow + 1)
    let tripProbe = afterTrip.allowsRequest()
    #expect(tripProbe)
    afterTrip.trip()
    tripClock.advance(shortWindow + 1)
    let afterTripProbe = afterTrip.allowsRequest()
    #expect(afterTripProbe, "trip() reused the previous episode's probe token")
}

@Test func aSuccessfulProbeClosesTheBreakerCompletely() {
    let clock = FakeClock()
    var b = openedBreaker(clock)
    clock.advance(RateConstants.circuitOpenSeconds + 1)
    let probe = b.allowsRequest()
    #expect(probe)

    b.recordSuccess()
    #expect(b.state() == .closed)
    let firstAfterClose = b.allowsRequest()
    #expect(firstAfterClose)
    let secondAfterClose = b.allowsRequest()
    #expect(secondAfterClose, "a closed breaker must not ration requests")
}

@Test func theContractCircuitTripsOnASingleFaultAndHoldsForAnHour() {
    // A schema change will not fix itself in thirty seconds, and hammering
    // an endpoint that is answering 200 with the wrong shape is pure waste.
    let clock = FakeClock()
    var b = CircuitBreaker(clock: clock, threshold: 1,
                           openSeconds: RateConstants.contractFaultCooldown)
    b.recordFailure()
    let blockedImmediately = b.allowsRequest()
    #expect(!blockedImmediately)
    clock.advance(RateConstants.contractFaultCooldown - 1)
    let stillBlocked = b.allowsRequest()
    #expect(!stillBlocked)
    clock.advance(2)
    let allowedNow = b.allowsRequest()
    #expect(allowedNow)
}

@Test func aThresholdBelowOneStillNeedsARealFailureToOpen() {
    // A threshold of zero must not mean "zero failures is enough". Nothing
    // constructed a degenerate breaker, so nothing said what one does; the
    // answer is that the threshold is only ever compared after a failure has
    // been counted, which is why the initializer needs no clamp to defend it.
    for threshold in [0, -3] {
        let clock = FakeClock()
        var b = CircuitBreaker(clock: clock, threshold: threshold,
                               openSeconds: RateConstants.circuitOpenSeconds)
        #expect(b.state() == .closed, "a threshold of \(threshold) was born open")
        #expect(b.consecutiveFailures == 0)
        let beforeAnythingFailed = b.allowsRequest()
        #expect(beforeAnythingFailed,
                "a threshold of \(threshold) refused a request before anything failed")

        b.recordFailure()
        #expect(b.state() == .open(untilMonotonic: RateConstants.circuitOpenSeconds))
        let afterOneFailure = b.allowsRequest()
        #expect(!afterOneFailure)
    }
}

@Test func theTwoCircuitsAreIndependent() {
    // A flaky café connection must not be able to silence the schema alarm,
    // and a schema change must not be reported as a network outage.
    let clock = FakeClock()
    var network = networkBreaker(clock)
    var contract = CircuitBreaker(clock: clock, threshold: 1,
                                  openSeconds: RateConstants.contractFaultCooldown)

    for _ in 0..<RateConstants.circuitFailureThreshold { network.recordFailure() }
    let networkBlocked = network.allowsRequest()
    #expect(!networkBlocked)
    let contractStillAllows = contract.allowsRequest()
    #expect(contractStillAllows, "the network circuit tripped the contract circuit")

    network.recordSuccess()
    contract.recordFailure()
    let networkAllowsAgain = network.allowsRequest()
    #expect(networkAllowsAgain)
    let contractBlocked = contract.allowsRequest()
    #expect(!contractBlocked)
}

@Test func trippingExplicitlyIsEquivalentToReachingTheThreshold() {
    // A 429 should open the circuit immediately rather than needing five
    // more requests to prove the point.
    let clock = FakeClock()
    var b = networkBreaker(clock)
    b.trip()
    let blockedAfterTrip = b.allowsRequest()
    #expect(!blockedAfterTrip)
    clock.advance(RateConstants.circuitOpenSeconds + 1)
    let allowedAfterWait = b.allowsRequest()
    #expect(allowedAfterWait)
}

@Test func aClosedBreakerHasNothingLeftToWaitFor() {
    // Callers take the maximum across two breakers. If a closed one reported
    // anything but zero, one healthy breaker could hold the other's work back.
    let b = networkBreaker(FakeClock(0))
    #expect(b.secondsRemaining() == 0)
}

@Test func anOpenBreakerCountsDownAndReachesZeroExactlyAtExpiry() {
    let clock = FakeClock(0)
    var b = networkBreaker(clock)
    b.trip()
    #expect(b.secondsRemaining() == RateConstants.circuitOpenSeconds)
    clock.advance(RateConstants.circuitOpenSeconds / 2)
    #expect(b.secondsRemaining() == RateConstants.circuitOpenSeconds / 2)
    clock.advance(RateConstants.circuitOpenSeconds / 2)
    // At expiry the breaker is half-open with its probe available, so there
    // is genuinely nothing left to wait for — and the reported wait must
    // never go negative.
    #expect(b.secondsRemaining() == 0)
    clock.advance(10_000)
    #expect(b.secondsRemaining() == 0)
}

@Test func timeGoingBackwardsDoesNotCloseAnOpenBreaker() {
    let clock = FakeClock(10_000)
    var b = networkBreaker(clock)
    b.trip()
    clock.advance(-100_000)
    let allowed = b.allowsRequest()
    #expect(!allowed)
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `swift test --build-system native --filter CircuitBreaker`
Expected: FAIL — `cannot find 'CircuitBreaker' in scope`.

- [ ] **Step 4: Write the implementation**

`Sources/TickerCore/CircuitBreaker.swift`:

```swift
public enum CircuitState: Equatable, Sendable {
    case closed
    case open(untilMonotonic: Double)
    /// One probe is in flight, or one is available to be taken.
    case halfOpen
}

/// A circuit breaker with a single-probe half-open state.
///
/// Squiggle runs two of these (spec §4.3), configured differently and kept
/// deliberately independent:
///
/// - the **network** circuit: five consecutive failed cycles, open 30 minutes;
/// - the **contract** circuit: one parse failure, open one hour.
///
/// Independence is structural, not a discipline to remember: each instance
/// owns its own `failures` / `openedAt` / `probeIssuedAt`, so a flaky
/// connection can never trip the schema alarm and a schema change can never
/// be laundered into "the network is down".
///
/// The half-open state hands out exactly one permit. If it let the whole
/// watchlist through, a still-broken upstream would receive twenty requests
/// as its reward for having been down.
///
/// One invariant runs through the whole type: **`secondsRemaining()` is never
/// zero at a moment when `allowsRequest()` would refuse.** Zero means "ask
/// now"; a caller told to ask now and then refused has nothing left to sleep
/// on, and spins. On a menu bar app that lives in a battery meter, a hot loop
/// is the worst failure this type can produce — worse than staying open too
/// long, and far worse than one extra request.
public struct CircuitBreaker {
    private let clock: any MonotonicClock
    private let threshold: Int
    private let openSeconds: Double

    private var failures: Int = 0
    private var openedAt: Double?

    /// When the outstanding half-open probe was issued, if one is out.
    ///
    /// An instant and not a flag: a bare `probeInFlight` is a latch with no
    /// way out. A probe that is granted and never resolved — the process
    /// suspended, the app quit mid-request, a caller that simply forgets to
    /// report — leaves the breaker half-open, refusing every request, for
    /// the rest of the process's life. With an instant the probe can be
    /// presumed lost after `RateConstants.probeTimeoutSeconds` and reissued.
    private var probeIssuedAt: Double?

    public init(clock: any MonotonicClock, threshold: Int, openSeconds: Double) {
        self.clock = clock
        // No clamp on `threshold`. `recordFailure()` compares it only after
        // counting the failure, so the left-hand side is at least 1 at every
        // comparison and a threshold of zero or less already behaves exactly
        // as one. A `max(1, threshold)` here would guard against nothing
        // while claiming in its own name to guard against something.
        self.threshold = threshold
        self.openSeconds = openSeconds
    }

    /// Failures actually recorded since the last success.
    ///
    /// `trip()` deliberately does not touch it: one 429 is one piece of bad
    /// news, and reporting five failures that never happened would make this
    /// a latch wearing a count's name.
    public var consecutiveFailures: Int { failures }

    public func state() -> CircuitState {
        state(at: clock.nowSeconds)
    }

    private func state(at now: Double) -> CircuitState {
        guard let openedAt else { return .closed }
        let expiry = openedAt + openSeconds
        // `<` and not `<=`: the breaker is open up to, but not including, its
        // expiry — the same half-open convention used for trading windows.
        return now < expiry ? .open(untilMonotonic: expiry) : .halfOpen
    }

    /// How long the caller should wait before asking again. Zero means "ask
    /// now", and is only ever answered when asking now would in fact be
    /// allowed — see the invariant on the type. While half-open with a probe
    /// still outstanding the answer is the remaining life of that probe, not
    /// zero: the breaker is refusing, and it owes the caller an interval.
    public func secondsRemaining() -> Double {
        // One read of the clock, shared by the state decision and the
        // arithmetic below. Two separate reads of a real `SystemClock` can
        // straddle a tick, which was the only thing that ever made a
        // `max(0, …)` floor here defensible; with a single read every
        // subtraction below is positive by construction, so there is no floor
        // to keep.
        let now = clock.nowSeconds
        switch state(at: now) {
        case .closed:
            return 0
        case .open(let expiry):
            return expiry - now
        case .halfOpen:
            guard let age = probeAge(at: now),
                  age < RateConstants.probeTimeoutSeconds else { return 0 }
            return RateConstants.probeTimeoutSeconds - age
        }
    }

    /// Decides whether to let a request through, and — while half-open —
    /// issues the single probe permit as a side effect.
    ///
    /// This is a command, not a query: call it **exactly once per request
    /// decision**, and then **report the outcome** with `recordSuccess()` or
    /// `recordFailure()`. Reporting is the load-bearing half of the contract.
    /// The first call issues the probe; every later call within the same
    /// half-open cycle merely observes that it is already out and returns
    /// `false`, which is what stops a still-down upstream getting twenty
    /// requests as its reward for the outage.
    ///
    /// A probe whose outcome is never reported is not fatal, but it is not
    /// free either: the breaker refuses for `RateConstants.probeTimeoutSeconds`
    /// from the moment the probe was issued, then presumes it lost and issues
    /// a fresh one.
    public mutating func allowsRequest() -> Bool {
        let now = clock.nowSeconds
        switch state(at: now) {
        case .closed:
            return true
        case .open:
            return false
        case .halfOpen:
            if let age = probeAge(at: now), age < RateConstants.probeTimeoutSeconds {
                return false
            }
            probeIssuedAt = now
            return true
        }
    }

    public mutating func recordSuccess() {
        failures = 0
        openedAt = nil
        // Deliberately no `probeIssuedAt = nil`. The token is released in
        // `open(at:)`, where a new episode begins, which is the only moment
        // it can be read: a closed breaker never consults it, and every route
        // back to half-open passes through `open(at:)` first. One release in
        // one place beats three assignments in three places to forget.
    }

    public mutating func recordFailure() {
        // Read the state — and the clock — *before* recording, because what
        // the breaker was when the request went out is what decides whether
        // the deadline moves.
        let now = clock.nowSeconds
        let observed = state(at: now)
        failures += 1

        switch observed {
        case .halfOpen:
            // A failed probe reopens for the full duration; the outage is not
            // over just because the clock said so. This case, not the failure
            // count, is what carries the reopen — after `trip()` the count can
            // be as low as one.
            open(at: now)
        case .open:
            // A failure recorded while open belongs to a request the breaker
            // had already refused, or to a caller that never asked. Restarting
            // the timer for it would let a stream of stale reports multiply
            // the outage without bound and make `.open(untilMonotonic:)` a
            // deadline the type does not keep.
            break
        case .closed:
            if failures >= threshold { open(at: now) }
        }
    }

    /// Open immediately, without waiting for the threshold. A 429 is proof
    /// enough on its own. The failure count is left alone — this is one piece
    /// of bad news, not five.
    public mutating func trip() {
        open(at: clock.nowSeconds)
    }

    /// Begins an open episode.
    ///
    /// The probe belongs to the episode that issued it, so a new episode
    /// starts with the token released. A token carried across would refuse
    /// the next cycle's probe for a whole `probeTimeoutSeconds` — a
    /// self-inflicted outage on a breaker that was ready to test the water.
    private mutating func open(at now: Double) {
        openedAt = now
        probeIssuedAt = nil
    }

    /// How long the outstanding probe has been out, or `nil` if none is.
    private func probeAge(at now: Double) -> Double? {
        probeIssuedAt.map { now - $0 }
    }
}
```

- [ ] **Step 5: Run to verify they pass**

Run: `swift test --build-system native --filter CircuitBreaker`
Expected: PASS.

Note `timeGoingBackwardsDoesNotCloseAnOpenBreaker`: it passes because a rewound
clock makes `now < expiry` *more* true, not less. That is the safe direction,
and the test exists to pin it there.

- [ ] **Step 6: Commit**

```bash
git add Sources/TickerCore/CircuitBreaker.swift Sources/TickerCore/RateConstants.swift Tests/TickerCoreTests/CircuitBreakerTests.swift
git commit -m "feat: independent network and contract circuit breakers"
```

---

## Task 11: `RefreshPolicy` — the one decision function

Everything so far answers "may I?". This task answers "should I, and when next?". It is a **pure function of its inputs** — no clock read, no I/O — which is what makes the 24-hour budget simulation in Task 12 possible at all.

**Files:**
- Create: `Sources/TickerCore/RefreshPolicy.swift`
- Test: `Tests/TickerCoreTests/RefreshPolicyTests.swift`

**Interfaces:**
- Consumes: `MarketState`, `RateConstants`, `RequestPacer`, `BackoffLadder`, `CircuitBreaker`.
- Produces:
  - `TickerCore.Visibility` — `enum { case visible, occluded }`, `Sendable`.
  - `TickerCore.RefreshInput` — `struct` with `nowMonotonic: Double`, `nowEpoch: Double`, `marketState: MarketState`, `visibility: Visibility`, `lowPowerMode: Bool`, `userIntervalSeconds: Double`, `watchlistCount: Int`, `nextRegularOpenEpoch: Double?`, `isCoolingDown: Bool`, `cooldownRemaining: Double`, `circuitAllows: Bool`, `circuitOpenRemaining: Double`.
  - `TickerCore.RefreshDecision` — `enum { case fetch, wait(seconds: Double) }`, `Equatable, Sendable`; `var waitSeconds: Double?`.
  - `TickerCore.RefreshPolicy` — `enum` with `static func decide(_ input: RefreshInput) -> RefreshDecision` , `static func cycleInterval(userIntervalSeconds:watchlistCount:marketState:visibility:lowPowerMode:) -> Double` and `static func isStale(lastSuccessEpoch:nowEpoch:userIntervalSeconds:watchlistCount:marketState:visibility:lowPowerMode:) -> Bool`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import TickerCore

private func input(
    market: MarketState = .regular,
    visibility: Visibility = .visible,
    lowPower: Bool = false,
    interval: Double = RateConstants.defaultRefreshInterval,
    count: Int = 4,
    nextOpen: Double? = nil,
    cooling: Bool = false,
    cooldownRemaining: Double = 0,
    circuitAllows: Bool = true,
    circuitOpenRemaining: Double = 0
) -> RefreshInput {
    RefreshInput(nowMonotonic: 0,
                 nowEpoch: 1_757_000_000,
                 marketState: market,
                 visibility: visibility,
                 lowPowerMode: lowPower,
                 userIntervalSeconds: interval,
                 watchlistCount: count,
                 nextRegularOpenEpoch: nextOpen,
                 isCoolingDown: cooling,
                 cooldownRemaining: cooldownRemaining,
                 circuitAllows: circuitAllows,
                 circuitOpenRemaining: circuitOpenRemaining)
}

@Test func theHappyPathFetches() {
    #expect(RefreshPolicy.decide(input()) == .fetch)
}

@Test func anActiveCooldownOutranksEverything() {
    let d = RefreshPolicy.decide(input(cooling: true, cooldownRemaining: 412))
    #expect(d == .wait(seconds: 412))
}

@Test func anOpenCircuitOutranksAVisibleMarketOpenWatchlist() {
    let d = RefreshPolicy.decide(input(circuitAllows: false, circuitOpenRemaining: 900))
    #expect(d == .wait(seconds: 900))
}

@Test func aCooldownIsPreferredOverAnOpenCircuitWhenBothApply() {
    // Order matters only for the number reported; both mean "do not fetch".
    // Pin it so the reported wait is never the shorter of the two, which
    // would have the caller wake up early and be refused again.
    let d = RefreshPolicy.decide(input(cooling: true, cooldownRemaining: 1800,
                                       circuitAllows: false, circuitOpenRemaining: 60))
    #expect(d.waitSeconds ?? 0 >= 1800)
}

@Test func aClosedMarketWaitsUntilShortlyBeforeTheNextOpen() {
    // Spec §4.1: while closed, one wake a minute before the open, not a
    // 15-minute poll that learns nothing 96 times a night.
    let now: Double = 1_757_000_000
    let open = now + 8 * 3600
    let d = RefreshPolicy.decide(input(market: .closed, nextOpen: open))
    let wait = d.waitSeconds ?? 0
    #expect(wait > 7 * 3600)
    #expect(wait <= 8 * 3600 - RateConstants.preOpenWakeLead + 1)
}

@Test func aClosedMarketWithNoKnownOpenFallsBackToASlowPoll() {
    // The open time comes from the last payload. On a cold launch into a
    // weekend there may be none, and a nil must not become an infinite sleep.
    let d = RefreshPolicy.decide(input(market: .closed, nextOpen: nil))
    let wait = d.waitSeconds ?? 0
    #expect(wait > 0)
    #expect(wait <= 3600, "a fallback poll of \(wait)s is a hang, not a poll")
}

@Test func aStaleNextOpenInThePastDoesNotProduceANegativeWait() {
    let now: Double = 1_757_000_000
    let d = RefreshPolicy.decide(input(market: .closed, nextOpen: now - 5000))
    #expect((d.waitSeconds ?? -1) >= 0)
}

@Test func occlusionStopsFetchingEntirely() {
    // Spec §4.1 and §5.4: hidden behind a notch or another app's menu items,
    // there is nothing to update. This is the single largest saving.
    let d = RefreshPolicy.decide(input(visibility: .occluded))
    #expect(d != .fetch)
}

@Test func extendedHoursAndLowPowerBothStretchTheCycle() {
    let base = RefreshPolicy.cycleInterval(userIntervalSeconds: 300, watchlistCount: 4,
                                           marketState: .regular, visibility: .visible,
                                           lowPowerMode: false)
    let pre = RefreshPolicy.cycleInterval(userIntervalSeconds: 300, watchlistCount: 4,
                                          marketState: .pre, visibility: .visible,
                                          lowPowerMode: false)
    let saving = RefreshPolicy.cycleInterval(userIntervalSeconds: 300, watchlistCount: 4,
                                             marketState: .regular, visibility: .visible,
                                             lowPowerMode: true)
    #expect(pre == base * RateConstants.quietMultiplier)
    #expect(saving == base * RateConstants.quietMultiplier)
}

@Test func theTwoMultipliersDoNotCompound() {
    // Low Power Mode during pre-market should not produce a nine-times
    // interval; the user asked for a slower ticker, not a stopped one.
    let both = RefreshPolicy.cycleInterval(userIntervalSeconds: 300, watchlistCount: 4,
                                           marketState: .pre, visibility: .visible,
                                           lowPowerMode: true)
    #expect(both == 300 * RateConstants.quietMultiplier)
}

@Test func theSpacingFloorRaisesTheCycleForLargeWatchlists() {
    // Spec §4.1: cycleInterval = max(userInterval, n × spacing). With 20
    // symbols the floor is 600s, so a 60s setting cannot be honoured — and
    // must not be pretended to be.
    let interval = RefreshPolicy.cycleInterval(userIntervalSeconds: 60, watchlistCount: 20,
                                               marketState: .regular, visibility: .visible,
                                               lowPowerMode: false)
    #expect(interval == 20 * RateConstants.spacingSeconds)
}

@Test func theSpacingFloorNeverShortensAUsersChosenInterval() {
    // The floor is a floor. A user who asked for 15 minutes with one symbol
    // gets 15 minutes, not 30 seconds.
    for count in [1, 2, 4, 10, 20] {
        for interval in RateConstants.refreshIntervalChoices {
            let cycle = RefreshPolicy.cycleInterval(userIntervalSeconds: interval,
                                                    watchlistCount: count,
                                                    marketState: .regular,
                                                    visibility: .visible,
                                                    lowPowerMode: false)
            #expect(cycle >= interval, "count \(count), interval \(interval) → \(cycle)")
            #expect(cycle >= Double(count) * RateConstants.spacingSeconds)
        }
    }
}

@Test func aFreshQuoteIsNotStale() {
    // Spec §7: the strip dims past three cycles. Below that it must not,
    // because a ticker that dims during normal operation teaches the user to
    // ignore the one signal it has.
    #expect(!RefreshPolicy.isStale(lastSuccessEpoch: 1_000, nowEpoch: 1_100,
                                   userIntervalSeconds: 180, watchlistCount: 4,
                                   marketState: .regular, visibility: .visible,
                                   lowPowerMode: false))
}

@Test func stalenessIsThreeCyclesAndNotThreeUserIntervals() {
    // The cycle, not the setting, is the real cadence — a 20-symbol watchlist
    // at 60s takes ten minutes per pass. Measuring against the setting would
    // dim a perfectly healthy large watchlist permanently.
    let cycle = RefreshPolicy.cycleInterval(userIntervalSeconds: 60, watchlistCount: 20,
                                            marketState: .regular, visibility: .visible,
                                            lowPowerMode: false)
    func stale(after elapsed: Double) -> Bool {
        RefreshPolicy.isStale(lastSuccessEpoch: 0, nowEpoch: elapsed,
                              userIntervalSeconds: 60, watchlistCount: 20,
                              marketState: .regular, visibility: .visible,
                              lowPowerMode: false)
    }
    #expect(!stale(after: cycle * RateConstants.stalenessMultiplier - 1))
    #expect(stale(after: cycle * RateConstants.stalenessMultiplier + 1))
}

@Test func aQuoteThatNeverArrivedIsStale() {
    // No successful fetch yet is exactly the state the dimmed strip is for.
    #expect(RefreshPolicy.isStale(lastSuccessEpoch: nil, nowEpoch: 5_000,
                                  userIntervalSeconds: 180, watchlistCount: 4,
                                  marketState: .regular, visibility: .visible,
                                  lowPowerMode: false))
}

@Test func aClosedMarketDoesNotDimTheStrip() {
    // Overnight the last close is the correct number, however old it is.
    // Dimming it every night would make the signal meaningless by morning.
    #expect(!RefreshPolicy.isStale(lastSuccessEpoch: 0, nowEpoch: 40 * 3600,
                                   userIntervalSeconds: 180, watchlistCount: 4,
                                   marketState: .closed, visibility: .visible,
                                   lowPowerMode: false))
}

@Test func aClockThatJumpedBackwardsDoesNotDimTheStrip() {
    #expect(!RefreshPolicy.isStale(lastSuccessEpoch: 10_000, nowEpoch: 1_000,
                                   userIntervalSeconds: 180, watchlistCount: 4,
                                   marketState: .regular, visibility: .visible,
                                   lowPowerMode: false))
}

@Test func anEmptyWatchlistNeverFetches() {
    #expect(RefreshPolicy.decide(input(count: 0)) != .fetch)
}

@Test func aNonsenseIntervalIsClampedRatherThanObeyed() {
    // Defence against a hand-edited settings file. Zero would busy-loop.
    for bad in [0.0, -1, .infinity, .nan] {
        let cycle = RefreshPolicy.cycleInterval(userIntervalSeconds: bad, watchlistCount: 1,
                                                marketState: .regular, visibility: .visible,
                                                lowPowerMode: false)
        #expect(cycle.isFinite)
        #expect(cycle >= RateConstants.spacingSeconds)
    }
}

@Test func everyDecisionIsFiniteAndNonNegative() {
    // A NaN wait becomes a timer that never fires: a silent, permanent hang
    // that no error message would ever explain.
    for market in [MarketState.pre, .regular, .post, .closed] {
        for visibility in [Visibility.visible, .occluded] {
            for lowPower in [false, true] {
                for count in [0, 1, 20] {
                    let d = RefreshPolicy.decide(input(market: market, visibility: visibility,
                                                       lowPower: lowPower, count: count))
                    if let wait = d.waitSeconds {
                        #expect(wait.isFinite)
                        #expect(wait >= 0)
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --build-system native --filter RefreshPolicy`
Expected: FAIL — `cannot find 'RefreshPolicy' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/TickerCore/RefreshPolicy.swift`:

```swift
public enum Visibility: Sendable {
    case visible
    /// Behind the notch, or pushed off by another app's menu items. There is
    /// nothing to update, and this is the single largest saving Squiggle makes.
    case occluded
}

public struct RefreshInput: Sendable {
    public var nowMonotonic: Double
    /// Wall-clock seconds, passed in as a number. `TickerCore` never reads a
    /// clock; trading periods are epochs from the payload, so comparing them
    /// requires one — as a parameter, not a dependency.
    public var nowEpoch: Double
    public var marketState: MarketState
    public var visibility: Visibility
    public var lowPowerMode: Bool
    public var userIntervalSeconds: Double
    public var watchlistCount: Int
    public var nextRegularOpenEpoch: Double?
    public var isCoolingDown: Bool
    public var cooldownRemaining: Double
    public var circuitAllows: Bool
    public var circuitOpenRemaining: Double

    public init(nowMonotonic: Double, nowEpoch: Double, marketState: MarketState,
                visibility: Visibility, lowPowerMode: Bool, userIntervalSeconds: Double,
                watchlistCount: Int, nextRegularOpenEpoch: Double?, isCoolingDown: Bool,
                cooldownRemaining: Double, circuitAllows: Bool, circuitOpenRemaining: Double) {
        self.nowMonotonic = nowMonotonic
        self.nowEpoch = nowEpoch
        self.marketState = marketState
        self.visibility = visibility
        self.lowPowerMode = lowPowerMode
        self.userIntervalSeconds = userIntervalSeconds
        self.watchlistCount = watchlistCount
        self.nextRegularOpenEpoch = nextRegularOpenEpoch
        self.isCoolingDown = isCoolingDown
        self.cooldownRemaining = cooldownRemaining
        self.circuitAllows = circuitAllows
        self.circuitOpenRemaining = circuitOpenRemaining
    }
}

public enum RefreshDecision: Equatable, Sendable {
    case fetch
    case wait(seconds: Double)

    public var waitSeconds: Double? {
        if case .wait(let s) = self { return s }
        return nil
    }
}

/// Should we fetch, and if not, for how long should we not?
///
/// A pure function, deliberately: it reads no clock and performs no I/O, so
/// the whole day-long budget simulation in the test suite is a loop over this
/// one call. A policy you cannot simulate is a policy you are guessing about.
public enum RefreshPolicy {

    /// How long one full pass over the watchlist should take.
    ///
    /// `max(userInterval, n × spacing)` — the 30s floor between requests means
    /// a 20-symbol watchlist needs ten minutes per pass whatever the user
    /// chose. Squiggle honours the floor and reports the real cadence rather
    /// than pretending to obey a setting it cannot.
    public static func cycleInterval(userIntervalSeconds: Double,
                                     watchlistCount: Int,
                                     marketState: MarketState,
                                     visibility: Visibility,
                                     lowPowerMode: Bool) -> Double {
        // A hand-edited settings file can contain anything at all.
        let requested = userIntervalSeconds.isFinite && userIntervalSeconds > 0
            ? userIntervalSeconds
            : RateConstants.defaultRefreshInterval

        let count = max(1, min(watchlistCount, RateConstants.maxWatchlistCount))
        let floor = Double(count) * RateConstants.spacingSeconds
        let base = max(requested, floor)

        // Extended hours and Low Power Mode each stretch the cycle. They do
        // not compound: the user asked for a slower ticker, not a stopped one.
        let quiet = marketState == .pre || marketState == .post || lowPowerMode
        return quiet ? base * RateConstants.quietMultiplier : base
    }

    /// Whether the strip should dim (spec §7). Measured against the cycle
    /// rather than the user's setting, because the cycle is the cadence that
    /// actually applies once the 30s floor binds.
    ///
    /// `nil` means nothing has ever arrived, which is stale by definition.
    public static func isStale(lastSuccessEpoch: Double?,
                               nowEpoch: Double,
                               userIntervalSeconds: Double,
                               watchlistCount: Int,
                               marketState: MarketState,
                               visibility: Visibility,
                               lowPowerMode: Bool) -> Bool {
        // While the market is shut, the last close is the right number no
        // matter how old it is. Dimming overnight would spend the signal on
        // the one case that is never a fault.
        guard marketState != .closed else { return false }
        guard let lastSuccessEpoch else { return true }

        let age = nowEpoch - lastSuccessEpoch
        // A clock correction can make this negative. Treat that as fresh: the
        // alternative is dimming the strip because the user changed timezone.
        guard age.isFinite, age > 0 else { return false }

        let cycle = cycleInterval(userIntervalSeconds: userIntervalSeconds,
                                  watchlistCount: watchlistCount,
                                  marketState: marketState,
                                  visibility: visibility,
                                  lowPowerMode: lowPowerMode)
        return age > cycle * RateConstants.stalenessMultiplier
    }

    public static func decide(_ input: RefreshInput) -> RefreshDecision {
        // Ordered by how long each reason lasts, longest first, so the wait we
        // report is the wait that actually applies. Reporting the shorter of
        // two live reasons would wake the caller early to be refused again.

        if input.isCoolingDown {
            return .wait(seconds: max(0, input.cooldownRemaining))
        }

        if !input.circuitAllows {
            return .wait(seconds: max(0, input.circuitOpenRemaining))
        }

        guard input.watchlistCount > 0 else {
            return .wait(seconds: RateConstants.defaultRefreshInterval)
        }

        let cycle = cycleInterval(userIntervalSeconds: input.userIntervalSeconds,
                                  watchlistCount: input.watchlistCount,
                                  marketState: input.marketState,
                                  visibility: input.visibility,
                                  lowPowerMode: input.lowPowerMode)

        if input.visibility == .occluded {
            // Do not fetch, but do not sleep forever either: the strip must be
            // current the moment it reappears, and unocclusion wakes us anyway.
            return .wait(seconds: cycle)
        }

        if input.marketState == .closed {
            guard let open = input.nextRegularOpenEpoch else {
                // No payload has told us when the market opens — a cold launch
                // into a weekend. Fall back to a slow poll rather than sleeping
                // indefinitely; a nil must never become a hang.
                return .wait(seconds: min(3600, max(cycle, RateConstants.defaultRefreshInterval)))
            }
            let untilOpen = open - input.nowEpoch - RateConstants.preOpenWakeLead
            // A stale open time from a payload older than the session it
            // described would otherwise produce a negative wait.
            return .wait(seconds: max(0, min(untilOpen, 12 * 3600)))
        }

        return .fetch
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --build-system native --filter RefreshPolicy`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TickerCore/RefreshPolicy.swift Tests/TickerCoreTests/RefreshPolicyTests.swift
git commit -m "feat: the pure refresh decision function"
```

---

## Task 12: The budget sweep

Spec §8.4. This is the test that justifies the whole design. It simulates 24 hours of wall-clock behaviour across **every** configuration the user can reach — four refresh intervals × five watchlist sizes — and asserts the daily request count stays under 1,200.

It is a test of the *composition*: pacer, policy and cycle floor together. Each is correct on its own in Tasks 8 and 11; only here does the number that matters get checked.

**Files:**
- Test: `Tests/TickerCoreTests/BudgetSweepTests.swift`

**Interfaces:**
- Consumes: `RefreshPolicy`, `RefreshInput`, `RequestPacer`, `RateConstants`, `MarketState`, `Visibility`, `FakeClock`.
- Produces: nothing. This task adds no source file — it is a pure verification task, and it exists as its own task because it is the gate the spec puts in front of the UI work.

- [ ] **Step 1: Write the simulator and the sweep**

`Tests/TickerCoreTests/BudgetSweepTests.swift`:

```swift
import Testing
@testable import TickerCore

/// Seconds since the start of an exchange-local day. The absolute date does
/// not matter; only the durations of each session do.
private enum Day {
    static let preOpen: Double = 4 * 3600            // 04:00
    static let regularOpen: Double = 9.5 * 3600      // 09:30
    static let regularClose: Double = 16 * 3600      // 16:00
    static let postClose: Double = 20 * 3600         // 20:00
    static let length: Double = 24 * 3600

    static func state(atSecondOfDay t: Double) -> MarketState {
        switch t {
        case preOpen..<regularOpen: return .pre
        case regularOpen..<regularClose: return .regular
        case regularClose..<postClose: return .post
        default: return .closed
        }
    }

    /// The next 09:30, as a second-of-day offset that may exceed a day.
    static func nextRegularOpen(afterSecondOfDay t: Double) -> Double {
        t < regularOpen ? regularOpen : regularOpen + length
    }
}

/// A one-second-tick simulation of Squiggle's actual fetch loop.
///
/// The loop it models is the one `TickerRunner` will implement in plan 2: ask
/// the policy whether to start a cycle, then walk the watchlist one symbol at
/// a time, each request passing through the pacer. Nothing here is
/// hypothetical — if this simulation and the runner ever disagree, the runner
/// is the bug.
private struct DaySimulation {
    var requests = 0
    var cyclesStarted = 0
    var cyclesRefusedByPacer = 0

    static func run(userInterval: Double,
                    watchlistCount: Int,
                    visibility: Visibility = .visible,
                    lowPowerMode: Bool = false,
                    marketOverride: MarketState? = nil) -> DaySimulation {
        var sim = DaySimulation()
        let clock = FakeClock()
        var pacer = RequestPacer(clock: clock)

        var pendingSymbols = 0
        var nextSymbolDue: Double = 0
        var cycleDeadline: Double = 0

        var t: Double = 0
        while t < Day.length {
            let market = marketOverride ?? Day.state(atSecondOfDay: t)

            if pendingSymbols > 0 {
                if t >= nextSymbolDue {
                    if pacer.take() {
                        sim.requests += 1
                        pendingSymbols -= 1
                        nextSymbolDue = t + RateConstants.spacingSeconds
                    } else {
                        // The bucket is the final authority. A cycle that
                        // cannot get tokens simply takes longer.
                        sim.cyclesRefusedByPacer += 1
                        nextSymbolDue = t + 1
                    }
                }
            } else if t >= cycleDeadline {
                let input = RefreshInput(
                    nowMonotonic: t,
                    nowEpoch: t,
                    marketState: market,
                    visibility: visibility,
                    lowPowerMode: lowPowerMode,
                    userIntervalSeconds: userInterval,
                    watchlistCount: watchlistCount,
                    nextRegularOpenEpoch: Day.nextRegularOpen(afterSecondOfDay: t),
                    isCoolingDown: false,
                    cooldownRemaining: 0,
                    circuitAllows: true,
                    circuitOpenRemaining: 0)

                switch RefreshPolicy.decide(input) {
                case .fetch:
                    sim.cyclesStarted += 1
                    pendingSymbols = watchlistCount
                    nextSymbolDue = t
                    cycleDeadline = t + RefreshPolicy.cycleInterval(
                        userIntervalSeconds: userInterval,
                        watchlistCount: watchlistCount,
                        marketState: market,
                        visibility: visibility,
                        lowPowerMode: lowPowerMode)
                case .wait(let seconds):
                    // Never advance by zero; that is an infinite loop, and a
                    // test that hangs teaches nothing.
                    cycleDeadline = t + max(1, seconds)
                }
            }

            t += 1
            clock.advance(1)
        }
        return sim
    }
}

/// Spec §4.2: the whole configuration space must fit under this.
private let dailyBudget = 1_200

@Test func theDailyBudgetHoldsAcrossEveryReachableConfiguration() {
    var worst = (interval: 0.0, count: 0, requests: 0)

    for interval in RateConstants.refreshIntervalChoices {
        for count in [1, 2, 4, 10, 20] {
            let sim = DaySimulation.run(userInterval: interval, watchlistCount: count)
            #expect(sim.requests <= dailyBudget,
                    "interval \(interval)s x \(count) symbols -> \(sim.requests) requests")
            if sim.requests > worst.requests {
                worst = (interval, count, sim.requests)
            }
        }
    }

    // Fail loudly if the sweep silently stopped exercising anything.
    #expect(worst.requests > 400,
            "the worst case was only \(worst.requests) requests; the simulation is not running")
}

@Test func theWorstCaseIsTheLargestWatchlistAtTheShortestInterval() {
    // Not an arbitrary assertion: it pins the shape of the curve. If some
    // future change makes a *smaller* watchlist more expensive, the
    // cycle-interval floor has stopped doing its job.
    let worstCase = DaySimulation.run(userInterval: 60, watchlistCount: 20)
    for interval in RateConstants.refreshIntervalChoices {
        for count in [1, 2, 4, 10, 20] {
            let sim = DaySimulation.run(userInterval: interval, watchlistCount: count)
            #expect(sim.requests <= worstCase.requests + 1,
                    "interval \(interval) x \(count) beat the supposed worst case")
        }
    }
}

@Test func theRequestRateNeverExceedsOnePerSpacingIntervalOverTheDay() {
    // The invariant behind the whole budget: because the 30s floor binds in
    // nearly every configuration, the rate is constant regardless of
    // watchlist size *and* user setting.
    for interval in RateConstants.refreshIntervalChoices {
        for count in [1, 2, 4, 10, 20] {
            let sim = DaySimulation.run(userInterval: interval, watchlistCount: count)
            let ceiling = Int(Day.length / RateConstants.spacingSeconds)
                + Int(RateConstants.bucketCapacity)
            #expect(sim.requests <= ceiling)
        }
    }
}

@Test func anOccludedDayCostsAlmostNothing() {
    // Spec §5.4: the single largest saving Squiggle makes. A user whose
    // Squiggle lives permanently behind the notch should not be paying for it.
    let sim = DaySimulation.run(userInterval: 60, watchlistCount: 20, visibility: .occluded)
    #expect(sim.requests == 0)
}

@Test func aWeekendCostsAlmostNothing() {
    let sim = DaySimulation.run(userInterval: 60, watchlistCount: 20, marketOverride: .closed)
    #expect(sim.requests == 0)
}

@Test func lowPowerModeCutsTheDayByRoughlyTheQuietMultiplier() {
    let normal = DaySimulation.run(userInterval: 180, watchlistCount: 10)
    let saving = DaySimulation.run(userInterval: 180, watchlistCount: 10, lowPowerMode: true)
    #expect(saving.requests < normal.requests)
    #expect(Double(saving.requests) <= Double(normal.requests) / 2)
}

@Test func aClosedMarketProducesNoBusyLoop() {
    // A wait of zero would spin the simulation for 86,400 iterations and, in
    // the real runner, spin a timer. Assert the cycle count is sane.
    let sim = DaySimulation.run(userInterval: 60, watchlistCount: 1, marketOverride: .closed)
    #expect(sim.cyclesStarted == 0)
}

@Test func thePacerIsNeverTheThingHoldingBackANormalDay() {
    // If the pacer is refusing requests during ordinary operation, the policy
    // is asking for more than the design allows and the two have drifted apart.
    let sim = DaySimulation.run(userInterval: 180, watchlistCount: 4)
    #expect(sim.cyclesRefusedByPacer == 0,
            "the pacer refused \(sim.cyclesRefusedByPacer) times on a default day")
}
```

- [ ] **Step 2: Run the sweep**

Run: `swift test --build-system native --filter Budget`
Expected: PASS.

If `theDailyBudgetHoldsAcrossEveryReachableConfiguration` fails, **do not raise
`dailyBudget`.** The number is the spec's, derived in §4.2 from the spacing
floor. A failure means the policy has started asking for more than the design
allows — fix the policy, or go back to the spec and change it deliberately.

- [ ] **Step 3: Record the worst case**

Print the sweep's worst case and paste it into the commit message, so the
budget headroom is recoverable from `git log` later:

```bash
swift test --build-system native --filter theWorstCaseIsTheLargest
```

- [ ] **Step 4: Commit**

```bash
git add Tests/TickerCoreTests/BudgetSweepTests.swift
git commit -m "test: 24-hour budget sweep over every reachable configuration"
```

---

## Task 13: Persistence

One file, `~/Library/Application Support/Squiggle/squiggle.json` (spec §6). Atomic writes, `decodeIfPresent` everywhere, refuse a newer schema, set a corrupt one aside. Modelled directly on `PresetStore` in the user's Pitch app.

**Never persisted:** a quote, and any credential — no cookies, no crumbs, no tokens. The support policy invites users to email their JSON, which would turn either into a leak channel.

**Files:**
- Create: `Sources/TickerCore/Store.swift`
- Create: `Sources/TickerCore/WatchlistStore.swift`
- Test: `Tests/TickerCoreTests/WatchlistStoreTests.swift`

**Interfaces:**
- Consumes: `Symbol`, `TickerError`, `RateConstants`.
- Produces:
  - `TickerCore.Settings` — `struct`, `Codable, Equatable, Sendable`: `refreshIntervalSeconds: Double`, `rows: Int`, `scrollPointsPerSecond: Double`, `colorScheme: String`, `maxVisibleWidth: Double`, `launchAtLogin: Bool`.
  - `TickerCore.Store` — `struct`, `Codable, Equatable, Sendable`: `schemaVersion: Int`, `symbols: [Symbol]`, `settings: Settings`, `cooldownUntilEpoch: Double?`; `static let currentSchemaVersion = 1`.
  - `TickerCore.WatchlistStore` — `protocol { func load() throws -> Store; func save(_ store: Store) throws }`.
  - `TickerCore.FileWatchlistStore` — `struct`, `init(url: URL)`, `static func defaultURL(applicationName: String) -> URL`, conforms to `WatchlistStore`. A set-aside is reported through `TickerError.storeCorrupt(quarantinedAt:)`, not through a property.

> `FileWatchlistStore` touches the filesystem, which `TickerCore`'s purity rules
> permit — the ban is on AppKit, UserDefaults, URLSession, timers, clocks and
> user-facing strings, not on `Foundation`'s file APIs. The cooldown epoch is
> the one documented wall-clock value in the package, and it enters and leaves
> as a `Double`.

- [ ] **Step 1: Write the failing tests**

`Tests/TickerCoreTests/WatchlistStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import TickerCore

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("squiggle-tests-\(UUID().uuidString)")
        .appendingPathComponent("squiggle.json")
}

private func write(_ json: String, to url: URL) throws {
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try json.write(to: url, atomically: true, encoding: .utf8)
}

@Test func loadingAMissingFileYieldsTheDefaultsRatherThanAnError() throws {
    // First launch is not an error condition.
    let store = try FileWatchlistStore(url: tempURL()).load()
    #expect(store.symbols.isEmpty)
    #expect(store.settings.rows == 1)
    #expect(store.settings.refreshIntervalSeconds == RateConstants.defaultRefreshInterval)
    #expect(store.cooldownUntilEpoch == nil)
}

@Test func aRoundTripPreservesEverything() throws {
    let url = tempURL()
    let fileStore = FileWatchlistStore(url: url)
    let original = Store(
        schemaVersion: 1,
        symbols: [try #require(Symbol("AAPL")), try #require(Symbol("BTC-USD"))],
        settings: Settings(refreshIntervalSeconds: 300, rows: 2, scrollPointsPerSecond: 24,
                           colorScheme: "monochrome", maxVisibleWidth: 320, launchAtLogin: true),
        cooldownUntilEpoch: 1_757_000_000)

    try fileStore.save(original)
    #expect(try fileStore.load() == original)
}

@Test func theWrittenFileIsHumanReadableAndStablyOrdered() throws {
    // Spec §6: the support policy is "email me your squiggle.json", so it has
    // to be readable, and a stable key order keeps diffs meaningful.
    let url = tempURL()
    try FileWatchlistStore(url: url).save(Store(
        schemaVersion: 1, symbols: [try #require(Symbol("MSFT"))],
        settings: Settings(), cooldownUntilEpoch: nil))

    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("\n"))
    let schemaIndex = try #require(text.range(of: "schemaVersion"))
    let symbolsIndex = try #require(text.range(of: "symbols"))
    #expect(schemaIndex.lowerBound < symbolsIndex.lowerBound)
}

@Test func aMissingKeyTakesItsDefaultInsteadOfFailingTheWholeLoad() throws {
    // decodeIfPresent everywhere: one unknown-to-this-version key must not
    // cost the user their entire watchlist.
    let url = tempURL()
    try write(#"{"schemaVersion":1,"symbols":["AAPL"]}"#, to: url)

    let store = try FileWatchlistStore(url: url).load()
    #expect(store.symbols.count == 1)
    #expect(store.settings.rows == 1)
}

@Test func anUnknownKeyIsIgnoredRatherThanRejected() throws {
    let url = tempURL()
    try write(#"{"schemaVersion":1,"symbols":["AAPL"],"favouriteColour":"puce"}"#, to: url)
    #expect(try FileWatchlistStore(url: url).load().symbols.count == 1)
}

@Test func aNewerSchemaIsRefusedAndTheFileIsLeftUntouched() throws {
    // A future Squiggle's file must survive a downgrade. Silently rewriting
    // it with this version's understanding discards whatever that version knew.
    let url = tempURL()
    let json = #"{"schemaVersion":99,"symbols":["AAPL"]}"#
    try write(json, to: url)

    #expect(throws: TickerError.self) { try FileWatchlistStore(url: url).load() }
    #expect(try String(contentsOf: url, encoding: .utf8) == json)
}

@Test func aCorruptFileIsSetAsideAndReplacedWithDefaults() throws {
    let url = tempURL()
    try write("{ this is not json at all", to: url)
    let fileStore = FileWatchlistStore(url: url)

    var setAside: URL?
    do {
        _ = try fileStore.load()
        Issue.record("a corrupt file loaded successfully")
    } catch let error as TickerError {
        guard case .storeCorrupt(let at) = error else {
            Issue.record("wrong error for a corrupt file: \(error)")
            return
        }
        setAside = at
    }

    let saved = try #require(setAside)
    #expect(FileManager.default.fileExists(atPath: saved.path))
    #expect(saved.lastPathComponent.hasPrefix("squiggle.json.bad-"))
    // The original is renamed aside, so the next load starts clean.
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(try fileStore.load().symbols.isEmpty)
}

@Test func aSecondCorruptionDoesNotOverwriteTheFirstCasualty() throws {
    let url = tempURL()
    let fileStore = FileWatchlistStore(url: url)

    var saved: [URL] = []
    for body in ["{ bad one", "{ bad two"] {
        try write(body, to: url)
        do { _ = try fileStore.load() } catch let e as TickerError {
            if case .storeCorrupt(let at) = e { saved.append(at) }
        }
    }
    #expect(saved.count == 2)
    #expect(saved[0] != saved[1], "the second set-aside landed on top of the first")
}

@Test func theWatchlistIsCappedOnDecodeAndNotJustInTheUI() throws {
    // Spec §4.2: the cap is a budget input, so a hand-edited file must not be
    // able to raise it. Keep the first twenty rather than throwing — the user
    // keeps a working app.
    let url = tempURL()
    let many = (1...50).map { "\"SYM\($0)\"" }.joined(separator: ",")
    try write("{\"schemaVersion\":1,\"symbols\":[\(many)]}", to: url)

    let store = try FileWatchlistStore(url: url).load()
    #expect(store.symbols.count == RateConstants.maxWatchlistCount)
    #expect(store.symbols.first?.raw == "SYM1")
}

@Test func invalidSymbolsInTheFileAreDroppedNotFatal() throws {
    let url = tempURL()
    try write(#"{"schemaVersion":1,"symbols":["AAPL","","bad/symbol","MSFT"]}"#, to: url)
    let store = try FileWatchlistStore(url: url).load()
    #expect(store.symbols.map(\.raw) == ["AAPL", "MSFT"])
}

@Test func duplicateSymbolsAreCollapsedPreservingFirstAppearance() throws {
    let url = tempURL()
    try write(#"{"schemaVersion":1,"symbols":["AAPL","MSFT","AAPL"]}"#, to: url)
    #expect(try FileWatchlistStore(url: url).load().symbols.map(\.raw) == ["AAPL", "MSFT"])
}

@Test func symbolCaseIsPreservedExactlyAsTheUserEnteredIt() throws {
    // Spec: symbols are stored verbatim. Yahoo is case-sensitive for some
    // listings, and helpfully upper-casing them breaks those.
    let url = tempURL()
    try write(#"{"schemaVersion":1,"symbols":["BRK-B","btc-usd"]}"#, to: url)
    #expect(try FileWatchlistStore(url: url).load().symbols.map(\.raw) == ["BRK-B", "btc-usd"])
}

@Test func nonsensicalSettingsValuesAreClampedOnDecode() throws {
    // The file is user-editable by design. Every number read from it is
    // hostile input until clamped.
    let url = tempURL()
    try write("""
    {"schemaVersion":1,"settings":{"refreshIntervalSeconds":-5,"rows":97,
     "scrollPointsPerSecond":100000,"maxVisibleWidth":-3}}
    """, to: url)

    let s = try FileWatchlistStore(url: url).load().settings
    #expect(s.refreshIntervalSeconds >= RateConstants.spacingSeconds)
    #expect(s.rows == 1 || s.rows == 2)
    #expect(s.scrollPointsPerSecond > 0 && s.scrollPointsPerSecond <= 200)
    #expect(s.maxVisibleWidth > 0)
}

@Test func aNonFiniteNumberInTheFileCannotReachTheApp() throws {
    // JSON has no NaN literal, but a huge exponent decodes to infinity, and
    // an infinite width becomes a status item that cannot lay out.
    let url = tempURL()
    try write(#"{"schemaVersion":1,"settings":{"maxVisibleWidth":1e400}}"#, to: url)
    let s = try FileWatchlistStore(url: url).load().settings
    #expect(s.maxVisibleWidth.isFinite)
}

@Test func aPersistedCooldownIsReadBackUnchanged() throws {
    // Converting the epoch into "seconds remaining" is the caller's job
    // (BackoffLadder.adoptPersistedCooldown, Task 9); the store's job is
    // only to hand back exactly what it was given.
    let url = tempURL()
    let deadline: Double = 1_757_000_600
    try write("{\"schemaVersion\":1,\"cooldownUntilEpoch\":\(deadline)}", to: url)

    let store = try FileWatchlistStore(url: url).load()
    #expect(try #require(store.cooldownUntilEpoch) == deadline)
}

@Test func anInfiniteCooldownInTheFileIsDiscarded() throws {
    let url = tempURL()
    try write(#"{"schemaVersion":1,"cooldownUntilEpoch":1e400}"#, to: url)
    #expect(try FileWatchlistStore(url: url).load().cooldownUntilEpoch == nil)
}

@Test func noQuoteDataIsEverWrittenToDisk() throws {
    // Spec §6, and a hard rule: the support policy is "email me your JSON".
    // A price is stale in seconds and worthless in a bug report; a credential
    // would be a leak. Neither goes in the file.
    let url = tempURL()
    try FileWatchlistStore(url: url).save(Store(
        schemaVersion: 1, symbols: [try #require(Symbol("AAPL"))],
        settings: Settings(), cooldownUntilEpoch: nil))

    let text = try String(contentsOf: url, encoding: .utf8).lowercased()
    for forbidden in ["price", "quote", "previousclose", "cookie", "crumb", "token", "session"] {
        #expect(!text.contains(forbidden), "the store file contains \"\(forbidden)\"")
    }
}

@Test func savingIsAtomicSoAnInterruptedWriteCannotShortenTheFile() throws {
    // Not directly observable in-process; assert the property we can observe —
    // that a save over an existing valid file always leaves a valid file.
    let url = tempURL()
    let fileStore = FileWatchlistStore(url: url)
    for i in 1...25 {
        try fileStore.save(Store(schemaVersion: 1,
                                 symbols: [try #require(Symbol("SYM\(i)"))],
                                 settings: Settings(), cooldownUntilEpoch: nil))
        #expect(try fileStore.load().symbols.count == 1)
    }
}

@Test func savingCreatesTheContainingDirectoryOnFirstRun() throws {
    let url = tempURL()   // its parent does not exist
    try FileWatchlistStore(url: url).save(Store(
        schemaVersion: 1, symbols: [], settings: Settings(), cooldownUntilEpoch: nil))
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func theDefaultLocationIsUnderApplicationSupport() {
    let url = FileWatchlistStore.defaultURL(applicationName: "Squiggle")
    #expect(url.path.contains("Application Support/Squiggle"))
    #expect(url.lastPathComponent == "squiggle.json")
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --build-system native --filter WatchlistStore`
Expected: FAIL — `cannot find 'FileWatchlistStore' in scope`.

- [ ] **Step 3: Write `Settings` and `Store`**

`Sources/TickerCore/Store.swift`:

```swift
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
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()

        func finite(_ value: Double?, _ fallback: Double) -> Double {
            guard let value, value.isFinite else { return fallback }
            return value
        }

        let interval = finite(try c.decodeIfPresent(Double.self, forKey: .refreshIntervalSeconds),
                              defaults.refreshIntervalSeconds)
        refreshIntervalSeconds = min(max(interval, RateConstants.spacingSeconds), 3600)

        let rawRows = try c.decodeIfPresent(Int.self, forKey: .rows) ?? defaults.rows
        rows = (rawRows == 2) ? 2 : 1

        let speed = finite(try c.decodeIfPresent(Double.self, forKey: .scrollPointsPerSecond),
                           defaults.scrollPointsPerSecond)
        scrollPointsPerSecond = min(max(speed, 4), 200)

        colorScheme = try c.decodeIfPresent(String.self, forKey: .colorScheme)
            ?? defaults.colorScheme

        let width = finite(try c.decodeIfPresent(Double.self, forKey: .maxVisibleWidth),
                           defaults.maxVisibleWidth)
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

        let cooldown = try c.decodeIfPresent(Double.self, forKey: .cooldownUntilEpoch)
        cooldownUntilEpoch = (cooldown?.isFinite ?? false) ? cooldown : nil
    }
}
```

- [ ] **Step 4: Write `FileWatchlistStore`**

`Sources/TickerCore/WatchlistStore.swift`:

```swift
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
        var target = directory.appendingPathComponent("\(base).bad-\(stamp)")
        // Two corruptions inside the same second must not land on the same
        // name — the first casualty is usually the more informative one.
        var suffix = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent("\(base).bad-\(stamp)-\(suffix)")
            suffix += 1
        }

        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
}
```

- [ ] **Step 5: Run to verify they pass**

Run: `swift test --build-system native --filter WatchlistStore`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/TickerCore/Store.swift Sources/TickerCore/WatchlistStore.swift \
        Tests/TickerCoreTests/WatchlistStoreTests.swift
git commit -m "feat: one atomic JSON file, refusing newer and setting corrupt aside"
```

---

## Task 14: `RowSplitter` — dealing one watchlist across two marquees

Spec §5.2 and the user's original "1 or 2 rows". One watchlist, up to two independently-scrolling rows. The split has to be *balanced by width*, not by count: a row holding `BRK-B $412.50 ▲0.31%` and `GOOGL $174.02 ▼1.04%` is far wider than one holding `F` and `T`, and two rows of wildly different widths look broken and finish their scroll cycles at wildly different times.

This lives in `TickerCore` and takes widths as plain `Double`s. It never sees a font, a string or a `CGFloat` — the renderer measures, the splitter divides.

**Files:**
- Create: `Sources/TickerCore/RowSplitter.swift`
- Test: `Tests/TickerCoreTests/RowSplitterTests.swift`

**Interfaces:**
- Consumes: `RateConstants` (for the watchlist cap, in one test only).
- Produces:
  - `TickerCore.RowSplitter` — `enum` (namespace only, no instances).
    - `public static func split(widths: [Double], rows: Int) -> [[Int]]`
      Returns exactly `max(1, min(rows, 2))` arrays of **indices into `widths`**, ascending within each row.

> Returning indices rather than the items themselves keeps the splitter free of
> whatever the renderer's item type turns out to be. Plan 2's `StripLayout` is
> unwritten; this signature does not care.

- [ ] **Step 1: Write the failing tests**

`Tests/TickerCoreTests/RowSplitterTests.swift`:

```swift
import Testing
@testable import TickerCore

/// Sum of the widths a row was given.
private func load(_ row: [Int], _ widths: [Double]) -> Double {
    row.reduce(0) { $0 + widths[$1] }
}

@Test func oneRowIsTheIdentity() {
    let widths = [10.0, 3.0, 88.0, 1.0]
    #expect(RowSplitter.split(widths: widths, rows: 1) == [[0, 1, 2, 3]])
}

@Test func indicesStayAscendingWithinEachRow() {
    // The marquee reads left to right. A row whose indices are out of order
    // would show the user's watchlist shuffled, which looks like a bug even
    // though every symbol is present.
    let widths = (0..<40).map { Double(($0 * 37) % 23 + 1) }
    for row in RowSplitter.split(widths: widths, rows: 2) {
        #expect(row == row.sorted())
    }
}

@Test func everyItemAppearsExactlyOnce() {
    let widths = (0..<40).map { Double(($0 * 37) % 23 + 1) }
    let rows = RowSplitter.split(widths: widths, rows: 2)
    #expect(rows.flatMap { $0 }.sorted() == Array(0..<widths.count))
}

@Test func theTwoRowsEndUpCloseInTotalWidth() {
    // The property that matters: rows that differ a lot in width look broken
    // and finish their scroll cycles at very different times.
    let widths = [40.0, 38.0, 41.0, 39.0, 42.0, 37.0]
    let rows = RowSplitter.split(widths: widths, rows: 2)
    let difference = abs(load(rows[0], widths) - load(rows[1], widths))
    #expect(difference <= widths.max() ?? 0)
}

@Test func balanceHoldsEvenWhenOneItemDominates() {
    // A single very wide item cannot be split, so the best achievable
    // imbalance is that item's own width minus the rest. Assert we hit it.
    let widths = [500.0, 10.0, 10.0, 10.0, 10.0]
    let rows = RowSplitter.split(widths: widths, rows: 2)
    let difference = abs(load(rows[0], widths) - load(rows[1], widths))
    #expect(difference == 460)
}

@Test func alternatingWidthsAreNotJustDealtRoundRobin() {
    // Round-robin would put every wide item in row 0 and every narrow one in
    // row 1 — the exact failure this type exists to prevent.
    let widths = [100.0, 1.0, 100.0, 1.0, 100.0, 1.0]
    let rows = RowSplitter.split(widths: widths, rows: 2)
    let difference = abs(load(rows[0], widths) - load(rows[1], widths))
    #expect(difference < 100, "round-robin dealing would give a difference of 297")
}

@Test func tiesGoToTheEarlierRowSoTheSplitIsDeterministic() {
    // Equal widths must produce the same answer on every launch; a split that
    // changes between runs makes the ticker visibly reshuffle for no reason.
    let widths = [10.0, 10.0, 10.0, 10.0]
    let first = RowSplitter.split(widths: widths, rows: 2)
    #expect(first == RowSplitter.split(widths: widths, rows: 2))
    #expect(first[0].first == 0)
}

@Test func anEmptyWatchlistYieldsTheRightNumberOfEmptyRows() {
    #expect(RowSplitter.split(widths: [], rows: 2) == [[], []])
    #expect(RowSplitter.split(widths: [], rows: 1) == [[]])
}

@Test func aSingleItemLeavesTheSecondRowEmptyRatherThanDuplicating() {
    #expect(RowSplitter.split(widths: [7.0], rows: 2) == [[0], []])
}

@Test func aNonsensicalRowCountIsClampedIntoRange() {
    // `rows` reaches here from a hand-edited settings file (Task 13 clamps to
    // 1 or 2, but the splitter must not depend on that having happened).
    #expect(RowSplitter.split(widths: [1.0, 2.0], rows: 0).count == 1)
    #expect(RowSplitter.split(widths: [1.0, 2.0], rows: -5).count == 1)
    #expect(RowSplitter.split(widths: [1.0, 2.0], rows: 99).count == 2)
}

@Test func nonFiniteAndNegativeWidthsDoNotPoisonTheBalance() {
    // A NaN in a running total makes every subsequent comparison false, which
    // silently degrades the splitter to "everything in row 0".
    let widths = [10.0, .nan, 10.0, -50.0, 10.0, .infinity, 10.0]
    let rows = RowSplitter.split(widths: widths, rows: 2)
    #expect(rows.flatMap { $0 }.sorted() == Array(0..<widths.count))
    #expect(!rows[0].isEmpty)
    #expect(!rows[1].isEmpty)
}

@Test func theSplitScalesToTheWatchlistCap() {
    let widths = (0..<RateConstants.maxWatchlistCount).map { Double($0 + 1) * 3 }
    let rows = RowSplitter.split(widths: widths, rows: 2)
    #expect(rows.flatMap { $0 }.count == RateConstants.maxWatchlistCount)
    let difference = abs(load(rows[0], widths) - load(rows[1], widths))
    #expect(difference <= widths.max() ?? 0)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --build-system native --filter RowSplitter`
Expected: FAIL — `cannot find 'RowSplitter' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/TickerCore/RowSplitter.swift`:

```swift
/// Divides one watchlist across the menu bar's one or two marquee rows.
///
/// The algorithm is greedy least-loaded assignment: walk the items in order
/// and give each to whichever row is currently narrowest. That is not the
/// optimal partition — optimal is NP-hard — but for the ≤20 items Squiggle
/// allows it lands within one item's width of optimal, which is the best any
/// split can do when a single item cannot be divided.
///
/// Walking in order is what keeps each row's indices ascending, so the
/// marquee still reads left to right within a row.
public enum RowSplitter {
    public static func split(widths: [Double], rows requestedRows: Int) -> [[Int]] {
        let rows = max(1, min(requestedRows, 2))
        var buckets = [[Int]](repeating: [], count: rows)
        guard rows > 1 else {
            buckets[0] = Array(widths.indices)
            return buckets
        }

        var loads = [Double](repeating: 0, count: rows)

        for (index, rawWidth) in widths.enumerated() {
            // A NaN in a running total makes every later comparison false,
            // which quietly degrades this to "everything in row 0". Negative
            // and infinite widths are equally meaningless. All become zero.
            let width = (rawWidth.isFinite && rawWidth > 0) ? rawWidth : 0

            // `<` rather than `<=` sends ties to the earlier row, so an
            // all-equal watchlist splits the same way on every launch.
            var target = 0
            for candidate in 1..<rows where loads[candidate] < loads[target] {
                target = candidate
            }

            buckets[target].append(index)
            loads[target] += width
        }

        return buckets
    }
}
```

> `.infinity` fails the `isFinite` check, so an infinite width becomes zero
> rather than permanently pinning one row as "full". That is the behaviour
> `nonFiniteAndNegativeWidthsDoNotPoisonTheBalance` asserts.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --build-system native --filter RowSplitter`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TickerCore/RowSplitter.swift Tests/TickerCoreTests/RowSplitterTests.swift
git commit -m "feat: width-balanced dealing of one watchlist across two rows"
```

---

## Task 15: Symbol search

Spec §5.3: the symbol picker is search-only. There is no browsable list of every instrument on earth, and no free-text field that lets a user save `APPL` and then wonder why it never updates. They type, Yahoo answers, they pick from the answers.

`v1/finance/search?q=` is the second and last endpoint Squiggle uses.

**Files:**
- Create: `Sources/TickerCore/SearchResult.swift`
- Create: `Sources/TickerCore/YahooSearchDecoding.swift`
- Modify: `Sources/YahooFeed/YahooClient.swift` — add `searchResults(query:limit:)` and two query items to the existing `search(_:)`
- Modify: `Sources/TickerCore/YahooQuoteDecoding.swift` — drop `private` from `translate(_:)`
- Modify: `Sources/squigglectl/Command.swift` — add the `search` verb
- Modify: `Sources/squigglectl/Rendering.swift` — extend `usage`, add `render(_:)` for results
- Modify: `Sources/squigglectl/main.swift` — dispatch `search`
- Test: `Tests/TickerCoreTests/YahooSearchDecodingTests.swift`
- Test: `Tests/squigglectlTests/CommandTests.swift` — extend with search parsing

**Interfaces:**
- Consumes: `Symbol`, `TickerError`, `YahooQuoteDecoding.translate(_:)`, `YahooClient.search(_:)`, `Command`, `Rendering`, and the `search-apple.json` fixture.
- **Fixture note (controller ruling R7):** Task 3 captures quote bodies only; it never
  produced `search-apple.json`, and no other task did either. The controller captures it
  into `Tests/Fixtures/yahoo-2026-09-08/` and commits it **before dispatching this task**.
  The implementer must therefore find the file already present. If it is absent, stop and
  report `BLOCKED` rather than fabricating one by hand — the tests below assert on real
  Yahoo relevance ordering, which a hand-written fixture cannot honestly supply.
- Produces:
  - `TickerCore.SearchResult` — `struct`, `Equatable, Sendable`: `symbol: Symbol`, `name: String`, `exchange: String`, `kind: String`.
  - `TickerCore.YahooSearchDecoding` — `enum`; `public static func results(from data: Data, limit: Int) throws -> [SearchResult]`.
  - `YahooFeed.YahooClient.searchResults(query: String, limit: Int) async throws -> [SearchResult]` — a plain method, **not** a protocol requirement.
  - `Command.search(query: String, limit: Int)` — a new case on the existing enum.

- [ ] **Step 1: Write the failing decoding tests**

`Tests/TickerCoreTests/YahooSearchDecodingTests.swift`:

```swift
import Foundation
import Testing
@testable import TickerCore

private func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // TickerCoreTests
        .deletingLastPathComponent()      // Tests
        .appendingPathComponent("Fixtures/yahoo-2026-09-08/\(name)")
    return try Data(contentsOf: url)
}

@Test func theAppleSearchFixtureDecodesToUsableResults() throws {
    let results = try YahooSearchDecoding.results(from: fixture("search-apple.json"), limit: 10)
    #expect(!results.isEmpty)
    let apple = try #require(results.first { $0.symbol.raw == "AAPL" })
    #expect(apple.name.contains("Apple"))
    #expect(!apple.exchange.isEmpty)
}

@Test func theLimitIsHonouredExactly() throws {
    let results = try YahooSearchDecoding.results(from: fixture("search-apple.json"), limit: 3)
    #expect(results.count <= 3)
}

@Test func aZeroOrNegativeLimitReturnsNothingRatherThanEverything() throws {
    #expect(try YahooSearchDecoding.results(from: fixture("search-apple.json"), limit: 0).isEmpty)
    #expect(try YahooSearchDecoding.results(from: fixture("search-apple.json"), limit: -1).isEmpty)
}

@Test func resultOrderFromYahooIsPreserved() throws {
    // Yahoo ranks by relevance and does it well. Re-sorting alphabetically
    // would bury AAPL under a dozen Apple-adjacent penny stocks.
    let all = try YahooSearchDecoding.results(from: fixture("search-apple.json"), limit: 50)
    let firstThree = try YahooSearchDecoding.results(from: fixture("search-apple.json"), limit: 3)
    #expect(Array(all.prefix(3)) == firstThree)
}

@Test func aQueryWithNoMatchesIsAnEmptyListAndNotAnError() throws {
    // Spec §7: an empty result is a normal outcome the picker shows as
    // "no matches", not a failure the user has to interpret.
    let json = Data(#"{"quotes":[],"news":[]}"#.utf8)
    #expect(try YahooSearchDecoding.results(from: json, limit: 10).isEmpty)
}

@Test func aMissingQuotesArrayIsTreatedAsNoMatches() throws {
    #expect(try YahooSearchDecoding.results(from: Data("{}".utf8), limit: 10).isEmpty)
}

@Test func entriesWithoutAUsableSymbolAreSkippedNotFatal() throws {
    // Yahoo's search index carries non-tradeable rows — indices, currencies,
    // and occasionally entries with no symbol at all. One bad row must not
    // cost the user the other nine good ones.
    let json = Data("""
    {"quotes":[
      {"shortname":"No symbol here","exchDisp":"NASDAQ"},
      {"symbol":"","shortname":"Empty","exchDisp":"NASDAQ"},
      {"symbol":"bad/symbol","shortname":"Slashes","exchDisp":"NASDAQ"},
      {"symbol":"MSFT","shortname":"Microsoft Corporation","exchDisp":"NASDAQ","quoteType":"EQUITY"}
    ]}
    """.utf8)
    let results = try YahooSearchDecoding.results(from: json, limit: 10)
    #expect(results.map(\.symbol.raw) == ["MSFT"])
}

@Test func longnameIsUsedWhenShortnameIsAbsent() throws {
    let json = Data("""
    {"quotes":[{"symbol":"BRK-B","longname":"Berkshire Hathaway Inc. New","exchDisp":"NYSE"}]}
    """.utf8)
    let results = try YahooSearchDecoding.results(from: json, limit: 10)
    #expect(results.first?.name == "Berkshire Hathaway Inc. New")
}

@Test func aResultWithNoNameAtAllFallsBackToItsSymbol() throws {
    // Better a row reading "XYZ  —  NASDAQ" than a blank line the user
    // cannot tell apart from a rendering bug.
    let json = Data(#"{"quotes":[{"symbol":"XYZ","exchDisp":"NASDAQ"}]}"#.utf8)
    #expect(try YahooSearchDecoding.results(from: json, limit: 10).first?.name == "XYZ")
}

@Test func missingExchangeAndKindDegradeToEmptyStringsRatherThanFailing() throws {
    let json = Data(#"{"quotes":[{"symbol":"XYZ","shortname":"Some Co"}]}"#.utf8)
    let result = try #require(try YahooSearchDecoding.results(from: json, limit: 10).first)
    #expect(result.exchange.isEmpty)
    #expect(result.kind.isEmpty)
}

@Test func searchDecodingRejectsNonJsonWithTheSameErrorAsQuoteDecoding() throws {
    // Consistency matters: `doctor` (Task 17) classifies faults by error case,
    // and a search failure that reported something different would be
    // diagnosed wrongly.
    #expect(throws: TickerError.notJSON) {
        try YahooSearchDecoding.results(from: Data("<html>429</html>".utf8), limit: 10)
    }
}

@Test func searchDecodingSurvivesEveryTruncationOfTheFixture() throws {
    // Same fuzz as Task 6: a connection cut mid-body must throw, never crash.
    let data = try fixture("search-apple.json")
    for length in stride(from: 0, to: data.count, by: 7) {
        _ = try? YahooSearchDecoding.results(from: Data(data.prefix(length)), limit: 10)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --build-system native --filter YahooSearchDecoding`
Expected: FAIL — `cannot find 'YahooSearchDecoding' in scope`.

- [ ] **Step 3: Write `SearchResult` and the decoder**

`Sources/TickerCore/SearchResult.swift`:

```swift
/// One row in the symbol picker.
///
/// `kind` and `exchange` are plain strings rather than enums on purpose:
/// Yahoo's search index contains instrument types this app has never heard of,
/// and an unknown value should show up in the picker as text, not fail the
/// whole search.
public struct SearchResult: Equatable, Sendable {
    public let symbol: Symbol
    public let name: String
    public let exchange: String
    public let kind: String

    public init(symbol: Symbol, name: String, exchange: String, kind: String) {
        self.symbol = symbol
        self.name = name
        self.exchange = exchange
        self.kind = kind
    }
}
```

`Sources/TickerCore/YahooSearchDecoding.swift`:

```swift
import Foundation

/// Decodes `v1/finance/search?q=`.
///
/// Far more forgiving than the quote decoder, and deliberately so. A quote
/// with a missing price is a contract fault worth shouting about; a search
/// row with a missing name is one imperfect line in a picker. The rule is:
/// skip what cannot be used, keep what can, and only throw when the response
/// as a whole is not what we asked for.
public enum YahooSearchDecoding {
    private struct Envelope: Decodable {
        let quotes: [Row]?

        struct Row: Decodable {
            let symbol: String?
            let shortname: String?
            let longname: String?
            let exchDisp: String?
            let quoteType: String?
        }
    }

    public static func results(from data: Data, limit: Int) throws -> [SearchResult] {
        guard limit > 0 else { return [] }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch let error as DecodingError {
            throw YahooQuoteDecoding.translate(error)
        }

        return (envelope.quotes ?? [])
            .compactMap { row -> SearchResult? in
                guard let raw = row.symbol, let symbol = Symbol(raw) else { return nil }
                let name = row.shortname ?? row.longname ?? symbol.raw
                return SearchResult(symbol: symbol,
                                    name: name,
                                    exchange: row.exchDisp ?? "",
                                    kind: row.quoteType ?? "")
            }
            .prefix(limit)
            .map { $0 }
    }
}
```

> `YahooQuoteDecoding.translate(_:)` is the translator written in Task 5. Reusing it is
> what makes `searchDecodingRejectsNonJsonWithTheSameErrorAsQuoteDecoding`
> pass, and what lets `doctor` classify a search failure and a quote failure
> with the same code.

- [ ] **Step 4: Decode search results on `YahooClient`**

`YahooClient` already conforms to `SymbolSearching` — Task 2 wrote
`search(_ query: String) async throws -> Data` and pointed it at
`/v1/finance/search`. Do **not** write `extension YahooClient: SymbolSearching`
here: restating a conformance the type already has is a compile error
(`redundant conformance`), and the protocol requirement returns `Data`, not
`[SearchResult]`.

Two edits, both in `Sources/YahooFeed/YahooClient.swift`.

First, add two query items to the **existing** `search(_:)` — find the
`components.queryItems` line Task 2 wrote and replace it with:

```swift
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            // Ask for the most Squiggle will ever show. Trimming to the
            // caller's limit happens in the decoder, so the transport method
            // keeps the one-argument shape `SymbolSearching` requires.
            URLQueryItem(name: "quotesCount", value: "20"),
            // Squiggle shows prices, not headlines. Zero news items keeps the
            // response small and the parse cheap.
            URLQueryItem(name: "newsCount", value: "0"),
        ]
```

Second, append the decoded convenience:

```swift
extension YahooClient {
    /// Search, decoded. Not a `SymbolSearching` requirement — that protocol is
    /// the transport seam and deals only in `Data`. This is the method the CLI
    /// and, later, the symbol picker actually call.
    public func searchResults(query: String, limit: Int) async throws -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty query is not a failure and is not worth a request.
        guard !trimmed.isEmpty else { return [] }
        let data = try await search(trimmed)
        return try YahooSearchDecoding.results(from: data, limit: limit)
    }
}
```

> Every byte still arrives through `body(of:symbol:)`, the one place `URLSession`
> is touched and the one place HTTP status becomes a `TickerError`. **No path may
> bypass `RequestPacer`**, and adding a second request helper here would have been
> exactly that path.

- [ ] **Step 5: Add the `search` verb**

In `Sources/squigglectl/Command.swift`, add the case:

```swift
case search(query: String, limit: Int)
```

and its parsing branch, alongside the existing `"quote"` branch:

```swift
case "search":
    var words: [String] = []
    var limit = 10
    var index = 0
    while index < rest.count {
        if rest[index] == "--limit" {
            guard index + 1 < rest.count,
                  let parsed = Int(rest[index + 1]), parsed > 0 else {
                return .failure("--limit needs a positive whole number")
            }
            limit = min(parsed, 20)
            index += 2
        } else {
            words.append(rest[index])
            index += 1
        }
    }
    // Multi-word queries are the normal case ("berkshire hathaway"), so join
    // the leftovers rather than demanding the user quote them.
    let query = words.joined(separator: " ")
    guard !query.isEmpty else { return .failure("search needs something to search for") }
    return .success(.search(query: query, limit: limit))
```

Extend `Rendering.usage`. Its exact text is asserted by a test written in
Task 2, so update that expectation in this same commit:

```
squigglectl — Squiggle's feed, without the menu bar

USAGE
  squigglectl quote <SYMBOL> [--raw]
  squigglectl search <QUERY...> [--limit N]

OPTIONS
  --raw        print the response body exactly as received
  --limit N    at most N search results (default 10, max 20)
```

And add the renderer to `Rendering`:

```swift
static func render(_ results: [SearchResult]) -> String {
    guard !results.isEmpty else { return "no matches" }
    // Pad to the widest symbol so the names line up. The picker in plan 2
    // uses a real table; this is the terminal's version of the same idea.
    let width = results.map(\.symbol.raw.count).max() ?? 0
    return results.map { result in
        let padded = result.symbol.raw.padding(toLength: width, withPad: " ", startingAt: 0)
        let suffix = result.exchange.isEmpty ? "" : "  (\(result.exchange))"
        return "\(padded)  \(result.name)\(suffix)"
    }.joined(separator: "\n")
}
```

In `main.swift`, dispatch `search` next to `quote`: print `Rendering.render(results)`
to stdout and return `0`; on a thrown `TickerError`, print its diagnosis to
stderr and return `1` — exactly the shape `quote` already uses.

- [ ] **Step 6: Extend the command tests**

Append to `Tests/squigglectlTests/CommandTests.swift`:

```swift
@Test func searchTakesAMultiWordQueryWithoutQuoting() {
    #expect(Command.parse(["search", "berkshire", "hathaway"])
        == .success(.search(query: "berkshire hathaway", limit: 10)))
}

@Test func searchAcceptsALimitAnywhereInTheArguments() {
    #expect(Command.parse(["search", "--limit", "3", "apple"])
        == .success(.search(query: "apple", limit: 3)))
    #expect(Command.parse(["search", "apple", "--limit", "3"])
        == .success(.search(query: "apple", limit: 3)))
}

@Test func theLimitIsCappedSoOneCommandCannotBecomeALargeRequest() {
    #expect(Command.parse(["search", "apple", "--limit", "5000"])
        == .success(.search(query: "apple", limit: 20)))
}

@Test func aNonNumericOrZeroLimitIsRejectedWithAMessage() {
    #expect(Command.parse(["search", "apple", "--limit", "lots"]).isFailure)
    #expect(Command.parse(["search", "apple", "--limit", "0"]).isFailure)
    #expect(Command.parse(["search", "apple", "--limit"]).isFailure)
}

@Test func searchWithNothingToSearchForIsRejected() {
    #expect(Command.parse(["search"]).isFailure)
    #expect(Command.parse(["search", "--limit", "5"]).isFailure)
}

@Test func usageMentionsEveryVerbTheToolAccepts() {
    // A verb that works but is undocumented is a verb nobody uses.
    for verb in ["quote", "search"] {
        #expect(Rendering.usage.contains("squigglectl \(verb)"))
    }
}
```

- [ ] **Step 7: Run to verify they pass**

Run: `swift test --build-system native`
Expected: PASS, whole suite.

- [ ] **Step 8: Try it against the live endpoint**

```bash
swift run --build-system native squigglectl search berkshire hathaway --limit 5
```

Expected: five rows, with `BRK-B` and `BRK-A` among them.

If this reports `rateLimited`, wait — do not loop. One `search` is one request
against the same daily budget as everything else.

- [ ] **Step 9: Commit**

```bash
git add Sources/TickerCore/SearchResult.swift Sources/TickerCore/YahooSearchDecoding.swift \
        Sources/YahooFeed/YahooClient.swift Sources/squigglectl/ \
        Tests/TickerCoreTests/YahooSearchDecodingTests.swift \
        Tests/squigglectlTests/CommandTests.swift
git commit -m "feat: search-only symbol lookup, skipping rows it cannot use"
```

---

## Task 16: `FeedEngine` and `squigglectl watch`

Everything from Tasks 8–13 exists in isolation. This task wires it into the single object that decides what to do next, and gives it a headless driver so the trading-day verification in Task 19 has something to run.

`FeedEngine` lives in `TickerCore` and performs no I/O. It answers one question — *"what should happen next?"* — and the caller obeys. `squigglectl watch` is one caller; plan 2's menu bar app will be the other, and it must use this same engine rather than reimplementing the loop.

**Files:**
- Create: `Sources/TickerCore/FeedEngine.swift`
- Modify: `Sources/squigglectl/Command.swift` — add the `watch` verb
- Modify: `Sources/squigglectl/Rendering.swift` — extend `usage`, add a one-line quote renderer
- Create: `Sources/squigglectl/WatchLoop.swift`
- Modify: `Sources/squigglectl/main.swift` — dispatch `watch`
- Test: `Tests/TickerCoreTests/FeedEngineTests.swift`

**Interfaces:**
- Consumes: `MonotonicClock`, `Randomizing`, `RequestPacer`, `BackoffLadder`, `CircuitBreaker`, `RefreshPolicy`, `RefreshInput`, `RefreshDecision`, `Visibility`, `MarketState`, `Symbol`, `Quote`, `TickerError`, `FailureKind`, `RateConstants`, `Settings`, `FakeClock`, `FakeRandom`.
- Produces:
  - `TickerCore.EngineContext` — `struct`, `Sendable`: `nowEpoch: Double`, `marketState: MarketState`, `visibility: Visibility`, `lowPowerMode: Bool`, `nextRegularOpenEpoch: Double?`.
  - `TickerCore.EngineAction` — `enum`, `Equatable, Sendable`: `case fetch(Symbol)`, `case sleep(seconds: Double)`.
  - `TickerCore.FeedEngine` — `struct`:
    - `init(clock: any MonotonicClock, random: any Randomizing = SystemRandom(), symbols: [Symbol], userIntervalSeconds: Double)`
    - `mutating func next(_ context: EngineContext) -> EngineAction`
    - `mutating func recordSuccess(_ quote: Quote, for symbol: Symbol)`
    - `mutating func record(_ error: TickerError, for symbol: Symbol)`
    - `mutating func replaceWatchlist(_ symbols: [Symbol])`
    - `var latest: [Symbol: Quote] { get }`
    - `var deadSymbols: Set<Symbol> { get }`
    - `func cooldownUntilEpoch(nowEpoch: Double) -> Double?`
    - `mutating func adoptPersistedCooldown(untilEpoch: Double, nowEpoch: Double)`

> `latest` is in memory only. It is never handed to `FileWatchlistStore`, and
> Task 13's `noQuoteDataIsEverWrittenToDisk` is what keeps that true.

- [ ] **Step 1: Write the failing tests**

`Tests/TickerCoreTests/FeedEngineTests.swift`:

```swift
import Testing
@testable import TickerCore

private func sym(_ raw: String) throws -> Symbol { try #require(Symbol(raw)) }

private func openMarket(_ epoch: Double = 1_757_000_000) -> EngineContext {
    EngineContext(nowEpoch: epoch, marketState: .regular, visibility: .visible,
                  lowPowerMode: false, nextRegularOpenEpoch: nil)
}

private func engine(_ clock: FakeClock,
                    _ symbols: [Symbol],
                    interval: Double = 180,
                    random: FakeRandom = FakeRandom(position: 1.0)) -> FeedEngine {
    FeedEngine(clock: clock, random: random, symbols: symbols, userIntervalSeconds: interval)
}

@Test func theFirstActionOnAnOpenMarketIsToFetchTheFirstSymbol() throws {
    let clock = FakeClock()
    var e = engine(clock, [try sym("AAPL"), try sym("MSFT")])
    #expect(e.next(openMarket()) == .fetch(try sym("AAPL")))
}

@Test func symbolsAreFetchedInWatchlistOrderOneAtATime() throws {
    let clock = FakeClock()
    let symbols = [try sym("AAPL"), try sym("MSFT"), try sym("NVDA")]
    var e = engine(clock, symbols)

    var fetched: [Symbol] = []
    for _ in 0..<3 {
        guard case .fetch(let s) = e.next(openMarket()) else {
            Issue.record("expected a fetch")
            return
        }
        fetched.append(s)
        e.recordSuccess(stubQuote(s), for: s)
        clock.advance(RateConstants.spacingSeconds)
    }
    #expect(fetched == symbols)
}

@Test func aSecondFetchInsideTheSpacingWindowIsRefusedByThePacer() throws {
    // The bucket starts full, so the first few go straight through; this test
    // drains it and then asserts the engine waits instead of bursting.
    let clock = FakeClock()
    let many = try (1...10).map { try sym("SYM\($0)") }
    var e = engine(clock, many, interval: 60)

    var slept = false
    for _ in 0..<12 {
        switch e.next(openMarket()) {
        case .fetch(let s): e.recordSuccess(stubQuote(s), for: s)
        case .sleep(let seconds):
            slept = true
            #expect(seconds > 0)
        }
    }
    #expect(slept, "ten symbols went out with no pause; the pacer was bypassed")
}

@Test func theSleepReportedIsTheTimeUntilTheNextTokenAndNotAGuess() throws {
    let clock = FakeClock()
    var e = engine(clock, [try sym("AAPL")], interval: 60)

    // Drain the bucket.
    while case .fetch(let s) = e.next(openMarket()) {
        e.recordSuccess(stubQuote(s), for: s)
    }
    guard case .sleep(let seconds) = e.next(openMarket()) else {
        Issue.record("expected a sleep once the bucket was empty")
        return
    }
    // Sleeping longer than necessary wastes a refresh; sleeping shorter wakes
    // the caller up to be refused again.
    #expect(seconds <= RateConstants.spacingSeconds)
    #expect(seconds > 0)
}

@Test func anOccludedMenuBarStopsFetchingEntirely() throws {
    let clock = FakeClock()
    var e = engine(clock, [try sym("AAPL")])
    var context = openMarket()
    context.visibility = .occluded

    for _ in 0..<20 {
        guard case .sleep = e.next(context) else {
            Issue.record("the engine fetched while occluded")
            return
        }
        clock.advance(60)
    }
}

@Test func aClosedMarketSleepsUntilShortlyBeforeTheOpen() throws {
    let clock = FakeClock()
    var e = engine(clock, [try sym("AAPL")])
    let now: Double = 1_757_000_000
    var context = EngineContext(nowEpoch: now, marketState: .closed, visibility: .visible,
                                lowPowerMode: false, nextRegularOpenEpoch: now + 7200)

    guard case .sleep(let seconds) = e.next(context) else {
        Issue.record("the engine fetched into a closed market")
        return
    }
    #expect(seconds == 7200 - RateConstants.preOpenWakeLead)
    context.nextRegularOpenEpoch = nil   // the oracle can be absent
    guard case .sleep(let fallback) = e.next(context) else { return }
    #expect(fallback > 0 && fallback <= 3600)
}

@Test func anEmptyWatchlistNeverFetchesAndNeverSpins() throws {
    let clock = FakeClock()
    var e = engine(clock, [])
    guard case .sleep(let seconds) = e.next(openMarket()) else {
        Issue.record("the engine fetched with nothing to fetch")
        return
    }
    #expect(seconds > 0, "a zero sleep with an empty watchlist is a busy loop")
}

@Test func aDeadSymbolIsSkippedForTheRestOfTheSession() throws {
    // Spec §4.3: a 404 means delisted or misspelt. Asking again every three
    // minutes forever wastes the budget on a symbol that will never answer.
    let clock = FakeClock()
    let symbols = [try sym("GONE"), try sym("AAPL")]
    var e = engine(clock, symbols)

    guard case .fetch(let first) = e.next(openMarket()) else { return }
    #expect(first == (try sym("GONE")))
    e.record(.symbolNotFound, for: first)
    #expect(e.deadSymbols.contains(try sym("GONE")))

    for _ in 0..<10 {
        clock.advance(RateConstants.spacingSeconds)
        if case .fetch(let s) = e.next(openMarket()) {
            #expect(s != (try sym("GONE")))
            e.recordSuccess(stubQuote(s), for: s)
        }
    }
}

@Test func aDeadSymbolDoesNotOpenTheCircuitOrStartACooldown() throws {
    // A delisted ticker is the user's problem, not the network's. Treating it
    // as a failure would punish the whole watchlist for one bad entry.
    let clock = FakeClock()
    var e = engine(clock, [try sym("GONE"), try sym("AAPL")])
    guard case .fetch = e.next(openMarket()) else { return }
    for _ in 0..<10 { e.record(.symbolNotFound, for: try sym("GONE")) }
    #expect(e.cooldownUntilEpoch(nowEpoch: 1_757_000_000) == nil)
    clock.advance(RateConstants.spacingSeconds)
    guard case .fetch = e.next(openMarket()) else {
        Issue.record("a dead symbol stopped the whole engine")
        return
    }
}

@Test func everySymbolBeingDeadStopsTheEngineWithoutBusyLooping() throws {
    let clock = FakeClock()
    var e = engine(clock, [try sym("GONE1"), try sym("GONE2")])
    e.record(.symbolNotFound, for: try sym("GONE1"))
    e.record(.symbolNotFound, for: try sym("GONE2"))
    guard case .sleep(let seconds) = e.next(openMarket()) else {
        Issue.record("the engine fetched a dead symbol")
        return
    }
    #expect(seconds > 0)
}

@Test func aRateLimitStopsEverythingForAtLeastTheBackoffBase() throws {
    let clock = FakeClock()
    var e = engine(clock, [try sym("AAPL")])
    guard case .fetch = e.next(openMarket()) else { return }
    e.record(.rateLimited(retryAfterSeconds: nil), for: try sym("AAPL"))

    guard case .sleep(let seconds) = e.next(openMarket()) else {
        Issue.record("the engine kept fetching through a 429")
        return
    }
    #expect(seconds >= RateConstants.rateLimitBackoffBase)
}

@Test func aRetryAfterHeaderIsHonouredWhenYahooSendsOne() throws {
    let clock = FakeClock()
    var e = engine(clock, [try sym("AAPL")])
    guard case .fetch = e.next(openMarket()) else { return }
    e.record(.rateLimited(retryAfterSeconds: 300), for: try sym("AAPL"))

    guard case .sleep(let seconds) = e.next(openMarket()) else { return }
    #expect(seconds >= 300)
}

@Test func fiveConsecutiveTransportFailuresOpenTheNetworkCircuit() throws {
    let clock = FakeClock()
    var e = engine(clock, [try sym("AAPL")])
    for _ in 0..<RateConstants.circuitFailureThreshold {
        e.record(.transport, for: try sym("AAPL"))
    }
    guard case .sleep(let seconds) = e.next(openMarket()) else {
        Issue.record("the circuit did not open after five failures")
        return
    }
    #expect(seconds > 0)

    clock.advance(RateConstants.circuitOpenSeconds + 1)
    guard case .fetch = e.next(openMarket()) else {
        Issue.record("the circuit never went half-open")
        return
    }
}

@Test func oneContractFaultIsEnoughToStopAsking() throws {
    // Spec §4.3: if Yahoo's shape changed, retrying cannot help — every
    // request will fail the same way. Back off for an hour and tell the user.
    let clock = FakeClock()
    var e = engine(clock, [try sym("AAPL")])
    e.record(.missingField(path: "chart.result[0].meta.regularMarketPrice"),
             for: try sym("AAPL"))

    guard case .sleep(let seconds) = e.next(openMarket()) else {
        Issue.record("a contract fault did not stop the engine")
        return
    }
    #expect(seconds > 0)
    clock.advance(RateConstants.contractFaultCooldown / 2)
    guard case .sleep = e.next(openMarket()) else {
        Issue.record("the contract cooldown expired far too early")
        return
    }
}

@Test func aSuccessAfterFailuresClearsTheLadderAndTheCircuit() throws {
    let clock = FakeClock()
    let s = try sym("AAPL")
    var e = engine(clock, [s])
    for _ in 0..<3 { e.record(.transport, for: s) }

    clock.advance(RateConstants.rateLimitBackoffCap)
    guard case .fetch = e.next(openMarket()) else {
        Issue.record("still cooling down long after the cap")
        return
    }
    e.recordSuccess(stubQuote(s), for: s)
    #expect(e.cooldownUntilEpoch(nowEpoch: 1_757_000_000) == nil)
}

@Test func aSuccessfulQuoteIsHeldInMemoryUnderItsSymbol() throws {
    let clock = FakeClock()
    let s = try sym("AAPL")
    var e = engine(clock, [s])
    e.recordSuccess(stubQuote(s, price: 231.5), for: s)
    #expect(e.latest[s]?.price == 231.5)
}

@Test func replacingTheWatchlistDropsQuotesForSymbolsNoLongerWatched() throws {
    // Otherwise the in-memory map grows for the life of the process and can
    // still render a symbol the user deliberately removed.
    let clock = FakeClock()
    let gone = try sym("AAPL")
    let kept = try sym("MSFT")
    var e = engine(clock, [gone, kept])
    e.recordSuccess(stubQuote(gone), for: gone)
    e.recordSuccess(stubQuote(kept), for: kept)

    e.replaceWatchlist([kept])
    #expect(e.latest[gone] == nil)
    #expect(e.latest[kept] != nil)
}

@Test func replacingTheWatchlistAlsoForgetsWhichSymbolsWereDead() throws {
    // The user removing and re-adding a symbol is how they say "try again".
    let clock = FakeClock()
    let s = try sym("GONE")
    var e = engine(clock, [s])
    e.record(.symbolNotFound, for: s)
    #expect(e.deadSymbols.contains(s))

    e.replaceWatchlist([s])
    #expect(e.deadSymbols.isEmpty)
}

@Test func replacingTheWatchlistDoesNotResetTheCooldown() throws {
    // Editing a watchlist must not be a way to escape a 429. Spec §4.3.
    let clock = FakeClock()
    var e = engine(clock, [try sym("AAPL")])
    e.record(.rateLimited(retryAfterSeconds: 600), for: try sym("AAPL"))
    e.replaceWatchlist([try sym("MSFT")])

    guard case .sleep = e.next(openMarket()) else {
        Issue.record("swapping the watchlist cleared a rate-limit cooldown")
        return
    }
}

@Test func aPersistedCooldownSurvivesARestart() throws {
    // The whole reason `cooldownUntilEpoch` is in the store file: relaunching
    // must not be a way around a 429.
    let clock = FakeClock()
    let now: Double = 1_757_000_000
    var e = engine(clock, [try sym("AAPL")])
    e.adoptPersistedCooldown(untilEpoch: now + 900, nowEpoch: now)

    guard case .sleep(let seconds) = e.next(openMarket(now)) else {
        Issue.record("a persisted cooldown was ignored after restart")
        return
    }
    #expect(seconds > 0)
}

@Test func aCooldownDeadlineAlreadyInThePastIsIgnored() throws {
    let clock = FakeClock()
    let now: Double = 1_757_000_000
    var e = engine(clock, [try sym("AAPL")])
    e.adoptPersistedCooldown(untilEpoch: now - 5000, nowEpoch: now)
    guard case .fetch = e.next(openMarket(now)) else {
        Issue.record("an expired cooldown still blocked the engine")
        return
    }
}

@Test func theEngineNeverReturnsAZeroLengthSleep() throws {
    // A zero sleep in the real driver is a spin loop that pins a core. Sweep
    // the states that produce a sleep and assert every one is positive.
    let clock = FakeClock()
    var e = engine(clock, [])
    for state in [MarketState.pre, .regular, .post, .closed] {
        for visibility in [Visibility.visible, .occluded] {
            let context = EngineContext(nowEpoch: 1_757_000_000, marketState: state,
                                        visibility: visibility, lowPowerMode: false,
                                        nextRegularOpenEpoch: nil)
            if case .sleep(let seconds) = e.next(context) {
                #expect(seconds > 0, "\(state)/\(visibility) produced a zero sleep")
            }
        }
    }
}
```

Add the shared stub helper to `Tests/TickerCoreTests/Fakes.swift` (created in Task 8):

```swift
/// A minimal well-formed quote, for tests that care about the engine's
/// bookkeeping rather than about decoding.
func stubQuote(_ symbol: Symbol, price: Double = 100, previousClose: Double = 99) -> Quote {
    Quote(symbol: symbol, shortName: symbol.raw, price: price,
          previousClose: previousClose, currency: "USD", asOfEpoch: 1_757_000_000)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --build-system native --filter FeedEngine`
Expected: FAIL — `cannot find 'FeedEngine' in scope`.

- [ ] **Step 3: Write `FeedEngine`**

`Sources/TickerCore/FeedEngine.swift`:

```swift
/// What the caller knows about the world right now. Everything here comes
/// from outside `TickerCore` — the clock, the market calendar, AppKit's
/// occlusion state, `ProcessInfo`'s low-power flag.
public struct EngineContext: Sendable {
    public var nowEpoch: Double
    public var marketState: MarketState
    public var visibility: Visibility
    public var lowPowerMode: Bool
    public var nextRegularOpenEpoch: Double?

    public init(nowEpoch: Double, marketState: MarketState, visibility: Visibility,
                lowPowerMode: Bool, nextRegularOpenEpoch: Double?) {
        self.nowEpoch = nowEpoch
        self.marketState = marketState
        self.visibility = visibility
        self.lowPowerMode = lowPowerMode
        self.nextRegularOpenEpoch = nextRegularOpenEpoch
    }
}

/// Everything spec §7 wants a diagnostic to show that only a running engine
/// knows. Read-only, no strings: `squigglectl watch` and, later, the app's
/// dropdown each word it themselves.
public struct EngineDiagnostics: Equatable, Sendable {
    public let tokensAvailable: Double
    public let cooldownRemaining: Double
    public let networkCircuit: CircuitState
    public let contractCircuit: CircuitState
    public let deadSymbolCount: Int
}

public enum EngineAction: Equatable, Sendable {
    case fetch(Symbol)
    case sleep(seconds: Double)
}

/// The one object that decides what Squiggle does next.
///
/// It performs no I/O and starts no timers: it is asked `next(_:)` and answers
/// either "fetch this symbol" or "do nothing for this long". Both
/// `squigglectl watch` and plan 2's menu bar app drive this same engine, which
/// is the only reason the budget sweep in Task 12 says anything about the
/// shipping app.
public struct FeedEngine {
    private let clock: any MonotonicClock
    private var pacer: RequestPacer
    private var ladder: BackoffLadder
    /// Two breakers, because the two failures need opposite responses: a flaky
    /// network deserves five chances and half an hour, a changed API shape
    /// deserves one chance and an hour.
    private var networkCircuit: CircuitBreaker
    private var contractCircuit: CircuitBreaker

    private var symbols: [Symbol]
    private var userIntervalSeconds: Double
    private var cursor = 0
    private var cycleDeadline: Double = 0

    private var quotes: [Symbol: Quote] = [:]
    private var dead: Set<Symbol> = []

    public init(clock: any MonotonicClock,
                random: any Randomizing = SystemRandom(),
                symbols: [Symbol],
                userIntervalSeconds: Double) {
        self.clock = clock
        self.pacer = RequestPacer(clock: clock)
        self.ladder = BackoffLadder(clock: clock, random: random)
        self.networkCircuit = CircuitBreaker(clock: clock,
                                             threshold: RateConstants.circuitFailureThreshold,
                                             openSeconds: RateConstants.circuitOpenSeconds)
        self.contractCircuit = CircuitBreaker(clock: clock,
                                              threshold: 1,
                                              openSeconds: RateConstants.contractFaultCooldown)
        self.symbols = symbols
        self.userIntervalSeconds = userIntervalSeconds
    }

    public var latest: [Symbol: Quote] { quotes }
    public var deadSymbols: Set<Symbol> { dead }

    private var liveSymbols: [Symbol] { symbols.filter { !dead.contains($0) } }

    public mutating func next(_ context: EngineContext) -> EngineAction {
        let now = clock.nowSeconds
        let live = liveSymbols

        let decision = RefreshPolicy.decide(RefreshInput(
            nowMonotonic: now,
            nowEpoch: context.nowEpoch,
            marketState: context.marketState,
            visibility: context.visibility,
            lowPowerMode: context.lowPowerMode,
            userIntervalSeconds: userIntervalSeconds,
            watchlistCount: live.count,
            nextRegularOpenEpoch: context.nextRegularOpenEpoch,
            isCoolingDown: ladder.isCoolingDown(),
            cooldownRemaining: ladder.secondsRemaining(),
            circuitAllows: networkCircuit.allowsRequest() && contractCircuit.allowsRequest(),
            circuitOpenRemaining: max(networkCircuit.secondsRemaining(),
                                      contractCircuit.secondsRemaining())))

        if case .wait(let seconds) = decision {
            // A zero here would be a spin loop in the driver. The policy is
            // supposed to prevent that; this is the belt to its braces.
            return .sleep(seconds: max(1, seconds))
        }

        guard !live.isEmpty else {
            return .sleep(seconds: RefreshPolicy.cycleInterval(
                userIntervalSeconds: userIntervalSeconds, watchlistCount: 0,
                marketState: context.marketState, visibility: context.visibility,
                lowPowerMode: context.lowPowerMode))
        }

        // A cycle in progress finishes before a new one starts; otherwise a
        // long watchlist would restart from the top forever and the symbols at
        // the end would never update.
        if cursor >= live.count {
            guard now >= cycleDeadline else {
                return .sleep(seconds: max(1, cycleDeadline - now))
            }
            cursor = 0
            cycleDeadline = now + RefreshPolicy.cycleInterval(
                userIntervalSeconds: userIntervalSeconds, watchlistCount: live.count,
                marketState: context.marketState, visibility: context.visibility,
                lowPowerMode: context.lowPowerMode)
        }

        // The bucket is the last word. Nothing below this line can bypass it.
        guard pacer.take() else {
            return .sleep(seconds: max(1, pacer.secondsUntilNextToken()))
        }

        let symbol = live[cursor]
        cursor += 1
        return .fetch(symbol)
    }

    public mutating func recordSuccess(_ quote: Quote, for symbol: Symbol) {
        quotes[symbol] = quote
        ladder.recordSuccess()
        networkCircuit.recordSuccess()
        contractCircuit.recordSuccess()
    }

    public mutating func record(_ error: TickerError, for symbol: Symbol) {
        let kind = FailureKind(error)

        switch kind {
        case .deadSymbol:
            // Not a failure of anything Squiggle controls. It must not open a
            // circuit, or one delisted ticker would stop the whole watchlist.
            dead.insert(symbol)
            return

        case .contractFault:
            contractCircuit.recordFailure()

        case .rateLimited:
            // Straight to open: a 429 means we are already over the line, and
            // four more strikes to confirm it is four more strikes.
            networkCircuit.trip()
            pacer.halveCapacity()

        case .offline, .server, .unauthorized:
            networkCircuit.recordFailure()
        }

        ladder.record(kind)
    }

    public mutating func replaceWatchlist(_ newSymbols: [Symbol]) {
        symbols = newSymbols
        let watched = Set(newSymbols)
        // Drop what is no longer watched: otherwise the map grows for the life
        // of the process and can still render a symbol the user removed.
        quotes = quotes.filter { watched.contains($0.key) }
        // Re-adding a symbol is how a user says "try that one again".
        dead = []
        cursor = 0
        cycleDeadline = 0
        // Deliberately NOT reset: `ladder`, both circuits and `pacer`. Editing
        // a watchlist is not a way around a 429.
    }

    public mutating func setUserInterval(_ seconds: Double) {
        userIntervalSeconds = seconds
        cycleDeadline = 0
    }

    /// The cooldown deadline as a wall-clock epoch, for `Store`.
    public mutating func diagnostics() -> EngineDiagnostics
    public func cooldownUntilEpoch(nowEpoch: Double) -> Double? {
        guard ladder.isCoolingDown() else { return nil }
        return nowEpoch + ladder.secondsRemaining()
    }

    public mutating func adoptPersistedCooldown(untilEpoch: Double, nowEpoch: Double) {
        ladder.adoptPersistedCooldown(secondsRemaining: untilEpoch - nowEpoch)
    }
}
```

> `CircuitBreaker.secondsRemaining()` comes from Task 10. Taking the maximum
> across both breakers is what makes the reported wait the wait that actually
> applies: a caller told to sleep for the network breaker while the contract
> breaker still has fifty minutes left would wake up to another refusal.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --build-system native --filter FeedEngine`
Expected: PASS.

- [ ] **Step 5: Write the headless driver**

`Sources/squigglectl/WatchLoop.swift`:

```swift
import Foundation
import TickerCore
import YahooFeed

/// Runs the real engine against the real endpoint, printing one line per
/// event. This is what Task 19's trading-day verification leaves running.
///
/// It deliberately duplicates none of the engine's decisions: it asks, obeys,
/// and reports. If this loop ever grows a rule of its own, that rule belongs
/// in `FeedEngine` where the tests can reach it.
struct WatchLoop {
    let client: YahooClient
    let store: FileWatchlistStore
    let symbols: [Symbol]
    let intervalSeconds: Double
    let maxCycles: Int?

    func run() async -> Int32 {
        let clock = SystemClock()
        var engine = FeedEngine(clock: clock, symbols: symbols,
                                userIntervalSeconds: intervalSeconds)

        if let persisted = try? store.load().cooldownUntilEpoch {
            engine.adoptPersistedCooldown(untilEpoch: persisted,
                                          nowEpoch: Date().timeIntervalSince1970)
            log("adopted a persisted cooldown")
        }

        var fetches = 0
        while maxCycles == nil || fetches < (maxCycles ?? 0) {
            let now = Date().timeIntervalSince1970
            let context = EngineContext(
                nowEpoch: now,
                // The CLI has no market calendar of its own; it uses the one
                // Yahoo already told it about, which is exactly what the app
                // will do. Before the first successful quote it assumes the
                // market is open — one wasted request beats never starting.
                marketState: marketState ?? .regular,
                visibility: .visible,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                nextRegularOpenEpoch: nextOpen)

            switch engine.next(context) {
            case .sleep(let seconds):
                log("sleep \(Int(seconds))s")
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

            case .fetch(let symbol):
                fetches += 1
                do {
                    // ONE request. The quote and the market calendar both come
                    // out of the same body (spec §3.2); asking a second
                    // endpoint for the calendar would double the daily budget.
                    let snapshot = try await client.snapshot(for: symbol)
                    engine.recordSuccess(snapshot.quote, for: symbol)
                    log(Rendering.line(snapshot.quote))
                    if let period = snapshot.tradingPeriod {
                        marketState = period.state(atEpoch: now)
                        nextOpen = period.nextRegularOpenEpoch(after: now)
                    }
                } catch let error as TickerError {
                    engine.record(error, for: symbol)
                    log("\(symbol.raw): \(Rendering.diagnosis(error))")
                } catch {
                    engine.record(.transport, for: symbol)
                    log("\(symbol.raw): transport")
                }
            }
        }
        return 0
    }
}
```

> `marketState` and `nextOpen` are `var`s on the loop, updated from the same
> response the quote came from. Declare them alongside the other properties,
> both starting `nil`.
>
> This needs one addition to `YahooClient` in the same commit — a single
> request that yields both values, since `Quote` and `TradingPeriod` are parsed
> from one body:
>
> ```swift
> public struct Snapshot: Sendable {
>     public let quote: Quote
>     public let tradingPeriod: TradingPeriod?
> }
>
> extension YahooClient {
>     public func snapshot(for symbol: Symbol) async throws -> Snapshot {
>         let data = try await fetch(symbol)
>         return Snapshot(quote: try YahooQuoteDecoding.quote(from: data, symbol: symbol),
>                         tradingPeriod: try? YahooQuoteDecoding.tradingPeriod(from: data))
>     }
> }
> ```
>
> `fetch(_:)` from Task 2 stays as it is — `squigglectl quote` has no use for
> the calendar, and `snapshot(for:)` is a decode of the body `fetch(_:)` already
> returns. One request, both facts, and only one place `URLSession` is touched,
> so both are paced.

Add the verb to `Command`:

```swift
case watch(symbols: [Symbol], intervalSeconds: Double, maxCycles: Int?)
```

parsed from `squigglectl watch AAPL MSFT [--interval 180] [--cycles N]`, with
an unparseable symbol rejected by name and `--interval` clamped into
`RateConstants.refreshIntervalChoices`' range rather than silently accepted.
With no symbols given, `watch` reads the watchlist from the store file.

Extend `usage`:

```
  squigglectl watch [SYMBOL...] [--interval N] [--cycles N]
```

```
  --interval N at least 30 seconds between refresh cycles (default 180)
  --cycles N   stop after N fetches instead of running until interrupted
```

- [ ] **Step 6: Run the whole suite**

Run: `swift test --build-system native`
Expected: PASS.

- [ ] **Step 7: Smoke-test the loop**

```bash
swift run --build-system native squigglectl watch AAPL MSFT --cycles 4
```

Expected: four quote lines, roughly 30 seconds apart, then exit 0. If they
arrive back-to-back with no pause, the pacer is being bypassed — stop and fix
that before Task 19.

- [ ] **Step 8: Commit**

```bash
git add Sources/TickerCore/FeedEngine.swift Sources/squigglectl/ \
        Tests/TickerCoreTests/FeedEngineTests.swift Tests/TickerCoreTests/Fakes.swift
git commit -m "feat: the single engine both the CLI and the app will drive"
```

---

## Task 17: `squigglectl doctor`

Spec §7. When a user writes in to say "it stopped updating", the answer has to be recoverable without a debugger and without asking them to paste anything secret. `doctor` runs the checks, prints them, and exits with a code that says how bad it is.

It touches the network exactly twice — one quote, one search — because a diagnostic that costs fifty requests is a diagnostic that causes the problem it is looking for.

The interesting part of this task is the layering. **`TickerCore` vends no user-facing strings**, so the diagnosis is a set of enum codes and `squigglectl` owns every word printed. That is what makes the classification testable without asserting on English.

**Files:**
- Create: `Sources/TickerCore/Diagnosis.swift`
- Modify: `Sources/squigglectl/Command.swift` — add the `doctor` verb
- Modify: `Sources/squigglectl/Rendering.swift` — the words for each check
- Create: `Sources/squigglectl/DoctorRun.swift`
- Modify: `Sources/squigglectl/main.swift` — dispatch `doctor`
- Test: `Tests/TickerCoreTests/DiagnosisTests.swift`
- Test: `Tests/squigglectlTests/RenderingTests.swift`

**Interfaces:**
- Consumes: `TickerError`, `RateConstants`, `RefreshPolicy`, `Store`, `FileWatchlistStore`, `YahooClient`.
- Produces:
  - `TickerCore.CheckID` — `enum: String, CaseIterable, Sendable`: `quoteEndpoint`, `searchEndpoint`, `tradingPeriods`, `storeFile`, `storeSchema`, `setAsideFiles`, `cooldown`, `budget`.
  - `TickerCore.CheckStatus` — `enum: Equatable, Sendable`: `ok`, `degraded`, `broken`, `skipped`.
  - `TickerCore.Check` — `struct: Equatable, Sendable`: `id: CheckID`, `status: CheckStatus`.
  - `TickerCore.Diagnosis` — `enum`:
    - `static func status(for error: TickerError?) -> CheckStatus`
    - `static func overall(_ checks: [Check]) -> CheckStatus`
    - `static func exitCode(for status: CheckStatus) -> Int32`
    - `static func estimatedDailyRequests(userIntervalSeconds: Double, watchlistCount: Int) -> Int`

- [ ] **Step 1: Write the failing tests**

`Tests/TickerCoreTests/DiagnosisTests.swift`:

```swift
import Testing
@testable import TickerCore

@Test func noErrorIsAHealthyCheck() {
    #expect(Diagnosis.status(for: nil) == .ok)
}

@Test func aRateLimitIsDegradedRatherThanBroken() {
    // Being throttled means the endpoint is working and Squiggle asked too
    // often. Reporting it as "broken" sends the user hunting for a fault
    // that does not exist.
    #expect(Diagnosis.status(for: .rateLimited(retryAfterSeconds: nil)) == .degraded)
    #expect(Diagnosis.status(for: .rateLimited(retryAfterSeconds: 120)) == .degraded)
}

@Test func beingOfflineIsDegradedBecauseItIsAlmostNeverSquigglesFault() {
    #expect(Diagnosis.status(for: .offline) == .degraded)
    #expect(Diagnosis.status(for: .transport) == .degraded)
}

@Test func aServerErrorIsDegraded() {
    #expect(Diagnosis.status(for: .serverError(status: 503)) == .degraded)
}

@Test func aContractFaultIsBrokenBecauseNoAmountOfWaitingFixesIt() {
    // Spec §4.3: if the response shape changed, every future request fails
    // identically. That is the one class of fault worth a loud red line.
    #expect(Diagnosis.status(for: .missingField(path: "chart.result[0].meta")) == .broken)
    #expect(Diagnosis.status(for: .wrongType(path: "meta.regularMarketPrice",
                                             expected: "number")) == .broken)
    #expect(Diagnosis.status(for: .noResult) == .broken)
    #expect(Diagnosis.status(for: .notJSON) == .broken)
}

@Test func anUnauthorizedResponseIsBroken() {
    // Spec §3.1: this is the failure mode that ends the project. It must
    // never be reported as a transient blip.
    #expect(Diagnosis.status(for: .unauthorized(status: 401)) == .broken)
}

@Test func aMissingSymbolIsTheUsersTypoAndNotAFault() {
    #expect(Diagnosis.status(for: .symbolNotFound) == .degraded)
    #expect(Diagnosis.status(for: .invalidSymbol) == .degraded)
}

@Test func everyErrorCaseHasAStatusAndNoneFallThrough() {
    // A new TickerError case that nobody classified would silently report as
    // whatever the default branch says. Enumerate them explicitly.
    let all: [TickerError] = [
        .invalidSymbol, .offline, .transport, .rateLimited(retryAfterSeconds: nil),
        .serverError(status: 500), .unauthorized(status: 401), .symbolNotFound,
        .emptyBody, .notJSON, .noResult, .missingField(path: "x"),
        .wrongType(path: "x", expected: "number"), .nonFiniteNumber(path: "x"),
        .negativeValue(path: "x", value: -1),
        .storeSchemaUnsupported(version: 99),
        .storeCorrupt(quarantinedAt: URL(fileURLWithPath: "/tmp/x")),
    ]
    for error in all {
        #expect(Diagnosis.status(for: error) != .skipped,
                "\(error) was never classified")
    }
}

@Test func theWorstCheckDecidesTheOverallResult() {
    #expect(Diagnosis.overall([Check(id: .quoteEndpoint, status: .ok)]) == .ok)
    #expect(Diagnosis.overall([
        Check(id: .quoteEndpoint, status: .ok),
        Check(id: .searchEndpoint, status: .degraded),
    ]) == .degraded)
    #expect(Diagnosis.overall([
        Check(id: .quoteEndpoint, status: .degraded),
        Check(id: .searchEndpoint, status: .broken),
    ]) == .broken)
}

@Test func skippedChecksDoNotDragTheOverallResultDown() {
    // A check skipped because an earlier one already failed says nothing
    // about health, and counting it would double-report one fault.
    #expect(Diagnosis.overall([
        Check(id: .quoteEndpoint, status: .ok),
        Check(id: .searchEndpoint, status: .skipped),
    ]) == .ok)
}

@Test func anEmptyRunIsNotSilentlyHealthy() {
    // Zero checks means the run itself failed. Reporting "ok" would be worse
    // than useless.
    #expect(Diagnosis.overall([]) == .broken)
}

@Test func exitCodesDistinguishTheThreeOutcomes() {
    // A script wrapping `doctor` needs to tell "throttled, try later" from
    // "this build is finished".
    #expect(Diagnosis.exitCode(for: .ok) == 0)
    #expect(Diagnosis.exitCode(for: .degraded) == 1)
    #expect(Diagnosis.exitCode(for: .broken) == 2)
    #expect(Diagnosis.exitCode(for: .skipped) == 0)
}

@Test func theBudgetEstimateMatchesTheSweepsWorstCase() {
    // Task 12 measures the real number by simulation; this is the closed-form
    // version the user sees. They must not contradict each other.
    let estimate = Diagnosis.estimatedDailyRequests(userIntervalSeconds: 60,
                                                    watchlistCount: 20)
    #expect(estimate > 0)
    #expect(estimate <= 1_200)
}

@Test func theBudgetEstimateIsFlatAcrossWatchlistSizesAtTheSpacingFloor() {
    // The invariant from spec §4.2, restated where a user can see it: once
    // the 30s floor binds, adding symbols costs nothing per day.
    let small = Diagnosis.estimatedDailyRequests(userIntervalSeconds: 60, watchlistCount: 4)
    let large = Diagnosis.estimatedDailyRequests(userIntervalSeconds: 60, watchlistCount: 20)
    #expect(small == large)
}

@Test func aLongerRefreshIntervalEstimatesFewerRequests() {
    let fast = Diagnosis.estimatedDailyRequests(userIntervalSeconds: 60, watchlistCount: 2)
    let slow = Diagnosis.estimatedDailyRequests(userIntervalSeconds: 900, watchlistCount: 2)
    #expect(slow < fast)
}

@Test func anEmptyWatchlistEstimatesNoRequests() {
    #expect(Diagnosis.estimatedDailyRequests(userIntervalSeconds: 60, watchlistCount: 0) == 0)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --build-system native --filter Diagnosis`
Expected: FAIL — `cannot find 'Diagnosis' in scope`.

- [ ] **Step 3: Write `Diagnosis`**

`Sources/TickerCore/Diagnosis.swift`:

```swift
/// Which check produced a result. A code, not a sentence: `TickerCore` vends
/// no user-facing strings, so `squigglectl` and the app each supply their own
/// wording for the same diagnosis.
public enum CheckID: String, CaseIterable, Sendable {
    case quoteEndpoint
    case searchEndpoint
    case tradingPeriods
    case storeFile
    case storeSchema
    case setAsideFiles
    case cooldown
    case budget
}

public enum CheckStatus: Equatable, Sendable {
    case ok
    /// Working, but not right now — throttled, offline, one bad symbol.
    /// Waiting or fixing the input resolves it.
    case degraded
    /// Waiting cannot help. Either the API changed shape or it started
    /// demanding credentials Squiggle deliberately does not hold.
    case broken
    /// Not run, usually because an earlier check made it pointless.
    case skipped
}

public struct Check: Equatable, Sendable {
    public let id: CheckID
    public let status: CheckStatus

    public init(id: CheckID, status: CheckStatus) {
        self.id = id
        self.status = status
    }
}

public enum Diagnosis {
    public static func status(for error: TickerError?) -> CheckStatus {
        guard let error else { return .ok }
        if error.isContractFault { return .broken }

        switch error {
        case .unauthorized:
            // Spec §3.1. If Yahoo starts demanding a crumb, Squiggle's whole
            // premise is gone; this is never a transient blip.
            return .broken
        case .offline, .transport, .rateLimited, .serverError,
             .symbolNotFound, .invalidSymbol:
            return .degraded
        case .storeSchemaUnsupported, .storeCorrupt:
            return .degraded
        default:
            // Everything left is a contract fault caught above; this branch
            // exists only for totality.
            return .broken
        }
    }

    public static func overall(_ checks: [Check]) -> CheckStatus {
        // Zero checks means the run itself fell over. "ok" would be a lie.
        guard !checks.isEmpty else { return .broken }
        if checks.contains(where: { $0.status == .broken }) { return .broken }
        if checks.contains(where: { $0.status == .degraded }) { return .degraded }
        return .ok
    }

    public static func exitCode(for status: CheckStatus) -> Int32 {
        switch status {
        case .ok, .skipped: return 0
        case .degraded: return 1
        case .broken: return 2
        }
    }

    /// The closed-form version of Task 12's simulation, for showing the user
    /// what their settings cost. Both must agree: if the sweep's worst case
    /// ever exceeds this, one of the two is wrong.
    public static func estimatedDailyRequests(userIntervalSeconds: Double,
                                              watchlistCount: Int) -> Int {
        guard watchlistCount > 0 else { return 0 }

        let cycle = RefreshPolicy.cycleInterval(
            userIntervalSeconds: userIntervalSeconds,
            watchlistCount: watchlistCount,
            marketState: .regular,
            visibility: .visible,
            lowPowerMode: false)

        // Squiggle only fetches while some session is open. Pre-market through
        // post-market is 16 hours, and the quiet multiplier already thins the
        // pre and post stretches, so 16 hours at the regular rate is an
        // over-estimate — which is the right direction for a budget figure.
        let activeSeconds: Double = 16 * 3600
        return Int((activeSeconds / cycle).rounded(.down)) * watchlistCount
    }
}
```

> `estimatedDailyRequests` at 60s × 20 symbols: the cycle floor makes the cycle
> `20 × 30 = 600s`, so `(57,600 / 600) = 96` cycles × 20 = **1,920** — over
> budget. That is deliberate and it is why the test asserts `<= 1_200`: the
> test will fail, and the fix is to cap the estimate at the pacer's real
> ceiling, which is what actually binds:
>
> ```swift
> let pacerCeiling = Int((activeSeconds / RateConstants.spacingSeconds).rounded(.down))
> return min(Int((activeSeconds / cycle).rounded(.down)) * watchlistCount, pacerCeiling)
> ```
>
> Write the naive version first, watch the test fail, then add the cap. The
> failure is the lesson: **the spacing floor, not the cycle interval, is what
> bounds the day** — the same fact §4.2 derives and Task 12 measures.

- [ ] **Step 4: Run, watch the budget test fail, apply the cap**

Run: `swift test --build-system native --filter Diagnosis`
Expected: FAIL on `theBudgetEstimateMatchesTheSweepsWorstCase` and
`theBudgetEstimateIsFlatAcrossWatchlistSizesAtTheSpacingFloor`.
Apply the `pacerCeiling` cap above, then re-run.
Expected: PASS.

- [ ] **Step 5: Write the CLI side**

`Sources/squigglectl/DoctorRun.swift` runs the checks in this order and stops
touching the network as soon as it is pointless:

1. `quoteEndpoint` — one `client.snapshot(for:)` for `AAPL`.
2. `searchEndpoint` — one `client.searchResults(query: "apple", limit: 1)`, **skipped**
   if the quote check came back `.broken`; a second request cannot add
   information once the API's shape is known to have changed.
3. `tradingPeriods` — resolve `pre`/`regular`/`post` from the snapshot check 1
   **already fetched**, and print them with the state they imply right now.
   Costs nothing: spec §3.2 puts the calendar in the same body as the quote.
   `.degraded` if the periods are absent or do not bracket each other.
4. `storeFile` — can the store file be read? A missing file is `.ok`.
5. `storeSchema` — `.degraded` on `storeSchemaUnsupported`.
6. `setAsideFiles` — any `squiggle.json.bad-*` next to the store file; their
   presence is `.degraded` and their **names only** are printed.
7. `cooldown` — is `cooldownUntilEpoch` in the future?
8. `budget` — `Diagnosis.estimatedDailyRequests` for the stored settings;
   `.degraded` if it exceeds 1,200.

**What `doctor` deliberately does not report.** Spec §7 asks the diagnostic to
show resolved trading periods, circuit and bucket state, the last N status
codes, and per-symbol field presence. Two of those a separate process cannot
see: circuit and bucket state live in a running `FeedEngine`'s memory, and so
does the recent-status history. Persisting them to reach `doctor` would mean
writing a request log to disk, which cuts against the one persistence rule
this project will not bend — the store file must stay safe to email.

So they are split by who can actually answer:

| §7 asks for | Delivered by |
| --- | --- |
| Resolved trading periods | `doctor`, check 3 above — free, from the snapshot it already has |
| Per-symbol field presence | `squigglectl probe <SYMBOL>` (Task 18), on demand, one symbol at a time |
| Circuit and bucket state | `squigglectl watch` (Task 16), which drives the engine in-process |
| Last N status codes | `squigglectl watch`, same reason; the app's dropdown in plan 2 |

Add the state line to `WatchLoop` in this task: after each event it prints
tokens available, both circuit states, and the ladder's remaining cooldown.
That is the whole of §7's live diagnosis, and it costs no requests because the
loop is already making them.

Every word lives in `Rendering`:

```swift
static func describe(_ id: CheckID) -> String {
    switch id {
    case .quoteEndpoint:  return "quote endpoint"
    case .searchEndpoint: return "search endpoint"
    case .tradingPeriods: return "trading calendar"
    case .storeFile:      return "settings file"
    case .storeSchema:    return "settings file version"
    case .setAsideFiles:  return "earlier unreadable settings files"
    case .cooldown:       return "backoff"
    case .budget:         return "daily request estimate"
    }
}

static func mark(_ status: CheckStatus) -> String {
    switch status {
    case .ok:       return "ok"
    case .degraded: return "warn"
    case .broken:   return "FAIL"
    case .skipped:  return "skip"
    }
}
```

**`doctor` prints no quote values, no file contents and no URLs with query
strings.** Its output is meant to be pasteable into an email, and the whole
point of never persisting a credential is undone if the diagnostic prints one.

- [ ] **Step 6: Test the wording layer**

`Tests/squigglectlTests/RenderingTests.swift`:

```swift
@Test func everyCheckHasWordingAndNoneIsBlank() {
    // A check that prints an empty label looks like a rendering bug to the
    // one person least able to diagnose it.
    for id in CheckID.allCases {
        #expect(!Rendering.describe(id).isEmpty)
    }
}

@Test func theFourStatusesReadDifferently() {
    let marks = [CheckStatus.ok, .degraded, .broken, .skipped].map(Rendering.mark)
    #expect(Set(marks).count == 4)
}
```

- [ ] **Step 7: Run it**

```bash
swift run --build-system native squigglectl doctor; echo "exit: $?"
```

Expected: eight labelled lines and `exit: 0`. An `exit: 2` on
`quote endpoint` means the endpoint check from Task 2 has regressed — stop and
read the spec's §3.1 branch before continuing.

- [ ] **Step 8: Commit**

```bash
git add Sources/TickerCore/Diagnosis.swift Sources/squigglectl/ \
        Tests/TickerCoreTests/DiagnosisTests.swift Tests/squigglectlTests/RenderingTests.swift
git commit -m "feat: doctor, two requests and no secrets in the output"
```

---

## Task 18: `squigglectl probe` — watching for contract drift

Squiggle depends on an endpoint nobody promised to keep stable. The mutation suite in Task 6 proves Squiggle *notices* when a field it reads goes missing. `probe` is the other half: it says **what changed**, by comparing the live response's shape against the fixture recorded on 2026-09-08.

This is the tool that turns "it broke and I don't know why" into "`meta.regularMarketPrice` became a string".

**Files:**
- Create: `Sources/TickerCore/ShapeDigest.swift`
- Modify: `Sources/squigglectl/Command.swift` — add the `probe` verb
- Modify: `Sources/squigglectl/Rendering.swift` — wording for each change kind
- Create: `Sources/squigglectl/ProbeRun.swift`
- Modify: `Sources/squigglectl/main.swift` — dispatch `probe`
- Modify: `docs/fixture-capture-log.md` — note that `--record` is how fixtures are refreshed
- Test: `Tests/TickerCoreTests/ShapeDigestTests.swift`

**Interfaces:**
- Consumes: `TickerError`, the Task 3 fixtures, and Task 6's `readFields`.
  **These are two different spellings of one fact and they must not be allowed
  to drift.** `readFields` is `[[String]]` — path components with a concrete
  array index (`["chart", "result", "0", "meta", "shortName"]`), because the
  mutation suite navigates the document with it. `readPaths` is `[String]` —
  dotted, with `[]` standing for any index
  (`"chart.result[].meta.shortName"`), because a digest folds every element of
  an array onto one path. Neither can be derived from the other without losing
  what the other needs, so both stay and a test below asserts they describe the
  same set. Task 6 already declares `readFields` without `private` for exactly
  this reason — if you find a `private` there, drop it; it stays internal to the
  test target.
- Produces:
  - `TickerCore.ValueType` — `enum: String, Equatable, Sendable`: `number`, `string`, `bool`, `null`, `object`, `array`.
  - `TickerCore.ShapeChange` — `enum: Equatable, Sendable`: `case missing(path: String, wasType: ValueType)`, `case added(path: String, type: ValueType)`, `case typeChanged(path: String, from: ValueType, to: ValueType)`; `var path: String`; `var breaksSquiggle: Bool`.
  - `TickerCore.ShapeDigest` — `struct: Equatable, Sendable`: `let paths: [String: ValueType]`; `static func digest(of data: Data) throws -> ShapeDigest`; `static func diff(recorded: ShapeDigest, live: ShapeDigest) -> [ShapeChange]`; `static let readPaths: [String]`; `static let requiredPaths: [String]`.

- [ ] **Step 1: Write the failing tests**

`Tests/TickerCoreTests/ShapeDigestTests.swift`:

```swift
import Foundation
import Testing
@testable import TickerCore

private func digest(_ json: String) throws -> ShapeDigest {
    try ShapeDigest.digest(of: Data(json.utf8))
}

@Test func nestedObjectsBecomeDottedPaths() throws {
    let d = try digest(#"{"chart":{"result":{"meta":{"symbol":"AAPL"}}}}"#)
    #expect(d.paths["chart.result.meta.symbol"] == .string)
}

@Test func arrayIndicesCollapseToASinglePlaceholder() throws {
    // A day of one-minute candles is 390 entries. Recording each index would
    // make every diff a wall of noise and every fixture refresh a rewrite.
    let d = try digest(#"{"a":[{"x":1},{"x":2},{"x":3}]}"#)
    #expect(d.paths["a[].x"] == .number)
    #expect(d.paths.keys.filter { $0.contains("a[") }.count == 1)
}

@Test func everyJsonTypeIsDistinguished() throws {
    let d = try digest("""
    {"n":1,"s":"x","b":true,"z":null,"o":{"k":1},"a":[1]}
    """)
    #expect(d.paths["n"] == .number)
    #expect(d.paths["s"] == .string)
    #expect(d.paths["b"] == .bool)
    #expect(d.paths["z"] == .null)
    #expect(d.paths["o"] == .object)
    #expect(d.paths["a"] == .array)
}

@Test func aBooleanIsNotReportedAsANumber() throws {
    // JSONSerialization bridges true/false to NSNumber on Darwin, so a naive
    // type check reports every bool as a number and the diff misses the one
    // change most likely to break a decoder.
    let d = try digest(#"{"b":true,"n":1}"#)
    #expect(d.paths["b"] == .bool)
    #expect(d.paths["n"] == .number)
}

@Test func anIdenticalResponseProducesNoChanges() throws {
    let d = try digest(#"{"a":{"b":1}}"#)
    #expect(ShapeDigest.diff(recorded: d, live: d).isEmpty)
}

@Test func aFieldThatDisappearedIsReportedAsMissing() throws {
    let before = try digest(#"{"a":1,"b":2}"#)
    let after = try digest(#"{"a":1}"#)
    #expect(ShapeDigest.diff(recorded: before, live: after)
        == [.missing(path: "b", wasType: .number)])
}

@Test func aNewFieldIsReportedAsAddedRatherThanIgnored() throws {
    // A new field is usually harmless, but it is also how Yahoo signals a
    // migration before removing the old one. Worth seeing.
    let before = try digest(#"{"a":1}"#)
    let after = try digest(#"{"a":1,"b":2}"#)
    #expect(ShapeDigest.diff(recorded: before, live: after)
        == [.added(path: "b", type: .number)])
}

@Test func aTypeChangeIsReportedAsOneChangeAndNotAsAPairOfEdits() throws {
    let before = try digest(#"{"a":1}"#)
    let after = try digest(#"{"a":"1"}"#)
    #expect(ShapeDigest.diff(recorded: before, live: after)
        == [.typeChanged(path: "a", from: .number, to: .string)])
}

@Test func changesAreOrderedStablySoTheOutputIsDiffable() throws {
    let before = try digest(#"{"z":1,"a":1,"m":1}"#)
    let after = try digest(#"{"q":1}"#)
    let changes = ShapeDigest.diff(recorded: before, live: after)
    #expect(changes.map(\.path) == changes.map(\.path).sorted())
}

@Test func aChangeToAFieldSquiggleReadsIsFlaggedAsBreaking() throws {
    let path = "chart.result[].meta.regularMarketPrice"
    #expect(ShapeDigest.readPaths.contains(path),
            "the read-path list has drifted from the decoder")
    #expect(ShapeChange.typeChanged(path: path, from: .number, to: .object).breaksSquiggle)
    #expect(ShapeChange.missing(path: path, wasType: .number).breaksSquiggle)
}

/// `["chart","result","0","meta","shortName"]` → `"chart.result[].meta.shortName"`.
private func dotted(_ components: [String]) -> String {
    components.map { $0 == "0" ? "[]" : $0 }
        .joined(separator: ".")
        .replacingOccurrences(of: ".[].", with: "[].")
}

@Test func theTwoListsOfFieldsWeDependOnDescribeTheSameSet() {
    // Task 6's mutation suite and this digest carry two spellings of one fact:
    // which fields Squiggle reads. Adding a field to one and forgetting the
    // other leaves a real dependency either untested or unwatched, and nothing
    // else in the suite would notice.
    let period = "chart.result[].meta.currentTradingPeriod"

    // The mutation suite stops at the trading-period object, because mutating
    // a container already covers every child; the digest names each boundary.
    // Collapse the digest's six down to the one they share.
    let watched = Set(ShapeDigest.readPaths.map {
        $0.hasPrefix(period + ".") ? period : $0
    })
    // Entries shorter than five components are the containers on the way down.
    let mutated = Set(readFields.filter { $0.count > 4 }.map(dotted))

    #expect(watched == mutated,
            "readFields and readPaths have drifted: \(watched.symmetricDifference(mutated))")
}

@Test func everyRequiredPathIsAlsoAWatchedPath() {
    for path in ShapeDigest.requiredPaths {
        #expect(ShapeDigest.readPaths.contains(path),
                "\(path) is required but nothing watches it")
    }
}

@Test func aFieldWithAFallbackGoingMissingIsNotBreaking() {
    // Task 5 falls back from `chartPreviousClose` to `previousClose`, and from
    // a missing name to the symbol itself. Reporting those as breaking would
    // send someone fixing a decoder that already copes.
    #expect(!ShapeChange.missing(path: "chart.result[].meta.previousClose",
                                 wasType: .number).breaksSquiggle)
    #expect(!ShapeChange.missing(path: "chart.result[].meta.shortName",
                                 wasType: .string).breaksSquiggle)
    // The price has nothing behind it.
    #expect(ShapeChange.missing(path: "chart.result[].meta.regularMarketPrice",
                                wasType: .number).breaksSquiggle)
}

@Test func aChangeToAFieldSquiggleIgnoresIsNotBreaking() throws {
    // Yahoo adds and removes fields Squiggle has never read. Flagging those as
    // breaking would train the reader to ignore the tool.
    #expect(!ShapeChange.added(path: "chart.result[].meta.gmtoffset", type: .number)
        .breaksSquiggle)
    #expect(!ShapeChange.missing(path: "chart.result[].indicators.adjclose", wasType: .array)
        .breaksSquiggle)
}

@Test func aNumberToStringChangeOnAPriceIsNotBreakingBecauseLenientDoubleHandlesIt() throws {
    // Task 4 exists precisely because Yahoo has sent prices as strings before.
    // Reporting that as breaking would be wrong — the decoder already copes.
    #expect(!ShapeChange.typeChanged(path: "chart.result[].meta.regularMarketPrice",
                                     from: .number, to: .string).breaksSquiggle)
}

@Test func theRecordedFixtureStillMatchesItself() throws {
    // A regression guard on the digester rather than on Yahoo: if this fails,
    // the digester changed, not the API.
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/yahoo-2026-09-08/regular-session.json")
    let d = try ShapeDigest.digest(of: Data(contentsOf: url))
    #expect(ShapeDigest.diff(recorded: d, live: d).isEmpty)
    // Only the required paths must be present. Yahoo omits some optional
    // fields on some listings, and failing over one of those would make this
    // test a report on Yahoo's mood rather than on the digester.
    for path in ShapeDigest.requiredPaths {
        #expect(d.paths[path] != nil, "the fixture has no \(path); the list is stale")
    }
}

@Test func digestingSomethingThatIsNotJsonThrowsRatherThanReturningEmpty() throws {
    // An empty digest would diff as "every field disappeared", which reads as
    // a catastrophic API change when it is really an error page.
    #expect(throws: TickerError.notJSON) {
        try ShapeDigest.digest(of: Data("<html>429</html>".utf8))
    }
}

@Test func digestingSurvivesEveryTruncationOfTheFixture() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/yahoo-2026-09-08/regular-session.json")
    let data = try Data(contentsOf: url)
    for length in stride(from: 0, to: data.count, by: 11) {
        _ = try? ShapeDigest.digest(of: Data(data.prefix(length)))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --build-system native --filter ShapeDigest`
Expected: FAIL — `cannot find 'ShapeDigest' in scope`.

- [ ] **Step 3: Write `ShapeDigest`**

`Sources/TickerCore/ShapeDigest.swift`:

```swift
import Foundation

public enum ValueType: String, Equatable, Sendable {
    case number, string, bool, null, object, array
}

public enum ShapeChange: Equatable, Sendable {
    case missing(path: String, wasType: ValueType)
    case added(path: String, type: ValueType)
    case typeChanged(path: String, from: ValueType, to: ValueType)

    public var path: String {
        switch self {
        case .missing(let p, _), .added(let p, _), .typeChanged(let p, _, _): return p
        }
    }

    /// Whether this change would actually stop Squiggle working.
    ///
    /// Most of Yahoo's churn is in fields Squiggle never reads. Flagging all
    /// of it as breaking would train whoever runs this to ignore the output,
    /// which is exactly when the real break arrives.
    public var breaksSquiggle: Bool {
        switch self {
        case .added:
            return false
        case .missing(let path, _):
            // A field disappearing only breaks Squiggle when nothing else can
            // stand in for it.
            return ShapeDigest.requiredPaths.contains(path)
        case .typeChanged(let path, let from, let to):
            guard ShapeDigest.readPaths.contains(path) else { return false }
            // `LenientDouble` (Task 4) already accepts a number sent as a
            // string, because Yahoo has done exactly that before.
            let interchangeable: Set<ValueType> = [.number, .string]
            return !(interchangeable.contains(from) && interchangeable.contains(to))
        }
    }
}

public struct ShapeDigest: Equatable, Sendable {
    public let paths: [String: ValueType]

    /// Every key path Squiggle's decoders actually read. Task 6's mutation
    /// suite walks this same list, so the two can never disagree about what
    /// "a field we depend on" means.
    public static let readPaths: [String] = [
        "chart.result[].meta.shortName",
        "chart.result[].meta.currency",
        "chart.result[].meta.exchangeTimezoneName",
        "chart.result[].meta.regularMarketPrice",
        "chart.result[].meta.chartPreviousClose",
        "chart.result[].meta.previousClose",
        "chart.result[].meta.regularMarketTime",
        "chart.result[].meta.currentTradingPeriod.pre.start",
        "chart.result[].meta.currentTradingPeriod.pre.end",
        "chart.result[].meta.currentTradingPeriod.regular.start",
        "chart.result[].meta.currentTradingPeriod.regular.end",
        "chart.result[].meta.currentTradingPeriod.post.start",
        "chart.result[].meta.currentTradingPeriod.post.end",
    ]

    /// The subset with no fallback behind it. Losing one of these stops
    /// Squiggle showing a price at all; losing any other read path costs a
    /// nicety — `previousClose` backs up `chartPreviousClose`, a missing name
    /// falls back to the symbol, and a missing timezone only affects
    /// labelling. Both lists are reported by `probe`; only this one is a
    /// reason to stop and fix something.
    public static let requiredPaths: [String] = [
        "chart.result[].meta.regularMarketPrice",
    ]

    public static func digest(of data: Data) throws -> ShapeDigest {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            // An empty digest would diff as "every field vanished", which
            // reads as a catastrophic API change when it is an error page.
            throw TickerError.notJSON
        }
        var paths: [String: ValueType] = [:]
        walk(root, prefix: "", into: &paths)
        return ShapeDigest(paths: paths)
    }

    private static func walk(_ value: Any, prefix: String, into paths: inout [String: ValueType]) {
        switch classify(value) {
        case .object:
            if !prefix.isEmpty { paths[prefix] = .object }
            guard let dictionary = value as? [String: Any] else { return }
            for (key, child) in dictionary {
                walk(child, prefix: prefix.isEmpty ? key : "\(prefix).\(key)", into: &paths)
            }
        case .array:
            if !prefix.isEmpty { paths[prefix] = .array }
            guard let array = value as? [Any] else { return }
            // Every element folds onto one "[]" path. A day of candles is 390
            // entries; recording each index would bury every real change.
            for child in array {
                walk(child, prefix: "\(prefix)[]", into: &paths)
            }
        case let leaf:
            if !prefix.isEmpty { paths[prefix] = leaf }
        }
    }

    private static func classify(_ value: Any) -> ValueType {
        if value is [String: Any] { return .object }
        if value is [Any] { return .array }
        if value is NSNull { return .null }
        if let number = value as? NSNumber {
            // On Darwin JSON booleans bridge to NSNumber, so a plain `is`
            // check calls every `true` a number — and a bool-to-number change
            // is exactly the kind a decoder trips over.
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool : .number
        }
        if value is String { return .string }
        return .null
    }

    public static func diff(recorded: ShapeDigest, live: ShapeDigest) -> [ShapeChange] {
        var changes: [ShapeChange] = []

        for (path, wasType) in recorded.paths {
            if let nowType = live.paths[path] {
                if nowType != wasType {
                    changes.append(.typeChanged(path: path, from: wasType, to: nowType))
                }
            } else {
                changes.append(.missing(path: path, wasType: wasType))
            }
        }
        for (path, type) in live.paths where recorded.paths[path] == nil {
            changes.append(.added(path: path, type: type))
        }

        // Dictionary order is not stable between runs. Sorting makes the
        // output diffable and the tests deterministic.
        return changes.sorted { $0.path < $1.path }
    }
}
```

> The last-resort `.null` in `classify` is unreachable for anything
> `JSONSerialization` produces. It is there because a `default:` that guessed
> `.string` would silently mislabel a future type rather than being obviously
> wrong.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --build-system native --filter ShapeDigest`
Expected: PASS.

Two failures here mean something specific:

- **`theTwoListsOfFieldsWeDependOnDescribeTheSameSet`** — `readFields` and
  `readPaths` disagree. Resolve it by reading Task 5's `Envelope.Meta` and
  making **both** lists match what that struct actually names. Do not edit one
  list to agree with the other; that hides the drift instead of fixing it.
- **`theRecordedFixtureStillMatchesItself`** — a required path is absent from
  the 2026-09-08 fixture. That fixture is the evidence the decoder was written
  against, so this is a defect in the list rather than in Yahoo.

- [ ] **Step 5: Wire up the `probe` verb**

`squigglectl probe <SYMBOL> [--record]`:

- **Default:** one request, digest the body, digest the recorded fixture,
  print the diff. Exit `0` when nothing breaking changed, `2` when something
  did. Breaking changes print first and are marked; the rest follow under a
  heading that says they are informational.
- **`--record`:** one request, write the body to
  `Tests/Fixtures/yahoo-<today>/chart-<symbol>.json`, and **append a line to
  `docs/fixture-capture-log.md`** giving the date, symbol, market state at
  capture and the file written.

Two rules for `--record`:

1. **It never overwrites an existing fixture directory.** A fixture is
   evidence of what the API returned on a particular day; replacing one
   destroys the only record of the shape the tests were written against. If
   the target directory exists, it refuses and says so.
2. **A recorded fixture is committed in its own commit**, separate from any
   code change, so `git log` shows plainly when the evidence moved.

- [ ] **Step 6: Run it**

```bash
swift run --build-system native squigglectl probe AAPL; echo "exit: $?"
```

Expected: `exit: 0`. Some `added` lines are normal — Yahoo adds fields
constantly. Any line marked breaking means the decoder needs attention before
Task 19 is worth starting.

- [ ] **Step 7: Commit**

```bash
git add Sources/TickerCore/ShapeDigest.swift Sources/squigglectl/ \
        Tests/TickerCoreTests/ShapeDigestTests.swift Tests/TickerCoreTests/MutationTests.swift \
        docs/fixture-capture-log.md
git commit -m "feat: probe reports what changed, not just that something did"
```

---

## Task 19: The trading day

Build-order step 4, and the gate the spec puts in front of every line of UI code: *"No UI until the feed has survived a real trading session."*

This task is **run by a human, not by an agent.** It takes a day of wall-clock time, needs a machine that stays awake and then deliberately sleeps, and its result is evidence rather than code. An agent executing this plan should stop here and hand back.

**Files:**
- Create: `docs/trading-day-2026-XX-XX.md` — the log
- Modify: `Tests/Fixtures/` — the clock-gated fixtures Task 3 could not capture
- Modify: `docs/fixture-capture-log.md` — tick off what was owed

**Prerequisites:** Tasks 1–18 complete, `swift test --build-system native` green,
`squigglectl doctor` exiting 0.

- [ ] **Step 1: Start the run before the pre-market session**

Pick a normal weekday — not a half-day, not a holiday, and ideally not a
quarterly expiry. Start before 04:00 US Eastern:

```bash
swift run --build-system native squigglectl watch AAPL MSFT BRK-B BTC-USD EURUSD=X --interval 180 2>&1 | tee docs/trading-day-$(date +%F).log
```

Five symbols spanning four instrument kinds: two ordinary equities, one with a
hyphen in its symbol, one crypto pair that trades 24/7, and one FX pair. If any
of those four kinds is going to behave differently, this is when it shows.

- [ ] **Step 2: Capture the clock-gated fixtures as each session opens**

Task 3 left these owed because they can only be captured when the market is in
that state. `docs/fixture-capture-log.md` lists them. In a **second terminal**,
at each of these moments, run one capture — and no more, because every one of
these spends from the same daily budget the watch loop is spending:

| Local time (US Eastern) | Fixture to end up with |
|---|---|
| ~05:00 | `pre-market.json` |
| ~10:30 | `regular-session.json` — Task 3 captured this one outside a live session; this is the recapture that makes the name true |
| ~17:00 | `post-market.json` |
| ~22:00 | `overnight-closed.json` — already discharged by Task 3; recapture only if stale |
| any time Saturday | `weekend.json`, and `crypto-while-equities-closed.json` from BTC-USD |

`probe --record` always writes `chart-<symbol>.json` and never overwrites, so
capturing five session states into one dated directory would collide on the
first repeat. Capture, then rename to the name in the table — these are the
names Task 3's owed list uses and the only ones later tests look for:

```bash
swift run --build-system native squigglectl probe AAPL --record
mv Tests/Fixtures/yahoo-$(date +%F)/chart-aapl.json \
   Tests/Fixtures/yahoo-$(date +%F)/pre-market.json   # or the row's name
```

- [ ] **Step 3: Exercise the conditions no test can fake**

During the day, do each of these and note the timestamp in the log:

1. **Turn off Wi-Fi for five minutes.** Expected: `offline` lines, then a clean
   resume. The backoff must not have escalated past the first rung, because
   `.offline` does not advance the ladder (Task 9).
2. **Close the lid for thirty minutes.** Expected: on wake, no burst. If the
   loop fires several requests back to back on wake, `RequestPacer`'s
   `lastRefill` arithmetic is wrong — the bucket refilled across the sleep.
   This is the single most likely real defect in the whole design and it is
   why `refill()` clamps elapsed time to be non-negative.
3. **Enable Low Power Mode for an hour.** Expected: request spacing widens by
   roughly the quiet multiplier.
4. **Add a deliberately bad symbol** (`NOTAREALTICKER`). Expected: one
   `symbolNotFound`, then silence about it — and the other four keep updating.

- [ ] **Step 4: Count what it actually cost**

```bash
grep -c '▲\|▼\|–' docs/trading-day-$(date +%F).log
```

Expected: **under 1,200**. This is the number the whole design exists to
control, and it is the first time it has been measured rather than simulated.

If it exceeds 1,200, do not adjust the budget. Compare the count against
Task 12's simulation for the same settings; the simulation and reality have
diverged, and finding out where is the point of this task.

- [ ] **Step 5: Write the log**

`docs/trading-day-2026-XX-XX.md` records, plainly:

- The date, the symbols, the interval, and the machine's uptime pattern.
- Total requests, and the simulated prediction for the same configuration.
- Every failure that occurred, its classification, and how long the recovery took.
- What happened at each of Step 3's four interventions.
- **Anything Yahoo did that the spec does not describe.** This is the most
  valuable section, and it is the one that will be empty if the run went well
  and full if it did not.

- [ ] **Step 6: Decide**

Three possible outcomes, and only the first one opens plan 2:

- **Green** — under budget, no unexplained failures, no contract drift.
  Proceed to the renderer.
- **Amber** — over budget, or a recovery slower than the spec predicts. Fix the
  engine, then run another day. The UI is not the problem and building it will
  not help.
- **Red** — `unauthorized`, or a contract change `probe` flags as breaking.
  **Stop.** Spec §3.1 says a crumb-gated Yahoo ends this approach, and no
  amount of UI work changes that. Go back to the spec and choose a different
  source before writing another line.

- [ ] **Step 7: Commit the evidence**

```bash
git add docs/trading-day-*.md docs/trading-day-*.log \
        docs/fixture-capture-log.md Tests/Fixtures/
git commit -m "docs: one trading day, measured"
```

---

## Why this plan stops here

Nineteen tasks and not one line of AppKit. That is deliberate, and it is the
spec's decision rather than this plan's: *"No UI until the feed has survived a
real trading session."*

The reasoning is worth stating plainly, because the temptation to skip ahead is
strong and the cost of doing so is hidden. Squiggle's hard problems are not
visual. A marquee that scrolls smoothly is an afternoon's work with a
`CALayer` and a known-good `preferredFrameRateRange`. The problems that can
actually kill this app are:

- an endpoint nobody promised to keep working, which may start demanding a
  credential Squiggle deliberately refuses to hold;
- a request budget that has to hold across every configuration a user can
  reach, including the ones they reach by hand-editing a JSON file;
- a wake-from-sleep path where the obvious implementation fires a burst of
  requests and gets the user's IP throttled.

Every one of those is settled — or exposed — by Tasks 1 through 19. None of
them is made easier by having a menu bar icon first, and a renderer built on
top of an unproven feed is a renderer that will be rewritten.

**What plan 2 covers**, once a trading day has come back green:

- `StripLayout` — measurement and the pre-rendered `CALayer` strip. Deferred
  because its shape depends on the renderer that does not exist yet, and
  guessing at it now would produce an interface written to nothing.
- Everything in `Sources/Squiggle/`: the `NSStatusItem`, occlusion handling,
  the settings window, the search-driven symbol picker, `SMAppService`
  launch-at-login, and the colour schemes.
- `Sources/Squiggle/ErrorText.swift` and the three visual states of spec §7 —
  fresh, dimmed, per-symbol `——` — plus the one-line detail at the foot of the
  dropdown and *Refresh now*. The **rules** behind those states are settled
  here: `RefreshPolicy.isStale` (Task 11) decides the dimming, `FeedEngine`'s
  `deadSymbols` (Task 16) decides the dashes, and `EngineDiagnostics` (Task 16)
  supplies the detail line. Plan 2 supplies only the words and the pixels,
  which is what keeps every user-facing string out of `TickerCore`.
- The app bundle, its `LSUIElement` plist, and the Gatekeeper instructions
  matching the ones Pitch ships.

Plan 2 consumes `FeedEngine`, `RowSplitter`, `Store` and `Diagnosis` exactly as
Tasks 11–18 define them. If plan 2 finds itself wanting to change one of those
signatures, that is a finding worth bringing back rather than a change to make
quietly — the budget sweep's guarantees are only as good as the engine staying
the thing that was measured.
