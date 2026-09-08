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
