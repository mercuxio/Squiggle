/// One row in the symbol picker.
///
/// `kind` and `exchange` are plain strings rather than enums on purpose:
/// Yahoo's search index contains instrument types this app has never heard of,
/// and an unknown value should show up in the picker as text, not fail the
/// whole search.
public struct SearchResult: Equatable, Sendable {
    public let symbol: Symbol
    public let name: String
    public let exchange: String
    public let kind: String

    public init(symbol: Symbol, name: String, exchange: String, kind: String) {
        self.symbol = symbol
        self.name = name
        self.exchange = exchange
        self.kind = kind
    }
}
