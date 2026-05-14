// swift-tools-version: 5.10
// Clawdmeter shared package — UsageData, AISource protocol, AnthropicSource,
// BurnRatePredictor, Theme, and MeterRenderer primitives.
//
// Per plan E6: primitives kit (Ring, Arc, BigNumeral, StaleBadge, AODStyle)
// Per plan E8: XCTest as test framework.

import PackageDescription

let package = Package(
    name: "ClawdmeterShared",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ClawdmeterShared", targets: ["ClawdmeterShared"]),
    ],
    dependencies: [
        // Snapshot testing for primitives (Pass 3 of eng review).
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
    ],
    targets: [
        .target(
            name: "ClawdmeterShared",
            dependencies: []
        ),
        .testTarget(
            name: "ClawdmeterSharedTests",
            dependencies: [
                "ClawdmeterShared",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ]
        ),
    ]
)
