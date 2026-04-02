// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Sneek",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "sneekd", targets: ["sneekd"]),
        .executable(name: "Sneek", targets: ["SneekApp"]),
        .library(name: "SneekLib", targets: ["SneekLib"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "sneekd",
            dependencies: [
                "SneekLib",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(name: "SneekLib"),
        .executableTarget(
            name: "SneekApp",
            dependencies: ["SneekLib"],
            path: "Sources/SneekApp"
        ),
        .executableTarget(
            name: "SneekTests",
            dependencies: ["SneekLib"],
            path: "Tests/SneekLibTests"
        ),
    ]
)
