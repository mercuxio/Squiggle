import Foundation

/// Decodes `v1/finance/search?q=`.
///
/// Far more forgiving than the quote decoder, and deliberately so. A quote
/// with a missing price is a contract fault worth shouting about; a search
/// row with a missing name is one imperfect line in a picker. The rule is:
/// skip what cannot be used, keep what can, and only throw when the response
/// as a whole is not what we asked for.
public enum YahooSearchDecoding {
    private struct Envelope: Decodable {
        let quotes: [Row]?

        struct Row: Decodable {
            let symbol: String?
            let shortname: String?
            let longname: String?
            let exchDisp: String?
            let quoteType: String?
        }
    }

    public static func results(from data: Data, limit: Int) throws -> [SearchResult] {
        guard limit > 0 else { return [] }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch let error as DecodingError {
            throw YahooQuoteDecoding.translate(error)
        }

        return (envelope.quotes ?? [])
            .compactMap { row -> SearchResult? in
                guard let raw = row.symbol, let symbol = Symbol(raw) else { return nil }
                let name = row.shortname ?? row.longname ?? symbol.raw
                return SearchResult(symbol: symbol,
                                    name: name,
                                    exchange: row.exchDisp ?? "",
                                    kind: row.quoteType ?? "")
            }
            .prefix(limit)
            .map { $0 }
    }
}
