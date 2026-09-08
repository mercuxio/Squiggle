import Foundation

/// Every Yahoo key path Squiggle depends on, in one file.
///
/// Observed against `query1.finance.yahoo.com/v8/finance/chart/{symbol}` on
/// **2026-09-08**. When Yahoo changes shape, this file is the whole diff.
///
/// Path: chart.result[0].meta.{regularMarketPrice, chartPreviousClose,
/// shortName, currency, exchangeTimezoneName, regularMarketTime,
/// currentTradingPeriod.{pre,regular,post}.{start,end}}
public enum YahooQuoteDecoding {
    private struct Envelope: Decodable {
        struct Chart: Decodable {
            let result: [Result]?
            struct Result: Decodable {
                let meta: Meta
            }
        }
        struct Meta: Decodable {
            let regularMarketPrice: LenientDouble?
            let chartPreviousClose: LenientDouble?
            let previousClose: LenientDouble?
            let shortName: String?
            let currency: String?
            let exchangeTimezoneName: String?
            let regularMarketTime: LenientDouble?
            let currentTradingPeriod: TradingPeriodPayload?
        }
        let chart: Chart
    }

    /// Decoded here but only interpreted in `TradingPeriod` (Task 7).
    struct TradingPeriodPayload: Decodable {
        struct Window: Decodable {
            let start: LenientDouble?
            let end: LenientDouble?
        }
        let pre: Window?
        let regular: Window?
        let post: Window?
    }

    public static func quote(from data: Data, symbol: Symbol) throws -> Quote {
        let meta = try self.meta(from: data)

        guard let price = meta.regularMarketPrice?.value else {
            throw TickerError.missingField(path: "chart.result[0].meta.regularMarketPrice")
        }
        guard price >= 0 else {
            throw TickerError.negativeValue(
                path: "chart.result[0].meta.regularMarketPrice", value: price)
        }

        // `chartPreviousClose` is the documented field; `previousClose` appears
        // on some instruments. Neither is required — a newly-listed symbol has
        // no previous close, and that is `.unknown`, not an error.
        let base = meta.chartPreviousClose?.value ?? meta.previousClose?.value

        return Quote(
            symbol: symbol,
            shortName: meta.shortName,
            price: price,
            previousClose: base,
            currency: meta.currency,
            asOfEpoch: meta.regularMarketTime?.value)
    }

    private static func meta(from data: Data) throws -> Envelope.Meta {
        guard !data.isEmpty else { throw TickerError.emptyBody }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch let error as TickerError {
            // LenientDouble's own typed errors pass through unchanged.
            throw error
        } catch let error as DecodingError {
            throw translate(error)
        } catch {
            throw TickerError.notJSON
        }

        guard let first = envelope.chart.result?.first else {
            throw TickerError.noResult
        }
        return first.meta
    }

    /// Turns a `DecodingError` into a `TickerError` that names the JSON path.
    ///
    /// Not `private`: Task 15's `YahooSearchDecoding` calls this same
    /// translator, which is what makes a malformed search body and a
    /// malformed quote body fail with the identical case — the property
    /// `doctor` relies on when it classifies the two endpoints alike.
    static func translate(_ error: DecodingError) -> TickerError {
        switch error {
        case .dataCorrupted(let context) where context.codingPath.isEmpty:
            // Not JSON at all. The 429 body — `text/html`, 19 bytes — lands
            // here, and it must not be reported as a missing field.
            return .notJSON
        case .keyNotFound(let key, let context):
            return .missingField(path: path(context.codingPath + [key]))
        case .valueNotFound(let type, let context):
            return .missingField(path: path(context.codingPath) + " (\(type))")
        case .typeMismatch(let type, let context):
            return .wrongType(path: path(context.codingPath), expected: "\(type)")
        case .dataCorrupted(let context):
            return .wrongType(path: path(context.codingPath), expected: "well-formed value")
        @unknown default:
            return .notJSON
        }
    }

    private static func path(_ keys: [any CodingKey]) -> String {
        keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            .joined(separator: ".")
            .replacingOccurrences(of: ".[", with: "[")
    }
}
