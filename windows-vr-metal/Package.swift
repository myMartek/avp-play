// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WindowsVRMetal",
    platforms: [
        .visionOS(.v1),
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "WindowsVRMetal", type: .dynamic, targets: ["WindowsVRMetal"])
    ],
    targets: [
        .target(name: "WindowsVRMetalABI", path: "Sources/WindowsVRMetalABI", publicHeadersPath: "include"),
        .target(name: "WindowsVRMetal", dependencies: ["WindowsVRMetalABI"])
    ]
)
