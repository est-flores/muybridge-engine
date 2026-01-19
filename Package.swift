// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MuybridgePlayer",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "MuybridgePlayer",
            targets: ["MuybridgePlayer"]
        )
    ],
    targets: [
        // Swift wrapper - source code only (no binary dependency for now)
        .target(
            name: "MuybridgePlayer",
            path: "platform/ios/swift",
            sources: ["MuybridgePlayer.swift", "MetalVideoView.swift"]
        )
    ]
)
