// swift-tools-version: 5.9
//
// framework-size — measure what a framework actually costs an app, and fail a
// build when it grows past its budget.

import PackageDescription

let package = Package(
    name: "framework-size",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "framework-size", targets: ["framework-size"]),
        .library(name: "FrameworkSizeCore", targets: ["FrameworkSizeCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "framework-size",
            dependencies: [
                "FrameworkSizeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/framework-size"
        ),
        .target(name: "FrameworkSizeCore", path: "Sources/FrameworkSizeCore"),
        .testTarget(
            name: "FrameworkSizeCoreTests",
            dependencies: ["FrameworkSizeCore"],
            path: "Tests/FrameworkSizeCoreTests"
        )
    ]
)
