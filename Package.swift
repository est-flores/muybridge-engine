// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MuybridgePlayer",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
    ],
    products: [
        .library(
            name: "MuybridgePlayer",
            targets: ["MuybridgePlayer"]
        )
    ],
    targets: [
        // C++/Obj-C++ native core - compiles bridge and platform code
        .target(
            name: "MuybridgeNative",
            path: "Sources/MuybridgeNative",
            sources: [
                "core/Clock.cpp",
                "core/AVSync.cpp",
                "core/BufferPool.cpp",
                "ios/IOSVideoDecoder.mm",
                "ios/MetalVideoRenderer.mm",
                "ios/MuybridgeBridge.mm",
            ],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("."),
                .headerSearchPath("include"),
                .headerSearchPath("ios"),
                .define("MUYBRIDGE_PLATFORM_IOS", to: "1", .when(platforms: [.iOS])),
                .define("MUYBRIDGE_PLATFORM_MACOS", to: "1", .when(platforms: [.macOS])),
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
            ]
        ),

        // Swift wrapper - depends on native core
        .target(
            name: "MuybridgePlayer",
            dependencies: ["MuybridgeNative"],
            path: "Sources/MuybridgePlayer",
            sources: ["MuybridgePlayer.swift", "MetalVideoView.swift"]
        ),

        .testTarget(
            name: "MuybridgePlayerTests",
            dependencies: ["MuybridgePlayer"],
            path: "Tests/MuybridgePlayerTests"
        ),

        .executableTarget(
            name: "MuybridgeDemo",
            dependencies: ["MuybridgePlayer"],
            path: "demo/macos"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
