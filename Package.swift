// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "HealthCoach",
    platforms: [
        .iOS("26.0"),
        .macOS("26.0"),
        .watchOS("26.0")
    ],
    products: [
        .library(
            name: "HealthCoachKit",
            targets: ["HealthCoachKit"]
        ),
        .executable(
            name: "healthcoach-mcp",
            targets: ["HealthCoachMCP"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
    ],
    targets: [
        .target(
            name: "HealthCoachKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Packages/HealthCoachKit/Sources/HealthCoachKit",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "HealthCoachMCP",
            dependencies: [
                "HealthCoachKit",
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Packages/HealthCoachKit/Sources/HealthCoachMCP",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "HealthCoachKitTests",
            dependencies: ["HealthCoachKit"],
            path: "Packages/HealthCoachKit/Tests/HealthCoachKitTests",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        )
    ]
)
