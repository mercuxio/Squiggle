// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Squiggle",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TickerCore", targets: ["TickerCore"]),
        .executable(name: "squigglectl", targets: ["squigglectl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.10.0"),
    ],
    targets: [
        .target(name: "TickerCore"),
        // Not a product: the only URLSession in the package, shared by
        // squigglectl now and the Squiggle app later. See the plan's
        // "One flagged deviation from the spec".
        .target(name: "YahooFeed", dependencies: ["TickerCore"]),
        .executableTarget(name: "squigglectl", dependencies: ["TickerCore", "YahooFeed"]),
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
    ]
)
