import Foundation
import TickerCore
import Testing
@testable import Squiggle

// MARK: - Choice

// The whole point of this type: an off-by-one in a segmented control
// silently swaps two schemes, and nothing else in the app would notice.
// One round-trip test covers all four controls because there is one
// mapping.
@Test func valuesRoundTrip() {
    for (index, value) in SettingsForm.interval.values.enumerated() {
        #expect(SettingsForm.interval.index(of: value) == index)
        #expect(SettingsForm.interval.value(at: index) == value)
    }
    for (index, value) in SettingsForm.scheme.values.enumerated() {
        #expect(SettingsForm.scheme.index(of: value) == index)
    }
    for (index, value) in SettingsForm.motion.values.enumerated() {
        #expect(SettingsForm.motion.index(of: value) == index)
    }
    for (index, value) in SettingsForm.rows.values.enumerated() {
        #expect(SettingsForm.rows.index(of: value) == index)
    }
}

@Test func anUnknownValueLandsOnTheFallback() {
    // The hand-edited-file case. `Settings` carries an unknown scheme
    // through verbatim (R119), so the window has to be able to show one.
    let index = SettingsForm.scheme.index(of: "puce")
    #expect(index == SettingsForm.scheme.index(of: SettingsForm.scheme.fallback))
}

// An index off the end yields the fallback rather than trapping.
@Test func anImpossibleIndexIsSurvivable() {
    #expect(SettingsForm.rows.value(at: 99) == SettingsForm.rows.fallback)
    #expect(SettingsForm.rows.value(at: -1) == SettingsForm.rows.fallback)
}

// A control whose titles and values have drifted apart shows the wrong
// label on the right value, which is worse than either alone.
@Test func titlesAndValuesAgree() {
    #expect(SettingsForm.rows.values.count == SettingsForm.rows.titles.count)
    #expect(SettingsForm.interval.values.count == SettingsForm.interval.titles.count)
    #expect(SettingsForm.scheme.values.count == SettingsForm.scheme.titles.count)
    #expect(SettingsForm.motion.values.count == SettingsForm.motion.titles.count)
}

@Test func theFallbacksAreReachable() {
    #expect(SettingsForm.rows.values.contains(SettingsForm.rows.fallback))
    #expect(SettingsForm.interval.values.contains(SettingsForm.interval.fallback))
    #expect(SettingsForm.scheme.values.contains(SettingsForm.scheme.fallback))
    #expect(SettingsForm.motion.values.contains(SettingsForm.motion.fallback))
}

// Spec §4.1 names the four; R119 and R120 name the vocabularies. If any
// of these drift the control offers something the app cannot honour.
@Test func theMenusAreTheSpecs() {
    #expect(SettingsForm.interval.values == RateConstants.refreshIntervalChoices)
    #expect(SettingsForm.rows.values == [1, 2])
    #expect(SettingsForm.scheme.values == ["monochrome", "classic", "accessible"])
    #expect(SettingsForm.motion.values == ["scroll", "step"])
}

// R143: a slider that can reach a value the decoder clamps is a setting
// that silently reverts on the next launch.
@Test func theSliderBoundsAreTheDecodersBounds() {
    var settings = Settings()
    settings.scrollPointsPerSecond = Settings.speedRange.upperBound
    settings.maxVisibleWidth = Settings.widthRange.upperBound
    let widest = try? roundTrip(settings)
    #expect(widest?.scrollPointsPerSecond == Settings.speedRange.upperBound)
    #expect(widest?.maxVisibleWidth == Settings.widthRange.upperBound)

    settings.scrollPointsPerSecond = Settings.speedRange.lowerBound
    settings.maxVisibleWidth = Settings.widthRange.lowerBound
    let narrowest = try? roundTrip(settings)
    #expect(narrowest?.scrollPointsPerSecond == Settings.speedRange.lowerBound)
    #expect(narrowest?.maxVisibleWidth == Settings.widthRange.lowerBound)
}

private func roundTrip(_ settings: Settings) throws -> Settings {
    let store = Store(schemaVersion: Store.currentSchemaVersion,
                      symbols: [], settings: settings, cooldownUntilEpoch: nil)
    let data = try JSONEncoder().encode(store)
    return try JSONDecoder().decode(Store.self, from: data).settings
}

// MARK: - The effective-interval line

// R144. Not "10 min": `budgetFloor(20)` is 1,440 seconds. Twenty symbols
// on the one-minute setting reports twenty-four minutes.
@Test func theFloorIsReportedAtItsRealValue() {
    let line = ErrorText.effectiveInterval(userIntervalSeconds: 60, watchlistCount: 20)
    #expect(line.contains("24 min"), "\(line)")
}

@Test func anUnthrottledSettingReadsPlainly() {
    // One symbol at fifteen minutes: 900s beats both the 30s spacing floor
    // and the 72s budget floor, so the setting is honoured exactly.
    let line = ErrorText.effectiveInterval(userIntervalSeconds: 900, watchlistCount: 1)
    #expect(!line.contains("("), "\(line)")
}

// An empty watchlist is not described as throttled.
@Test func nothingToFetchIsNotAFloor() {
    let line = ErrorText.effectiveInterval(userIntervalSeconds: 60, watchlistCount: 0)
    #expect(!line.contains("("), "\(line)")
}

@Test func theChosenIntervalIsAlwaysStated() {
    let line = ErrorText.effectiveInterval(userIntervalSeconds: 60, watchlistCount: 20)
    #expect(line.hasPrefix(ErrorText.intervalTitles[0]), "\(line)")
}
