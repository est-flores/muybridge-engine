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
        // Swift wrapper that depends on the binary framework
        .target(
            name: "MuybridgePlayer",
            dependencies: ["MuybridgePlayerBinary"],
            path: "platform/ios/swift"
        ),
        
        // Pre-compiled XCFramework (added during release)
        .binaryTarget(
            name: "MuybridgePlayerBinary",
            // Option 1: URL to hosted XCFramework (for releases)
            // url: "https://github.com/yourorg/muybridge-engine/releases/download/v1.0.0/MuybridgePlayerBinary.xcframework.zip",
            // checksum: "SHA256_CHECKSUM_HERE"
            
            // Option 2: Local path (for development)
            path: "platform/ios/MuybridgePlayerBinary.xcframework"
        )
    ]
)
