// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenMindCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "ScreenMindCore",
            targets: ["ScreenMindCore"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ScreenMindCore",
            dependencies: [],
            path: "Sources/ScreenMindCore",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "ScreenMindCoreTests",
            dependencies: ["ScreenMindCore"],
            path: "Tests/ScreenMindCoreTests"
        )
    ]
)
