import XCTest
@testable import AVPPlayCore

final class LabJudgeTests: XCTestCase {
    func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> [UInt8] {
        (0..<64 * 64).flatMap { _ in [r, g, b, 255] }
    }
    /// Ein Bild mit Inhalt: ein Verlauf, verschoben um `shift`.
    func picture(shift: Int = 0) -> [UInt8] {
        (0..<64 * 64).flatMap { i -> [UInt8] in
            let v = UInt8(((i % 64) * 4 + shift) % 256)
            return [v, UInt8((i / 64) * 3 % 256), 80, 255]
        }
    }
    func frame(_ name: String, _ pixels: [UInt8]) -> (LabJudge.Frame, [UInt8]) {
        let m = LabJudge.judge(pixels: pixels)
        return (.init(name: name, look: m.look, mean: m.mean, spread: m.spread, magenta: m.magenta, color: m.color), pixels)
    }

    func testOneFrameLooks() {
        XCTAssertEqual(LabJudge.judge(pixels: solid(0, 0, 0)).look, .black)
        XCTAssertEqual(LabJudge.judge(pixels: solid(3, 3, 4)).look, .black)
        XCTAssertEqual(LabJudge.judge(pixels: solid(255, 255, 255)).look, .flat)
        XCTAssertEqual(LabJudge.judge(pixels: solid(255, 255, 255)).color, "#ffffff")
        XCTAssertEqual(LabJudge.judge(pixels: solid(255, 0, 255)).look, .magenta)   // iB Cricket's pink before its fix
        XCTAssertEqual(LabJudge.judge(pixels: picture()).look, .picture)
    }

    func testVerdicts() {
        func verdict(_ frames: [(LabJudge.Frame, [UInt8])], summary: String = "") -> LabJudge.Verdict {
            LabJudge.verdict(frames: frames.map(\.0), pixels: frames.map(\.1), summary: summary).verdict
        }
        let black = frame("frame_000.png", solid(0, 0, 0))
        // A loading screen at the start is black; content after it is a picture.
        XCTAssertEqual(verdict([black, frame("frame_001.png", picture(shift: 0)), frame("frame_002.png", picture(shift: 40)),
                                frame("frame_003.png", picture(shift: 90))]), .picture)
        XCTAssertEqual(verdict([black, black, black]), .noPicture)
        XCTAssertEqual(verdict([]), .noPicture)
        XCTAssertEqual(verdict([black, frame("frame_001.png", picture()), frame("frame_002.png", solid(255, 0, 255)),
                                frame("frame_003.png", solid(255, 0, 255))]), .brokenPicture)
        XCTAssertEqual(verdict([frame("frame_000.png", solid(255, 255, 255))]), .brokenPicture)
        XCTAssertEqual(verdict([frame("frame_000.png", picture()), frame("frame_001.png", picture()),
                                frame("frame_002.png", picture())]), .frozen)
        XCTAssertEqual(verdict([frame("frame_000.png", picture())],
                               summary: "how it ended:\n    STOPPED: called unresolved import AAudio_x\n"), .stopped)
    }

    func testVulkanPicturesPairTheEyesAndPreferTheNamedStage() {
        let p = LabJudge.pictures(["vk_f01500_s0_eye0.png", "vk_f01500_s0_eye1.png", "vk_f01500_s1_eye0_named.png",
                                   "vk_f01500_s1_eye1_named.png", "xr_f00300_layer1_eye0.png", "xr_f00300_layer0_eye0.png",
                                   "xr_f00300_layer0_eye1.png", "frame_002.png", "notes.txt"])
        XCTAssertEqual(p.map(\.key), ["frame_002.png", "vk_f01500", "xr_f00300"])
        XCTAssertEqual(p[1].eye0, "vk_f01500_s1_eye0_named.png")
        XCTAssertEqual(p[1].eye1, "vk_f01500_s1_eye1_named.png")
        XCTAssertEqual(p[2].eye0, "xr_f00300_layer0_eye0.png")
        XCTAssertEqual(p[2].eye1, "xr_f00300_layer0_eye1.png")
        XCTAssertNil(p[0].eye1)
    }

    func testOneEye() {
        var (f, px) = frame("vk_f00100_s0_eye0.png", picture())
        f.otherEye = .black
        XCTAssertEqual(LabJudge.verdict(frames: [f], pixels: [px], summary: "").verdict, .oneEye)
        f.otherEye = .picture
        XCTAssertEqual(LabJudge.verdict(frames: [f], pixels: [px], summary: "").verdict, .picture)
    }

    func testFolderFromRealFilesAndJudgeJson() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("judge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let frames = dir.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        for (i, pixels) in [solid(0, 0, 0), picture(shift: 0), picture(shift: 100)].enumerated() {
            try png(pixels, to: frames.appendingPathComponent(String(format: "frame_%03d.png", i)))
        }
        let r = try LabJudge.write(folder: dir)
        XCTAssertEqual(r.frames.map(\.look), [.black, .picture, .picture])
        XCTAssertEqual(r.verdict, .picture)
        XCTAssertEqual(r.firstPicture, "frame_001.png")
        let back = try JSONDecoder().decode(LabJudge.Result.self, from: Data(contentsOf: dir.appendingPathComponent("judge.json")))
        XCTAssertEqual(back, r)
    }

    func png(_ pixels: [UInt8], to url: URL) throws {
        var data = pixels
        let image = data.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(data: buffer.baseAddress, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(image), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
}
