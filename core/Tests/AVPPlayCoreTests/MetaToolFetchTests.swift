import XCTest
@testable import AVPPlayCore

final class MetaToolFetchTests: XCTestCase {
    /// Geladen wird nur bei Meta selbst, und mitgeschickt wird nichts außer der öffentlichen Kennung des Werkzeugs.
    func testDownloadsOnlyFromMetaWithThePublicToolId() throws {
        let url = MetaToolFetch.url
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "www.oculus.com")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(Set(items.map(\.name)), ["id", "access_token"])
        XCTAssertEqual(items.first { $0.name == "id" }?.value, MetaToolFetch.appId)
        XCTAssertEqual(items.first { $0.name == "access_token" }?.value, "OC|\(MetaToolFetch.appId)|")
    }

    func testProgressFraction() {
        XCTAssertEqual(MetaToolFetch.Progress(received: 50, total: 200).fraction, 0.25)
        XCTAssertEqual(MetaToolFetch.Progress(received: 300, total: 200).fraction, 1)
        XCTAssertEqual(MetaToolFetch.Progress(received: 10, total: 0).fraction, 0)
    }

    /// Eine Datei, die nicht von Meta signiert ist, wird nicht eingerichtet – auch wenn sie so heißt.
    func testAdoptRefusesAnUnsignedFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("metatoolfetch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("ovr-platform-util")
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: fake)
        XCTAssertThrowsError(try MetaTool.adopt(from: fake, to: dir.appendingPathComponent("installed")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("installed").path))
    }
}
