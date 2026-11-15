import CryptoKit
import Foundation
import XCTest
@testable import AVPPlayCore

/// A game whose picture comes out of its own files gets it from the files' origin before its parts are built.
final class ArchiveArtOriginTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-art-origin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A small PNG: what the origin serves.
    private func png(_ red: Double) -> Data {
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: red, green: 0.5, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func sha1(_ data: Data) -> String { Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func recipe(icon: String, background: String?, origin: String?) throws -> Recipe {
        let shipped = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes/vivecraft.json")
        var r = try JSONDecoder().decode(Recipe.self, from: Data(contentsOf: shipped))
        r.icon = .init(archive: .init(icon: icon, background: background, origin: origin))
        return r
    }

    func testThePictureComesFromTheOriginByContentAndIsKeptOnce() async throws {
        let icon = png(0.9), back = png(0.1)
        let iconName = sha1(icon), backName = sha1(back)
        let r = try recipe(icon: "assets/objects/\(iconName.prefix(2))/\(iconName)",
                           background: "assets/objects/\(backName.prefix(2))/\(backName)",
                           origin: "https://resources.example.net")
        let store = ContentStore(root: root)
        let asked = Asked()
        let served: @Sendable (URL) async -> Data? = { url in
            await asked.add(url.absoluteString)
            if url.lastPathComponent == iconName { return icon }
            if url.lastPathComponent == backName { return back }
            return nil
        }
        XCTAssertNil(ArchiveArt.hero(recipe: r, store: store), "no picture before anything is fetched")
        let made = await ArchiveArt.fetchFromOrigin(recipe: r, store: store, fetch: served)
        XCTAssertTrue(made)
        let urls = await asked.all
        XCTAssertEqual(Set(urls), ["https://resources.example.net/\(iconName.prefix(2))/\(iconName)",
                                    "https://resources.example.net/\(backName.prefix(2))/\(backName)"])
        let hero = try XCTUnwrap(ArchiveArt.hero(recipe: r, store: store), "the picture stands in for the parts")
        XCTAssertNotNil(ArchiveArt.largestImage(hero))
        let again = await ArchiveArt.fetchFromOrigin(recipe: r, store: store, fetch: served)
        XCTAssertFalse(again, "fetched once, not at every refresh")
        let count = await asked.all.count
        XCTAssertEqual(count, 2)
    }

    func testAFileWhoseContentIsNotItsNameIsDropped() async throws {
        let icon = png(0.9)
        let wrongName = String(repeating: "a", count: 40)
        let r = try recipe(icon: "assets/objects/aa/\(wrongName)", background: nil, origin: "https://resources.example.net")
        let store = ContentStore(root: root)
        let made = await ArchiveArt.fetchFromOrigin(recipe: r, store: store, fetch: { _ in icon })
        XCTAssertFalse(made)
        XCTAssertNil(ArchiveArt.hero(recipe: r, store: store))
    }

    func testOnlyHttpsOriginsAndContentNames() {
        XCTAssertNotNil(ArchiveArt.originBase("https://resources.download.minecraft.net"))
        XCTAssertNil(ArchiveArt.originBase("http://resources.download.minecraft.net"))
        XCTAssertNil(ArchiveArt.originBase("https://example.net/?a=b"))
        XCTAssertEqual(ArchiveArt.contentName("assets/objects/f0/f00657542252858a721e715a2e888a9226404e35"),
                       "f00657542252858a721e715a2e888a9226404e35")
        XCTAssertNil(ArchiveArt.contentName("assets/icons/icon_256x256.png"))
        XCTAssertNil(ArchiveArt.contentName("assets/objects/F0/F00657542252858A721E715A2E888A9226404E35"))
    }

    func testTheShippedRecipeNamesAnOriginItsPathsFit() throws {
        let shipped = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes/vivecraft.json")
        let r = try JSONDecoder().decode(Recipe.self, from: Data(contentsOf: shipped))
        let pictures = try XCTUnwrap(r.icon?.archive)
        XCTAssertNotNil(pictures.origin.flatMap(ArchiveArt.originBase))
        XCTAssertNotNil(ArchiveArt.contentName(pictures.icon))
        XCTAssertNotNil(pictures.background.flatMap(ArchiveArt.contentName))
    }
}

private actor Asked {
    var all: [String] = []
    func add(_ s: String) { all.append(s) }
}
