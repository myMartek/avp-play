import XCTest
@testable import AVPPlayCore

/// „Raum vermessen“ für alle Spiele: die Einstellung, und woran eine Toolchain zeigt, dass sie sie kennt.
final class RoomMeasuringTests: XCTestCase {
    func temp() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-room-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testOnUnlessSwitchedOff() throws {
        let base = temp()
        XCTAssertTrue(InstallDefaults.roomMeasuring(base: base), "without a setting it is on")
        try InstallDefaults.setRoomMeasuring(false, base: base)
        XCTAssertFalse(InstallDefaults.roomMeasuring(base: base))
        try InstallDefaults.setRoomMeasuring(true, base: base)
        XCTAssertTrue(InstallDefaults.roomMeasuring(base: base))
        // a damaged file counts as no setting
        try Data("{".utf8).write(to: InstallDefaults.file(base: base))
        XCTAssertTrue(InstallDefaults.roomMeasuring(base: base))
    }

    func testToolchainSupport() throws {
        let root = temp()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("visionos"), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: root.appendingPathComponent("visionos/run.sh"), atomically: true, encoding: .utf8)
        let gen = root.appendingPathComponent("visionos/gen_xcodeproj.py")
        try "KLEPTON_TEST_ON = 1\n".write(to: gen, atomically: true, encoding: .utf8)
        XCTAssertFalse(try Toolchain(root: root).supportsRoomMeasuring)
        try "os.environ.get('KLEPTON_ROOM_GUARD')\n".write(to: gen, atomically: true, encoding: .utf8)
        XCTAssertTrue(try Toolchain(root: root).supportsRoomMeasuring)
    }
}
