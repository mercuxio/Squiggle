This 401 body is **reconstructed from documentation, not captured**. Squiggle
has never received a 401 from `v8/chart` — if it had, the design's central
assumption (§3.1) would be wrong and the plan would have stopped.

Its job is to witness what a 401 body *cannot* tell the parser. Nothing in
these bytes says 401: `TickerError.unauthorized(status:)` is raised from the
HTTP status line, before the body is decoded, and carries the status number,
which only the response knows. Handed to `YahooQuoteDecoding` this body is
well-formed JSON with no `chart` key, so it decodes to a **contract fault** —
threshold 1, one-hour cooldown, on the theory that the endpoint's shape has
changed for everyone. That is the wrong answer for a credential problem, and
it is why the status must be classified before the body is read.
`theUnauthorizedBodyIsAContractFaultAndNotAClassification` in
`Tests/TickerCoreTests/YahooQuoteDecodingTests.swift` pins exactly that.

Replace it the first time a real one is seen.
