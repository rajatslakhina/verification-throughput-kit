// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VerificationThroughput",
    // Only platforms CI actually builds are declared. watchOS is deliberately
    // absent: `Int` is 32-bit there, and every ceiling in this package is
    // derived from `Int.max` rather than a 64-bit literal precisely so that
    // adding it later stays a one-line change instead of an audit.
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "VerificationThroughput", targets: ["VerificationThroughput"]),
        .library(name: "VerificationThroughputUI", targets: ["VerificationThroughputUI"])
    ],
    targets: [
        .target(name: "VerificationThroughput"),
        .target(
            name: "VerificationThroughputUI",
            dependencies: ["VerificationThroughput"]
        ),
        .testTarget(
            name: "VerificationThroughputTests",
            dependencies: ["VerificationThroughput"]
        )
    ]
)
