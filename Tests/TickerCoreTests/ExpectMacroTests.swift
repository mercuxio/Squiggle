import Testing

/// A landmine in the test framework itself, pinned so it cannot be stepped on.
///
/// This package builds against the standalone `swift-testing` package rather
/// than the copy bundled with the toolchain, because the Command Line Tools
/// alone do not expose `Testing` to SwiftPM. That release's `#expect` macro
/// mis-resolves any comparison whose left operand is already a `Bool` or
/// `Bool?`: it checks that operand alone and discards the comparison.
///
/// The result is silent. `#expect(x == false)` compiles, reads correctly, and
/// passes for every value of `x`. Squiggle's pause predicates and market-state
/// checks are all `Bool`, which is precisely the shape this swallows.
///
/// So: never write `== true` or `== false` inside `#expect`. Write the plain
/// condition (`#expect(x)`, `#expect(!x)`), or for an optional supply the
/// failing default (`#expect(x ?? false)`), or hoist the value into a local.
///
/// If this test ever starts failing, that is good news: the macro has been
/// fixed, and the `??` gymnastics elsewhere in this suite can be unwound.
@Test func boolComparisonsAreInvisibleToTheExpectMacro() {
    var checked = false
    // A comparison the macro is expected to swallow. `alwaysTrue` is a `Bool`,
    // so the macro checks it instead of the `== false` around it — and passes.
    let alwaysTrue = true
    #expect(alwaysTrue == false)
    checked = true

    // The control: identical shape, `Int` operands, correctly evaluated. If
    // this were also swallowed the test above would prove nothing.
    #expect(1 == 1)
    #expect(checked)
}
