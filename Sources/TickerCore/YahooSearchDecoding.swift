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

        // Same shape and position as `YahooQuoteDecoding.meta(from:)`'s guard:
        // zero bytes must fail as `.emptyBody`, not reach `JSONDecoder` and
        // come back mis-classified as `.notJSON`. `doctor` (Task 17)
        // classifies faults by error case, so the two decoders have to agree
        // on which case an empty body produces.
        guard !data.isEmpty else { throw TickerError.emptyBody }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch let error as DecodingError {
            throw YahooQuoteDecoding.translate(error)
        } catch {
            // Not a `DecodingError` — for example an `NSError` from a
            // malformed encoding `JSONDecoder` couldn't get far enough to
            // raise its own typed error for. Unlike the quote decoder, there
            // is no `LenientDouble` in this envelope to produce a `TickerError`
            // here, so this catch-all only ever sees something untyped.
            // `.notJSON` is the deliberate choice: it's the same case
            // `.dataCorrupted` with an empty coding path already maps to
            // above (via `translate`), so an untyped failure here still
            // funnels into the case the quote decoder uses for "this was
            // never JSON at all", rather than escaping raw and breaking the
            // typed-error contract `doctor` depends on.
            throw TickerError.notJSON
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
