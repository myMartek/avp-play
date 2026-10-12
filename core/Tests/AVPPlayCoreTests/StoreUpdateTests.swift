import XCTest
@testable import AVPPlayCore

final class StoreUpdateTests: XCTestCase {
    private func tested() -> Recipe {
        func file(_ name: String, _ role: String, _ dest: String?, required: Bool = true, source: FileSource? = nil, local: String? = nil) -> RecipeFile {
            RecipeFile(name: name, role: role, id: "1000000", size: 10, sha256: String(repeating: "a", count: 64), required: required,
                       dest: dest, localName: local, locale: nil, source: source)
        }
        return Recipe(schema: Recipe.supportedSchema, id: "golf", title: "Golf", package: "com.example.golf", versionName: "6.7",
                      versionCode: 60366, store: .init(appId: "2462678267173943"), toolchain: .init(target: "golf", minCommit: "abc1234"),
                      files: [file("Golf.apk", "apk", "", local: "golf.apk"),
                              file("main.60366.com.example.golf.obb", "main-obb", "android-files/obb"),
                              file("course-a.bundle", "content-bundle", "android-files/Android/obb/com.example.golf"),
                              file("course-b.bundle", "content-bundle", "android-files/Android/obb/com.example.golf"),
                              file("index.json", "manifest", nil, required: false)],
                      addons: Addons(kind: .purchaseList, dest: "android-files", items: nil),
                      status: .init(playability: "verified", download: "proven", notes: nil), icon: nil, trees: nil)
    }

    func testANewerBuildIsOfferedUnlessTheRecipeIsPinned() {
        var recipe = tested()
        let newer = CatalogBuild(buildId: "30000000000000001", version: "6.9", versionCode: 60500, fileName: nil)
        XCTAssertTrue(StoreUpdate.isOffered(newer, for: recipe))
        XCTAssertFalse(StoreUpdate.isOffered(CatalogBuild(buildId: "30000000000000001", version: "6.7", versionCode: 60366, fileName: nil), for: recipe))
        XCTAssertFalse(StoreUpdate.isOffered(nil, for: recipe))
        recipe.store.pinned = true
        XCTAssertFalse(StoreUpdate.isOffered(newer, for: recipe), "ein Spiel, das bei seiner Fassung bleiben soll")
    }

    func testTheNewestBuildTakesThePlacesOfTheTestedOne() throws {
        let build = CatalogBuild(buildId: "30000000000000001", version: "6.9", versionCode: 60500, fileName: nil)
        let listed = [ListedFile(name: "Golf.apk", id: "40000000000000001", kind: "APK", sizeText: "60MB"),
                      ListedFile(name: "main.60500.com.example.golf.obb", id: "40000000000000002", kind: "OBB", sizeText: "1GB"),
                      ListedFile(name: "course-a.bundle", id: "40000000000000003", kind: "ASSET", sizeText: "90MB"),
                      ListedFile(name: "course-new.bundle", id: "40000000000000004", kind: "ASSET", sizeText: "95MB"),
                      ListedFile(name: "extras.pak", id: "40000000000000005", kind: "ASSET", sizeText: "5MB")]
        let newest = try StoreUpdate.make(tested: tested(), build: build, files: listed)
        XCTAssertEqual(newest.id, "golf")
        XCTAssertEqual(newest.versionCode, 60500)
        XCTAssertEqual(newest.toolchain.target, "golf")
        XCTAssertEqual(newest.toolchain.minCommit, "abc1234")
        XCTAssertEqual(newest.addons?.kind, .purchaseList, "die Freischaltung der Zusatzinhalte bleibt die geprüfte")
        XCTAssertEqual(newest.status.playability, "untested")
        XCTAssertNotNil(newest.status.notes?.first)

        func entry(_ name: String) -> RecipeFile? { newest.files.first { $0.name == name } }
        XCTAssertEqual(entry("Golf.apk")?.localName, "golf.apk")
        XCTAssertEqual(entry("Golf.apk")?.id, "40000000000000001")
        XCTAssertEqual(entry("main.60500.com.example.golf.obb")?.dest, "android-files/obb")
        XCTAssertEqual(entry("course-a.bundle")?.dest, "android-files/Android/obb/com.example.golf")
        XCTAssertEqual(entry("course-new.bundle")?.role, "content-bundle", "eine neue Datei bekommt den Platz der gleichartigen")
        XCTAssertEqual(entry("course-new.bundle")?.dest, "android-files/Android/obb/com.example.golf")
        XCTAssertEqual(entry("extras.pak")?.dest, "android-files/Android/obb/com.example.golf", "ohne Gegenstück: der Ordner des Pakets")
        XCTAssertNil(entry("course-b.bundle"), "was der neue Build nicht mehr hat, fällt weg")
        XCTAssertNil(entry("main.60366.com.example.golf.obb"))
        // Nichts vom geprüften Build wird als Größe oder Prüfsumme des neuen ausgegeben.
        XCTAssertTrue(newest.files.filter { $0.source == nil }.allSatisfy { $0.sha256 == nil && $0.size == nil })
        // Ein Build ohne APK ist keiner.
        XCTAssertThrowsError(try StoreUpdate.make(tested: tested(), build: build, files: Array(listed.dropFirst())))
    }

    func testAddOnsTheStoreDeliversFollowTheNewBuildAndNeverBecomeFilesOfTheGame() throws {
        func file(_ name: String, _ role: String, _ dest: String?, local: String? = nil) -> RecipeFile {
            RecipeFile(name: name, role: role, id: "1000000", size: 10, sha256: String(repeating: "a", count: 64), required: true,
                       dest: dest, localName: local, locale: nil, source: nil)
        }
        let songs = [AddonItem(sku: "P1S1", name: "boundless", id: "2000001", size: 11, sha256: String(repeating: "b", count: 64), group: "one"),
                     AddonItem(sku: "P1S2", name: "epic", id: "2000002", size: nil, sha256: nil, group: "one"),
                     AddonItem(sku: "P2S1", name: "withdrawn", id: "2000003", size: nil, sha256: nil, group: "two")]
        let tested = Recipe(schema: Recipe.supportedSchema, id: "saber", title: "Saber", package: "com.example.saber", versionName: "1.40",
                            versionCode: 1716, store: .init(appId: "2448060205267927"), toolchain: .init(target: "saber", minCommit: "abc1234"),
                            files: [file("saber.apk", "apk", "", local: "saber.apk"), file("main.1716.com.example.saber.obb", "main-obb", "android-files/obb")],
                            addons: Addons(kind: .deliveredAssets, dest: "android-files/klepton-assets", items: songs),
                            status: .init(playability: "verified", download: "proven", notes: nil), icon: nil, trees: nil)
        let build = CatalogBuild(buildId: "30000000000000001", version: "1.45", versionCode: 3148, fileName: nil)
        let listed = [ListedFile(name: "saber.apk", id: "40000000000000001", kind: "APK", sizeText: "60MB"),
                      ListedFile(name: "main.3148.com.example.saber.obb", id: "40000000000000002", kind: "OBB", sizeText: "1GB"),
                      ListedFile(name: "boundless", id: "40000000000000003", kind: "ASSET", sizeText: "11MB"),
                      ListedFile(name: "epic", id: "40000000000000004", kind: "ASSET", sizeText: "12MB"),
                      ListedFile(name: "brandnew", id: "40000000000000005", kind: "ASSET", sizeText: "9MB")]
        let newest = try StoreUpdate.make(tested: tested, build: build, files: listed)

        XCTAssertEqual(newest.files.map(\.name), ["saber.apk", "main.3148.com.example.saber.obb"],
                       "kein Song ist eine Datei des Spiels – auch der nicht, den das geprüfte Rezept noch nicht kennt")
        XCTAssertEqual(newest.addons?.kind, .deliveredAssets)
        XCTAssertEqual(newest.addons?.dest, "android-files/klepton-assets")
        let items = newest.addons?.items ?? []
        XCTAssertEqual(items.map(\.name), ["boundless", "epic"], "was der neue Build nicht mehr führt, fällt weg")
        XCTAssertEqual(items.map(\.id), ["40000000000000003", "40000000000000004"], "unter der Kennung des neuen Builds")
        XCTAssertEqual(items.map(\.sku), ["P1S1", "P1S2"], "der Kauf, zu dem ein Song gehört, bleibt der geprüfte")
        XCTAssertTrue(items.allSatisfy { $0.size == nil && $0.sha256 == nil }, "nichts vom geprüften Build gilt als Prüfsumme des neuen")
        // Mit der Kaufliste des Kontos wird daraus genau das Gekaufte.
        let wanted = FetchPlan.wantedFiles(recipe: newest, selection: FetchSelection(ownedSKUs: ["P1S2", "P9S9"]))
        XCTAssertEqual(wanted.filter { $0.role == "addon" }.map(\.name), ["epic"])
        XCTAssertEqual(wanted.first { $0.role == "addon" }?.id, "40000000000000004")
    }

    func testAChosenVersionIsAVerifiedOneOrALookedUpOneOrTheDefault() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-versions-\(UUID().uuidString)", isDirectory: true)
        let drafts = dir.appendingPathComponent("drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let encoder = JSONEncoder()
        let current = tested()                                  // 6.7, Code 60366: gilt ohne Wahl
        var older = current                                      // eine weitere geprüfte Fassung, älter
        older.versionName = "6.5"; older.versionCode = 60100
        var looked = current                                     // aus dem Store nachgeschlagen, ungetestet
        looked.versionName = "6.6"; looked.versionCode = 60200
        looked.status = .init(playability: "untested", download: "listed", notes: nil)
        try encoder.encode(looked).write(to: StoreUpdate.url(drafts: drafts, recipeId: "golf", versionCode: 60200))
        func code(_ choices: StoreUpdate.Choices, variants: [Recipe] = [older]) -> Int? {
            StoreUpdate.resolve([current], variants: variants, drafts: drafts, choices: choices).first?.versionCode
        }
        XCTAssertEqual(code(.init()), 60366, "ohne Wahl die Fassung des Rezepts")
        XCTAssertEqual(code(.init(versions: ["golf": 60100])), 60100, "eine weitere geprüfte Fassung – auch eine ältere")
        XCTAssertEqual(StoreUpdate.resolve([current], variants: [older], drafts: drafts, choices: .init(versions: ["golf": 60100])).first?.status.playability,
                       "verified")
        XCTAssertEqual(code(.init(versions: ["golf": 60200])), 60200, "eine nachgeschlagene aus dem Store")
        XCTAssertEqual(code(.init(versions: ["golf": 60366])), 60366, "die Fassung ohne Wahl, ausdrücklich gewählt")
        XCTAssertEqual(code(.init(versions: ["golf": 60999])), 60366, "eine Wahl ohne Rezept fällt zurück")
        XCTAssertEqual(code(.init(versions: ["golf": 60100]), variants: []), 60366, "ein geprüftes Rezept, das es nicht mehr gibt, auch")
        XCTAssertEqual(code(.init(versions: ["other": 60100])), 60366, "die Wahl gilt je Spiel")
        // Ein nachgeschlagenes Rezept eines anderen Spiels unter diesem Namen gilt nicht.
        var foreign = looked
        foreign.store = .init(appId: "9999999999")
        foreign.versionCode = 60300
        try encoder.encode(foreign).write(to: StoreUpdate.url(drafts: drafts, recipeId: "golf", versionCode: 60300))
        XCTAssertEqual(code(.init(versions: ["golf": 60300])), 60366)
        // Ein Spiel, das bei seiner Fassung bleiben soll, bleibt dabei.
        var pinned = current
        pinned.store.pinned = true
        XCTAssertEqual(StoreUpdate.resolve([pinned], variants: [older], drafts: drafts, choices: .init(versions: ["golf": 60100])).first?.versionCode, 60366)
        // Die Wahl „die neueste“ aus der Zeit vor der Liste gilt weiter, und eine bestimmte Fassung geht ihr vor.
        var newest = current
        newest.versionName = "6.9"; newest.versionCode = 60500
        try encoder.encode(newest).write(to: StoreUpdate.url(drafts: drafts, recipeId: "golf"))
        XCTAssertEqual(code(.init(latest: ["golf"])), 60500)
        XCTAssertEqual(code(.init(latest: ["golf"], versions: ["golf": 60100])), 60100)
        XCTAssertEqual(code(.init(versions: ["golf": 60500])), 60500, "…und ihr Rezept lässt sich auch als bestimmte Fassung wählen")
    }

    func testTheStoredChoiceReadsAFileFromBeforeVersionsAndChoosingReplacesNewest() throws {
        let old = try JSONDecoder().decode(StoreUpdate.Choices.self, from: Data(#"{"latest":["walkabout"]}"#.utf8))
        XCTAssertEqual(old.latest, ["walkabout"])
        XCTAssertEqual(old.versions, [:])
        var choices = old
        choices.choose(1716, for: "walkabout")
        XCTAssertEqual(choices.versions, ["walkabout": 1716])
        XCTAssertFalse(choices.latest.contains("walkabout"), "eine bestimmte Fassung ersetzt „die neueste“")
        choices.choose(nil, for: "walkabout")
        XCTAssertEqual(choices, StoreUpdate.Choices())
        let round = try JSONDecoder().decode(StoreUpdate.Choices.self, from: JSONEncoder().encode(StoreUpdate.Choices(versions: ["a": 2])))
        XCTAssertEqual(round.versions, ["a": 2])
    }

    func testFurtherVerifiedVersionsAreReadFromTheirFolderByNameAndCode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-variants-\(UUID().uuidString)", isDirectory: true)
        let folder = dir.appendingPathComponent(RecipeStore.variantsFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let encoder = JSONEncoder()
        var a = tested(); a.versionCode = 60100
        var b = tested(); b.versionCode = 60200
        try encoder.encode(a).write(to: folder.appendingPathComponent("golf-60100.json"))
        try encoder.encode(b).write(to: folder.appendingPathComponent("golf-60200.json"))
        try encoder.encode(b).write(to: folder.appendingPathComponent("golf-1.json"))          // der Name nennt einen anderen Code
        try Data("{".utf8).write(to: folder.appendingPathComponent("golf-60300.json"))           // nicht lesbar
        try encoder.encode(tested()).write(to: dir.appendingPathComponent("golf.json"))         // die ohne Wahl: kein Teil davon
        let store = RecipeStore(directory: dir)
        XCTAssertEqual(store.loadVariants().map(\.versionCode), [60200, 60100], "die neueste zuerst")
        XCTAssertEqual(try store.loadAll().map(\.versionCode), [60366], "der Ordner selbst führt weiter nur die eine je Spiel")
        XCTAssertTrue(RecipeStore(directory: folder).loadVariants().isEmpty, "ohne Unterordner gibt es keine")
    }

    func testMetasAnswerNamesEveryVersionNewestFirst() {
        let answer = Data(#"{"data":{"node":{"supportedBinaries":{"edges":[{"node":{"version":"6.7","versionCode":60366,"id":"27353254667689625"}},{"node":{"version":"6.8","versionCode":62568,"id":"28028576350157450"}},{"node":{"version":"6.8 again","versionCode":62568,"id":"28028576350157451"}},{"node":{"version":"x","versionCode":99999999,"id":"not-a-number"}},{"node":{"version":"6.5","versionCode":60100,"id":"27000000000000001"}},{"node":null}]}}}}"#.utf8)
        let builds = MetaClient.builds(inAnswer: answer)
        XCTAssertEqual(builds.map(\.versionCode), [62568, 60366, 60100])
        XCTAssertEqual(builds.map(\.version), ["6.8", "6.7", "6.5"], "je Versionsnummer ein Build")
        XCTAssertEqual(MetaClient.newestBuild(inAnswer: answer)?.buildId, builds.first?.buildId)
        XCTAssertTrue(MetaClient.builds(inAnswer: Data(#"{"errors":[{"message":"x"}]}"#.utf8)).isEmpty)
    }

    func testMetasAnswerIsReadForItsNewestBuildAndNothingElse() {
        let answer = Data(#"{"data":{"node":{"__typename":"Application","displayName":"Golf","supportedBinaries":{"edges":[{"node":{"__typename":"AndroidBinary","changeLog":null,"version":"6.7","versionCode":60366,"id":"27353254667689625"}},{"node":{"__typename":"AndroidBinary","version":"6.8","versionCode":62568,"id":"28028576350157450"}},{"node":{"version":"x","versionCode":99999999,"id":"not-a-number"}},{"node":null}]}}}}"#.utf8)
        let newest = MetaClient.newestBuild(inAnswer: answer)
        XCTAssertEqual(newest?.version, "6.8")
        XCTAssertEqual(newest?.versionCode, 62568)
        XCTAssertEqual(newest?.buildId, "28028576350157450")
        XCTAssertNil(MetaClient.newestBuild(inAnswer: Data(#"{"errors":[{"message":"Exception was thrown"}]}"#.utf8)))
        XCTAssertNil(MetaClient.newestBuild(inAnswer: Data(#"{"data":{"node":null}}"#.utf8)))
        XCTAssertNil(MetaClient.newestBuild(inAnswer: Data("no json".utf8)))
    }

    func testAnInstalledOlderVersionOfTheGameIsAnUpdate() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qi-older-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        var recipe = tested()
        recipe.versionName = "6.8"
        recipe.versionCode = 62568
        let prefix = "com.example.games"
        func onDevice(_ version: String, _ build: String) -> GameStatus.OnDevice {
            GameStatus.of(recipe: recipe, store: ContentStore(root: dir),
                          apps: [InstalledApp(bundleIdentifier: "\(prefix).golf", name: "Golf", version: version, bundleVersion: build)],
                          toolchainVersion: 291, bundlePrefix: prefix).onDevice
        }
        // Dieselbe Fassung, jetzige Toolchain; dieselbe Fassung, ältere Toolchain.
        XCTAssertEqual(onDevice("6.8", "62568.291"), .current(stamp: "6.8 (62568.291)"))
        XCTAssertEqual(onDevice("6.8", "62568.281"), .olderToolchain(stamp: "6.8 (62568.281)"))
        // Die vorige Fassung des Spiels, von diesem Werkzeug gebaut: eine Aktualisierung.
        XCTAssertEqual(onDevice("6.7", "60366.291"), .olderGame(stamp: "6.7 (60366.291)"))
        // Eine neuere Fassung als die des Rezepts, oder ein fremder Stempel: keine Aussage über „älter“.
        XCTAssertEqual(onDevice("6.9", "70000.291"), .unstamped(stamp: "6.9 (70000.291)"))
        XCTAssertEqual(onDevice("6.7", "1"), .unstamped(stamp: "6.7 (1)"))
    }

    func testAnUnchangedFileIsTakenFromTheOtherVersionWhenItsChecksumMatches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qi-adopt-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = ContentStore(root: root)
        let old = tested()
        var new = tested()
        new.versionName = "6.8"
        new.versionCode = 62568
        // Zwei Kursdateien der alten Fassung liegen im Bestand; eine davon ist in der neuen unverändert.
        let fm = FileManager.default
        try fm.createDirectory(at: store.directory(for: old), withIntermediateDirectories: true)
        let same = Data("the same course".utf8), changed = Data("an old course".utf8)
        try same.write(to: store.directory(for: old).appendingPathComponent("course-a.bundle"))
        try changed.write(to: store.directory(for: old).appendingPathComponent("course-b.bundle"))
        func entry(_ name: String, _ content: Data) -> RecipeFile {
            RecipeFile(name: name, role: "content-bundle", id: "40000000000000003", size: Int64(content.count),
                       sha256: Hashing.sha256(of: content), required: true, dest: "android-files", localName: nil, locale: nil, source: nil)
        }
        let a = entry("course-a.bundle", same)
        new.files = [a]

        XCTAssertEqual(store.siblings(of: a, in: new).map { $0.deletingLastPathComponent().lastPathComponent }, ["golf-60366"])
        XCTAssertEqual(store.siblings(of: a, in: old), [], "die eigene Fassung ist kein Geschwister")

        let lines = LockedBox<[String]>([])
        let fetcher = Fetcher(client: MetaClient(token: String(repeating: "x", count: 40)), store: store, gate: RequestGate(minInterval: .zero))
        let summary = try await fetcher.run([PlannedFetch(file: a, action: .download)], recipe: new) { lines.set(lines.get() + [$0]) }
        XCTAssertEqual(summary.adopted, 1)
        XCTAssertEqual(summary.downloaded, 0)
        XCTAssertEqual(try Data(contentsOf: store.url(for: a, in: new)), same)
        XCTAssertTrue(fm.fileExists(atPath: store.directory(for: old).appendingPathComponent("course-a.bundle").path), "kopiert, nicht verschoben")
        XCTAssertTrue(lines.get().contains { $0.contains("course-a.bundle") })
    }

    func testTheChoiceDecidesWhichRecipeIsUsed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qi-update-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let drafts = root.appendingPathComponent("drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
        let build = CatalogBuild(buildId: "30000000000000001", version: "6.9", versionCode: 60500, fileName: nil)
        let newest = try StoreUpdate.make(tested: tested(), build: build,
                                          files: [ListedFile(name: "Golf.apk", id: "40000000000000001", kind: "APK", sizeText: "60MB")])
        try JSONEncoder().encode(newest).write(to: StoreUpdate.url(drafts: drafts, recipeId: "golf"))

        // Ohne Wahl: das geprüfte.
        XCTAssertEqual(StoreUpdate.resolve([tested()], drafts: drafts, choices: .init()).first?.versionCode, 60366)
        // Gewählt: das neueste.
        XCTAssertEqual(StoreUpdate.resolve([tested()], drafts: drafts, choices: .init(latest: ["golf"])).first?.versionCode, 60500)
        // Gewählt, aber das Spiel bleibt bei seiner Fassung.
        var pinned = tested()
        pinned.store.pinned = true
        XCTAssertEqual(StoreUpdate.resolve([pinned], drafts: drafts, choices: .init(latest: ["golf"])).first?.versionCode, 60366)
        // Gewählt, aber das geprüfte Rezept hat inzwischen aufgeholt: es gilt wieder.
        var caughtUp = tested()
        caughtUp.versionCode = 60500
        XCTAssertEqual(StoreUpdate.resolve([caughtUp], drafts: drafts, choices: .init(latest: ["golf"])).first?.status.playability, "verified")

        // Die Wahl überlebt das Speichern.
        let file = root.appendingPathComponent("store-updates.json")
        try StoreUpdate.Choices(latest: ["golf", "other"]).save(to: file)
        XCTAssertEqual(StoreUpdate.Choices.load(from: file).latest, ["golf", "other"])
        XCTAssertEqual(StoreUpdate.Choices.load(from: root.appendingPathComponent("nothing.json")).latest, [])
    }
}
