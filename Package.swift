// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Squiggle",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TickerCore", targets: ["TickerCore"]),
        .executable(name: "squigglectl", targets: ["squigglectl"]),
        .executable(name: "Squiggle", targets: ["Squiggle"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.10.0"),
        // The second dependency, and the only one that ships inside the app:
        // Sparkle does the update check. SwiftPM links it but cannot embed a
        // binary framework into an executable product, so
        // scripts/package-app.sh copies Sparkle.framework into the bundle by
        // hand. See that script for the embedding and signing order.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "TickerCore"),
        // Not a product: the only URLSession in the package, shared by
        // squigglectl now and the Squiggle app later. See the plan's
        // "One flagged deviation from the spec".
        .target(name: "YahooFeed", dependencies: ["TickerCore"]),
        .executableTarget(name: "squigglectl", dependencies: ["TickerCore", "YahooFeed"]),
        .executableTarget(
            name: "Squiggle",
            dependencies: [
                "TickerCore", "YahooFeed",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .testTarget(
            name: "TickerCoreTests",
            dependencies: [
                "TickerCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "squigglectlTests",
            dependencies: [
                "squigglectl",
                "TickerCore",
                "YahooFeed",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "SquiggleTests",
            dependencies: [
                "Squiggle",
                "TickerCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
