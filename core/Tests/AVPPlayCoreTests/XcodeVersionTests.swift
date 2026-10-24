import XCTest
@testable import AVPPlayCore

/// Ein Xcode vor 27 wird erkannt, und ein neueres daneben wird gefunden (avp-play#81).
final class XcodeVersionTests: XCTestCase {
    func testMajorVersionFromTheFirstLineOfXcodebuild() {
        XCTAssertEqual(DeveloperTools.xcodeMajor(fromVersionLine: "Xcode 26.5"), 26)
        XCTAssertEqual(DeveloperTools.xcodeMajor(fromVersionLine: "Xcode 27.1"), 27)
        XCTAssertEqual(DeveloperTools.xcodeMajor(fromVersionLine: "Xcode 27.0 Beta 3"), 27)
        XCTAssertEqual(DeveloperTools.xcodeMajor(fromVersionLine: "Xcode 28"), 28)
        XCTAssertNil(DeveloperTools.xcodeMajor(fromVersionLine: "Build version 27A9275"))
        XCTAssertNil(DeveloperTools.xcodeMajor(fromVersionLine: ""))
    }

    func testNewerXcodesSkipTheChosenOneAndOldOnes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("xcodes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        func app(_ name: String, _ version: String) throws {
            let contents = folder.appendingPathComponent("\(name).app/Contents")
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("Developer"), withIntermediateDirectories: true)
            try (["CFBundleShortVersionString": version] as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        }
        try app("Xcode", "26.5")
        try app("Xcode-beta", "27.0")
        try app("Xcode-27.2", "27.2")
        try app("Simulator", "27.0")

        let chosen = folder.appendingPathComponent("Xcode.app/Contents/Developer").path
        let found = DeveloperTools.newerXcodes(in: folder, chosen: chosen)
        XCTAssertEqual(found.map(\.name), ["Xcode-27.2", "Xcode-beta"])
        let command = try XCTUnwrap(found.first?.selectCommand)
        XCTAssertTrue(command.hasPrefix("sudo xcode-select -s \""), command)
        XCTAssertTrue(command.hasSuffix("/Xcode-27.2.app/Contents/Developer\""), command)

        let fromBeta = DeveloperTools.newerXcodes(in: folder, chosen: folder.appendingPathComponent("Xcode-beta.app/Contents/Developer").path)
        XCTAssertEqual(fromBeta.map(\.name), ["Xcode-27.2"])
    }
}
