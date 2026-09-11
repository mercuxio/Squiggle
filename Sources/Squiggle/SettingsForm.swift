import Foundation
import TickerCore

/// A control that offers a fixed list of values, and the two-way mapping
/// between the list and the stored setting.
///
/// One type for all four fixed-choice controls, because the bug these have is
/// always the same bug: an index and a list that disagree by one, which shows
/// the right label on the wrong value and is invisible until someone notices
/// their ticker is the wrong colour. Four controls sharing one mapping means
/// one test finds it.
struct Choice<Value: Equatable & Sendable>: Sendable {
    let values: [Value]
    let titles: [String]
    /// Used in both directions when the other side is unreachable: the row to
    /// select for a stored value that is not offered, and the value to report
    /// for an index that does not exist.
    let fallback: Value

    /// The row to select for a stored value. A value this control does not
    /// offer selects the fallback's row — `Settings` carries an unknown
    /// `colorScheme` through verbatim (R119), so the window has to be able to
    /// show a file it does not fully understand without refusing to open.
    func index(of value: Value) -> Int {
        values.firstIndex(of: value) ?? values.firstIndex(of: fallback) ?? 0
    }

    /// The value for a selected row. Total over every `Int`, including the
    /// `-1` an `NSSegmentedControl` reports when nothing is selected.
    func value(at index: Int) -> Value {
        values.indices.contains(index) ? values[index] : fallback
    }
}

/// The four fixed-choice controls in the Settings window, as data.
///
/// Each one's values come from the type that owns them — the spec's interval
/// menu from `RateConstants`, the row count from `Settings` — rather than
/// being listed again here, so that adding a fifth interval widens the popup
/// without anyone remembering to.
enum SettingsForm {
    static let rows = Choice(values: Settings.rowChoices,
                             titles: ErrorText.rowTitles,
                             fallback: 2)

    static let interval = Choice(values: RateConstants.refreshIntervalChoices,
                                 titles: ErrorText.intervalTitles,
                                 fallback: RateConstants.defaultRefreshInterval)

    // R119's vocabulary. Strings and not `ColorScheme`, because this is the
    // mapping to what `Settings` stores, and `Settings` stores a string so
    // that `TickerCore` never learns what a colour is.
    static let scheme = Choice(values: ["monochrome", "classic", "accessible"],
                               titles: ErrorText.schemeTitles,
                               fallback: "monochrome")

    static let motion = Choice(values: ["scroll", "step"],
                               titles: ErrorText.motionTitles,
                               fallback: "scroll")
}
