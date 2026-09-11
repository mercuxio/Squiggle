/// Squiggle's pure core: parsing, scheduling policy, rate limiting, layout.
///
/// Performs no network I/O, reads no clock, generates no randomness, and
/// produces no user-facing strings. Time and randomness are parameters.
///
/// "No I/O" would be the cleaner sentence and it would be false:
/// `FileWatchlistStore` reads and writes the watchlist file, which is the one
/// sanctioned exception and the reason Foundation's file APIs are permitted
/// here. `PurityTests` pins the import list and the clock and randomness call
/// sites; it does not pin this paragraph, so the paragraph has to be true on
/// its own.
public enum TickerCore {
    /// The date the Yahoo payload shape recorded in this package was observed.
    public static let payloadObservationDate = "2026-09-08"
}
