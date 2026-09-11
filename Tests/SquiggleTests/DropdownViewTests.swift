import AppKit
import TickerCore
import Testing
@testable import Squiggle

private let posix = Locale(identifier: "en_US_POSIX")
private let now: Double = 1_757_000_000

private func sym(_ raw: String) throws -> Symbol {
    try #require(Symbol(raw))
}

private func model(_ symbols: [Symbol]) -> MenuModel {
    MenuModel.build(symbols: symbols, quotes: [:], dead: [], lastSuccessEpoch: now - 60,
                    lastError: nil, storeFault: nil, nowEpoch: now,
                    nextStepEpoch: nil, locale: posix)
}

/// A target that exists only to give the buttons a real object to point at.
/// The selectors are never sent; what is under test is the wiring, not the
/// controller behind it.
@MainActor private final class Spy: NSObject {
    @objc func remove(_ sender: Any?) {}
    @objc func command(_ sender: Any?) {}
}

@MainActor
private func view(_ symbols: [Symbol]) -> DropdownView {
    DropdownView(model: model(symbols),
                 target: Spy(),
                 remove: #selector(Spy.remove(_:)),
                 command: { _ in #selector(Spy.command(_:)) })
}

@MainActor private func everyView(in root: NSView) -> [NSView] {
    root.subviews.reduce([root]) { $0 + everyView(in: $1) }
}

@MainActor private func removeButtons(in root: NSView) -> [RemoveButton] {
    everyView(in: root).compactMap { $0 as? RemoveButton }
}

/// The point of `RemoveButton` carrying a `Symbol` instead of an index: one
/// trash button per watched symbol, each holding the symbol it removes, in the
/// order the watchlist has them. An index would be right here and wrong the
/// moment a row above it went away.
@MainActor
@Test func everyRowCarriesItsOwnSymbolOnItsTrashButton() throws {
    let watched = [try sym("AAPL"), try sym("VOD.L"), try sym("^GSPC")]
    let carried = removeButtons(in: view(watched)).map(\.symbol)
    #expect(carried == watched)
}

/// Symbols are Yahoo's spelling, verbatim, all the way to the button that
/// removes them — the same rule the strip and the store follow.
@MainActor
@Test func theSymbolOnTheButtonIsNotNormalised() throws {
    let odd = try sym("BRK-B")
    let button = try #require(removeButtons(in: view([odd])).first)
    #expect(button.symbol.raw == "BRK-B")
}

/// An empty watchlist has no rows to remove, and so no trash buttons — but it
/// still gets a footer, because that is where *Add Symbol* lives and an empty
/// watchlist is exactly when the user needs it.
@MainActor
@Test func anEmptyWatchlistHasNoTrashButtonsButStillHasItsFooter() {
    let built = view([])
    #expect(removeButtons(in: built).isEmpty)
    let footers = everyView(in: built).compactMap { $0 as? MenuFooterView }
    #expect(footers.count == 1)
}

/// Nothing in this view formats anything. Every string it puts on screen came
/// out of `MenuModel`, so the model's titles are findable in the view tree
/// verbatim — if one is not, a second formatter has grown somewhere.
@MainActor
@Test func noStringAppearsThatTheModelDidNotDecide() throws {
    let watched = [try sym("AAPL")]
    let built = view(watched)
    let shown = Set(everyView(in: built).compactMap { ($0 as? NSTextField)?.stringValue })
    for item in model(watched).items {
        switch item {
        case .quote(let title, _): #expect(shown.contains(title))
        case .footer(let text): #expect(shown.contains(text))
        case .separator: break
        }
    }
}
