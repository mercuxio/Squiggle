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

    /// Every key path the chart response's decoder actually reads. Task 6's
    /// mutation suite walks this same list, so the two can never disagree
    /// about what "a field we depend on" means. `YahooSearchDecoding` reads
    /// its own paths from a different endpoint's response and is not
    /// represented here — `probe` only ever fetches the chart endpoint (see
    /// `ProbeRun.swift`), so this list needs nothing beyond it.
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
        // A prefix ending in "[]" is the synthetic stand-in for "every
        // element of that array" (see `case .array` below), not a field
        // name Yahoo ever sent. Recording a container type *at* that
        // placeholder — "a[]" is an object — duplicates information already
        // on the array's own path ("a" is an array) without naming anything
        // real, and it is counted by the same `contains("a[")` a caller
        // would use to find every path folded under that array, which is
        // supposed to name each such path once. Leaf values are unaffected:
        // an array of scalars still records e.g. "a[]" as `.number`, because
        // that is the only place that fact is ever recorded.
        let isElementContainer = prefix.hasSuffix("[]")
        switch classify(value) {
        case .object:
            if !prefix.isEmpty, !isElementContainer { paths[prefix] = .object }
            guard let dictionary = value as? [String: Any] else { return }
            for (key, child) in dictionary {
                walk(child, prefix: prefix.isEmpty ? key : "\(prefix).\(key)", into: &paths)
            }
        case .array:
            if !prefix.isEmpty, !isElementContainer { paths[prefix] = .array }
            guard let array = value as? [Any] else { return }
            // Every element folds onto one "[]" path. A day of candles is 390
            // entries; recording each index would bury every real change.
            for child in array {
                walk(child, prefix: "\(prefix)[]", into: &paths)
            }
        case .number:
            if !prefix.isEmpty { paths[prefix] = .number }
        case .string:
            if !prefix.isEmpty { paths[prefix] = .string }
        case .bool:
            if !prefix.isEmpty { paths[prefix] = .bool }
        case .null:
            if !prefix.isEmpty { paths[prefix] = .null }
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
