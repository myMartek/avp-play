import XCTest
@testable import WindowsVRCore

final class LocalizationTests: XCTestCase {
    func testPreferredLanguageResolution() {
        XCTAssertEqual(WindowsVRLanguage.resolve(preferredLanguages: ["de-DE"]), .german)
        XCTAssertEqual(WindowsVRLanguage.resolve(preferredLanguages: ["en-US"]), .english)
        XCTAssertEqual(WindowsVRLanguage.resolve(preferredLanguages: ["fr-FR"]), .english)
        XCTAssertEqual(WindowsVRLanguage.resolve(preferredLanguages: []), .english)
    }
}
