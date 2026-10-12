// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "WindowsVRCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "WindowsVRCore", targets: ["WindowsVRCore"]),
    ],
    targets: [
        .target(name: "WindowsVRCore"),
        .testTarget(name: "WindowsVRCoreTests", dependencies: ["WindowsVRCore"]),
    ]
)
