import XCTest
@testable import AVPPlayCore

/// Die Sprache der Spiele für alle Spiele: die Einstellung, die Werte, und woran eine Toolchain zeigt, dass sie sie kennt.
final class GameLanguageTests: XCTestCase {
    func temp() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-lang-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testValues() {
        for ok in ["device", "en", "de_DE", "pt_BR", "zh_TW", "fil_PH"] { XCTAssertTrue(GameLanguage.isValid(ok), ok) }
        for bad in ["", "game", "de", "de-DE", "DE_de", "en_US.UTF-8", "fr_FR;rm"] { XCTAssertFalse(GameLanguage.isValid(bad), bad) }
        XCTAssertTrue(GameLanguage.choices.allSatisfy { GameLanguage.isValid($0.code) })
        XCTAssertEqual(Set(GameLanguage.choices.map(\.code)).count, GameLanguage.choices.count, "no code twice")
    }

    func testSettingKeepsRoomMeasuring() throws {
        let base = temp()
        XCTAssertNil(InstallDefaults.gameLanguage(base: base), "without a setting: none")
        try InstallDefaults.setRoomMeasuring(false, base: base)
        try InstallDefaults.setGameLanguage("fr_FR", base: base)
        XCTAssertEqual(InstallDefaults.gameLanguage(base: base), "fr_FR")
        XCTAssertFalse(InstallDefaults.roomMeasuring(base: base), "one setting does not drop the other")
        try InstallDefaults.setGameLanguage("bogus", base: base)
        XCTAssertNil(InstallDefaults.gameLanguage(base: base), "an invalid value is not stored")
        try InstallDefaults.setGameLanguage("device", base: base)
        try InstallDefaults.setGameLanguage(nil, base: base)
        XCTAssertNil(InstallDefaults.gameLanguage(base: base))
    }

    func testToolchainSupport() throws {
        let root = temp()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("visionos"), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: root.appendingPathComponent("visionos/run.sh"), atomically: true, encoding: .utf8)
        let gen = root.appendingPathComponent("visionos/gen_xcodeproj.py")
        try "KLEPTON_ROOM_GUARD = 1\n".write(to: gen, atomically: true, encoding: .utf8)
        XCTAssertFalse(try Toolchain(root: root).supportsGameLanguagePreset)
        try "os.environ.get(\"KLEPTON_GAME_LANGUAGE\", \"\")\n".write(to: gen, atomically: true, encoding: .utf8)
        XCTAssertTrue(try Toolchain(root: root).supportsGameLanguagePreset)
    }
}
