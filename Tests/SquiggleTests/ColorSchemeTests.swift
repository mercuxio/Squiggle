import AppKit
import TickerCore
import Testing
@testable import Squiggle

// `Direction` is not `CaseIterable`, and this list is the reason it does
// not need to be: a fifth direction fails the exhaustive switch in
// `ColorPolicy.color` at build time, which is a better guard than a sweep.
private let everyDirection: [Direction] = [.up, .down, .flat, .unknown]
private let everyScheme: [ColorScheme] = [.monochrome, .classic, .accessible]

private func color(_ role: ColorRole, _ scheme: ColorScheme,
                   stale: Bool = false) -> NSColor {
    ColorPolicy.color(for: role, scheme: scheme, isStale: stale)
}

// the spec's three scheme names are the whole vocabulary
@Test func theVocabularyIsTheSpecs() {
    #expect(ColorScheme(setting: "monochrome") == .monochrome)
    #expect(ColorScheme(setting: "classic") == .classic)
    #expect(ColorScheme(setting: "accessible") == .accessible)
}

// R119: the field is a lenient `String` precisely so that an unknown value
// is a rendering decision rather than a decode failure. Monochrome is the
// right fallback because it is both the default and the accessible one.
@Test func anUnknownSettingFallsBackToMonochrome() {
    #expect(ColorScheme(setting: "auto") == .monochrome)
    #expect(ColorScheme(setting: "Classic") == .monochrome)
    #expect(ColorScheme(setting: "") == .monochrome)
}

// Differentiate Without Color forces Monochrome over any scheme
@Test func theAccessibilitySettingWins() {
    for scheme in everyScheme {
        let forced = ColorPolicy.effective(requested: scheme,
                                           differentiateWithoutColor: true)
        #expect(forced == .monochrome, "\(scheme) survived the override")
    }
}

// with the setting off, the requested scheme is the effective one
@Test func otherwiseTheUserChoiceStands() {
    for scheme in everyScheme {
        let effective = ColorPolicy.effective(requested: scheme,
                                              differentiateWithoutColor: false)
        #expect(effective == scheme)
    }
}

// Spec §5.3: "the symbol is the anchor the eye lands on and must not move
// in the colour space."
@Test func theLabelRoleIsAlwaysTheLabelColour() {
    for scheme in everyScheme {
        #expect(color(.label, scheme) == NSColor.labelColor, "\(scheme)")
    }
}

// Classic is systemGreen up and systemRed down
@Test func classicIsTheFamiliarPair() {
    #expect(color(.direction(.up), .classic) == NSColor.systemGreen)
    #expect(color(.direction(.down), .classic) == NSColor.systemRed)
}

// R141: the blue/orange axis, taken from the system palette so that both
// appearances and Increase Contrast keep working.
@Test func accessibleIsTheColourblindSafeAxis() {
    #expect(color(.direction(.up), .accessible) == NSColor.systemBlue)
    #expect(color(.direction(.down), .accessible) == NSColor.systemOrange)
}

// Monochrome colours nothing at all
@Test func monochromeIsUniform() {
    for direction in everyDirection {
        #expect(color(.direction(direction), .monochrome) == NSColor.labelColor,
                "\(direction) picked up a colour")
    }
}

// Spec §5.3: "`.flat` and `.unknown` are never coloured." A flat day is
// not an event, and `.unknown` means Squiggle does not know which way it
// went — colouring either would be an assertion it cannot make.
@Test func theUneventfulDirectionsStayNeutral() {
    for scheme in [ColorScheme.classic, .accessible] {
        #expect(color(.direction(.flat), scheme) == NSColor.labelColor, "\(scheme)")
        #expect(color(.direction(.unknown), scheme) == NSColor.labelColor, "\(scheme)")
    }
}

// R142 and spec §7: the *whole* strip dims, which includes the deltas a
// colour scheme would otherwise have coloured.
@Test func stalenessOutranksEverything() {
    for scheme in everyScheme {
        #expect(color(.label, scheme, stale: true) == NSColor.tertiaryLabelColor,
                "\(scheme) label")
        for direction in everyDirection {
            #expect(color(.direction(direction), scheme, stale: true)
                        == NSColor.tertiaryLabelColor,
                    "\(scheme) \(direction)")
        }
    }
}

// a fresh strip is not dimmed
@Test func freshIsNotDim() {
    let dimmed = color(.label, .monochrome, stale: false) == NSColor.tertiaryLabelColor
    #expect(!dimmed)
}
