import Foundation

/// How the strip moves. The raw values are R120's stored vocabulary, so the
/// settings file and this type cannot drift apart.
enum MotionMode: String, Equatable, Sendable {
    case scroll
    case step

    /// Decodes a stored setting. Anything outside the vocabulary becomes the
    /// default rather than failing: the file is the user's, it is editable by
    /// hand, and a ticker that refuses to start because a word is misspelled
    /// is worse than one that scrolls when it was asked to step.
    init(setting: String) {
        self = MotionMode(rawValue: setting) ?? .scroll
    }
}

/// What the menu bar shows: one strip, two strips, or one stock at a time.
/// The raw values are the stored vocabulary `Settings.display` keeps, so the
/// settings file and this type cannot drift apart — the same contract
/// `MotionMode` has.
enum DisplayMode: String, Equatable, Sendable {
    case one
    case two
    case flip

    /// Decodes a stored setting, defaulting the way `MotionMode(setting:)`
    /// does. A word this build has never heard of — a file written by a later
    /// Squiggle — shows two rows rather than refusing to start, and the
    /// unknown word stays in the file untouched.
    init(setting: String) {
        self = DisplayMode(rawValue: setting) ?? .two
    }
}

/// How the strip moves, once the display mode and Reduce Motion have both had
/// their say. `TickerView` switches on this and nothing else.
///
/// Flip carries whether it must do without the rotation, rather than leaving
/// the view to ask the workspace a second time: the answer has to be the same
/// one `StatusItemController` used when it chose the layout, and two reads of
/// a system setting a few lines apart is exactly how they would differ.
enum StripMotion: Equatable, Sendable {
    case scroll
    case step
    /// - Parameter crossfading: Reduce Motion is on, so the card dips through
    ///   transparent instead of turning.
    case flip(crossfading: Bool)
}

/// How the footer's refresh icon says a fetch is under way.
///
/// Two cases rather than an optional `Bool`, because "not refreshing" is the
/// absence of an indicator entirely — already spelled by the absence of one of
/// these — and a third case for it would make one state sayable twice.
enum RefreshIndicator: Equatable, Sendable {
    case spin
    case tint
}

enum MotionPolicy {
    /// Spec §5.1: one page every four seconds.
    static let stepSeconds: Double = 4
    /// R137: how long the dip through transparent takes, split either side of
    /// the page switch.
    static let fadeSeconds: Double = 0.35

    /// Spec §5.1: "Step is *forced* when Reduce Motion is enabled."
    ///
    /// The stored setting is not consulted and not changed. Turning the
    /// system setting off restores whatever the user had chosen, because
    /// their choice was never overwritten — only overruled.
    static func effective(requested: MotionMode, reduceMotion: Bool) -> MotionMode {
        reduceMotion ? .step : requested
    }

    /// The one place display mode, the stored motion mode and Reduce Motion
    /// are reconciled.
    ///
    /// Flip is its own motion, so it overrides the scroll/step choice rather
    /// than combining with it — which is why Settings disables that control
    /// while Flip is selected. The stored choice is untouched and comes back
    /// when the user leaves Flip, exactly as Reduce Motion overrules without
    /// overwriting.
    static func stripMotion(display: DisplayMode,
                            requested: MotionMode,
                            reduceMotion: Bool) -> StripMotion {
        guard display != .flip else { return .flip(crossfading: reduceMotion) }
        switch effective(requested: requested, reduceMotion: reduceMotion) {
        case .scroll: return .scroll
        case .step: return .step
        }
    }

    /// The same rule `effective` applies to the strip, applied to the footer:
    /// Reduce Motion overrules the animation without removing the signal.
    ///
    /// A glyph rotating until the network answers is exactly the indefinite
    /// motion that setting exists to stop, so the icon brightens instead —
    /// which is what it already does under the pointer, so the vocabulary is
    /// one the user has seen before.
    static func refreshIndicator(reduceMotion: Bool) -> RefreshIndicator {
        reduceMotion ? .tint : .spin
    }

    /// The x positions the row layer steps through, one per page, starting at
    /// zero. A strip that fits its window is a single page and therefore does
    /// not move at all — the same rule scroll mode follows.
    static func pageOffsets(contentWidth: Double, visibleWidth: Double) -> [Double] {
        guard visibleWidth > 0 else { return [0] }
        let pages = max(1, Int((contentWidth / visibleWidth).rounded(.up)))
        return (0..<pages).map { -Double($0) * visibleWidth }
    }

    /// Key times for the discrete position animation: `pageCount + 1` of
    /// them, evenly spaced from 0 to 1.
    ///
    /// One more than there are values, because that is what Core Animation's
    /// `.discrete` calculation mode asks for — each value holds for the span
    /// between consecutive times, so N values need N+1 boundaries. The
    /// interpolating modes want an equal count, which is the mistake this
    /// function exists to stop someone making at the call site.
    static func pageKeyTimes(pageCount: Int) -> [Double] {
        let pages = max(1, pageCount)
        return (0...pages).map { Double($0) / Double(pages) }
    }

    /// The opacity timeline for one full cycle of `pageCount` pages.
    ///
    /// Each page contributes three frames — invisible at the moment the
    /// position switches, fully up a fraction later, held until just before
    /// the next switch — and one final zero closes the loop, so the repeat
    /// wraps onto a matching value instead of snapping from 1 to 0.
    ///
    /// Key times are fractions of the whole timeline, which is why the fade's
    /// share shrinks as pages are added: the fade is a fixed number of
    /// seconds, and the timeline it is a fraction of grows with the page
    /// count.
    static func fadeKeyframes(pageCount: Int) -> (values: [Double], keyTimes: [Double]) {
        let pages = max(1, pageCount)
        let total = stepSeconds * Double(pages)
        let half = (fadeSeconds / 2) / total

        var values: [Double] = []
        var keyTimes: [Double] = []
        for page in 0..<pages {
            let start = Double(page) / Double(pages)
            let end = Double(page + 1) / Double(pages)
            values.append(contentsOf: [0, 1, 1])
            keyTimes.append(contentsOf: [start, start + half, end - half])
        }
        values.append(0)
        keyTimes.append(1)
        return (values, keyTimes)
    }
}
