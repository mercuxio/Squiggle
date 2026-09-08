import Foundation
import TickerCore

/// A quote and its instrument's trading calendar, decoded from one response
/// body. `tradingPeriod` is `nil` when this session's payload did not carry
/// `currentTradingPeriod` — absent rather than an error, since the quote
/// itself is still good.
public struct Snapshot: Sendable {
    public let quote: Quote
    public let tradingPeriod: TradingPeriod?

    public init(quote: Quote, tradingPeriod: TradingPeriod?) {
        self.quote = quote
        self.tradingPeriod = tradingPeriod
    }
}

/// The only `URLSession` in the package.
///
/// Endpoint choice is spec §3.1: `v8/chart` in preference to `v7/quote`,
/// because `v7` is reported to be cookie-and-crumb gated. **That report was
/// never independently confirmed** — confirming it is the point of this task.
/// If `v8` turns out to need authentication, this file is where that lands;
/// nothing in `TickerCore` changes.
public struct YahooClient: QuoteFetching, SymbolSearching {
    /// An absent User-Agent is blocked outright by Yahoo (spec §4.3).
    public static let defaultUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private let session: URLSession
    private let userAgent: String

    public init(userAgent: String = YahooClient.defaultUserAgent) {
        let configuration = URLSessionConfiguration.ephemeral
        // Never persist a credential: an ephemeral configuration keeps no
        // cookie jar and no disk cache, so there is nothing to leak into a
        // support bundle (spec §6).
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // A price is not worth a roaming charge or a tethered connection.
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        configuration.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: configuration)
        self.userAgent = userAgent
    }

    public func fetch(_ symbol: Symbol) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "query1.finance.yahoo.com"
        // `Symbol` has already rejected anything needing escaping in a path.
        components.path = "/v8/finance/chart/\(symbol.raw)"
        components.queryItems = [
            URLQueryItem(name: "range", value: "1d"),
            URLQueryItem(name: "interval", value: "1d"),
        ]
        return try await body(of: components, symbol: symbol)
    }

    /// One request, both facts. `Quote` and `TradingPeriod` are parsed from
    /// the same `v8/chart` body, so a caller that wants both — `squigglectl
    /// watch` and, later, the app's own polling loop — must decode them from
    /// one fetch rather than asking a second endpoint and doubling its share
    /// of the daily budget (spec §3.2).
    public func snapshot(for symbol: Symbol) async throws -> Snapshot {
        let data = try await fetch(symbol)
        return Snapshot(
            quote: try YahooQuoteDecoding.quote(from: data, symbol: symbol),
            // The trading calendar is a bonus fact this same body happens to
            // carry, not something `snapshot(for:)` promises: an older
            // instrument, or a shape Yahoo has not sent this session, simply
            // yields `nil` here rather than failing a request that otherwise
            // produced a perfectly good quote.
            tradingPeriod: try? YahooQuoteDecoding.tradingPeriod(from: data))
    }

    public func search(_ query: String) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "query1.finance.yahoo.com"
        components.path = "/v1/finance/search"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            // Ask for the most Squiggle will ever show. Trimming to the
            // caller's limit happens in the decoder, so the transport method
            // keeps the one-argument shape `SymbolSearching` requires.
            URLQueryItem(name: "quotesCount", value: String(RateConstants.maxSearchResultCount)),
            // Squiggle shows prices, not headlines. Zero news items keeps the
            // response small and the parse cheap.
            URLQueryItem(name: "newsCount", value: "0"),
        ]
        return try await body(of: components, symbol: nil)
    }

    private func body(of components: URLComponents, symbol: Symbol?) async throws -> Data {
        guard let url = components.url else { throw TickerError.transport("bad URL") }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw TickerError.offline
        } catch {
            throw TickerError.transport(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw TickerError.transport("non-HTTP response")
        }

        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw TickerError.unauthorized(status: http.statusCode)
        case 404:
            if let symbol { throw TickerError.symbolNotFound(symbol) }
            throw TickerError.serverError(status: 404)
        case 429:
            // Observed 2026-09-08: this body is `text/html`, 19 bytes, and
            // carries NO Retry-After. Honour the header if it appears; never
            // depend on it, and never try to parse the body as JSON.
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
            throw TickerError.rateLimited(retryAfterSeconds: retryAfter)
        default:
            throw TickerError.serverError(status: http.statusCode)
        }
    }
}

extension YahooClient {
    /// Search, decoded. Not a `SymbolSearching` requirement — that protocol is
    /// the transport seam and deals only in `Data`. This is the method the CLI
    /// and, later, the symbol picker actually call.
    public func searchResults(query: String, limit: Int) async throws -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty query is not a failure and is not worth a request.
        guard !trimmed.isEmpty else { return [] }
        let data = try await search(trimmed)
        return try YahooSearchDecoding.results(from: data, limit: limit)
    }
}
