import XCTest
@testable import AVPPlayCore

final class JobLogFilesTests: XCTestCase {
    func temp() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-joblog-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    func testWritesLinesAndKeepsTheFileOpenUntilClosed() {
        let url = temp().appendingPathComponent("a.log")
        let files = JobLogFiles()
        files.write("eins", id: "a", to: url)
        files.write("zwei", id: "a", to: url)
        XCTAssertEqual(files.open, ["a"])
        XCTAssertEqual(text(url), "eins\nzwei\n")
        files.close("a")
        XCTAssertTrue(files.open.isEmpty)
    }

    func testClosingTwiceOrWithoutAnOpenFileIsHarmless() {
        let url = temp().appendingPathComponent("a.log")
        let files = JobLogFiles()
        files.close("niemand")
        files.write("eins", id: "a", to: url)
        files.close("a")
        files.close("a")
        files.closeAll()
        XCTAssertTrue(files.open.isEmpty)
        XCTAssertEqual(text(url), "eins\n")
    }

    /// Ein fortgesetzter Auftrag schreibt nach dem Schließen an dieselbe Datei weiter, statt sie zu überschreiben.
    func testWritingAgainAfterCloseAppends() throws {
        let url = temp().appendingPathComponent("a.log")
        try "früher\n".write(to: url, atomically: true, encoding: .utf8)
        let files = JobLogFiles()
        files.write("eins", id: "a", to: url)
        files.close("a")
        files.write("zwei", id: "a", to: url)
        files.close("a")
        XCTAssertEqual(text(url), "früher\neins\nzwei\n")
    }

    func testCloseAllClosesEveryFile() {
        let dir = temp()
        let files = JobLogFiles()
        files.write("x", id: "a", to: dir.appendingPathComponent("a.log"))
        files.write("y", id: "b", to: dir.appendingPathComponent("b.log"))
        XCTAssertEqual(files.open, ["a", "b"])
        files.closeAll()
        XCTAssertTrue(files.open.isEmpty)
    }

    /// Lässt sich die Datei nicht öffnen (Ordner fehlt), bleibt nichts offen und es wird nichts geworfen.
    func testUnwritablePlaceLeavesNothingOpen() {
        let url = temp().appendingPathComponent("fehlt/a.log")
        let files = JobLogFiles()
        files.write("x", id: "a", to: url)
        XCTAssertTrue(files.open.isEmpty)
    }
}
