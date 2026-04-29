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
        .package(url: "https://github.com/exPHAT/SwiftWhisper.git", branch: "master")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "VideoToSrt",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SwiftWhisper", package: "SwiftWhisper")
            ]
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
