// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "VideoToSrt",
    platforms: [
        .macOS("26.0")
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "VideoToSrt",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "WhisperCore"
            ]
        ),
        .target(
            name: "WhisperCore",
            dependencies: ["whisper"]
        ),
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.8.4/whisper-v1.8.4-xcframework.zip",
            checksum: "1c7a93bd20fe4e57e0af12051ddb34b7a434dfc9acc02c8313393150b6d1821f"
        ),
        .testTarget(
            name: "VideoToSrtTests",
            dependencies: ["VideoToSrt"],
            resources: [
                .copy("samples")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
