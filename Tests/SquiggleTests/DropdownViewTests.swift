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
        case .quote(let row): #expect(shown.contains(row.title))
        case .footer(let text): #expect(shown.contains(text))
        case .separator: break
        }
    }
}

// MARK: - Coloured direction glyphs

private func coloured(_ symbol: Symbol, price: Double, previousClose: Double) -> MenuModel {
    let quote = Quote(symbol: symbol, shortName: nil, price: price,
                      previousClose: previousClose, currency: "USD", asOfEpoch: nil)
    return MenuModel.build(symbols: [symbol], quotes: [symbol: quote], dead: [],
                           lastSuccessEpoch: now - 60, lastError: nil, storeFault: nil,
                           nowEpoch: now, nextStepEpoch: nil, locale: posix)
}

@MainActor
private func view(_ model: MenuModel, scheme: ColorScheme, stale: Bool = false) -> DropdownView {
    DropdownView(model: model,
                 target: Spy(),
                 remove: #selector(Spy.remove(_:)),
                 command: { _ in #selector(Spy.command(_:)) },
                 color: { ColorPolicy.color(for: $0, scheme: scheme, isStale: stale) })
}

/// The colour the row's text is actually painted in, at a given character.
///
/// Asked of the *view*, using the range the *model* published, so these tests
/// exercise the whole path — model locates the arrow, view paints it — rather
/// than either half on its own.
@MainActor
private func color(in root: NSView, at index: Int) -> NSColor? {
    for case let field as NSTextField in everyView(in: root) {
        let text = field.attributedStringValue
        guard text.length > index else { continue }
        guard let painted = text.attribute(.foregroundColor, at: index,
                                           effectiveRange: nil) as? NSColor else { continue }
        return painted
    }
    return nil
}

@MainActor
private func firstGlyph(_ model: MenuModel) -> MenuModel.QuoteRow.Glyph? {
    for item in model.items {
        if case .quote(let row) = item { return row.glyph }
    }
    return nil
}

/// The user's request: "when color is not monichrom the dropdown's triangles
/// should also have colors". The strip has coloured its arrow since Task 7;
/// this row flattened the same line into one string and painted all of it
/// `.label`.
@MainActor
@Test func aRisingRowsTriangleIsGreenUnderClassic() throws {
    let built = coloured(try sym("AAPL"), price: 101, previousClose: 100)
    let span = try #require(firstGlyph(built))
    let painted = try #require(color(in: view(built, scheme: .classic), at: span.range.location))
    #expect(painted == NSColor.systemGreen)
}

@MainActor
@Test func aFallingRowsTriangleIsRedUnderClassic() throws {
    let built = coloured(try sym("AAPL"), price: 99, previousClose: 100)
    let span = try #require(firstGlyph(built))
    let painted = try #require(color(in: view(built, scheme: .classic), at: span.range.location))
    #expect(painted == NSColor.systemRed)
}

/// R141's pair, which survives deuteranopia and protanopia — and which the
/// dropdown gets for free by asking `ColorPolicy` the question the strip asks,
/// rather than choosing two colours of its own.
@MainActor
@Test func theAccessibleSchemeReachesTheDropdownToo() throws {
    let built = coloured(try sym("AAPL"), price: 101, previousClose: 100)
    let span = try #require(firstGlyph(built))
    let painted = try #require(
        color(in: view(built, scheme: .accessible), at: span.range.location))
    #expect(painted == NSColor.systemBlue)
}

/// Monochrome means monochrome everywhere. This is also the path
/// `accessibilityDisplayShouldDifferentiateWithoutColor` takes, because
/// `ColorPolicy.effective` turns that setting into this scheme before the
/// resolver ever sees a role.
@MainActor
@Test func monochromeLeavesTheTriangleTheColourOfTheText() throws {
    let built = coloured(try sym("AAPL"), price: 101, previousClose: 100)
    let span = try #require(firstGlyph(built))
    let painted = try #require(
        color(in: view(built, scheme: .monochrome), at: span.range.location))
    #expect(painted == NSColor.labelColor)
}

/// R142 and spec §7: when the numbers are old the whole strip dims, deltas
/// included. The dropdown shows the same numbers, so its triangle dims with
/// them — a green arrow inside a greyed-out panel would read as the one live
/// thing on screen.
@MainActor
@Test func aStaleRowsTriangleGreysOutWithTheRestOfIt() throws {
    let built = coloured(try sym("AAPL"), price: 101, previousClose: 100)
    let span = try #require(firstGlyph(built))
    let painted = try #require(
        color(in: view(built, scheme: .classic, stale: true), at: span.range.location))
    #expect(painted == NSColor.tertiaryLabelColor)
}

/// Colour applies to the direction glyph and to nothing else — the rule
/// `ColorPolicy` states for the strip, now provably true of the dropdown.
@MainActor
@Test func theDigitsBesideTheTriangleAreNotColoured() throws {
    let built = coloured(try sym("AAPL"), price: 101, previousClose: 100)
    let span = try #require(firstGlyph(built))
    let after = span.range.location + span.range.length
    let painted = try #require(color(in: view(built, scheme: .classic), at: after))
    #expect(painted == NSColor.labelColor)
}

// MARK: - The refresh icon while a fetch is in flight

@MainActor
private func footer(_ refreshing: RefreshIndicator?) -> MenuFooterView {
    MenuFooterView(target: Spy(),
                   selector: { _ in #selector(Spy.command(_:)) },
                   refreshing: refreshing)
}

/// Found by the label VoiceOver reads, which is `ErrorText.refreshNow` — the
/// same string the tooltip uses. Matching on the glyph would mean this test
/// knew what a Lucide icon looks like.
@MainActor
private func button(_ command: MenuCommand, in root: NSView) -> NSButton? {
    for case let button as NSButton in everyView(in: root)
    where button.accessibilityLabel() == command.title {
        return button
    }
    return nil
}

/// The user's first request: "when the refresh icon is clicked, animate it by
/// rotation to show the refresh process".
///
/// The animation is asserted on the layer rather than watched for on screen,
/// because there is nothing to watch — the interesting claim is that the spin
/// exists the moment the view is *built*, which is what makes it survive the
/// rebuild the click itself triggers.
@MainActor
@Test func theRefreshIconSpinsWhileAFetchIsInFlight() throws {
    let refresh = try #require(button(.refreshNow, in: footer(.spin)))
    let spinner = try #require(refresh as? SpinningFooterButton)
    let layer = try #require(spinner.layer)
    #expect(layer.animation(forKey: SpinningFooterButton.animationKey) != nil)
}

/// Only the icon that means "fetch" says a fetch is happening. A quit button
/// that span would be saying something untrue about itself.
@MainActor
@Test func noOtherFooterIconSpins() {
    let bar = footer(.spin)
    for command in MenuFooterView.leadingCommands + [MenuFooterView.trailingCommand]
    where command != .refreshNow {
        #expect(button(command, in: bar) as? SpinningFooterButton == nil)
    }
}

/// The resting state, and the one the footer is in almost all of the time.
@MainActor
@Test func withNoFetchInFlightTheRefreshIconIsAnOrdinaryButton() throws {
    let refresh = try #require(button(.refreshNow, in: footer(nil)))
    #expect(refresh as? SpinningFooterButton == nil)
    #expect(refresh.contentTintColor == NSColor.secondaryLabelColor)
}

/// Spec §5.1's rule, applied to the footer by `MotionPolicy.refreshIndicator`:
/// a glyph turning until the network answers is exactly the indefinite motion
/// Reduce Motion exists to stop. The indicator stays; only its means change.
@MainActor
@Test func underReduceMotionTheIconBrightensRatherThanTurning() throws {
    let refresh = try #require(button(.refreshNow, in: footer(.tint)))
    #expect(refresh as? SpinningFooterButton == nil)
    #expect(refresh.contentTintColor == NSColor.labelColor)
}
