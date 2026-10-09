import XCTest
@testable import AVPPlayCore

final class RecipeTests: XCTestCase {
    func recipe(files: [RecipeFile], addons: Addons? = nil) -> Recipe {
        Recipe(schema: 1, id: "demo", title: "Demo", package: "com.example.demo", versionName: "1.0", versionCode: 7,
               store: .init(appId: "123"), toolchain: .init(target: "demo", minCommit: "abc"), files: files,
               addons: addons, status: .init(playability: "untested", download: "unknown", notes: nil), icon: nil)
    }
    func file(_ name: String, required: Bool = true, size: Int64? = 10, sha: String? = nil, locale: String? = nil,
              dest: String? = "android-files/obb") -> RecipeFile {
        RecipeFile(name: name, role: "x", id: "42", size: size, sha256: sha, required: required, dest: dest,
                   localName: nil, locale: locale, source: nil)
    }

    func testValidRecipePasses() throws {
        try recipe(files: [file("a.obb"), file("b.obb", sha: String(repeating: "a", count: 64))]).validate()
    }

    func testRejectsPathsLeadingOutside() {
        for bad in ["../x", "a/b", ".hidden", "", "..", "a\\b"] {
            XCTAssertThrowsError(try recipe(files: [file(bad)]).validate(), "Name \(bad)")
        }
        for bad in ["/etc", "a/../b", "a//b", "../x"] {
            XCTAssertThrowsError(try recipe(files: [file("a", dest: bad)]).validate(), "Ziel \(bad)")
        }
    }

    func testRejectsNonNumericIdsDuplicateNamesAndBadChecksums() {
        var f = file("a"); f.id = "12; rm -rf"
        XCTAssertThrowsError(try recipe(files: [f]).validate())
        XCTAssertThrowsError(try recipe(files: [file("a"), file("a")]).validate())
        XCTAssertThrowsError(try recipe(files: [file("a", sha: "xyz")]).validate())
        var r = recipe(files: [file("a")]); r.schema = 2
        XCTAssertThrowsError(try r.validate()) { XCTAssertEqual($0 as? RecipeError, .unsupportedSchema(2)) }
    }

    func testShippedRecipesLoadAndValidate() throws {
        // die mitgelieferten Rezepte: Paket liegt in <Projekt>/core, Rezepte in <Projekt>/recipes
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
        let all = try RecipeStore(directory: dir).loadAll()
        // Die sieben Referenzspiele sind da; dazu kommen Rezepte, die aus einem geprüften Entwurf entstanden sind.
        // Die tragen die Kennung des Entwurfs (`store-<App-Kennung>`), damit schon Geladenes weiter gilt.
        let ids = Set(all.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: ["alyx", "batman", "beatsaber140", "doom3quest", "moss", "walkabout", "wrath2"]))
        for recipe in all where !["alyx", "batman", "beatsaber140", "doom3quest", "moss", "walkabout", "wrath2"].contains(recipe.id) {
            XCTAssertEqual(recipe.id, recipe.store.appId.map(DraftRecipe.identifier(appId:)), "\(recipe.id)")
            XCTAssertEqual(recipe.status.playability, "verified", "\(recipe.id)")
            XCTAssertFalse(recipe.files.isEmpty, "\(recipe.id)")
        }
        let wrath = try XCTUnwrap(all.first { $0.id == "wrath2" })
        XCTAssertEqual(wrath.files.filter(\.required).count, 84)
        XCTAssertTrue(wrath.files.filter(\.required).allSatisfy { $0.sha256 != nil && $0.size != nil })
        let bs = try XCTUnwrap(all.first { $0.id == "beatsaber140" })
        XCTAssertEqual(bs.addons?.kind, .deliveredAssets)
        XCTAssertEqual(bs.addons?.items?.count, 248)
    }
}

final class FetchPlanTests: XCTestCase {
    let helper = RecipeTests()

    func testOnlyRequiredFilesUnlessSelected() {
        let r = helper.recipe(files: [helper.file("main.obb"), helper.file("de.obb", required: false, locale: "de-DE"),
                                      helper.file("fr.obb", required: false, locale: "fr-FR"),
                                      helper.file("extra.bin", required: false)])
        XCTAssertEqual(FetchPlan.wantedFiles(recipe: r, selection: .init()).map(\.name), ["main.obb"])
        XCTAssertEqual(FetchPlan.wantedFiles(recipe: r, selection: .init(locales: ["de-DE"])).map(\.name), ["main.obb", "de.obb"])
        XCTAssertEqual(FetchPlan.wantedFiles(recipe: r, selection: .init(optionalNames: ["extra.bin"])).map(\.name),
                       ["main.obb", "extra.bin"])
    }

    func testAddonsAreNeverPlannedWithoutConfirmedPurchase() {
        let items = [AddonItem(sku: "P1S1", name: "songa", id: "1", size: nil, sha256: nil, group: "p1"),
                     AddonItem(sku: "P1S2", name: "songb", id: "2", size: nil, sha256: nil, group: "p1")]
        let r = helper.recipe(files: [helper.file("main.obb")],
                              addons: Addons(kind: .deliveredAssets, dest: "android-files/klepton-assets", items: items))
        XCTAssertEqual(FetchPlan.wantedFiles(recipe: r, selection: .init()).map(\.name), ["main.obb"])
        XCTAssertEqual(FetchPlan.wantedFiles(recipe: r, selection: .init(ownedSKUs: ["P1S2", "P9S9"])).map(\.name),
                       ["main.obb", "songb"])
    }

    func testActionsFollowLocalState() {
        let r = helper.recipe(files: [helper.file("a"), helper.file("b"), helper.file("c"), helper.file("d"),
                                      helper.file("e", size: nil)])
        let states: [String: ContentStore.FileState] = ["a": .missing, "b": .present(size: 10), "c": .present(size: 9),
                                                        "d": .partial(4), "e": .partial(4)]
        let plan = FetchPlan.plan(recipe: r, selection: .init()) { states[$0.name]! }
        XCTAssertEqual(plan.map(\.action), [.download, .keep, .download, .resume(from: 4), .resume(from: 4)])
    }

    func testOnlyRestrictsThePlan() {
        let r = helper.recipe(files: [helper.file("a"), helper.file("b")])
        XCTAssertEqual(FetchPlan.wantedFiles(recipe: r, selection: .init(only: ["b"])).map(\.name), ["b"])
    }
}

final class MetaClientTests: XCTestCase {
    func testNextPageDropsTokenAndStaysOnHost() {
        let next = MetaClient.sanitizedNextPage("https://graph.oculus.com/1/viewer_purchases?after=abc&access_token=OCAsecretsecretsecretsecret&limit=200")
        XCTAssertEqual(next?.host, "graph.oculus.com")
        XCTAssertFalse(next!.absoluteString.contains("access_token"))
        XCTAssertTrue(next!.absoluteString.contains("after=abc"))
        XCTAssertNil(MetaClient.sanitizedNextPage("https://example.com/1/viewer_purchases?after=abc"))
        XCTAssertNil(MetaClient.sanitizedNextPage("http://graph.oculus.com/1/viewer_purchases"))
    }

    func testRequestCarriesTokenOnlyInHeader() {
        let r = MetaClient.request(MetaClient.graphURL(path: "/me", query: [URLQueryItem(name: "fields", value: "id")]),
                                   token: "FRLexampleexampleexample")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer FRLexampleexampleexample")
        XCTAssertFalse(r.url!.absoluteString.contains("FRL"))
    }

    func testContentRangeTotal() {
        XCTAssertEqual(DownloadDelegate.totalSize(contentRange: "bytes 0-4095/43406683"), 43406683)
        XCTAssertNil(DownloadDelegate.totalSize(contentRange: "bytes 0-4095/*"))
        XCTAssertNil(DownloadDelegate.totalSize(contentRange: nil))
    }

    func testSKUFilter() {
        XCTAssertTrue(MetaClient.isPlainSKU("P17S1"))
        XCTAssertFalse(MetaClient.isPlainSKU("a b"))
        XCTAssertFalse(MetaClient.isPlainSKU("a\nsku evil"))
        XCTAssertFalse(MetaClient.isPlainSKU(""))
    }
}

final class SupportTests: XCTestCase {
    func testRedaction() {
        let token = "FRL" + String(repeating: "a", count: 175)
        XCTAssertEqual(Redaction.redact("x \(token) y"), "x <REDACTED> y")
        XCTAssertEqual(Redaction.redact("https://h/?id=1&access_token=abcDEF123&x=2"), "https://h/?id=1&access_token=<REDACTED>&x=2")
        XCTAssertEqual(Redaction.redact("Authorization: Bearer abc.def"), "Authorization: Bearer <REDACTED>")
        XCTAssertEqual(Redaction.redact("nichts Geheimes"), "nichts Geheimes")
    }

    func testGateDelay() {
        let t0 = ContinuousClock.now
        XCTAssertEqual(RequestGate.delay(lastFinished: nil, now: t0, minInterval: .seconds(5)), .zero)
        XCTAssertEqual(RequestGate.delay(lastFinished: t0, now: t0 + .seconds(2), minInterval: .seconds(5)), .seconds(3))
        XCTAssertEqual(RequestGate.delay(lastFinished: t0, now: t0 + .seconds(9), minInterval: .seconds(5)), .zero)
    }

    func testSha256OfFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qi-hash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        XCTAssertEqual(try Hashing.sha256(of: url), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testStoreStates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qi-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = RecipeTests()
        let f = helper.file("a.obb")
        let r = helper.recipe(files: [f])
        let store = ContentStore(root: root)
        XCTAssertEqual(store.state(of: f, in: r), .missing)
        try FileManager.default.createDirectory(at: store.directory(for: r), withIntermediateDirectories: true)
        try Data(count: 4).write(to: store.partialURL(for: f, in: r))
        XCTAssertEqual(store.state(of: f, in: r), .partial(4))
        try Data(count: 10).write(to: store.url(for: f, in: r))
        XCTAssertEqual(store.state(of: f, in: r), .present(size: 10))
    }
}

final class AdopterTests: XCTestCase {
    func testAdoptsOnlyVerifiedFiles() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("qi-adopt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = tmp.appendingPathComponent("quelle/tief/er")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: source.appendingPathComponent("good.obb"))
        try Data("abd".utf8).write(to: source.appendingPathComponent("wrong.obb"))        // gleiche Größe, anderer Inhalt
        try Data("abc".utf8).write(to: source.appendingPathComponent("local.apk"))        // unter dem lokalen Namen
        try Data("abc".utf8).write(to: source.appendingPathComponent("nohash.bundle"))
        let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let helper = RecipeTests()
        var apk = helper.file("Store-Name.apk", size: 3, sha: abc); apk.localName = "local.apk"
        let recipe = helper.recipe(files: [helper.file("good.obb", size: 3, sha: abc), helper.file("wrong.obb", size: 3, sha: abc),
                                           apk, helper.file("nohash.bundle", size: 3), helper.file("absent.obb", size: 3, sha: abc)])
        let store = ContentStore(root: tmp.appendingPathComponent("bestand"))
        let first = try Adopter(store: store).adopt(recipe: recipe, from: [tmp.appendingPathComponent("quelle")])
        XCTAssertEqual(first.adopted.sorted(), ["Store-Name.apk", "good.obb"])
        XCTAssertEqual(first.mismatched, ["wrong.obb"])
        XCTAssertEqual(first.unverifiable, ["nohash.bundle"])
        XCTAssertEqual(first.notFound, ["absent.obb"])
        XCTAssertEqual(try Hashing.sha256(of: store.url(for: apk, in: recipe)), abc)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: helper.file("wrong.obb"), in: recipe).path))
        let second = try Adopter(store: store).adopt(recipe: recipe, from: [tmp.appendingPathComponent("quelle")])
        XCTAssertEqual(second.adopted, [])
        XCTAssertEqual(second.alreadyPresent, 2)
        // eine einzelne Datei als Quelle
        try Data("abc".utf8).write(to: tmp.appendingPathComponent("absent.obb"))
        let third = try Adopter(store: store).adopt(recipe: recipe, from: [tmp.appendingPathComponent("absent.obb")])
        XCTAssertEqual(third.adopted, ["absent.obb"])
    }
}

final class ApkUnpackerTests: XCTestCase {
    func testEntryFilterAndSafety() {
        XCTAssertTrue(ApkUnpacker.wanted("assets/bin/Data/x"))
        XCTAssertTrue(ApkUnpacker.wanted("lib/arm64-v8a/libmain.so"))
        XCTAssertFalse(ApkUnpacker.wanted("lib/armeabi-v7a/libmain.so"))
        XCTAssertFalse(ApkUnpacker.wanted("classes.dex"))
        XCTAssertTrue(ApkUnpacker.isSafeEntry("assets/a/b"))
        XCTAssertFalse(ApkUnpacker.isSafeEntry("../etc/passwd"))
        XCTAssertFalse(ApkUnpacker.isSafeEntry("assets/../../x"))
        XCTAssertFalse(ApkUnpacker.isSafeEntry("/abs"))
    }

    func testValueFormatting() {
        XCTAssertEqual(AXML.floatText(Float(2.1).bitPattern), "2.1")
        XCTAssertEqual(AXML.escape("a&b<c>\"d"), "a&amp;b&lt;c&gt;&quot;d")
        XCTAssertEqual(AXML.typedValue(type: 0x12, data: 1, raw: 0xFFFF_FFFF, strings: []), "true")
        XCTAssertEqual(AXML.typedValue(type: 0x10, data: 0xFFFF_FFFF, raw: 0xFFFF_FFFF, strings: []), "-1")
        XCTAssertEqual(AXML.typedValue(type: 0x01, data: 0x7f090021, raw: 0xFFFF_FFFF, strings: []), "@0x7f090021")
        XCTAssertEqual(AXML.typedValue(type: 0x03, data: 1, raw: 1, strings: ["a", "b"]), "b")
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try AXML.decode(Data([1, 2, 3])))
        XCTAssertThrowsError(try AXML.decode(Data([3, 0, 8, 0, 0xFF, 0xFF, 0xFF, 0x7F, 1, 0, 8, 0, 0xFF, 0xFF, 0, 0])))
    }
}

final class StageTests: XCTestCase {
    let helper = RecipeTests()

    func testDestinations() {
        var apk = helper.file("Store.apk", dest: ""); apk.localName = "game.apk"
        XCTAssertEqual(StagePlan.destination(for: apk), "Documents/game.apk")
        XCTAssertEqual(StagePlan.destination(for: helper.file("main.obb", dest: "android-files/obb")), "Documents/android-files/obb/main.obb")
        XCTAssertNil(StagePlan.destination(for: helper.file("de.lang", dest: nil)))
    }

    func testOnlyMissingOrChangedFilesAreCopied() {
        let u = URL(fileURLWithPath: "/x")
        let a = helper.file("a.obb"), b = helper.file("b.obb"), c = helper.file("c.obb"), d = helper.file("d.lang", dest: nil)
        let items = StagePlan.plan(local: [(a, u, 10), (b, u, 10), (c, u, 10), (d, u, 10)],
                                   remote: ["Documents/android-files/obb/a.obb": 10, "Documents/android-files/obb/b.obb": 9])
        XCTAssertEqual(items.map(\.destination), ["Documents/android-files/obb/b.obb", "Documents/android-files/obb/c.obb"])
    }

    func testAddonFileContents() {
        let items = [AddonItem(sku: "P1S2", name: "songb", id: "22", size: nil, sha256: nil, group: nil),
                     AddonItem(sku: "P1S1", name: "songa", id: "11", size: nil, sha256: nil, group: nil)]
        XCTAssertEqual(AddonFiles.assetIndex(items),
                       "# klepton-assets v1 — vom Store gelieferte Zusatzdateien\nasset 11 songa\nasset 22 songb\n")
        let text = AddonFiles.entitlements(appId: "123", skus: ["Tiki", "Alice"], verified: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(text.contains("app_id 123\nverified 1970-01-01T00:00:00Z\nsku Alice\nsku Tiki\n"))
    }

    func testConfirmedPurchasesSurviveAFailedRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qi-purch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ContentStore(root: root)
        let r = helper.recipe(files: [helper.file("a")])
        struct Offline: Error {}

        let none = await PurchaseRecord.refresh(store: store, recipe: r) { _ in throw Offline() }
        XCTAssertNil(none)                                             // nie bestätigt: nichts freischalten

        let first = await PurchaseRecord.refresh(store: store, recipe: r) { _ in ["B", "A"] }
        XCTAssertEqual(first?.record.skus, ["A", "B"]); XCTAssertEqual(first?.source, .fresh)

        let failed = await PurchaseRecord.refresh(store: store, recipe: r) { _ in throw Offline() }
        XCTAssertEqual(failed?.record.skus, ["A", "B"])                // bestätigter Stand bleibt
        if case .cached = failed?.source {} else { XCTFail("erwartet: zwischengespeicherter Stand") }

        let refunded = await PurchaseRecord.refresh(store: store, recipe: r) { _ in ["A"] }
        XCTAssertEqual(refunded?.record.skus, ["A"])                   // erfolgreiche Abfrage ersetzt (Rückgabe wird sichtbar)
    }

    func testDeviceJsonParsing() throws {
        let devices = #"{"result":{"devices":[{"hardwareProperties":{"platform":"visionOS","reality":"physical","udid":"U1"},"connectionProperties":{"tunnelState":"connected","pairingState":"paired"},"deviceProperties":{"name":"VP","osVersionNumber":"27.2","developerModeStatus":"enabled"}},{"hardwareProperties":{"platform":"visionOS","reality":"simulated","udid":"S1"}},{"hardwareProperties":{"platform":"iOS","reality":"physical","udid":"I1"}}]}}"#
        XCTAssertEqual(try DeviceControl.parseDevices(Data(devices.utf8)),
                       [Device(udid: "U1", name: "VP", osVersion: "27.2", reachable: true, paired: true, developerMode: true)])
        let files = #"{"result":{"files":[{"metadata":{"size":8964688},"name":"a","relativePath":"a","resources":{"isDirectory":false}},{"metadata":{"size":96},"relativePath":"dir","resources":{"isDirectory":true}}]}}"#
        XCTAssertEqual(try DeviceControl.parseFiles(Data(files.utf8)),
                       [RemoteFile(relativePath: "a", size: 8964688, isDirectory: false), RemoteFile(relativePath: "dir", size: 96, isDirectory: true)])
    }

    func testDefaultBundleId() {
        XCTAssertEqual(Toolchain.defaultBundleId(target: "moss", user: "Anna"), "anna.dev.klepton.target.moss")
    }
}

final class AppIconTests: XCTestCase {
    /// Ein einfarbiges Testbild als PNG.
    func png(_ size: Int, red: CGFloat) -> Data {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: red, green: 0.2, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    func testLayersAreFullSizeAndBackIsOpaque() throws {
        for source in [AppIcon.Source.single(png(192, red: 1)), .adaptive(background: png(432, red: 0), foreground: png(432, red: 1)),
                       .adaptive(background: nil, foreground: png(432, red: 1))] {
            let layers = try XCTUnwrap(AppIcon.layers(from: source))
            for data in [layers.back, layers.middle, layers.front] {
                let image = try XCTUnwrap(AppIcon.image(data))
                XCTAssertEqual(image.width, 1024); XCTAssertEqual(image.height, 1024)
            }
            let back = try XCTUnwrap(AppIcon.image(layers.back))
            XCTAssertTrue([.none, .noneSkipLast, .noneSkipFirst].contains(back.alphaInfo), "hinterste Ebene muss deckend sein")
        }
    }

    func testWritesImageStack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qi-icon-\(UUID().uuidString).solidimagestack")
        defer { try? FileManager.default.removeItem(at: dir) }
        try AppIcon.writeImageStack(.single(png(192, red: 1)), to: dir)
        for layer in ["Front", "Middle", "Back"] {
            let base = dir.appendingPathComponent("\(layer).solidimagestacklayer/Content.imageset")
            XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("\(layer.lowercased()).png").path))
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent("Contents.json"))) as? [String: Any]
            XCTAssertNotNil(json?["images"])
        }
        let top = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("Contents.json"))) as? [String: Any]
        XCTAssertEqual((top?["layers"] as? [[String: String]])?.count, 3)
    }

    func testDensityRanking() {
        XCTAssertGreaterThan(ResourceTable.rank(640), ResourceTable.rank(480))
        XCTAssertEqual(ResourceTable.rank(0xFFFE), 0); XCTAssertEqual(ResourceTable.rank(0), 0)
        XCTAssertTrue(AppIcon.isBitmap("res/Gx.PNG")); XCTAssertFalse(AppIcon.isBitmap("res/a.xml"))
    }

    func testPlaceholderAndCustomIcon() throws {
        let ordinary = AppIcon.Source.single(png(64, red: 0.5))
        XCTAssertFalse(AppIcon.isEnginePlaceholder(ordinary))
        XCTAssertEqual(AppIcon.fingerprint(ordinary).count, 64)
        // bei zweiteiligen Icons zählt der Vordergrund
        XCTAssertEqual(AppIcon.fingerprint(.adaptive(background: png(8, red: 0), foreground: png(64, red: 0.5))),
                       AppIcon.fingerprint(ordinary))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qi-custom-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(AppIcon.custom(at: url))                      // gibt es nicht
        try Data("kein Bild".utf8).write(to: url)
        XCTAssertNil(AppIcon.custom(at: url))                      // kein Bild
        try png(256, red: 1).write(to: url)
        XCTAssertNotNil(AppIcon.custom(at: url))
    }

    func testResourceTableRejectsGarbage() {
        XCTAssertThrowsError(try ResourceTable.candidates(arsc: Data([1, 2, 3]), resourceId: 0x7f010000))
    }
}

final class StoreArtTests: XCTestCase {
    func testImageURLsFromStorePage() {
        let page = """
        <html><script type="application/ld+json" nonce="x">{"@context":"https://schema.org","@graph":[{"@type":["SoftwareApplication","Product"],"name":"Demo","image":[{"@id":"https://scontent-fra5-1.oculuscdn.com/v/a.webp?sig=1"},{"@id":"https://evil.example.com/b.webp"},{"@id":"http://scontent.oculuscdn.com/c.webp"},{"@id":"https://scontent.xx.fbcdn.net/d.webp"}]}]}</script></html>
        """
        XCTAssertEqual(StoreArt.imageURLs(inStorePage: page).map(\.host), ["scontent-fra5-1.oculuscdn.com", "scontent.xx.fbcdn.net"])
        XCTAssertEqual(StoreArt.imageURLs(inStorePage: "<html>nichts</html>"), [])
    }

    func testSquareCoverRule() {
        XCTAssertTrue(StoreArt.isSquareCover(width: 1440, height: 1440))
        XCTAssertTrue(StoreArt.isSquareCover(width: 1440, height: 1430))
        XCTAssertFalse(StoreArt.isSquareCover(width: 2560, height: 1440))
        XCTAssertFalse(StoreArt.isSquareCover(width: 1008, height: 1440))
        XCTAssertFalse(StoreArt.isSquareCover(width: 96, height: 96))
    }
}

final class SpecialAppTests: XCTestCase {
    let helper = RecipeTests()

    func testSourcesAreValidated() throws {
        var free = helper.file("port.apk", sha: String(repeating: "a", count: 64)); free.id = ""
        free.source = FileSource(kind: .url, url: "https://example.org/port.apk", hint: nil)
        var own = helper.file("pak000.pk4"); own.id = ""
        own.source = FileSource(kind: .user, url: nil, hint: "aus deinem Steam-Kauf")
        try helper.recipe(files: [free, own]).validate()

        var noHash = free; noHash.sha256 = nil                           // freier Download ohne Prüfsumme
        XCTAssertThrowsError(try helper.recipe(files: [noHash]).validate())
        var plain = free; plain.source?.url = "http://example.org/port.apk"   // kein https
        XCTAssertThrowsError(try helper.recipe(files: [plain]).validate())
        var storeWithoutId = helper.file("x.obb"); storeWithoutId.id = ""     // Store-Datei braucht eine ID
        XCTAssertThrowsError(try helper.recipe(files: [storeWithoutId]).validate())
    }

    func testUserFilesAreNeverPlannedForDownload() {
        var own = helper.file("pak000.pk4"); own.source = FileSource(kind: .user, url: nil, hint: nil)
        let r = helper.recipe(files: [own, helper.file("main.obb")])
        let missing = FetchPlan.plan(recipe: r, selection: .init()) { _ in .missing }
        XCTAssertEqual(missing.map(\.action), [.needsUser, .download])
        let present = FetchPlan.plan(recipe: r, selection: .init()) { _ in .present(size: 10) }
        XCTAssertEqual(present.map(\.action), [.keep, .keep])
    }

    func testSteamLibraryIcon() throws {
        let tests = AppIconTests()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qi-steam-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(AppIcon.steamLibrary(appId: "9050", cacheRoots: [root]))
        let dir = root.appendingPathComponent("9050")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try tests.png(64, red: 0).write(to: dir.appendingPathComponent("library_hero.jpg"))
        try tests.png(64, red: 1).write(to: dir.appendingPathComponent("logo.png"))
        let source = try XCTUnwrap(AppIcon.steamLibrary(appId: "9050", cacheRoots: [root]))
        let layers = try XCTUnwrap(AppIcon.layers(from: source))
        XCTAssertEqual(AppIcon.image(layers.back)?.width, 1024)
        XCTAssertEqual(AppIcon.image(layers.front)?.height, 1024)
        XCTAssertNil(AppIcon.steamLibrary(appId: "../etc", cacheRoots: [root]))
    }
}

final class TreeTests: XCTestCase {
    let helper = RecipeTests()

    func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qi-tree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func tree(_ name: String = "game", role: RecipeTree.Role = .game, markers: [RecipeTree.Marker]) -> RecipeTree {
        RecipeTree(name: name, role: role, source: .init(kind: .user, url: nil, hint: nil), markers: markers)
    }

    func recipe(trees: [RecipeTree]) -> Recipe {
        var r = helper.recipe(files: [])
        r.trees = trees
        return r
    }

    func testTreesAreValidated() throws {
        let sha = String(repeating: "a", count: 64)
        try recipe(trees: [tree(markers: [.init(path: "bin/app", size: 3, sha256: sha)])]).validate()
        // ohne Kenndatei wäre jeder Ordner recht
        XCTAssertThrowsError(try recipe(trees: [tree(markers: [])]).validate())
        for bad in ["../x", "/etc/passwd", "a/../b", ""] {
            XCTAssertThrowsError(try recipe(trees: [tree(markers: [.init(path: bad, size: nil, sha256: sha)])]).validate(), bad)
        }
        XCTAssertThrowsError(try recipe(trees: [tree(markers: [.init(path: "a", size: nil, sha256: "kurz")])]).validate())
        XCTAssertThrowsError(try recipe(trees: [tree("../x", markers: [.init(path: "a", size: nil, sha256: sha)])]).validate())
        // Ein Ordner aus dem Netz ist ein Archiv mit Prüfsumme – ohne sie, mit http oder mit einem Ordner, der aus dem
        // Archiv hinausführt, fällt das Rezept durch.
        func fromNet(_ url: String?, _ archive: ArchiveSource?) -> RecipeTree {
            var t = tree(markers: [.init(path: "bin/app", size: 3, sha256: sha)])
            t.source = FileSource(kind: .url, url: url, hint: nil, steam: nil, archive: archive)
            return t
        }
        try recipe(trees: [fromNet("https://example.org/a.tar.gz", .init(sha256: sha, size: 10, folder: "files"))]).validate()
        try recipe(trees: [fromNet("https://example.org/a.tar.gz", .init(sha256: sha, size: nil, folder: nil))]).validate()
        for bad in [fromNet("https://example.org/a.tar.gz", nil), fromNet("http://example.org/a.tar.gz", .init(sha256: sha, size: 1, folder: nil)),
                    fromNet(nil, .init(sha256: sha, size: 1, folder: nil)), fromNet("https://example.org/a.tar.gz", .init(sha256: "kurz", size: 1, folder: nil)),
                    fromNet("https://example.org/a.tar.gz", .init(sha256: sha, size: 1, folder: "../x")),
                    fromNet("https://example.org/a.tar.gz", .init(sha256: sha, size: 1, folder: ""))] {
            XCTAssertThrowsError(try recipe(trees: [bad]).validate(), "\(bad.source)")
        }
        // jede Rolle höchstens einmal
        XCTAssertThrowsError(try recipe(trees: [tree("a", markers: [.init(path: "a", size: nil, sha256: sha)]),
                                                tree("b", markers: [.init(path: "a", size: nil, sha256: sha)])]).validate())
    }

    func testAdoptsOnlyTheTreeTheRecipeDescribes() throws {
        let dir = try scratch()
        let fm = FileManager.default
        let right = dir.appendingPathComponent("richtig"), wrong = dir.appendingPathComponent("falsch")
        for (base, content) in [(right, "abc"), (wrong, "xyz")] {
            try fm.createDirectory(at: base.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: base.appendingPathComponent("bin/app"))
            try Data("daten".utf8).write(to: base.appendingPathComponent("inhalt.bin"))
            try fm.createSymbolicLink(atPath: base.appendingPathComponent("verweis").path, withDestinationPath: "inhalt.bin")
        }
        let sha = try Hashing.sha256(of: right.appendingPathComponent("bin/app"))
        let r = recipe(trees: [tree(markers: [.init(path: "bin/app", size: 3, sha256: sha)])])
        let store = TreeStore(store: ContentStore(root: dir.appendingPathComponent("bestand")))

        XCTAssertEqual(store.missing(recipe: r).map(\.name), ["game"])
        XCTAssertEqual(try store.adopt(recipe: r, from: [wrong]).notFound, ["game"])
        XCTAssertEqual(store.missing(recipe: r).count, 1)

        XCTAssertEqual(try store.adopt(recipe: r, from: [wrong, right]).adopted, ["game"])
        XCTAssertTrue(store.missing(recipe: r).isEmpty)
        let target = store.url(for: r.trees![0], in: r)
        // Links bleiben Links, und das Verzeichnis zählt nur reguläre Dateien
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: target.appendingPathComponent("verweis").path), "inhalt.bin")
        XCTAssertEqual(TreeStore.listing(of: target), ["bin/app": 3, "inhalt.bin": 5])
        XCTAssertEqual(try store.adopt(recipe: r, from: [right]).alreadyPresent, ["game"])
        XCTAssertEqual(store.toolchainEnvironment(recipe: r), ["KL_LX_GAME": target.path])
        // die Quelle bleibt unberührt
        XCTAssertEqual(try String(contentsOf: right.appendingPathComponent("bin/app"), encoding: .utf8), "abc")
    }
}

final class LoginTests: XCTestCase {
    let token = "FRL" + String(repeating: "aB3dE6gH9", count: 19) + "xyz1"      // 178 Zeichen, frei erfunden

    func testSieveHoldsBackTheTokenButNotThePrompts() {
        var sieve = TokenSieve()
        var shown = sieve.feed(Array("Email: ".utf8))
        for c in "marcel".utf8 { shown += sieve.feed([c]) }              // Echo beim Tippen: Zeichen für Zeichen
        shown += sieve.feed(Array("@example.org\r\nPassword: \r\nAccess token: \(token)\r\n".utf8))
        shown += sieve.finish()
        let text = String(decoding: shown, as: UTF8.self)
        XCTAssertEqual(sieve.token, token)
        XCTAssertFalse(text.contains(token.prefix(12)), "kein Stück des Tokens darf durchgehen")
        XCTAssertEqual(text, "Email: marcel@example.org\r\nPassword: \r\nAccess token: \(TokenSieve.placeholder)\r\n")
    }

    func testSieveHandlesATokenSplitAcrossReadsAndAtTheVeryEnd() {
        var sieve = TokenSieve()
        let bytes = Array(token.utf8)
        var shown = sieve.feed(bytes[..<100]) + sieve.feed(bytes[100...])
        shown += sieve.finish()
        XCTAssertEqual(sieve.token, token)
        XCTAssertEqual(String(decoding: shown, as: UTF8.self), TokenSieve.placeholder)
        // lange Wörter, die kein Token sind, bleiben lesbar
        var other = TokenSieve()
        let word = String(repeating: "a", count: 40)
        XCTAssertEqual(String(decoding: other.feed(Array("\(word) fertig".utf8)) + other.finish(), as: UTF8.self), "\(word) fertig")
        XCTAssertNil(other.token)
    }

    /// Ein Attrappen-Werkzeug an Stelle von ovr-platform-util: fragt wie das echte interaktiv ab und gibt am Ende
    /// einen (erfundenen) Token aus. Geprüft wird der Weg durch das Pseudo-Terminal, nicht Metas Anmeldung.
    func testLoginRelaysInputAndReturnsOnlyTheToken() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qi-login-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("fake-tool")
        try """
        #!/bin/bash
        [ "$1" = get-access-token ] || exit 9
        if : < /dev/tty; then echo "steuerndes Terminal vorhanden"; else echo "KEIN steuerndes Terminal"; fi
        printf 'Email: '; read -r email
        printf 'Password: '; read -rs password; echo
        [ "$email" = "user@example.org" ] && [ "$password" = "geheim" ] || { echo "falsche Eingabe"; exit 3; }
        echo "Access token: \(token)"
        """.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        // Wie ein Mensch: erst tippen, wenn die Aufforderung dasteht. (Vorab Getipptes würde das Terminal
        // anzeigen, solange das Werkzeug das Echo noch nicht abgeschaltet hat – wie an jedem Terminal.)
        let keys = Pipe(), screen = Pipe()
        let result = LockedBox<Result<String, Error>?>(nil)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            result.set(Result { try MetaLogin.run(tool: tool, input: keys.fileHandleForReading.fileDescriptor,
                                                  output: screen.fileHandleForWriting.fileDescriptor) })
            try? screen.fileHandleForWriting.close()
            done.signal()
        }
        var shown = ""
        var answered = 0
        let answers = [("Email: ", "user@example.org\n"), ("Password: ", "geheim\n")]
        while true {
            let chunk = screen.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            shown += String(decoding: chunk, as: UTF8.self)
            if answered < answers.count, shown.contains(answers[answered].0) {
                Thread.sleep(forTimeInterval: 0.3)
                keys.fileHandleForWriting.write(Data(answers[answered].1.utf8))
                answered += 1
            }
        }
        done.wait()
        let got = try XCTUnwrap(result.get()).get()
        XCTAssertEqual(got, token)
        XCTAssertTrue(shown.contains("steuerndes Terminal vorhanden"), shown)
        XCTAssertTrue(shown.contains("Email: ") && shown.contains(TokenSieve.placeholder), shown)
        XCTAssertFalse(shown.contains(token.prefix(12)), "der Token darf nicht auf dem Bildschirm erscheinen")
        XCTAssertFalse(shown.contains("geheim"), "das Passwort wird nicht angezeigt")

        // falsche Eingabe: das Werkzeug bricht ab, es gibt keinen Token
        let keys2 = Pipe(), screen2 = Pipe()
        keys2.fileHandleForWriting.write(Data("user@example.org\nfalsch\n".utf8))
        XCTAssertThrowsError(try MetaLogin.run(tool: tool, input: keys2.fileHandleForReading.fileDescriptor,
                                               output: screen2.fileHandleForWriting.fileDescriptor)) {
            XCTAssertEqual($0 as? LoginError, .toolFailed(3))
        }
    }

    func testOnlyMetaSignedToolIsAccepted() throws {
        // irgendein anderes signiertes Programm des Systems ist nicht Metas Werkzeug
        XCTAssertThrowsError(try MetaTool(url: URL(fileURLWithPath: "/bin/ls")).verify()) {
            guard case .wrongSigner = $0 as? LoginError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try MetaTool(url: URL(fileURLWithPath: "/nicht/vorhanden")).verify()) {
            XCTAssertEqual($0 as? LoginError, .toolMissing("/nicht/vorhanden"))
        }
    }

    func testMetasOwnToolIsAcceptedWhereInstalled() throws {
        let tool = MetaTool(url: MetaTool.defaultURL)
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: tool.url.path), "ovr-platform-util liegt hier nicht")
        XCTAssertNoThrow(try tool.verify())
    }

    func testKeychainRoundTripWithoutTruncation() throws {
        // eigener Dienstname nur für diesen Test; der echte Eintrag wird nicht berührt
        let store = TokenStore(service: "questinstaller-selbsttest")
        defer { _ = try? store.delete(account: "probe") }
        try store.write(token: token, account: "probe")
        XCTAssertEqual(try store.read(account: "probe").count, 178)
        XCTAssertEqual(try store.read(account: "probe"), token)
        XCTAssertTrue(try store.delete(account: "probe"))
        XCTAssertThrowsError(try store.read(account: "probe"))
        XCTAssertThrowsError(try store.write(token: "zu kurz", account: "probe"))
        XCTAssertThrowsError(try store.write(token: token, account: "a b; rm"))
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}

final class JobTests: XCTestCase {
    let helper = RecipeTests()
    struct Boom: Error, CustomStringConvertible { var description: String }

    func setup() throws -> (JobStore, Job) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qi-jobs-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let recipe = helper.recipe(files: [helper.file("main.obb")])
        var request = InstallRequest(toolchain: "/pfad/zur/toolchain")
        request.team = "ABCDE12345"
        request.locales = ["de-DE"]
        return (JobStore(directory: dir), Job(recipe: recipe, request: request, toolchainCommit: "abc1234"))
    }

    func testRunsAllStepsInOrderAndPersistsTheResult() async throws {
        let (store, job) = try setup()
        let seen = LockedBox<[InstallStep]>([])
        let done = try await JobRunner(store: store).run(job, currentToolchain: "abc1234") { step, _ in seen.set(seen.get() + [step]) }
        XCTAssertEqual(seen.get(), [.account, .fetch, .build, .stage, .unlock])
        XCTAssertEqual(done.state, .finished)
        let saved = try store.load(job.id)
        XCTAssertEqual(saved.state, .finished)
        XCTAssertEqual(saved.completed, InstallStep.allCases)
        XCTAssertEqual(saved.request.locales, ["de-DE"])             // die Angaben des Nutzers sind eingefroren
        XCTAssertEqual(saved.recipe.files.map(\.name), ["main.obb"]) // das Rezept ebenso
        // ein abgeschlossener Auftrag läuft nicht noch einmal
        do { _ = try await JobRunner(store: store).run(saved, currentToolchain: "abc1234") { _, _ in }; XCTFail() }
        catch { XCTAssertEqual(error as? JobError, .alreadyFinished(job.id)) }
    }

    func testFailureIsRecordedAndResumeContinuesAtTheFailedStep() async throws {
        let (store, job) = try setup()
        let runner = JobRunner(store: store)
        let secret = "FRL" + String(repeating: "x", count: 120)
        do {
            _ = try await runner.run(job, currentToolchain: "abc1234") { step, _ in
                if step == .build { throw Boom(description: "Build fehlgeschlagen, access_token=\(secret)") }
            }
            XCTFail("hätte abbrechen müssen")
        } catch {}
        let stopped = try store.load(job.id)
        XCTAssertEqual(stopped.state, .failed)
        XCTAssertEqual(stopped.current, .build)
        XCTAssertEqual(stopped.completed, [.account, .fetch])
        XCTAssertFalse(try String(contentsOf: store.directory.appendingPathComponent("\(job.id).json"), encoding: .utf8).contains(secret),
                       "ein Token darf nicht in der Auftragsdatei landen")
        XCTAssertNotNil(stopped.failure)

        let seen = LockedBox<[InstallStep]>([])
        let done = try await runner.run(stopped, currentToolchain: "abc1234") { step, _ in seen.set(seen.get() + [step]) }
        XCTAssertEqual(seen.get(), [.build, .stage, .unlock], "Erledigtes wird nicht wiederholt")
        XCTAssertEqual(done.state, .finished)
        XCTAssertEqual(done.attempts, 2)
        XCTAssertNil(done.failure)
    }

    func testInterruptedJobResumesAndFrozenToolchainIsEnforced() async throws {
        let (store, job) = try setup()
        // so sieht ein Auftrag aus, dessen Programm mitten im Kopieren beendet wurde
        var interrupted = job
        interrupted.state = .running
        interrupted.current = .stage
        interrupted.completed = [.account, .fetch, .build]
        try store.save(interrupted)
        XCTAssertEqual(store.all().map(\.id), [job.id])

        do { _ = try await JobRunner(store: store).run(try store.load(job.id), currentToolchain: "fff0000") { _, _ in }; XCTFail() }
        catch { XCTAssertEqual(error as? JobError, .toolchainChanged(was: "abc1234", now: "fff0000")) }

        let seen = LockedBox<[InstallStep]>([])
        _ = try await JobRunner(store: store).run(try store.load(job.id), currentToolchain: "abc1234") { step, _ in seen.set(seen.get() + [step]) }
        XCTAssertEqual(seen.get(), [.stage, .unlock])
    }

    func testCancelledJobDoesNotRunAndUnknownIdsAreRejected() async throws {
        let (store, job) = try setup()
        try store.save(job)
        let runner = JobRunner(store: store)
        XCTAssertEqual(try runner.cancel(job.id).state, .cancelled)
        do { _ = try await runner.run(try store.load(job.id), currentToolchain: "abc1234") { _, _ in }; XCTFail() }
        catch { XCTAssertEqual(error as? JobError, .cancelled(job.id)) }
        XCTAssertThrowsError(try store.load("../../etc/passwd")) { XCTAssertEqual($0 as? JobError, .notFound("../../etc/passwd")) }
        XCTAssertThrowsError(try store.load("gibt-es-nicht"))
    }
}

final class UntestedGameTests: XCTestCase {
    // Erfundene Kennungen im Format, das Metas Werkzeug schreibt.
    let listing = """
    {"type":"log","level":"info","message":"Logs are written to: /tmp/oc_cli.log"}
    {"type":"log","level":"info","message":"\\nThe following file(s) would be downloaded:"}
    {"type":"log","level":"info","message":"  Some Game-Android-Shipping-arm64.apk  62.7MB  [APK] 8254815691289807"}
    {"type":"log","level":"info","message":"\\nApp contains corresponding OBB file: 8254813211290055."}
    {"type":"log","level":"info","message":"  main.151047.com.example.game.obb  2.4GB  [OBB] 8254813211290055"}
      plain text line.bundle  140KB  [ASSET] 24544644515232330
      ../escape.bundle  1KB  [ASSET] 24544644515232331
      no-id.bundle  1KB  [ASSET] abc
    {"type":"log","level":"info","message":"\\nTotal time: 0m 0s.\\n"}
    """

    func testListingIsReadFromJsonAndPlainLines() {
        let files = MetaListing.parse(listing)
        XCTAssertEqual(files.map(\.name), ["Some Game-Android-Shipping-arm64.apk", "main.151047.com.example.game.obb", "plain text line.bundle"])
        XCTAssertEqual(files.map(\.kind), ["APK", "OBB", "ASSET"])
        XCTAssertEqual(files[1].id, "8254813211290055")
        XCTAssertEqual(files[1].sizeText, "2.4GB")
        XCTAssertEqual(MetaListing.reason(in: #"{"type":"log","level":"error","message":"Cannot find apk with ID 1"}"# + "\n"), "Cannot find apk with ID 1")
        XCTAssertEqual(MetaListing.parse("nothing here"), [])
    }

    func testDraftRecipePlacesFilesByEngineAndIsMarkedUntested() throws {
        let game = CatalogGame(appId: "1921533091289407", title: "Some Game", package: "com.example.game", publisher: nil, status: "untested",
                               noteEn: nil, noteDe: nil, target: "somegame", works: 0, problems: 0, fails: 0, build: nil)
        let build = CatalogBuild(buildId: "8254815691289807", version: "1.2", versionCode: 151047, fileName: nil)
        let files = MetaListing.parse(listing)
        let draft = try DraftRecipe.make(game: game, build: build, files: files, target: "somegame", minCommit: "abc1234")
        XCTAssertEqual(draft.id, "store-1921533091289407")
        XCTAssertEqual(draft.status.playability, "untested")
        XCTAssertEqual(draft.files.map(\.role), ["apk", "main-obb", "content-bundle"])
        XCTAssertEqual(draft.files[0].localName, "somegame.apk")
        XCTAssertEqual(draft.files[0].id, "8254815691289807")
        XCTAssertEqual(draft.files[1].dest, DraftRecipe.obbPlaceholder, "den Ort setzt die Toolchain beim Kopieren ein")
        XCTAssertEqual(draft.files[2].dest, "android-files/Android/obb/com.example.game")
        XCTAssertTrue(draft.files.allSatisfy { $0.sha256 == nil && $0.size == nil && $0.source == nil }, "nichts als Metas Kennungen")
        XCTAssertThrowsError(try DraftRecipe.make(game: game, build: build, files: Array(files.dropFirst()), target: "somegame", minCommit: "abc1234"))

        // Ein Spiel, das die Toolchain nicht kennt, bekommt einen Namen aus seiner Store-Kennung.
        let generic = DraftRecipe.genericTarget(appId: game.appId)
        XCTAssertEqual(generic, "x1921533091289407")
        XCTAssertTrue(DraftRecipe.isGeneric(generic))
        for name in ["superhot", "x", "x12", "x1921533091289407a", "xx1921533091289407"] { XCTAssertFalse(DraftRecipe.isGeneric(name), name) }
        let attempt = try DraftRecipe.make(game: game, build: build, files: files, target: generic, minCommit: "abc1234")
        XCTAssertEqual(attempt.files[0].localName, "x1921533091289407.apk")
        XCTAssertEqual(Toolchain.genericEnvironment(recipe: attempt), ["KLEPTON_GENERIC_TARGET": "x1921533091289407", "KLEPTON_GENERIC_DISPLAY": "Some Game"])
        XCTAssertEqual(Toolchain.genericEnvironment(recipe: draft), [:])
        XCTAssertEqual(Toolchain.defaultBundleId(target: generic, user: "anna"), "anna.dev.klepton.target.x1921533091289407")
    }

    func testCatalogueEntriesFromTheServerAreChecked() throws {
        func game(_ json: String) -> CatalogGame? { try? JSONDecoder().decode(CatalogGame.self, from: Data(json.utf8)) }
        let good = #"{"appId":"1921533091289407","title":"SUPERHOT VR","package":"unity.x","status":"untested","works":1,"problems":0,"fails":0,"target":"superhot","build":{"buildId":"24922928844056506","version":"1.161","versionCode":161}}"#
        XCTAssertEqual(game(good)?.isSane, true)
        XCTAssertEqual(game(good.replacingOccurrences(of: "1921533091289407", with: "19215 OR 1"))?.isSane, false)
        XCTAssertEqual(game(good.replacingOccurrences(of: "24922928844056506", with: "../../x"))?.isSane, false)
        XCTAssertEqual(game(good.replacingOccurrences(of: "superhot", with: "a b;rm"))?.isSane, false)
        XCTAssertEqual(game(good.replacingOccurrences(of: "SUPERHOT VR", with: "a\\u0007b"))?.isSane, false)
        let feedback = CatalogFeedback(appId: "1", versionCode: 1, result: .works, comment: "  " + String(repeating: "x", count: 2000), appVersion: "1", toolchain: "206", lang: "en")
        XCTAssertEqual(feedback.comment.count, 1000)
    }
}

final class AnonymizeTests: XCTestCase {
    func testPersonalDetailsAreRemovedBeforeAReportIsShared() {
        // Alle Angaben sind erfunden. Der Benutzerordner wird zusammengesetzt, damit in diesem Quelltext kein
        // Pfad steht, der wie ein echter aussieht.
        let home = "/" + "Users" + "/anna"
        let text = """
        Log: \(home)/Library/Application Support/AVPPlay/store/moss-1/.last-build.log
        Device 0000ABCD-0011223344556677, CoreDevice 01234567-89AB-CDEF-0123-456789ABCDEF
        app anna.dev.klepton.target.moss signed by ABCDE12345, token FRLabcdefghijklmnopqrstuvwxyz0123456789
        Annabelle is someone else.
        """
        let out = Redaction.anonymize(text, user: "anna", home: home, alsoHide: ["ABCDE12345"])
        XCTAssertFalse(out.contains(home))
        XCTAssertTrue(out.contains("~/Library/Application Support/AVPPlay/store/moss-1/.last-build.log"))
        XCTAssertFalse(out.contains("0000ABCD"))
        XCTAssertFalse(out.contains("01234567-89AB"))
        XCTAssertFalse(out.contains("ABCDE12345"))
        XCTAssertFalse(out.contains("FRLabc"))
        XCTAssertTrue(out.contains("<user>.dev.klepton.target.moss"))
        XCTAssertTrue(out.contains("Annabelle"), "nur der ganze Name wird ersetzt")
        XCTAssertEqual(Redaction.anonymize("/" + "Users" + "/bob/x", user: "anna", home: home), "~/x", "auch fremde Benutzerordner")
    }
}

final class UpdaterTests: XCTestCase {
    func testVersionsCompareNumberByNumber() {
        XCTAssertTrue(Updater.isNewer("1.0.1", than: "1.0.0"))
        XCTAssertTrue(Updater.isNewer("1.10", than: "1.9.9"))
        XCTAssertTrue(Updater.isNewer("2", than: "1.99.99"))
        XCTAssertFalse(Updater.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(Updater.isNewer("1.0.0", than: "1.0.1"))
        XCTAssertFalse(Updater.isNewer("", than: "0"))
    }

    func testLatestReleaseIsReadFromGitHubsAnswer() throws {
        let json = """
        {"tag_name":"v1.2.3","html_url":"https://github.com/x/y/releases/tag/v1.2.3","body":"Notes",
         "assets":[{"name":"klepton-toolchain-204-abc.tar.gz","browser_download_url":"https://example.org/t.tar.gz","size":5},
                   {"name":"AVP-Play-1.2.3.dmg","browser_download_url":"https://example.org/a.dmg","size":42,
                    "digest":"sha256:ABCDEF"}]}
        """
        let r = try Updater.parseLatest(Data(json.utf8))
        XCTAssertEqual(r.version, "1.2.3")
        XCTAssertEqual(r.image.absoluteString, "https://example.org/a.dmg")
        XCTAssertEqual(r.imageSize, 42)
        XCTAssertEqual(r.imageSHA256, "abcdef")
        XCTAssertThrowsError(try Updater.parseLatest(Data(#"{"tag_name":"v1","html_url":"https://x","assets":[]}"#.utf8)), "kein Abbild")
        XCTAssertThrowsError(try Updater.parseLatest(Data(#"{"tag_name":"neueste","html_url":"https://x","assets":[{"name":"a.dmg","browser_download_url":"https://x/a.dmg"}]}"#.utf8)))
        XCTAssertThrowsError(try Updater.parseLatest(Data("kein json".utf8)))
    }

    func testAnAppFromAnotherDeveloperIsNeverAccepted() {
        // gültig signiert, aber weder von unserem Team noch beglaubigt im Sinne der Prüfung
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        XCTAssertThrowsError(try Updater.verify(app: calculator, team: "ABCDE12345", bundleId: "com.apple.calculator", newerThan: "0")) {
            guard case UpdateError.notTrusted = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertNil(Updater.team(of: URL(fileURLWithPath: "/nicht/vorhanden.app")))
    }

    func testADamagedDownloadIsRefusedAndRemoved() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("qi-upd-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("quelle.dmg")
        try Data("abbild".utf8).write(to: source)
        var release = AppRelease(version: "9.9.9", page: URL(string: "https://example.org")!, notes: "", image: source,
                                 imageSize: 6, imageSHA256: try Hashing.sha256(of: source))
        let good = try await Updater.download(release, to: dir.appendingPathComponent("updates"))
        XCTAssertEqual(try Data(contentsOf: good), Data("abbild".utf8))
        release.imageSHA256 = String(repeating: "0", count: 64)
        do { _ = try await Updater.download(release, to: dir.appendingPathComponent("updates")); XCTFail("angenommen") }
        catch { XCTAssertEqual(error as? UpdateError, .damaged) }
        XCTAssertFalse(fm.fileExists(atPath: good.path), "die beschädigte Datei bleibt nicht liegen")
        // Ein Ort, an den nicht geschrieben werden kann, wird erkannt
        XCTAssertFalse(Updater.canReplace(app: URL(fileURLWithPath: "/Volumes/AVP Play/AVP Play.app")))
        XCTAssertFalse(Updater.canReplace(app: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/1/d/AVP Play.app")))
    }
}

final class MetaToolSetupTests: XCTestCase {
    func testDownloadsAreFoundNewestFirstAndUnfinishedOnesSkipped() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("qi-dl-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir.appendingPathComponent("ovr-platform-util-ordner"), withIntermediateDirectories: true)
        for (name, age) in [("ovr-platform-util", 300.0), ("ovr-platform-util (1)", 10.0), ("ovr-platform-util.crdownload", 1.0),
                            ("etwas-anderes", 1.0)] {
            let url = dir.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        XCTAssertEqual(MetaTool.downloads(in: dir).map(\.lastPathComponent), ["ovr-platform-util (1)", "ovr-platform-util"])
        XCTAssertEqual(MetaTool.downloads(in: dir.appendingPathComponent("gibt-es-nicht")), [])
    }

    func testAFileThatIsNotMetasIsNeverSetUp() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("qi-tool-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("tools/ovr-platform-util")
        // ein echtes, gültig signiertes Programm – aber nicht von Meta
        XCTAssertThrowsError(try MetaTool.adopt(from: URL(fileURLWithPath: "/bin/ls"), to: target)) {
            guard case LoginError.wrongSigner = $0 else { return XCTFail("\($0)") }
        }
        // eine Datei ohne Signatur, wie sie aus dem Browser käme (nicht ausführbar)
        let plain = dir.appendingPathComponent("ovr-platform-util")
        try Data("#!/bin/sh\necho hallo\n".utf8).write(to: plain)
        XCTAssertThrowsError(try MetaTool.adopt(from: plain, to: target)) {
            guard case LoginError.wrongSigner = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertFalse(fm.fileExists(atPath: target.path), "nichts davon wurde abgelegt")
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathExtension("new").path))
    }
}

final class LegacyDataTests: XCTestCase {
    func testOldFolderIsRenamedOnceAndNeverMerged() throws {
        let fm = FileManager.default
        let support = fm.temporaryDirectory.appendingPathComponent("qi-legacy-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? fm.removeItem(at: support) }
        let old = support.appendingPathComponent("QuestInstaller/store/spiel-1", isDirectory: true)
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("inhalt".utf8).write(to: old.appendingPathComponent("datei.obb"))

        XCTAssertTrue(DataLocation.adoptLegacyData(in: support))
        let moved = support.appendingPathComponent("AVPPlay/store/spiel-1/datei.obb")
        XCTAssertEqual(try Data(contentsOf: moved), Data("inhalt".utf8))
        XCTAssertFalse(fm.fileExists(atPath: support.appendingPathComponent("QuestInstaller").path))
        XCTAssertFalse(DataLocation.adoptLegacyData(in: support), "ein zweites Mal gibt es nichts zu tun")

        // Gibt es beide Ordner, wird nichts angefasst – auch nichts zusammengeführt.
        try fm.createDirectory(at: support.appendingPathComponent("QuestInstaller/jobs"), withIntermediateDirectories: true)
        XCTAssertFalse(DataLocation.adoptLegacyData(in: support))
        XCTAssertTrue(fm.fileExists(atPath: support.appendingPathComponent("QuestInstaller/jobs").path))
        XCTAssertTrue(fm.fileExists(atPath: moved.path))
    }

    func testTokenMovesFromTheOldKeychainEntry() throws {
        let old = TokenStore(service: "avpplay-selbsttest-alt"), new = TokenStore(service: "avpplay-selbsttest-neu")
        addTeardownBlock { _ = try? old.delete(account: "umzug"); _ = try? new.delete(account: "umzug") }
        let token = String(repeating: "Ab3", count: 20)          // erfunden, kein echter Token
        try old.write(token: token, account: "umzug")
        XCTAssertEqual(try new.adoptLegacy(from: old.service, account: "umzug"), token)
        XCTAssertEqual(try new.read(account: "umzug"), token)
        XCTAssertThrowsError(try old.read(account: "umzug"), "der alte Eintrag ist danach weg")
        XCTAssertThrowsError(try new.adoptLegacy(from: old.service, account: "anderes"))
    }
}

final class FailureKindTests: XCTestCase {
    func testErrorsMapToWhatTheUserCanDoNext() {
        XCTAssertEqual(FailureKind.of(InstallError.appRunning("Moss")), .gameRunning)
        XCTAssertEqual(FailureKind.of(InstallError.notOwned("Moss")), .notOwned)
        XCTAssertEqual(FailureKind.of(InstallError.userFilesNeeded(names: ["a"], hint: nil)), .ownFiles)
        XCTAssertEqual(FailureKind.of(InstallError.teamMissing), .setup)
        XCTAssertEqual(FailureKind.of(MetaError.tokenRejected("x")), .signIn)
        XCTAssertEqual(FailureKind.of(MetaError.transport("x")), .download)
        XCTAssertEqual(FailureKind.of(TokenError.malformed), .signIn)
        XCTAssertEqual(FailureKind.of(DeviceError.noDevice), .device)
        XCTAssertEqual(FailureKind.of(ToolchainError.buildFailed(log: URL(fileURLWithPath: "/tmp/x"), hint: "")), .build)
        XCTAssertEqual(FailureKind.of(ToolchainError.syncFailed(log: URL(fileURLWithPath: "/tmp/x"), hint: "")), .copy)
        XCTAssertEqual(FailureKind.of(FetchError.checksumMismatch(name: "a")), .download)
        XCTAssertEqual(FailureKind.of(URLError(.notConnectedToInternet)), .download)
        XCTAssertEqual(FailureKind.of(CancellationError()), .other)
    }
}

final class OwnershipCacheTests: XCTestCase {
    func testAnswersAreKeptAndGoStaleAfterADay() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qi-own-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let cache = OwnershipCache(store: ContentStore(root: dir))
        XCTAssertEqual(cache.load(), [:])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try cache.save(["1": .init(owned: true, checked: now), "2": .init(owned: false, checked: now)])
        XCTAssertEqual(cache.load()["1"]?.owned, true)
        XCTAssertEqual(cache.load()["2"]?.owned, false)
        XCTAssertTrue(OwnershipCache.needsCheck(nil, now: now))
        XCTAssertFalse(OwnershipCache.needsCheck(cache.load()["1"], now: now.addingTimeInterval(3600)))
        XCTAssertTrue(OwnershipCache.needsCheck(cache.load()["1"], now: now.addingTimeInterval(25 * 3600)))
        XCTAssertTrue(OwnershipCache.needsCheck(cache.load()["1"], now: now.addingTimeInterval(-60)), "eine Antwort aus der Zukunft gilt nicht")
        cache.clear()
        XCTAssertEqual(cache.load(), [:])
    }
}

final class BundleNamingTests: XCTestCase {
    func testPrefixAndIdentifier() {
        XCTAssertEqual(Toolchain.defaultBundlePrefix(user: "Anna Maria"), "annamaria.dev.klepton.target")
        XCTAssertEqual(Toolchain.defaultBundlePrefix(user: "…"), "user.dev.klepton.target")
        XCTAssertEqual(Toolchain.bundleId(target: "moss", prefix: nil), Toolchain.defaultBundleId(target: "moss"))
        XCTAssertEqual(Toolchain.bundleId(target: "moss", prefix: ""), Toolchain.defaultBundleId(target: "moss"))
        XCTAssertEqual(Toolchain.bundleId(target: "moss", prefix: "com.example.games"), "com.example.games.moss")
        XCTAssertEqual(Toolchain.defaultBundleId(target: "moss", user: "anna"), Toolchain.defaultBundlePrefix(user: "anna") + ".moss")
        for good in ["com.example", "com.example.my-games", "a1.b2.c3"] { XCTAssertTrue(Toolchain.isValidBundlePrefix(good), good) }
        for bad in ["", "example", "com..example", ".com.example", "com.example.", "com.exa mple", "com.exämple", "com.example/x",
                    String(repeating: "a.", count: 60) + "b"] {
            XCTAssertFalse(Toolchain.isValidBundlePrefix(bad), bad)
        }
    }

    func testStatusLooksForTheAppUnderTheChosenPrefix() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qi-prefix-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let recipe = Recipe(schema: 1, id: "moss", title: "Moss", package: "com.x.moss", versionName: "1.0", versionCode: 7,
                            store: .init(appId: nil), toolchain: .init(target: "moss", minCommit: "abc1234"), files: [],
                            addons: nil, status: .init(playability: "untested", download: "unknown", notes: nil), icon: nil)
        let apps = [InstalledApp(bundleIdentifier: "com.example.games.moss", name: "Moss", version: "1.0", bundleVersion: "7.5")]
        let store = ContentStore(root: dir)
        XCTAssertEqual(GameStatus.of(recipe: recipe, store: store, apps: apps, toolchainVersion: 5).onDevice, .notInstalled)
        XCTAssertEqual(GameStatus.of(recipe: recipe, store: store, apps: apps, toolchainVersion: 5, bundlePrefix: "com.example.games").onDevice,
                       .current(stamp: "1.0 (7.5)"))
    }
}

final class RunningAppTests: XCTestCase {
    func testAppIsRunningWhenAProcessLivesInItsBundle() throws {
        let apps = try DeviceControl.parseApps(Data("""
        {"result":{"apps":[
          {"bundleIdentifier":"x.doom","name":"Doom 3","version":"1.4.8","bundleVersion":"48.202",
           "url":"file:///private/var/containers/Bundle/Application/AAAA/KleptonDoom3.app/"},
          {"bundleIdentifier":"x.moss","name":"Moss","url":"file:///private/var/containers/Bundle/Application/BBBB/KleptonMoss.app"},
          {"bundleIdentifier":"x.none","name":"Ohne Ort"}]}}
        """.utf8))
        let running = try DeviceControl.parseProcesses(Data("""
        {"result":{"deviceIdentifier":"D","runningProcesses":[
          {"executable":"file:///sbin/launchd","processIdentifier":1},
          {"processIdentifier":7},
          {"executable":"file:///private/var/containers/Bundle/Application/AAAA/KleptonDoom3.app/KleptonDoom3","processIdentifier":42},
          {"executable":"file:///private/var/containers/Bundle/Application/BBBB/KleptonMoss.appendix/x","processIdentifier":43}]}}
        """.utf8))
        XCTAssertEqual(running.count, 3)
        XCTAssertTrue(DeviceControl.isRunning(apps[0], executables: running))
        XCTAssertFalse(DeviceControl.isRunning(apps[1], executables: running), "ein ähnlich beginnender Pfad zählt nicht")
        XCTAssertFalse(DeviceControl.isRunning(apps[2], executables: running), "ohne bekannten Ort keine Aussage")
    }
}

final class ToolchainPackageTests: XCTestCase {
    func testAppStamp() {
        XCTAssertEqual(AppStamp.short(versionName: "1.4.8"), "1.4.8")
        XCTAssertEqual(AppStamp.short(versionName: "1.40.8_7379"), "1.40.8")
        XCTAssertEqual(AppStamp.short(versionName: "12.1.1689309"), "12.1.1689309")
        XCTAssertEqual(AppStamp.short(versionName: "1.0.3.151047"), "1.0.3")
        XCTAssertEqual(AppStamp.short(versionName: "Steam-Build 25487405"), "25487405")
        XCTAssertEqual(AppStamp.short(versionName: "beta"), "1.0")
        XCTAssertEqual(AppStamp.short(versionName: "v.."), "1.0")
        XCTAssertEqual(AppStamp.build(versionCode: 48, toolchainVersion: 199), "48.199")
        XCTAssertEqual(AppStamp.build(versionCode: -3, toolchainVersion: 5_000_000_000), "0.999999999")
    }

    func git(_ dir: URL, _ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path, "-c", "user.name=Test", "-c", "user.email=test@example.org",
                       "-c", "commit.gpgsign=false"] + args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "git \(args.joined(separator: " "))")
    }

    /// Ein winziger „Fork“: versionierter Quelltext, vorgebaute Teile und etwas, das nicht ins Paket darf.
    func makeCheckout() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qi-fork-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("visionos"), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: dir.appendingPathComponent("visionos/run.sh"), atomically: true, encoding: .utf8)
        try "vendor/\nvendor-moltenvk/\n/spiel/\n".write(to: dir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try git(dir, "init", "-q")
        try git(dir, "add", "-A")
        try git(dir, "commit", "-q", "-m", "eins")
        try "zwei\n".write(to: dir.appendingPathComponent("zwei.txt"), atomically: true, encoding: .utf8)
        try git(dir, "add", "-A")
        try git(dir, "commit", "-q", "-m", "zwei")
        for part in ["vendor/out/xros", "vendor/out/xrsim", "vendor-moltenvk/out/include",
                     "vendor-moltenvk/out/xros", "vendor-moltenvk/out/xrsim"] {
            try fm.createDirectory(at: dir.appendingPathComponent(part), withIntermediateDirectories: true)
            try Data("lib".utf8).write(to: dir.appendingPathComponent(part).appendingPathComponent("teil.bin"))
        }
        // Spielinhalte liegen in echten Arbeitsverzeichnissen daneben und sind nie versioniert
        try fm.createDirectory(at: dir.appendingPathComponent("spiel"), withIntermediateDirectories: true)
        try Data("geheim".utf8).write(to: dir.appendingPathComponent("spiel/inhalt.obb"))
        return dir
    }

    func testPackInstallRoundTrip() throws {
        let checkout = try makeCheckout()
        let out = checkout.deletingLastPathComponent().appendingPathComponent("qi-pkg-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }
        let (archive, manifest) = try ToolchainPackager.pack(checkout: checkout, to: out.appendingPathComponent("pakete"))
        XCTAssertEqual(manifest.version, 2)
        XCTAssertEqual(manifest.appRevision, 2)
        // Ein Commit, der nur das Bauskript und einen Text ändert, hebt die Nummer, aber nicht den Stand der Spiele.
        try "#!/bin/sh\n# geändert\n".write(to: checkout.appendingPathComponent("visionos/run.sh"), atomically: true, encoding: .utf8)
        try "Hinweis\n".write(to: checkout.appendingPathComponent("LIESMICH.md"), atomically: true, encoding: .utf8)
        try git(checkout, "add", "-A")
        try git(checkout, "commit", "-q", "-m", "drei")
        let later = try ToolchainPackager.pack(checkout: checkout, to: out.appendingPathComponent("pakete-später")).1
        XCTAssertEqual(later.version, 3)
        XCTAssertEqual(later.appRevision, 2)
        XCTAssertEqual(manifest.ancestors.count, 2)
        XCTAssertEqual(manifest.ancestors.first, manifest.commit)
        XCTAssertNotNil(manifest.sha256)

        let packager = ToolchainPackager(root: out.appendingPathComponent("installiert"))
        let toolchain = try packager.install(archive: archive)
        XCTAssertEqual(toolchain.commit(), manifest.commit)
        XCTAssertEqual(toolchain.version(), 2)
        // ohne Versionsgeschichte: die Vorfahren stehen in der Beschreibung
        XCTAssertTrue(toolchain.satisfies(minCommit: manifest.ancestors.last!))
        XCTAssertFalse(toolchain.satisfies(minCommit: "0123abc"))
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: toolchain.root.appendingPathComponent("zwei.txt").path))
        XCTAssertTrue(fm.fileExists(atPath: toolchain.root.appendingPathComponent("vendor/out/xros/teil.bin").path))
        XCTAssertFalse(fm.fileExists(atPath: toolchain.root.appendingPathComponent("spiel").path), "nichts Unversioniertes im Paket")
        XCTAssertFalse(fm.fileExists(atPath: toolchain.root.appendingPathComponent(".git").path))
        XCTAssertEqual(packager.installed().map { $0.commit() }, [manifest.commit])
        // ein zweites Mal: derselbe Stand bleibt stehen
        XCTAssertEqual(try packager.install(archive: archive).root, toolchain.root)
    }

    func testPruneKeepsTheNewestAndWhatAnOpenJobHolds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qi-prune-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let packager = ToolchainPackager(root: root)
        func plant(_ version: Int, _ commit: String) throws {
            let m = ToolchainManifest(format: 1, version: version, commit: commit, ancestors: [commit], created: Date())
            let dir = packager.directory(for: m)
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("visionos"), withIntermediateDirectories: true)
            try "#!/bin/sh\n".write(to: dir.appendingPathComponent("visionos/run.sh"), atomically: true, encoding: .utf8)
            try ToolchainPackager.encoder.encode(m).write(to: dir.appendingPathComponent("toolchain.json"))
        }
        try plant(1, "aaaaaaa"); try plant(2, "bbbbbbb"); try plant(3, "ccccccc"); try plant(4, "ddddddd")
        // der offene Auftrag nennt den vollen Commit, das Paket den kurzen
        let removed = try packager.prune(keep: 1, protecting: ["bbbbbbb0123456789"])
        XCTAssertEqual(removed.map(\.version), [3, 1])
        XCTAssertEqual(packager.installed().map { $0.manifest?.version }, [4, 2])
        XCTAssertEqual(try packager.prune(keep: 0).count, 1, "das neueste bleibt immer")
        XCTAssertEqual(packager.installed().map { $0.manifest?.version }, [4])
    }

    func testTamperedArchiveAndDirtyCheckoutAreRefused() throws {
        let checkout = try makeCheckout()
        let out = checkout.deletingLastPathComponent().appendingPathComponent("qi-pkg-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }
        let (archive, _) = try ToolchainPackager.pack(checkout: checkout, to: out)
        let packager = ToolchainPackager(root: out.appendingPathComponent("installiert"))

        // ein Byte angehängt: gleiche Beschreibung, anderes Archiv
        let handle = try FileHandle(forWritingTo: archive)
        handle.seekToEndOfFile(); handle.write(Data([0])); try handle.close()
        XCTAssertThrowsError(try packager.install(archive: archive)) { XCTAssertEqual($0 as? PackageError, .sizeMismatch) }
        XCTAssertTrue(packager.installed().isEmpty)

        // ohne Beschreibung wird gar nicht erst entpackt
        try FileManager.default.removeItem(at: ToolchainPackager.sidecar(for: archive))
        XCTAssertThrowsError(try packager.install(archive: archive))

        // nicht eingecheckte Änderungen an Versioniertem: kein Paket
        try "geändert\n".write(to: checkout.appendingPathComponent("zwei.txt"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ToolchainPackager.pack(checkout: checkout, to: out)) {
            guard case .uncommittedChanges = $0 as? PackageError else { return XCTFail("\($0)") }
        }
    }
}

/// Die Sprache ist eine globale Einstellung: jeder Test setzt sie selbst und stellt den vorigen Stand wieder her.
final class LocalizationTests: XCTestCase {
    func testSentenceFollowsLanguage() {
        let before = L10n.language
        defer { L10n.language = before }
        L10n.language = .en
        XCTAssertEqual(L("a", "b"), "a")
        L10n.language = .de
        XCTAssertEqual(L("a", "b"), "b")
    }

    func testSystemLanguage() {
        XCTAssertEqual(L10n.systemLanguage(preferred: ["de-DE", "en-US"]), .de)
        XCTAssertEqual(L10n.systemLanguage(preferred: ["en-US", "de-DE"]), .en)
        XCTAssertEqual(L10n.systemLanguage(preferred: []), .en)
    }

    func testErrorDescriptionInBothLanguages() {
        let before = L10n.language
        defer { L10n.language = before }
        L10n.language = .en
        let english = InstallError.teamMissing.description
        L10n.language = .de
        let german = InstallError.teamMissing.description
        XCTAssertFalse(english.isEmpty)
        XCTAssertFalse(german.isEmpty)
        XCTAssertNotEqual(english, german)
    }

    func testLocalizedTextDecodesBothForms() throws {
        let before = L10n.language
        defer { L10n.language = before }
        let texts = try JSONDecoder().decode([LocalizedText].self, from: Data(#"["x", {"en":"x","de":"y"}]"#.utf8))
        XCTAssertEqual(texts.count, 2)
        L10n.language = .en
        XCTAssertEqual(texts.map(\.text), ["x", "x"])
        L10n.language = .de
        XCTAssertEqual(texts.map(\.text), ["x", "y"])
    }
}

final class SteamTests: XCTestCase {
    let helper = RecipeTests()

    func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qi-steam-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func source(_ app: String = "1007", depots: [(String, String)] = [("1006", "4559160656493359681")], folder: String? = nil) -> FileSource {
        FileSource(kind: .user, url: nil, hint: nil,
                   steam: SteamSource(app: app, depots: depots.map { .init(id: $0.0, manifest: $0.1, bytes: nil) }, folder: folder))
    }

    func testOnlyPlainIdentifiersBecomeArguments() throws {
        XCTAssertTrue(source().steam!.isSane)
        XCTAssertTrue(source(folder: "game").steam!.isSane)
        for bad in [source("9050 +quit"), source("-1"), source(""), source(depots: []), source(depots: [("9051", "")]),
                    source(depots: [("9051; rm", "1")]), source(depots: [("9051", "+login")]), source(folder: "../x"), source(folder: "a/b"), source(folder: "")] {
            XCTAssertFalse(bad.steam!.isSane, "\(bad)")
        }
        for name in ["gordon_freeman", "a.b-c", "user@example.org"] { XCTAssertTrue(SteamTool.isAccountName(name), name) }
        for name in ["", "x", "+quit", "-flag", "@NoPrompt", "two words", "name;rm", "ümlaut", String(repeating: "a", count: 65)] {
            XCTAssertFalse(SteamTool.isAccountName(name), name)
        }
        // Im Rezept: ein Steam-Eintrag braucht eine Prüfsumme, und einer mit unbrauchbaren Kennungen fällt durch.
        var file = helper.file("pak000.pk4", sha: String(repeating: "a", count: 64))
        file.source = source("9050", depots: [("9051", "8286038173018646412")])
        try helper.recipe(files: [file]).validate()
        file.sha256 = nil
        XCTAssertThrowsError(try helper.recipe(files: [file]).validate())
        file.sha256 = String(repeating: "a", count: 64)
        file.source = source("9050 +app_update 1", depots: [("9051", "1")])
        XCTAssertThrowsError(try helper.recipe(files: [file]).validate())
    }

    func testOlderProgramsStillReadARecipeWithASteamEntry() throws {
        // Der Eintrag ist ein Zusatz: „vom Nutzer bereitzustellen“ bleibt die Art, also bleibt auch der Weg über einen Ordner.
        let json = #"{"kind":"user","hint":{"en":"x","de":"y"},"steam":{"app":"9050","depots":[{"id":"9051","manifest":"8286038173018646412","bytes":1579920089}]}}"#
        let decoded = try JSONDecoder().decode(FileSource.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.kind, .user)
        XCTAssertEqual(decoded.steam?.depots.first?.bytes, 1_579_920_089)
        XCTAssertNil(try JSONDecoder().decode(FileSource.self, from: Data(#"{"kind":"user"}"#.utf8)).steam)
    }

    /// Die Sätze stammen aus Läufen von SteamCMD (anonym, 2026-10-09).
    func testReadsWhatSteamCmdSays() {
        let owned = """
        Waiting for user info...OK
        License packageID 17906:
         - State   : Active (flags 0x0) - Purchased : Fri Oct  9 00:54:42 2026 in "", None
         - Apps\t: 5, 7, 90, 1007
        Unloading Steam API...OK
        """
        XCTAssertEqual(SteamRun.licence(owned, app: "1007"), .owned)
        XCTAssertEqual(SteamRun.licence("Waiting for user info...OK\nNo active license found for appID 546560.\n", app: "546560"), .notOwned)
        // Weder das eine noch das andere: unklar, und dann wird nichts angefordert.
        XCTAssertEqual(SteamRun.licence("Waiting for user info...OK\nUnloading Steam API...OK\n", app: "9050"), .unclear)
        XCTAssertEqual(SteamRun.licence("License packageID 1:\n - State   : Expired\n", app: "9050"), .unclear)

        let refused = "Cached credentials not found.\nFAILED (No cached credentials and @NoPromptForPassword is set)\n"
        XCTAssertTrue(SteamRun.loginFailed(refused))
        XCTAssertEqual(SteamRun.failureLine(refused), "FAILED (No cached credentials and @NoPromptForPassword is set)")
        XCTAssertFalse(SteamRun.loginFailed(owned))

        let done = #"Depot download complete : "/x/tools/steamcmd\steamapps\content\app_1007\depot_1006" (manifest 4559160656493359681)"#
        XCTAssertTrue(SteamRun.depotComplete("Downloading depot 1006 (4 files, 35 MB) ... \n" + done, depot: "1006"))
        XCTAssertFalse(SteamRun.depotComplete(done, depot: "100"))
        XCTAssertFalse(SteamRun.depotComplete("Downloading depot 1006 (4 files, 35 MB) ... \n", depot: "1006"))
    }

    func testWhatPointsAtTheAccountIsNotShown() {
        let said = SteamTool.clean("Logging in user 'gordon' [U:1:123456789] to Steam Public...\u{1B}[0mOK 76561198000000001")
        XCTAssertFalse(said.contains("123456789"))
        XCTAssertFalse(said.contains("76561198000000001"))
        XCTAssertTrue(said.contains("to Steam Public...OK"))
    }

    func testATreeIsAssembledFromLayersWithoutOverwriting() throws {
        let dir = try scratch()
        let fm = FileManager.default
        let first = dir.appendingPathComponent("depot_a/game"), second = dir.appendingPathComponent("depot_b/game")
        try fm.createDirectory(at: first.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: second.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: second.appendingPathComponent("maps/deep"), withIntermediateDirectories: true)
        try Data("linux".utf8).write(to: first.appendingPathComponent("bin/app"))
        try Data("ANDERS".utf8).write(to: second.appendingPathComponent("bin/app"))       // darf die erste Schicht nicht ersetzen
        try Data("zusatz".utf8).write(to: second.appendingPathComponent("bin/extra"))
        try Data("karte".utf8).write(to: second.appendingPathComponent("maps/deep/a.vpk"))
        let sha = try Hashing.sha256(of: first.appendingPathComponent("bin/app"))
        var tree = RecipeTree(name: "game", role: .game, source: source(folder: "game"), markers: [.init(path: "bin/app", size: 5, sha256: sha)])
        var recipe = helper.recipe(files: [])
        recipe.trees = [tree]
        let store = TreeStore(store: ContentStore(root: dir.appendingPathComponent("bestand")))

        XCTAssertTrue(try store.assemble(tree, in: recipe, from: [first, second]))
        let made = store.url(for: tree, in: recipe)
        XCTAssertEqual(try String(contentsOf: made.appendingPathComponent("bin/app"), encoding: .utf8), "linux")
        XCTAssertEqual(try String(contentsOf: made.appendingPathComponent("bin/extra"), encoding: .utf8), "zusatz")
        XCTAssertEqual(try String(contentsOf: made.appendingPathComponent("maps/deep/a.vpk"), encoding: .utf8), "karte")
        XCTAssertTrue(store.missing(recipe: recipe).isEmpty)
        // Die Schichten bleiben, wie sie waren.
        XCTAssertEqual(try String(contentsOf: second.appendingPathComponent("bin/app"), encoding: .utf8), "ANDERS")

        // Passt die Kenndatei nicht, entsteht nichts – und was schon im Bestand liegt, bleibt.
        tree.markers = [.init(path: "bin/app", size: 5, sha256: String(repeating: "0", count: 64))]
        XCTAssertFalse(try store.assemble(tree, in: recipe, from: [first, second]))
        XCTAssertTrue(fm.fileExists(atPath: made.appendingPathComponent("bin/app").path))
        XCTAssertFalse(try store.assemble(tree, in: recipe, from: [dir.appendingPathComponent("gibt-es-nicht")]))
    }

    func testOnlyWhatIsMissingIsAskedOfSteam() throws {
        let dir = try scratch()
        let store = ContentStore(root: dir)
        var have = helper.file("pak000.pk4", sha: String(repeating: "a", count: 64)), lack = helper.file("pak001.pk4", sha: String(repeating: "b", count: 64))
        have.source = source("9050", depots: [("9051", "1")])
        lack.source = source("9050", depots: [("9051", "1")])
        let fromMeta = helper.file("main.obb")
        let recipe = helper.recipe(files: [have, lack, fromMeta])
        try FileManager.default.createDirectory(at: store.directory(for: recipe), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: store.url(for: have, in: recipe))
        XCTAssertTrue(SteamFetcher.usesSteam(recipe))
        XCTAssertFalse(SteamFetcher.usesSteam(helper.recipe(files: [fromMeta])))
        XCTAssertEqual(SteamFetcher.needed(recipe: recipe, store: store).files.map(\.name), ["pak001.pk4"])
    }

    /// Ein echter Durchlauf mit Valves Werkzeug, ohne Konto: SteamCMD kennt die Anmeldung „anonymous“, und die
    /// besitzt Valves frei verteilbare Steamworks-Bibliotheken (App 1007). Läuft nur, wenn `AVPPLAY_STEAM_TOOL`
    /// auf einen Ordner mit SteamCMD zeigt; geladen werden rund 100 MB.
    func testFetchesADepotAndAdoptsOnlyWhatMatches() throws {
        guard let path = ProcessInfo.processInfo.environment["AVPPLAY_STEAM_TOOL"] else { throw XCTSkip("AVPPLAY_STEAM_TOOL ist nicht gesetzt") }
        let dir = try scratch()
        // Die Depots gehen dabei nicht neben das Werkzeug, sondern über den Verweis an einen eigenen Ort – so, wie
        // wenn der Bestand auf einem anderen Laufwerk liegt.
        let landing = dir.appendingPathComponent("depots")
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).appendingPathComponent("steamapps"))
        addTeardownBlock { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).appendingPathComponent("steamapps")) }
        let tool = SteamTool(directory: URL(fileURLWithPath: path), home: dir.appendingPathComponent("home"), contentRoot: landing)
        try tool.verify()
        let store = ContentStore(root: dir.appendingPathComponent("bestand"))
        var file = helper.file("steamclient.so", size: 49_104_528, sha: "7cceb10c5c24beed4684803c808bb88ec9c3c29df39347bad3ca6edf666ecf8e", dest: "x")
        file.source = source()
        var recipe = helper.recipe(files: [file])
        recipe.trees = [RecipeTree(name: "runtime", role: .sysroot, source: source(folder: "linux64"),
                                   markers: [.init(path: "libsteamwebrtc.so", size: 7_817_336, sha256: "f5a85fa63b9838709fa4abd0b1287e811da810bec3e4bb4ac898beda9aed984e")])]
        try recipe.validate()

        var said: [String] = []
        let adopted = try SteamFetcher(tool: tool, store: store, account: "anonymous").fetch(recipe: recipe) { said.append($0) }
        XCTAssertEqual(Set(adopted), ["steamclient.so", "runtime"], said.joined(separator: "\n"))
        XCTAssertEqual(try Hashing.sha256(of: store.url(for: file, in: recipe)), file.sha256)
        XCTAssertTrue(TreeStore(store: store).missing(recipe: recipe).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: TreeStore(store: store).url(for: recipe.trees![0], in: recipe).appendingPathComponent("steamclient.so").path))
        // Übernommen heißt auch: bei SteamCMD liegt es nicht noch einmal. Und es lag am gewählten Ort.
        XCTAssertFalse(FileManager.default.fileExists(atPath: tool.contentDirectory(app: "1007").path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: tool.directory.appendingPathComponent("steamapps").path),
                       landing.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: landing.appendingPathComponent("content").path))
        XCTAssertTrue(SteamFetcher.needed(recipe: recipe, store: store).files.isEmpty)
        // Ein zweiter Lauf fragt Steam nichts mehr.
        XCTAssertEqual(try SteamFetcher(tool: tool, store: store, account: "anonymous").fetch(recipe: recipe), [])

        // Ein Spiel, das dem Konto nicht gehört: Schluss nach der Besitzfrage, es wird nichts angefordert.
        var alyx = helper.file("hlvr", sha: String(repeating: "c", count: 64))
        alyx.source = source("546560", depots: [("546564", "9198205754520568813")])
        XCTAssertThrowsError(try SteamFetcher(tool: tool, store: store, account: "anonymous").fetch(recipe: helper.recipe(files: [alyx]))) {
            XCTAssertEqual($0 as? SteamError, .notOwned("Demo"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tool.contentDirectory(app: "546560").path))
        // Ohne gemerkte Anmeldung: klare Absage, keine Rückfrage nach einem Passwort.
        XCTAssertThrowsError(try SteamFetcher(tool: tool, store: store, account: "nobody_signed_in_here").fetch(recipe: helper.recipe(files: [alyx]))) {
            guard case SteamError.notSignedIn = $0 else { return XCTFail("\($0)") }
        }
    }
}

final class StoreLocationTests: XCTestCase {
    func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qi-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testTheChosenFolderIsRememberedAndCanBeUndone() throws {
        let base = try scratch()
        XCTAssertNil(StoreLocation.custom(base: base))
        XCTAssertEqual(StoreLocation.current(base: base).path, base.appendingPathComponent("store").path)

        let chosen = URL(fileURLWithPath: "/Volumes/Extern/Spiele")
        XCTAssertEqual(StoreLocation.folder(in: chosen).path, "/Volumes/Extern/Spiele/AVP Play Downloads")
        XCTAssertEqual(StoreLocation.folder(in: StoreLocation.folder(in: chosen)).path, "/Volumes/Extern/Spiele/AVP Play Downloads")
        try StoreLocation.set(StoreLocation.folder(in: chosen), base: base)
        XCTAssertEqual(StoreLocation.current(base: base).path, "/Volumes/Extern/Spiele/AVP Play Downloads")
        // Zurück zum üblichen Ort – ausdrücklich oder indem er selbst gewählt wird.
        try StoreLocation.set(nil, base: base)
        XCTAssertNil(StoreLocation.custom(base: base))
        try StoreLocation.set(chosen, base: base)
        try StoreLocation.set(StoreLocation.standard(base: base), base: base)
        XCTAssertNil(StoreLocation.custom(base: base))
        // Eine kaputte Datei ist keine Wahl.
        try Data("kein json".utf8).write(to: base.appendingPathComponent("settings.json"))
        XCTAssertNil(StoreLocation.custom(base: base))
    }

    func testAFolderOnADiskThatIsNotConnectedIsNotAvailable() throws {
        let base = try scratch()
        XCTAssertTrue(StoreLocation.isAvailable(base.appendingPathComponent("noch/nicht/da")))
        XCTAssertFalse(StoreLocation.isAvailable(URL(fileURLWithPath: "/Volumes/gibt-es-nicht-\(UUID().uuidString)/AVP Play Downloads")))
        XCTAssertTrue(StoreLocation.sameVolume(base, base.appendingPathComponent("x/y")))

        // Gewählt und erreichbar – bis derselbe Pfad auf ein anderes Laufwerk führt: Dann ist die Platte fort, auch
        // wenn es den Ordner (leer, auf dem Startlaufwerk) noch gibt.
        let chosen = base.appendingPathComponent("extern/AVP Play Downloads")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        try StoreLocation.set(chosen, base: base)
        XCTAssertTrue(StoreLocation.isAvailable(chosen, base: base))
        let file = base.appendingPathComponent("settings.json")
        var saved = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertNotNil(saved["volume"])
        saved["volume"] = "00000000-0000-0000-0000-000000000000"
        try JSONSerialization.data(withJSONObject: saved).write(to: file)
        XCTAssertFalse(StoreLocation.isAvailable(chosen, base: base))
        // Für andere Ordner gilt der Vermerk nicht.
        XCTAssertTrue(StoreLocation.isAvailable(base.appendingPathComponent("anderswo"), base: base))
    }

    func testMovingKeepsEverythingAndRemovesNothingBeforeItHasArrived() throws {
        let dir = try scratch()
        let fm = FileManager.default
        let old = dir.appendingPathComponent("alt"), new = dir.appendingPathComponent("neu")
        try fm.createDirectory(at: old.appendingPathComponent("moss-1/game/bin"), withIntermediateDirectories: true)
        try Data("apk".utf8).write(to: old.appendingPathComponent("moss-1/moss.apk"))
        try Data("programm".utf8).write(to: old.appendingPathComponent("moss-1/game/bin/app"))
        try fm.createSymbolicLink(atPath: old.appendingPathComponent("moss-1/game/verweis").path, withDestinationPath: "bin/app")
        try fm.createDirectory(at: old.appendingPathComponent("doom-2"), withIntermediateDirectories: true)
        try Data("pak".utf8).write(to: old.appendingPathComponent("doom-2/pak000.pk4"))
        try Data("{}".utf8).write(to: old.appendingPathComponent("ownership.json"))
        // Am neuen Ort liegt schon etwas unter einem der Namen: das bleibt, und das alte auch.
        try fm.createDirectory(at: new.appendingPathComponent("doom-2"), withIntermediateDirectories: true)
        try Data("anderes".utf8).write(to: new.appendingPathComponent("doom-2/pak000.pk4"))

        XCTAssertEqual(StoreMove.measure(old.appendingPathComponent("moss-1")).files, 2)
        XCTAssertThrowsError(try StoreMove.run(from: old, to: old)) { XCTAssertEqual($0 as? StoreMoveError, .sameFolder) }

        let seen = Collected()
        let result = try StoreMove.run(from: old, to: new, copying: true, progress: { seen.add($0) })
        XCTAssertEqual(result.moved, ["moss-1", "ownership.json"])
        XCTAssertEqual(result.skipped, ["doom-2"])
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("moss-1/game/bin/app"), encoding: .utf8), "programm")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: new.appendingPathComponent("moss-1/game/verweis").path), "bin/app")
        XCTAssertFalse(fm.fileExists(atPath: old.appendingPathComponent("moss-1").path))
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("doom-2/pak000.pk4"), encoding: .utf8), "pak")
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("doom-2/pak000.pk4"), encoding: .utf8), "anderes")
        XCTAssertEqual(seen.values.last?.done, seen.values.last?.total)
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: new.path).contains { $0.hasPrefix(".moving-") })

        // Angehalten: nichts ist verloren, nichts Halbes bleibt am neuen Ort.
        try fm.createDirectory(at: old.appendingPathComponent("alyx-3"), withIntermediateDirectories: true)
        try Data("spiel".utf8).write(to: old.appendingPathComponent("alyx-3/hlvr"))
        XCTAssertThrowsError(try StoreMove.run(from: old, to: new, copying: true, shouldStop: { true })) { XCTAssertEqual($0 as? StoreMoveError, .stopped) }
        XCTAssertTrue(fm.fileExists(atPath: old.appendingPathComponent("alyx-3/hlvr").path))
        XCTAssertFalse(fm.fileExists(atPath: new.appendingPathComponent("alyx-3").path))
        // Auf demselben Laufwerk wird nur umbenannt.
        XCTAssertEqual(try StoreMove.run(from: old, to: new).moved, ["alyx-3"])
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("alyx-3/hlvr"), encoding: .utf8), "spiel")
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var values: [StoreMove.Progress] = []
        func add(_ p: StoreMove.Progress) { lock.lock(); values.append(p); lock.unlock() }
    }
}
