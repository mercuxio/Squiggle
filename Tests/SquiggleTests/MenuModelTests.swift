import Foundation
import TickerCore
import Testing
@testable import Squiggle

private let posix = Locale(identifier: "en_US_POSIX")
private let now: Double = 1_757_000_000

private func sym(_ raw: String) throws -> Symbol {
    try #require(Symbol(raw))
}

private func quote(_ symbol: Symbol, price: Double, previousClose: Double?,
                   currency: String?) -> Quote {
    Quote(symbol: symbol, shortName: nil, price: price,
          previousClose: previousClose, currency: currency, asOfEpoch: nil)
}

private func model(symbols: [Symbol] = [], quotes: [Symbol: Quote] = [:],
                   dead: Set<Symbol> = [], lastSuccessEpoch: Double? = nil,
                   lastError: TickerError? = nil, storeFault: TickerError? = nil,
                   nextStepEpoch: Double? = nil) -> MenuModel {
    MenuModel.build(symbols: symbols, quotes: quotes, dead: dead,
                    lastSuccessEpoch: lastSuccessEpoch, lastError: lastError,
                    storeFault: storeFault, nowEpoch: now,
                    nextStepEpoch: nextStepEpoch, locale: posix)
}

private func titles(_ model: MenuModel) -> [String] {
    model.items.compactMap {
        switch $0 {
        case .quote(let title, _): return title
        case .footer(let text): return text
        case .command(let command): return command.title
        case .separator: return nil
        }
    }
}

@Test func aRowReadsLikeTheStrip() throws {
    let aapl = try sym("AAPL")
    let built = model(symbols: [aapl],
                      quotes: [aapl: quote(aapl, price: 178.11,
                                           previousClose: 176.87, currency: "USD")])
    let row = try #require(titles(built).first)
    #expect(row.contains("AAPL"))
    #expect(row.contains("178.11"))
    #expect(row.contains("USD"))
    #expect(row.contains("\u{25B2}"))
}

// The GBp rule. A London listing reports pence, and an upper-cased "GBP"
// would claim the price was in pounds and be wrong by a factor of 100.
@Test func theCurrencyCodeIsNotTouched() throws {
    let vod = try sym("VOD.L")
    let built = model(symbols: [vod],
                      quotes: [vod: quote(vod, price: 68.4,
                                          previousClose: 68.4, currency: "GBp")])
    let row = try #require(titles(built).first)
    #expect(row.contains("GBp"))
    #expect(!row.contains("GBP"))
}

@Test func aDeadSymbolKeepsItsRow() throws {
    let bad = try sym("NOPE")
    let built = model(symbols: [bad], dead: [bad])
    let row = try #require(titles(built).first)
    #expect(row.contains("NOPE"))
    #expect(row.contains(Formatting.deadPlaceholder))
}

// Same rule as `StripLayout.pieces`: a symbol with no quote yet and a
// symbol given up on both render the placeholder, and the difference
// between them is the footer line, not a second glyph.
@Test func anUnfetchedSymbolShowsThePlaceholder() throws {
    let fresh = try sym("MSFT")
    let built = model(symbols: [fresh])
    let row = try #require(titles(built).first)
    #expect(row.contains(Formatting.deadPlaceholder))
}

@Test func rowsFollowTheWatchlist() throws {
    let order = [try sym("AAPL"), try sym("MSFT"), try sym("^GSPC")]
    let built = model(symbols: order)
    let rows = built.items.compactMap { item -> Symbol? in
        if case .quote(_, let symbol) = item { return symbol }
        return nil
    }
    #expect(rows == order)
}

@Test func theCommandsAreAlwaysThere() {
    let commands = model().items.compactMap { item -> MenuCommand? in
        if case .command(let command) = item { return command }
        return nil
    }
    #expect(commands == [.refreshNow, .settings, .quit])
}

@Test func commandTitlesComeFromOnePlace() {
    #expect(MenuCommand.refreshNow.title == ErrorText.refreshNow)
    #expect(MenuCommand.settings.title == ErrorText.settings)
    #expect(MenuCommand.quit.title == ErrorText.quit)
}

@Test func aHealthyFooterSaysWhenItLastUpdated() throws {
    let built = model(lastSuccessEpoch: now - 180)
    let footer = try #require(built.items.compactMap { item -> String? in
        if case .footer(let text) = item { return text }
        return nil
    }.first)
    #expect(footer == "Updated 3 min ago")
}

// R139: the transient fault wins. A store fault is permanent for the
// session and will be back the moment the feed recovers; a dropped
// network is a minute long, and a minute spent hidden is a minute the
// user never gets told.
@Test func theFeedErrorWins() throws {
    let built = model(lastSuccessEpoch: now - 60,
                      lastError: .offline,
                      storeFault: .storeSchemaUnsupported(version: 99))
    let footer = try #require(built.items.compactMap { item -> String? in
        if case .footer(let text) = item { return text }
        return nil
    }.first)
    #expect(footer == "No network connection.")
}

@Test func theStoreFaultIsNotLost() throws {
    let built = model(lastSuccessEpoch: now - 60,
                      storeFault: .storeSchemaUnsupported(version: 99))
    let footer = try #require(built.items.compactMap { item -> String? in
        if case .footer(let text) = item { return text }
        return nil
    }.first)
    #expect(footer.contains("newer Squiggle"))
}

@Test func theRetryComesFromTheRealSchedule() throws {
    let built = model(lastSuccessEpoch: now - 900,
                      lastError: .rateLimited(retryAfterSeconds: nil),
                      nextStepEpoch: now + 720)
    let footer = try #require(built.items.compactMap { item -> String? in
        if case .footer(let text) = item { return text }
        return nil
    }.first)
    #expect(footer.contains("12 min"))
}

// A separator either side of the footer, and one before Quit. Asserted as
// a shape rather than by index so that Tasks 13 and 15 inserting their own
// items cannot quietly turn this into a test of nothing.
@Test func separatorsAreWhereSeparatorsBelong() throws {
    let built = model(symbols: [try sym("AAPL")])
    let isSeparator = built.items.map { item -> Bool in
        if case .separator = item { return true }
        return false
    }
    // `first`/`last` are `Bool?`, so `!` will not apply and `== false`
    // is the swallowed shape. Hoist, defaulting to `true` so an empty
    // menu — itself a bug — fails here rather than passing vacuously.
    let opensWithSeparator = isSeparator.first ?? true
    let endsWithSeparator = isSeparator.last ?? true
    #expect(!opensWithSeparator)
    #expect(!endsWithSeparator)
    let doubled = zip(isSeparator, isSeparator.dropFirst()).contains { $0 && $1 }
    #expect(!doubled)
}
