import Testing

// Placeholder so this target has a source file: `Package.swift` declares
// `squigglectlTests` with no `path:` override, so SwiftPM requires a real
// directory under `Tests/squigglectlTests/` to resolve the target — the
// same role `Sources/squigglectl/main.swift` plays for the executable
// target. Task 2 supersedes this file with `CommandTests.swift`, which
// will test argument parsing properly.
@Test func squigglectlTestsTargetResolves() {
    #expect(1 == 1)
}
