import XCTest
@testable import AVPPlayCore

/// Xcode's Metal Toolchain before a build with a toolchain of its own (avp-play#149).
final class MetalToolchainTests: XCTestCase {
    func testOnlyGamesWithAToolchainOfTheirOwnNeedIt() {
        XCTAssertFalse(MetalToolchain.needed(kind: Toolchain.kleptonKind))
        for kind in ["vxruntime", "lambdavision", "revc", "jkxr"] { XCTAssertTrue(MetalToolchain.needed(kind: kind), kind) }
    }

    func testInstalledMeansTheMetalCompilerForVisionOSRuns() {
        var asked: [String] = []
        XCTAssertTrue(MetalToolchain.installed(run: { asked = $0; return 0 }))
        XCTAssertEqual(asked, ["/usr/bin/xcrun", "-sdk", "xros", "metal", "--version"])
        XCTAssertFalse(MetalToolchain.installed(run: { _ in 1 }))
    }

    func testProgressIsReadFromTheDownloadsLines() {
        // Real lines from Xcode 27.2 on a Mac with German region settings (2026-11-26).
        func state(_ line: String) -> [Int64]? { MetalToolchain.bytes(in: line).map { [$0.done, $0.total] } }
        XCTAssertEqual(state("Downloading... (328 kB of 838,9 MB downloaded)"), [328_000, 838_900_000])
        XCTAssertEqual(state("Downloading... (27,2 MB of 838,9 MB downloaded)"), [27_200_000, 838_900_000])
        XCTAssertEqual(state("Downloading... (821,7 MB of 838,9 MB downloaded)"), [821_700_000, 838_900_000])
        XCTAssertEqual(state("Downloading... (27.2 MB of 838.9 MB downloaded)"), [27_200_000, 838_900_000])
        XCTAssertEqual(state("Downloading... (12 bytes of 1,2 GB downloaded)"), [12, 1_200_000_000])
        XCTAssertEqual(state("Downloading... (1.234,5 MB of 2,1 GB downloaded)"), [1_234_500_000, 2_100_000_000])
        XCTAssertNil(state("Beginning asset download..."))
        XCTAssertNil(state("Done downloading: Metal Toolchain 27B47."))
        XCTAssertNil(state("Downloaded asset to: /System/Library/AssetsV2/x/022-22476-056.dmg"))
    }

    func testTheReasonIsTheLastErrorLineOrElseTheLastLine() {
        XCTAssertEqual(MetalToolchain.reason(in: "Beginning asset download...\nerror: The network connection was lost.\n\n"),
                       "error: The network connection was lost.")
        XCTAssertEqual(MetalToolchain.reason(in: "Beginning asset download...\nsomething else\n"), "something else")
        XCTAssertNil(MetalToolchain.reason(in: "\n \n"))
    }

    func testABuildFailureNamesTheToolchainsOwnReason() {
        func hint(_ text: String) -> String { Toolchain.buildFailureHint(in: text.split(separator: "\n")) }
        // What Skyrim VR's toolchain printed without the Metal Toolchain: the reader saw only "Build or installation failed".
        let skyrim = """
        == skyrimvr: stage shaders done (61 s)
        == skyrimvr: stage app ...
        vxrt_build app: the shader set is missing: /x/private/shadercache-xros-manifest/.complete (made by: tools/vxrt_build.py shaders)
        !! build FAILED: stage app is missing an input (see the message above)
        """
        XCTAssertEqual(hint(skyrim), "stage app is missing an input (see the message above)")
        // Xcode's own error line still comes before the toolchain's summary of it.
        XCTAssertEqual(hint("/a/b.swift:3:1: error: cannot find 'x' in scope\n!! build FAILED: stage app failed (exit 65)"),
                       "/a/b.swift:3:1: error: cannot find 'x' in scope")
        // And the Metal compiler's own word before everything else.
        XCTAssertEqual(hint("error: error: cannot execute tool 'metal' due to missing Metal Toolchain; use: xcodebuild -downloadComponent MetalToolchain\n/a.swift:1:1: error: other\n!! build FAILED: x"),
                       "error: error: cannot execute tool 'metal' due to missing Metal Toolchain; use: xcodebuild -downloadComponent MetalToolchain")
        XCTAssertEqual(hint("== nothing useful\n"), "")
    }

    func testTheMessageSaysWhereToGetItAndCountsAsSetup() {
        let error = ToolchainError.metalToolchainMissing("no connection")
        XCTAssertEqual(FailureKind.of(error), .setup)
        let text = error.description
        XCTAssertTrue(text.contains("no connection"), text)
        XCTAssertTrue(text.contains("Settings › Components"), text)
        XCTAssertTrue(text.contains("Metal Toolchain"), text)
        XCTAssertTrue(text.contains(MetalToolchain.downloadCommand), text)
    }
}

/// Apple's real download, only on request (`AVPPLAY_REAL_METAL_DOWNLOAD=1`): it may fetch about 900 MB.
final class MetalToolchainDownloadTests: XCTestCase {
    func testTheRealDownloadRunsAndLeavesTheCompilerWorking() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AVPPLAY_REAL_METAL_DOWNLOAD"] == "1")
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("metal-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let lines = LineBox()
        let reason = await MetalToolchain.download(log: log) { lines.add($0) }
        XCTAssertNil(reason)
        XCTAssertTrue(MetalToolchain.installed())
        XCTAssertFalse(lines.all.isEmpty)
        XCTAssertFalse(try String(contentsOf: log, encoding: .utf8).isEmpty)
        let all = lines.all
        let states = all.compactMap(MetalToolchain.bytes(in:))
        XCTAssertFalse(states.isEmpty, "no line with a byte count: \(all.prefix(5))")
        print("metal download: \(all.count) lines, \(states.count) with a byte count, last \(states.last.map { "\($0.done)/\($0.total)" } ?? "-")")
        print("metal download first:", all.prefix(8))
        print("metal download last:", all.suffix(8))
    }
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
