/// Squiggle's pure core: parsing, scheduling policy, rate limiting, layout.
///
/// Performs no I/O, reads no clock, generates no randomness, and produces no
/// user-facing strings. Time and randomness are parameters.
public enum TickerCore {
    /// The date the Yahoo payload shape recorded in this package was observed.
    public static let payloadObservationDate = "2026-09-08"
}
