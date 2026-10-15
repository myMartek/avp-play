import XCTest
@testable import AVPPlayCore

final class AssetFilesTests: XCTestCase {
    private var recipes: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
    }

    private func deadpool() throws -> Recipe { try RecipeStore(directory: recipes).load(id: "store-3240283705987790") }

    private func demo(_ entries: [AssetFileEntry]?, versionName: String = "1.0") -> Recipe {
        Recipe(schema: 1, id: "demo", title: "Demo", package: "com.example.demo", versionName: versionName, versionCode: 7,
               store: .init(appId: "123"), toolchain: .init(target: "demo", minCommit: "abc"),
               files: [RecipeFile(name: "de.lang", role: "content-bundle", id: "555", size: 100, sha256: nil, required: true,
                                  dest: "android-files/Android/obb/com.example.demo", localName: nil, locale: nil, source: nil)],
               addons: nil, status: .init(playability: "verified", download: "proven", notes: nil), icon: nil, trees: nil,
               assetFiles: entries)
    }

    private let deadpoolList = """
        # Written by AVP Play from the game's recipe on every install and update. Do not edit.
        # store-3240283705987790 versionCode 8742
        asset 26412782438311256 de.lang 3256791074 de meta=1.0.40.356975.Quest
        asset 26412785311644302 en.lang 3213363608 en meta=1.0.40.356975.Quest
        asset 26412785891644244 fr.lang 3085743950 fr meta=1.0.40.356975.Quest
        asset 26412781741644659 es.lang 3366955276 es meta=1.0.40.356975.Quest
        asset 26412784368311063 es-mx.lang 3247674165 es-MX meta=1.0.40.356975.Quest
        asset 26412779154978251 ja.lang 3442971619 ja meta=1.0.40.356975.Quest

        """

    // MARK: Serialization

    func testDeadpoolListIsExact() throws {
        let recipe = try deadpool()
        XCTAssertEqual(recipe.versionName, "1.0.40.356975.Quest")
        XCTAssertEqual(recipe.versionCode, 8742)
        XCTAssertEqual(AssetFilesList.contents(for: recipe), deadpoolList)
    }

    func testTagIsOptionalAndMetaDefaultsToTheVersionName() throws {
        let recipe = demo([AssetFileEntry(id: "555", file: "de.lang", size: 100),
                           AssetFileEntry(id: "556", file: "packs/fr.lang", size: 9, tag: "fr-CA", meta: "build+2")], versionName: "2.5.Quest")
        XCTAssertNoThrow(try recipe.validate())
        XCTAssertEqual(AssetFilesList.contents(for: recipe), """
            \(AssetFilesList.header)
            # demo versionCode 7
            asset 555 de.lang 100 meta=2.5.Quest
            asset 556 packs/fr.lang 9 fr-CA meta=build+2

            """)
    }

    func testTheFieldDecodesFromJSONWithOptionalParts() throws {
        let json = #"[{"id": "1", "file": "a.lang", "size": 5}, {"id": "2", "file": "b.lang", "size": 6, "tag": "b", "meta": "x"}]"#
        let entries = try JSONDecoder().decode([AssetFileEntry].self, from: Data(json.utf8))
        XCTAssertEqual(entries, [AssetFileEntry(id: "1", file: "a.lang", size: 5),
                                 AssetFileEntry(id: "2", file: "b.lang", size: 6, tag: "b", meta: "x")])
    }

    // MARK: Validation

    private func rejects(_ entries: [AssetFileEntry], versionName: String = "1.0", _ why: String,
                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try demo(entries, versionName: versionName).validate(), why, file: file, line: line) { error in
            guard case RecipeError.invalid(let text) = error else { return XCTFail("\(error)", file: file, line: line) }
            XCTAssertTrue(text.contains("asset files") || text.contains("Asset-Dateien"), text, file: file, line: line)
        }
    }

    func testBadPathsAreRejected() {
        for path in ["/sdcard/de.lang", "../de.lang", "packs/../../de.lang", "./de.lang", "packs/./de.lang", "packs//de.lang",
                     "packs/", "", ".", "..", "de lang", "de\tlang", "de\\lang", "de\nlang",
                     String(repeating: "a", count: 256)] {
            rejects([AssetFileEntry(id: "1", file: path, size: 1, tag: "de")], "path '\(path)'")
        }
        XCTAssertNoThrow(try demo([AssetFileEntry(id: "1", file: "packs/sub/de.lang", size: 1)]).validate())
    }

    func testDuplicatesAreRejected() {
        rejects([AssetFileEntry(id: "1", file: "a.lang", size: 1), AssetFileEntry(id: "1", file: "b.lang", size: 1)], "same ID")
        rejects([AssetFileEntry(id: "1", file: "a.lang", size: 1), AssetFileEntry(id: "2", file: "a.lang", size: 1)], "same file")
    }

    func testAtMost32Entries() {
        let entries = (1...33).map { AssetFileEntry(id: "\($0)", file: "p\($0).lang", size: 1) }
        XCTAssertNoThrow(try demo(Array(entries.prefix(32))).validate())
        rejects(entries, "33 entries")
        rejects([], "an empty list")
    }

    func testIdsSizesTagsAndMetaFollowTheRuntimeRules() {
        rejects([AssetFileEntry(id: "abc", file: "a.lang", size: 1)], "letters in the ID")
        rejects([AssetFileEntry(id: "0", file: "a.lang", size: 1)], "ID 0")
        rejects([AssetFileEntry(id: "-1", file: "a.lang", size: 1)], "negative ID")
        rejects([AssetFileEntry(id: "18446744073709551616", file: "a.lang", size: 1)], "ID beyond 64 bits")
        rejects([AssetFileEntry(id: "1", file: "a.lang", size: 0)], "size 0")
        rejects([AssetFileEntry(id: "1", file: "a.lang", size: -5)], "negative size")
        rejects([AssetFileEntry(id: "1", file: "a.lang", size: 1, tag: "de DE")], "blank in the tag")
        rejects([AssetFileEntry(id: "1", file: "a.lang", size: 1, tag: String(repeating: "a", count: 32))], "tag too long")
        rejects([AssetFileEntry(id: "1", file: ".lang", size: 1)], "no tag and none in the file name")
        rejects([AssetFileEntry(id: "1", file: "a.lang", size: 1, meta: "two words")], "blank in meta")
        rejects([AssetFileEntry(id: "1", file: "a.lang", size: 1)], versionName: "1.0 beta", "default meta with a blank")
        XCTAssertNoThrow(try demo([AssetFileEntry(id: "1", file: "a.lang", size: 1, meta: "ok")], versionName: "1.0 beta").validate())
        rejects([AssetFileEntry(id: "555", file: "de.lang", size: 99)], "size differs from the recipe's file with that ID")
        XCTAssertNoThrow(try demo([AssetFileEntry(id: "18446744073709551615", file: "a.lang", size: 1)]).validate())
    }

    func testARecipeWithABadListIsNotLoaded() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-assetfiles-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let encoder = JSONEncoder()
        try encoder.encode(demo([AssetFileEntry(id: "1", file: "../a.lang", size: 1)])).write(to: dir.appendingPathComponent("demo.json"))
        XCTAssertThrowsError(try RecipeStore(directory: dir).load(id: "demo"))
        try encoder.encode(demo([AssetFileEntry(id: "1", file: "a.lang", size: 1)])).write(to: dir.appendingPathComponent("demo.json"))
        XCTAssertEqual(try RecipeStore(directory: dir).load(id: "demo").assetFiles?.count, 1)
    }

    // MARK: Writing

    /// What a stage step would hand to devicectl: the destination and the file's text at that moment. Doubles as the
    /// game's container on the device, whose files it keeps by path.
    private final class Copies: @unchecked Sendable {
        var made: [(name: String, destination: String, text: String)] = []
        var sources: [URL] = []
        var device: [String: Data] = [:]
        var unreadable = false
        var unwritable = false
        var fetched: [String] = []
        func copy(_ url: URL, _ destination: String) throws {
            if unwritable { throw DeviceError.tool("copy refused") }
            sources.append(url)
            let data = try Data(contentsOf: url)
            made.append((url.lastPathComponent, destination, String(decoding: data, as: UTF8.self)))
            device[destination] = data
        }
        var container: AssetFilesList.Container {
            AssetFilesList.Container(
                size: { self.device[$0].map { Int64($0.count) } },
                fetch: { path, local in
                    self.fetched.append(path)
                    guard !self.unreadable, let data = self.device[path] else { throw DeviceError.tool("cannot read") }
                    try data.write(to: local)
                },
                put: copy)
        }
    }

    /// The installer's messages, for what it says about a list it found.
    private final class Messages: @unchecked Sendable {
        var lines: [String] = []
    }

    private func installer(_ recipe: Recipe, messages: Messages = Messages()) -> Installer {
        Installer(recipe: recipe, request: InstallRequest(toolchain: "/nonexistent"),
                  store: ContentStore(root: FileManager.default.temporaryDirectory)) { messages.lines.append($0) }
    }

    func testTitlesWithoutAssetFilesGetNoList() throws {
        let copies = Copies()
        XCTAssertNil(AssetFilesList.contents(for: demo(nil)))
        XCTAssertNil(try AssetFilesList.write(recipe: demo(nil), copy: copies.copy))
        try installer(demo(nil)).writeAssetFiles(in: copies.container)
        XCTAssertTrue(copies.made.isEmpty, "nothing is written, and with no list on the device nothing is touched")
        // Every shipped recipe except the ones that name packs stays without a list.
        for recipe in try RecipeStore(directory: recipes).loadAll() where recipe.assetFiles == nil {
            XCTAssertNil(AssetFilesList.contents(for: recipe), recipe.id)
        }
    }

    func testTheListIsWrittenUnderItsFinalNameAndCleanedUp() throws {
        let copies = Copies()
        XCTAssertEqual(try AssetFilesList.write(recipe: try deadpool(), copy: copies.copy), 6)
        XCTAssertEqual(copies.made.count, 1)
        XCTAssertEqual(copies.made.first?.name, "klepton-asset-files.txt", "renamed from the temporary name before copying")
        XCTAssertEqual(copies.made.first?.destination, "Documents/android-files/klepton-asset-files.txt")
        XCTAssertEqual(copies.made.first?.text, deadpoolList)
        for url in copies.sources {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path), "temporary folder removed")
        }
    }

    func testInstallAndUpdateBothWriteTheList() throws {
        // Install and update run the same job (the app's install and “update all” both enqueue every step), and the
        // content syncs run the stage step too: the list is written wherever data is staged.
        for steps in [InstallStep.allCases, InstallStep.addonSync, InstallStep.contentSync] {
            XCTAssertTrue(steps.contains(.stage), "\(steps)")
        }

        // Install: the shipped recipe.
        let tested = try deadpool()
        let installCopies = Copies()
        try installer(tested).writeAssetFiles(in: installCopies.container)
        XCTAssertEqual(installCopies.made.map(\.destination), [AssetFilesList.destination])
        XCTAssertEqual(installCopies.made.first?.text, deadpoolList)

        // Update to another verified build of the project: the list follows the recipe chosen for the update.
        var newer = tested
        newer.versionCode = 9000
        newer.versionName = "1.0.41.400000.Quest"
        let drafts = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-assetfiles-drafts-\(UUID().uuidString)")
        let chosen = StoreUpdate.resolve([tested], variants: [newer], drafts: drafts,
                                         choices: .init(versions: [tested.id: 9000]))
        XCTAssertEqual(chosen.first?.versionCode, 9000)
        let updateCopies = Copies()
        try installer(try XCTUnwrap(chosen.first)).writeAssetFiles(in: updateCopies.container)
        XCTAssertEqual(updateCopies.made.map(\.destination), [AssetFilesList.destination])
        let text = try XCTUnwrap(updateCopies.made.first?.text)
        XCTAssertTrue(text.contains("# store-3240283705987790 versionCode 9000\n"), text)
        XCTAssertEqual(text.components(separatedBy: "meta=1.0.41.400000.Quest\n").count - 1, 6, text)
        XCTAssertFalse(text.contains("1.0.40.356975.Quest"), text)
    }

    func testAnUntestedStoreBuildDropsTheList() throws {
        // Meta's tool names the new build's files without exact sizes, and its asset IDs are new ones: a list copied
        // from the tested build would be wrong, so the draft has none (and the device's list is left alone).
        let tested = try deadpool()
        let build = CatalogBuild(buildId: "30000000000000001", version: "1.0.41.400000.Quest", versionCode: 9000, fileName: nil)
        let files = [ListedFile(name: "PILO-Android-Shipping-arm64.apk", id: "30000000000000002", kind: "APK", sizeText: "90MB"),
                     ListedFile(name: "de.lang", id: "30000000000000003", kind: "ASSET", sizeText: "3.3GB")]
        let draft = try StoreUpdate.make(tested: tested, build: build, files: files)
        XCTAssertNil(draft.assetFiles)
        XCTAssertNil(AssetFilesList.contents(for: draft))
    }

    // MARK: A list left over on the device

    func testTheHeaderCarriesTheOwnerMark() {
        XCTAssertTrue(AssetFilesList.header.hasPrefix(AssetFilesList.ownerMark))
        XCTAssertTrue(AssetFilesList.isOwn(Data(deadpoolList.utf8)))
        XCTAssertTrue(AssetFilesList.isOwn(Data("# Written by AVP Play, older wording\r\nasset 1 a.lang 5\n".utf8)))
        XCTAssertFalse(AssetFilesList.isOwn(Data("asset 1 a.lang 5\n# Written by AVP Play\n".utf8)), "only the first line counts")
        XCTAssertFalse(AssetFilesList.isOwn(Data(" # Written by AVP Play\n".utf8)))
        XCTAssertFalse(AssetFilesList.isOwn(Data()))
    }

    func testOurOwnListIsEmptiedWhenTheRecipeHasNone() throws {
        // Deadpool VR was installed from the tested recipe; the update goes to an untested store build without a list.
        let copies = Copies()
        try installer(try deadpool()).writeAssetFiles(in: copies.container)
        XCTAssertEqual(copies.device[AssetFilesList.destination].map { String(decoding: $0, as: UTF8.self) }, deadpoolList)

        let build = CatalogBuild(buildId: "30000000000000001", version: "1.0.41.400000.Quest", versionCode: 9000, fileName: nil)
        let files = [ListedFile(name: "PILO-Android-Shipping-arm64.apk", id: "30000000000000002", kind: "APK", sizeText: "90MB")]
        let draft = try StoreUpdate.make(tested: try deadpool(), build: build, files: files)
        XCTAssertNil(draft.assetFiles)
        let messages = Messages()
        try installer(draft, messages: messages).writeAssetFiles(in: copies.container)
        XCTAssertEqual(copies.device[AssetFilesList.destination], Data(), "replaced by an empty file")
        XCTAssertEqual(copies.made.last?.name, AssetFilesList.fileName, "under the list's own name")
        XCTAssertEqual(copies.made.last?.destination, AssetFilesList.destination)
        XCTAssertEqual(messages.lines.count, 1, "\(messages.lines)")
        XCTAssertTrue(messages.lines.first?.contains(AssetFilesList.fileName) == true, "\(messages.lines)")
        for url in copies.sources {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path), "temporary file removed")
        }

        // Once emptied there is nothing left to do: no second copy, no second message.
        let made = copies.made.count
        try installer(draft, messages: messages).writeAssetFiles(in: copies.container)
        XCTAssertEqual(copies.made.count, made)
        XCTAssertEqual(messages.lines.count, 1)
        XCTAssertEqual(try AssetFilesList.clearOwn(in: copies.container), .none)
    }

    func testAForeignListIsLeftAlone() throws {
        for text in ["asset 1 a.lang 5 meta=x\n", "# written by hand\nasset 1 a.lang 5\n", "\n# Written by AVP Play\n"] {
            let copies = Copies()
            copies.device[AssetFilesList.destination] = Data(text.utf8)
            let messages = Messages()
            try installer(demo(nil), messages: messages).writeAssetFiles(in: copies.container)
            XCTAssertTrue(copies.made.isEmpty, text)
            XCTAssertEqual(copies.device[AssetFilesList.destination], Data(text.utf8), text)
            XCTAssertEqual(copies.fetched, [AssetFilesList.destination], "read, not changed")
            XCTAssertEqual(messages.lines.count, 1, "\(messages.lines)")
            XCTAssertEqual(try AssetFilesList.clearOwn(in: copies.container), .foreign)
        }
    }

    func testAListThatCannotBeReadIsLeftAlone() throws {
        let copies = Copies()
        copies.device[AssetFilesList.destination] = Data(deadpoolList.utf8)
        copies.unreadable = true
        let messages = Messages()
        try installer(demo(nil), messages: messages).writeAssetFiles(in: copies.container)
        XCTAssertTrue(copies.made.isEmpty)
        XCTAssertEqual(copies.device[AssetFilesList.destination], Data(deadpoolList.utf8))
        XCTAssertEqual(messages.lines.count, 1, "\(messages.lines)")
        XCTAssertEqual(try AssetFilesList.clearOwn(in: copies.container), .unreadable)

        // A listing that fails says nothing about the file either: it stays, unread.
        let unlisted = AssetFilesList.Container(size: { _ in throw DeviceError.tool("no listing") },
                                                fetch: { _, _ in XCTFail("not read") },
                                                put: { _, _ in XCTFail("not written") })
        XCTAssertEqual(try AssetFilesList.clearOwn(in: unlisted), .none)
    }

    func testAFailedEmptyingDoesNotStopTheStep() throws {
        let copies = Copies()
        copies.device[AssetFilesList.destination] = Data(deadpoolList.utf8)
        copies.unwritable = true
        let messages = Messages()
        XCTAssertNoThrow(try installer(demo(nil), messages: messages).writeAssetFiles(in: copies.container))
        XCTAssertEqual(copies.device[AssetFilesList.destination], Data(deadpoolList.utf8))
        XCTAssertEqual(messages.lines.count, 1, "\(messages.lines)")
        XCTAssertThrowsError(try AssetFilesList.clearOwn(in: copies.container))
    }

    func testTitlesWithAssetFilesStillRewriteTheList() throws {
        // Whatever lies there – a foreign list, an older one of ours, an emptied one – a recipe with a list replaces
        // it, without reading it first.
        for old in ["asset 9 x.lang 1\n", "\(AssetFilesList.header)\n# store-3240283705987790 versionCode 1\n", ""] {
            let copies = Copies()
            copies.device[AssetFilesList.destination] = Data(old.utf8)
            try installer(try deadpool()).writeAssetFiles(in: copies.container)
            XCTAssertEqual(copies.device[AssetFilesList.destination].map { String(decoding: $0, as: UTF8.self) }, deadpoolList, old)
            XCTAssertTrue(copies.fetched.isEmpty, old)
            XCTAssertEqual(copies.made.count, 1, old)
        }
    }
}
