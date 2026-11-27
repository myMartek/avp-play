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

/// Echter Download von Metas Server (253 MB). Läuft nur mit `AVPPLAY_LIVE_META=1`; das eingerichtete
/// Werkzeug des Nutzers bleibt unberührt, weil alles in einem eigenen temporären Ordner landet.
final class MetaToolFetchLiveTests: XCTestCase {
    func testRealDownloadIsSignedByMeta() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AVPPLAY_LIVE_META"] == "1", "set AVPPLAY_LIVE_META=1")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("metatoollive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("tools/ovr-platform-util")
        let seen = Seen()
        let started = Date()
        let tool = try await MetaToolFetch.fetchAndAdopt(to: destination) { p in seen.note(p) }
        let size = (try FileManager.default.attributesOfItem(atPath: tool.url.path)[.size] as? NSNumber)?.int64Value ?? 0
        print("LIVE: \(size) bytes in \(Int(Date().timeIntervalSince(started))) s, \(seen.count) progress calls, last \(seen.last.map { "\($0.received)/\($0.total)" } ?? "-")")
        XCTAssertEqual(tool.url, destination)
        XCTAssertGreaterThan(size, 10_000_000)
        XCTAssertGreaterThan(seen.count, 1)
        XCTAssertEqual(seen.last?.fraction ?? 0, 1, accuracy: 0.001)
        XCTAssertNoThrow(try tool.verify())
    }

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var count = 0
        private(set) var last: MetaToolFetch.Progress?
        func note(_ p: MetaToolFetch.Progress) { lock.lock(); count += 1; last = p; lock.unlock() }
    }
}
