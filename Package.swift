// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "BuildBeacon",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BuildBeaconKit", targets: ["BuildBeaconKit"]),
        .library(name: "BuildBeaconUI", targets: ["BuildBeaconUI"]),
        .executable(name: "BuildBeacon", targets: ["BuildBeacon"]),
    ],
    targets: [
        .target(
            name: "BuildBeaconKit",
            path: "Sources/BuildBeaconKit"
        ),
        .target(
            name: "BuildBeaconUI",
            dependencies: ["BuildBeaconKit"],
            path: "Sources/BuildBeaconUI",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "BuildBeacon",
            dependencies: ["BuildBeaconKit", "BuildBeaconUI"],
            path: "Sources/BuildBeaconApp"
        ),
        .testTarget(
            name: "BuildBeaconKitTests",
            dependencies: ["BuildBeaconKit"],
            path: "Tests/BuildBeaconKitTests"
        ),
        .testTarget(
            name: "BuildBeaconUITests",
            dependencies: ["BuildBeaconUI", "BuildBeaconKit"],
            path: "Tests/BuildBeaconUITests"
        ),
        .testTarget(
            name: "BuildBeaconAppTests",
            dependencies: ["BuildBeacon"],
            path: "Tests/BuildBeaconAppTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
