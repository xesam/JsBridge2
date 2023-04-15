// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "js-bridge-core-swift",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "BridgeCore",
            targets: ["BridgeCore"]),
        .library(
            name: "BridgeSystem",
            targets: ["BridgeSystem"]),
        .library(
            name: "js-bridge-core-swift",
            targets: ["BridgeCore", "BridgeSystem"]),
    ],
    targets: [
        .target(
            name: "BridgeCore",
            path: "Sources/Bridge"
        ),
        .target(
            name: "BridgeSystem",
            dependencies: ["BridgeCore"],
            path: "Sources/BridgeSystem"
        ),
        .testTarget(
            name: "BridgeCoreTests",
            dependencies: ["BridgeCore"],
            path: "Tests/BridgeCoreTests"
        ),
        .testTarget(
            name: "BridgeSystemTests",
            dependencies: ["BridgeSystem"],
            path: "Tests/BridgeSystemTests"
        ),
    ]
)
