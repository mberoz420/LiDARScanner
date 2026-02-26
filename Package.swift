// swift-tools-version: 5.9
// This file is for reference - use the Xcode project for full functionality

import PackageDescription

let package = Package(
    name: "LiDARScanner",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "LiDARScanner",
            targets: ["LiDARScanner"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "LiDARScanner",
            dependencies: [],
            path: "LiDARScanner"
        ),
        .testTarget(
            name: "LiDARScannerTests",
            dependencies: ["LiDARScanner"],
            path: "LiDARScannerTests"
        ),
    ]
)
