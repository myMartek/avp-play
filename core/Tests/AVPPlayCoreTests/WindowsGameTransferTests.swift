import Foundation
import XCTest
@testable import AVPPlayCore

final class WindowsGameTransferTests: XCTestCase {
    func testOwnershipAndBundleIDAreRejectedBeforeReadingFiles() {
        let missing = URL(fileURLWithPath: "/does/not/exist")

        XCTAssertThrowsError(try WindowsGameTransfer.validateLocalInputs(
            source: missing, manifestURL: missing, bundleID: "unsafe", owned: false)) { error in
                guard let transferError = error as? WindowsGameTransferError,
                      case .ownershipAttestationRequired = transferError else {
                    return XCTFail("Expected explicit ownership attestation to be required, got \(error)")
                }
            }
        XCTAssertThrowsError(try WindowsGameTransfer.validateLocalInputs(
            source: missing, manifestURL: missing, bundleID: "not a bundle id", owned: true)) { error in
                guard let transferError = error as? WindowsGameTransferError,
                      case .invalidBundleID = transferError else {
                    return XCTFail("Expected invalid bundle ID to be rejected, got \(error)")
                }
            }
    }

    func testMalformedAndUnsupportedManifestAreRejectedLocally() throws {
        let fixture = try Fixture()
        try fixture.writeManifest("not json")
        XCTAssertThrowsError(try WindowsGameTransfer.validateLocalInputs(
            source: fixture.source, manifestURL: fixture.manifestURL,
            bundleID: "com.example.player", owned: true)) { error in
                guard let transferError = error as? WindowsGameTransferError,
                      case .invalidManifest = transferError else {
                    return XCTFail("Expected malformed JSON to be rejected, got \(error)")
                }
            }

        try fixture.writeManifest(#"{"id":"demo","title":"Demo","executableRelativePath":"game.exe","backend":"windowsWineFEX","graphics":"direct3D11","launchArguments":[],"schemaVersion":2}"#)
        assertPreflightError(.unsupportedSchema(2), fixture: fixture)
    }

    func testUnsafeManifestPathIsRejectedBeforeAnyDeviceOperation() throws {
        let fixture = try Fixture()
        try fixture.writeManifest(fixture.manifest(executable: #"..\outside.exe"#))

        assertPreflightError(.unsafePath(#"..\outside.exe"#), fixture: fixture)
    }

    func testUnsafeSourceEntryAndMissingExecutableAreRejectedLocally() throws {
        let fixture = try Fixture()
        try fixture.writeManifest(fixture.manifest())
        try Data([1]).write(to: fixture.source.appendingPathComponent("bad?.dat"))
        assertPreflightError(.unsafePath("bad?.dat"), fixture: fixture)

        try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("bad?.dat"))
        try fixture.writeManifest(fixture.manifest(executable: "missing.exe"))
        assertPreflightError(.executableMissing("missing.exe"), fixture: fixture)
    }

    func testValidLocalPreflightAcceptsX64ManifestWithoutDeviceAccess() throws {
        let fixture = try Fixture()
        try fixture.writeManifest(fixture.manifest())
        try fixture.writeX64Executable()

        let preflight = try WindowsGameTransfer.validateLocalInputs(
            source: fixture.source, manifestURL: fixture.manifestURL,
            bundleID: "com.example.player", owned: true)

        XCTAssertEqual(preflight.manifest.id, "demo")
        XCTAssertEqual(preflight.sourceFiles.map(\.relativePath), ["game.exe"])
        XCTAssertEqual(preflight.totalBytes, 70)
    }

    private func assertPreflightError(_ expected: WindowsGameTransferError, fixture: Fixture,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try WindowsGameTransfer.validateLocalInputs(
            source: fixture.source, manifestURL: fixture.manifestURL,
            bundleID: "com.example.player", owned: true), file: file, line: line) { error in
                XCTAssertEqual(error as? WindowsGameTransferError, expected, file: file, line: line)
            }
    }

    private final class Fixture {
        let directory: URL
        let source: URL
        let manifestURL: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("WindowsGameTransferTests-\(UUID().uuidString)", isDirectory: true)
            source = directory.appendingPathComponent("game", isDirectory: true)
            manifestURL = directory.appendingPathComponent("manifest.json")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        func writeManifest(_ contents: String) throws {
            try Data(contents.utf8).write(to: manifestURL)
        }

        func manifest(executable: String = "game.exe") -> String {
            let object: [String: Any] = [
                "id": "demo", "title": "Demo", "executableRelativePath": executable,
                "backend": "windowsWineFEX", "graphics": "direct3D11",
                "launchArguments": [String](), "schemaVersion": 1,
            ]
            return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }

        func writeX64Executable() throws {
            var bytes = Data(repeating: 0, count: 70)
            bytes[0] = 0x4d
            bytes[1] = 0x5a
            bytes[0x3c] = 64
            bytes[64] = 0x50
            bytes[65] = 0x45
            bytes[66] = 0
            bytes[67] = 0
            bytes[68] = 0x64
            bytes[69] = 0x86
            try bytes.write(to: source.appendingPathComponent("game.exe"))
        }
    }
}
