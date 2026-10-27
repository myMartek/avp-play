// swift-tools-version: 6.0
// Spike d30-remote (moonshot.md): the Mac renders, the Vision Pro shows. A cube in a RemoteImmersiveSpace, the
// headset's pose and pinches read from the Mac, frame timing measured. Not part of AVP Play.
import PackageDescription

let package = Package(
    name: "D30Remote",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "D30Remote", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
