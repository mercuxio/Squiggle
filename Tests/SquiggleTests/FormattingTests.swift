import Foundation
import Testing
@testable import Squiggle

// Every test pins an explicit locale (R128). `.autoupdatingCurrent` is the
// production default and is exactly what must not appear in an assertion: a
// suite that passes in en_US and fails in de_DE is testing the machine.
private let posix = Locale(identifier: "en_US_POSIX")
private let german = Locale(identifier: "de_DE")

@Test func aPriceAtOrAboveOneKeepsTwoDecimals() {
    #expect(Formatting.price(232.1, locale: posix) == "232.10")
}

@Test func aPriceBelowOneKeepsFour() {
    // A sub-dollar instrument rendered to two decimals loses most of its
    // information — $0.0431 becomes $0.04, and a 10% move becomes invisible.
    #expect(Formatting.price(0.0431, locale: posix) == "0.0431")
}

@Test func indexScaleNumbersKeepTheirGroupingSeparator() {
    // If this one fails, `en_US_POSIX` on this toolchain does not group; pin
    // `Locale(identifier: "en_US")` for this test only and leave the rest on
    // POSIX. Do not respond by deleting the assertion — an index printed as
    // `5432.10` in the menu bar is the thing it exists to catch.
    #expect(Formatting.price(5432.1, locale: posix) == "5,432.10")
}

@Test func theLocaleIsTheCallersNotTheProcessS() {
    #expect(Formatting.price(1234.5, locale: german) == "1.234,50")
}

@Test func aDeltaIsAbsoluteBecauseTheGlyphCarriesTheSign() {
    // R127: the strip renders `▼` next to this, so a minus sign would say the
    // same thing twice — and `▼-1.10` reads as a double negative.
    #expect(Formatting.delta(-1.1, locale: posix) == "1.10")
    #expect(Formatting.delta(0.42, locale: posix) == "0.42")
}

@Test func aPercentageKeepsTwoDecimalsAndItsSignIsAlsoTheGlyphS() {
    #expect(Formatting.percent(0.1834, locale: posix) == "0.18%")
    #expect(Formatting.percent(-2.5, locale: posix) == "2.50%")
}

@Test func anAbsentNumberRendersNothingRatherThanAWord() {
    // The caller drops the whole segment when this is empty (Task 5). Returning
    // "n/a" or "—" here would put a second em-dash next to the dead-symbol one
    // and mean something different.
    #expect(Formatting.delta(nil, locale: posix).isEmpty)
    #expect(Formatting.percent(nil, locale: posix).isEmpty)
}

@Test func aNonFiniteNumberRendersNothingRatherThanInf() {
    // `chartPreviousClose == 0` is supposed to yield `.unknown` upstream
    // (spec §5.3), but this is the last line before the menu bar and
    // `NumberFormatter` renders infinity as "∞" quite happily.
    #expect(Formatting.percent(.infinity, locale: posix).isEmpty)
    #expect(Formatting.percent(.nan, locale: posix).isEmpty)
    #expect(Formatting.delta(.infinity, locale: posix).isEmpty)
    #expect(Formatting.price(.nan, locale: posix) == Formatting.deadPlaceholder)
}
