This 401 body is **reconstructed from documentation, not captured**. Squiggle
has never received a 401 from `v8/chart` — if it had, the design's central
assumption (§3.1) would be wrong and the plan would have stopped.

Its only job is to prove the parser classifies a 401 body as
`unauthorized` rather than as a contract fault. Replace it the first time a
real one is seen.
