import XCTest
@testable import AVPPlayCore

/// Ein Spiel aus zwei Kaufquellen: das Rezept aus dem Meta-Store und daneben eines für den Steam-Kauf.
final class SteamSourceTests: XCTestCase {
    private func file(_ name: String, _ role: String, _ dest: String?, steam: Bool, local: String? = nil) -> RecipeFile {
        let source = steam ? FileSource(kind: .user, url: nil, hint: nil,
                                        steam: SteamSource(app: "1408230", depots: [.init(id: "1408232", manifest: "4654829008722659631", bytes: 10)]),
                                        archive: nil) : nil
        return RecipeFile(name: name, role: role, id: steam ? "" : "1000000", size: 10, sha256: String(repeating: "a", count: 64),
                          required: true, dest: dest, localName: local, locale: nil, source: source)
    }

    private func meta() -> Recipe {
        Recipe(schema: Recipe.supportedSchema, id: "golf", title: "Golf", package: "com.example.golf", versionName: "6.8",
               versionCode: 62568, store: .init(appId: "2462678267173943"), toolchain: .init(target: "golf", minCommit: "abc1234"),
               files: [file("Golf.apk", "apk", "", steam: false, local: "golf.apk"),
                       file("main.62568.com.example.golf.obb", "main-obb", "android-files/obb", steam: false)],
               addons: Addons(kind: .purchaseList, dest: "android-files", items: nil),
               status: .init(playability: "verified", download: "proven", notes: nil), icon: nil, trees: nil)
    }

    private func steam() -> Recipe {
        Recipe(schema: Recipe.supportedSchema, id: "golf", title: "Golf", package: "com.example.golf", versionName: "6.8",
               versionCode: 58568, store: .init(appId: nil, steamAppId: "1408230"), toolchain: .init(target: "golf", minCommit: "abc1234"),
               files: [file("Golf.apk", "apk", "", steam: true, local: "golf.apk"),
                       file("main.58568.com.example.golf.obb", "main-obb", "android-files/obb", steam: true)],
               addons: Addons(kind: .purchaseList, dest: "android-files", items: nil, steamApps: ["1791210", "1847170"]),
               status: .init(playability: "verified", download: "proven", notes: nil),
               icon: .init(steamAppId: nil, metaAppId: "2462678267173943"), trees: nil)
    }

    func testARecipeNamesItsPurchaseSource() throws {
        XCTAssertEqual(meta().source, .meta)
        XCTAssertEqual(steam().source, .steam)
        try steam().validate()
        XCTAssertEqual(steam().catalogAppId, "2462678267173943", "im Katalog steht das Spiel unter seiner Meta-Seite")
        XCTAssertEqual(OwnershipCache.key(for: meta()), "2462678267173943")
        XCTAssertEqual(OwnershipCache.key(for: steam()), "steam:1408230")

        var both = steam()
        both.store.appId = "2462678267173943"
        XCTAssertThrowsError(try both.validate(), "ein Rezept hat eine Kaufquelle")
        var odd = steam()
        odd.store.steamAppId = "1408230 +quit"
        XCTAssertThrowsError(try odd.validate(), "die Kennung wird zum Argument für Valves Werkzeug")
        var addon = steam()
        addon.addons?.steamApps = ["17x"]
        XCTAssertThrowsError(try addon.validate())
    }

    func testOnlyRecipesNamedAfterGameAndSourceCount() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-sources-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent(RecipeStore.sourcesFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        try encoder.encode(steam()).write(to: folder.appendingPathComponent("golf.steam.json"))
        try encoder.encode(steam()).write(to: folder.appendingPathComponent("other.steam.json"))
        try encoder.encode(meta()).write(to: folder.appendingPathComponent("golf.meta.json"))
        try Data("{".utf8).write(to: folder.appendingPathComponent("broken.steam.json"))
        let found = RecipeStore(directory: dir).loadSources()
        XCTAssertEqual(found.map(\.versionCode), [58568])
    }

    func testTheChosenSourceDecidesWhichRecipeApplies() {
        let drafts = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-none-\(UUID().uuidString)", isDirectory: true)
        func resolved(_ choices: StoreUpdate.Choices, sources: [Recipe]) -> Recipe? {
            StoreUpdate.resolve([meta()], sources: sources, drafts: drafts, choices: choices).first
        }
        XCTAssertEqual(resolved(.init(), sources: [steam()])?.source, .meta, "ohne Wahl gilt das mitgelieferte Rezept")
        XCTAssertEqual(resolved(.init(sources: ["golf": .steam]), sources: [steam()])?.versionCode, 58568)
        XCTAssertEqual(resolved(.init(sources: ["golf": .steam]), sources: [])?.source, .meta, "ohne Rezept für Steam bleibt es bei Meta")
        // Die Wahl einer Fassung gehört zum Meta-Store; bei Steam gibt es nur die des Rezepts.
        XCTAssertEqual(resolved(.init(versions: ["golf": 60366], sources: ["golf": .steam]), sources: [steam()])?.versionCode, 58568)
        var foreign = steam()
        foreign.toolchain = .init(target: "other", minCommit: "abc1234")
        XCTAssertEqual(resolved(.init(sources: ["golf": .steam]), sources: [foreign])?.source, .meta)
    }

    func testChoicesKeepOnlyADeviatingSourceAndReadOlderFiles() throws {
        var choices = StoreUpdate.Choices()
        choices.choose(source: .steam, for: "golf")
        XCTAssertEqual(choices.sources, ["golf": .steam])
        choices.choose(source: .meta, for: "golf")
        XCTAssertTrue(choices.sources.isEmpty, "die Quelle des mitgelieferten Rezepts braucht keinen Eintrag")
        let old = try JSONDecoder().decode(StoreUpdate.Choices.self, from: Data(#"{"latest":["golf"],"versions":{"saber":1716}}"#.utf8))
        XCTAssertTrue(old.sources.isEmpty)
        XCTAssertEqual(old.versions, ["saber": 1716])
        choices.choose(source: .steam, for: "golf")
        let again = try JSONDecoder().decode(StoreUpdate.Choices.self, from: JSONEncoder().encode(choices))
        XCTAssertEqual(again, choices)
    }

    /// Die Ausgabe von SteamCMD für mehrere `licenses_for_app` in einem Lauf, wie sie am 2026-10-13 aussah.
    func testSteamAnswersAreReadPerApp() {
        let output = """
        Logging in using cached credentials.
        Logging in user '…' […] to Steam Public...OK
        License packageID 494200:
         - State   : Active (flags 0x200) - Purchased : Wed Dec 10 23:02:16 2025 in "DE", PayPal
         - Apps\t: 1408230,  (1 in total)
         - Depots   : 1408231, 1408232,  (2 in total)
        License packageID 643136:
         - State   : Active (flags 0x200) - Purchased : Wed Dec 10 23:02:16 2025 in "DE", PayPal
         - Apps\t: 1791210,  (1 in total)
         - Depots   :  (0 in total)
        No active license found for appID 1847170.
        License packageID 700000:
         - State   : Expired (flags 0x0)
         - Apps\t: 1906500, 2016530,  (2 in total)
        Unloading Steam API...OK
        """
        let asked = ["1408230", "1791210", "1847170", "1906500", "2086230"]
        let answers = SteamRun.licences(output, apps: asked)
        XCTAssertEqual(answers["1408230"], true)
        XCTAssertEqual(answers["1791210"], true)
        XCTAssertEqual(answers["1847170"], false)
        XCTAssertNil(answers["1906500"], "eine Lizenz, die nicht aktiv ist, ist kein Ja")
        XCTAssertNil(answers["2086230"], "wozu Steam nichts sagt, steht nichts fest")
        // Eine Depotnummer in einer anderen Zeile ist keine App des Kontos.
        XCTAssertNil(SteamRun.licences(output, apps: ["1408232"])["1408232"])
        // Nach „keine“ kommt für dieselbe App kein Ja mehr aus einem fremden Block, und umgekehrt bleibt ein Ja ein Ja.
        XCTAssertEqual(SteamRun.licences(output + "\nNo active license found for appID 1408230.", apps: ["1408230"])["1408230"], true)
    }

    func testTheOtherSourceOnTheDeviceIsNotThisInstallation() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-other-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ContentStore(root: dir)
        let bundle = Toolchain.bundleId(target: "golf", prefix: nil)
        func status(_ recipe: Recipe, installed: String, other: Set<Int>) -> GameStatus.OnDevice {
            let apps = [InstalledApp(bundleIdentifier: bundle, name: "Golf", version: "6.8", bundleVersion: installed)]
            return GameStatus.of(recipe: recipe, store: store, apps: apps, toolchainVersion: 365, otherSourceBuilds: other).onDevice
        }
        // Gewählt ist Steam, installiert die Fassung aus dem Meta-Store – und umgekehrt.
        XCTAssertEqual(status(steam(), installed: "62568.358", other: [62568, 60366]), .otherSource(stamp: "6.8 (62568.358)"))
        XCTAssertEqual(status(meta(), installed: "58568.365", other: [58568]), .otherSource(stamp: "6.8 (58568.365)"))
        // Die eigene Fassung bleibt, was sie war; ohne Wissen um die andere Quelle auch der Rest.
        XCTAssertEqual(status(steam(), installed: "58568.365", other: [62568]), .current(stamp: "6.8 (58568.365)"))
        XCTAssertEqual(status(meta(), installed: "58568.365", other: []), .olderGame(stamp: "6.8 (58568.365)"))
    }

    func testSavedGamesOfTheTwoSourcesStayApart() throws {
        XCTAssertNotEqual(SaveStore.key(for: meta()), SaveStore.key(for: steam()))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-saves-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir); OtherSources.use(recipes: nil) }
        let recipes = dir.appendingPathComponent("recipes", isDirectory: true)
        try FileManager.default.createDirectory(at: recipes.appendingPathComponent(RecipeStore.sourcesFolder), withIntermediateDirectories: true)
        try JSONEncoder().encode(meta()).write(to: recipes.appendingPathComponent("golf.json"))
        try JSONEncoder().encode(steam()).write(to: recipes.appendingPathComponent("\(RecipeStore.sourcesFolder)/golf.steam.json"))
        OtherSources.use(recipes: recipes)
        XCTAssertEqual(OtherSources.builds(of: steam()), [62568])
        XCTAssertEqual(OtherSources.builds(of: meta()), [58568])

        let store = ContentStore(root: dir.appendingPathComponent("store", isDirectory: true))
        let bundle = Toolchain.defaultBundleId(target: "golf")
        let fromMeta = [InstalledApp(bundleIdentifier: bundle, name: "Golf", version: "6.8", bundleVersion: "62568.358")]
        let fromSteam = [InstalledApp(bundleIdentifier: bundle, name: "Golf", version: "6.8", bundleVersion: "58568.368")]
        // Was aus dem Meta-Store auf dem Gerät liegt, ist für das Steam-Rezept nicht installiert – und umgekehrt.
        XCTAssertNil(SaveSync.installedBundle(recipe: steam(), store: store, prefix: nil, apps: fromMeta))
        XCTAssertNil(SaveSync.installedBundle(recipe: meta(), store: store, prefix: nil, apps: fromSteam))
        XCTAssertEqual(SaveSync.installedBundle(recipe: meta(), store: store, prefix: nil, apps: fromMeta), bundle)
        XCTAssertEqual(SaveSync.installedBundle(recipe: steam(), store: store, prefix: nil, apps: fromSteam), bundle)
        // Ohne Wissen um die andere Quelle gilt wie bisher: installiert ist installiert.
        OtherSources.use(recipes: nil)
        XCTAssertEqual(SaveSync.installedBundle(recipe: steam(), store: store, prefix: nil, apps: fromMeta), bundle)
    }

    func testFilesOfASteamPurchaseCountAsDownloads() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-steamfiles-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let status = GameStatus.of(recipe: steam(), store: ContentStore(root: dir), apps: nil, toolchainVersion: nil)
        XCTAssertEqual(status.filesToDownload, 2)
        XCTAssertEqual(status.bytesToDownload, 20)
        XCTAssertTrue(status.userProvidedMissing.isEmpty, "das Programm holt sie selbst aus dem Steam-Kauf")
        // Eine Sonderapp, deren Dateien nur zufällig auch bei Steam liegen, bleibt „selbst bereitzustellen“.
        var special = steam()
        special.store.steamAppId = nil
        XCTAssertEqual(GameStatus.of(recipe: special, store: ContentStore(root: dir), apps: nil, toolchainVersion: nil).userProvidedMissing.count, 2)
    }

    /// Portals deutsche Stimmen: angehakt wird die Sprache, Valves Werkzeug bekommt die Dateinamen, und ein Auftrag
    /// für die Sonderapp holt sie selbst – ein Meta-Spiel mit einzelnen Steam-Teilen (Alyx' Workshop) aber nicht.
    func testPortalVoicesFollowTheLanguageAndTheJobFetchesThem() throws {
        let recipes = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
        let portal = try RecipeStore(directory: recipes).load(id: "portal")
        let voices: Set = ["portal_sound_vo_german_dir.vpk", "portal_sound_vo_german_000.vpk", "portal_sound_vo_german.vpk.sound.cache"]
        XCTAssertEqual(SteamFetcher.chosenNames(recipe: portal, locales: ["de-DE"], optionalNames: []), voices)
        XCTAssertEqual(SteamFetcher.chosenNames(recipe: portal, locales: [], optionalNames: []), [])
        // Jede der vier Sprachausgaben aus Steam ist für sich wählbar, mit ihrem eigenen Depot.
        for (locale, word, depot) in [("fr-FR", "french", "407"), ("es-ES", "spanish", "406"), ("ru-RU", "russian", "405")] {
            let files = portal.files.filter { $0.locale == locale }
            XCTAssertEqual(Set(files.map(\.name)), ["portal_sound_vo_\(word)_dir.vpk", "portal_sound_vo_\(word)_000.vpk",
                                                    "portal_sound_vo_\(word).vpk.sound.cache"])
            XCTAssertEqual(Set(files.compactMap { $0.source?.steam?.depots.first?.id }), [depot])
            XCTAssertEqual(files.compactMap(\.size).reduce(0, +), files.first?.source?.steam?.depots.first?.bytes)
            XCTAssertEqual(SteamFetcher.chosenNames(recipe: portal, locales: [locale], optionalNames: []), Set(files.map(\.name)))
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let chosen = SteamFetcher.chosenNames(recipe: portal, locales: ["de-DE"], optionalNames: [])
        XCTAssertEqual(Set(SteamFetcher.needed(recipe: portal, store: ContentStore(root: dir), optionalNames: chosen).files.map(\.name)), voices)

        XCTAssertNil(portal.source)
        XCTAssertTrue(SteamFetcher.fetchesInJob(portal))
        XCTAssertTrue(SteamFetcher.fetchesInJob(steam()))
        XCTAssertFalse(SteamFetcher.fetchesInJob(meta()))
        var metaWithSteamParts = meta()
        metaWithSteamParts.files.append(file("1.vpk", "workshop", "lx", steam: true))
        XCTAssertFalse(SteamFetcher.fetchesInJob(metaWithSteamParts))
    }

    /// Half-Life 2: sechs Sprachausgaben aus Steam, jede mit ihrem eigenen Depot und vollständig, und wie Portal
    /// eine Sonderapp, deren Auftrag sie selbst holt.
    func testHalfLife2VoicesFollowTheLanguage() throws {
        let recipes = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
        let hl2 = try RecipeStore(directory: recipes).load(id: "hl2")
        XCTAssertEqual(hl2.toolchain.target, "sourcevr-hl2")
        for (locale, word, depot) in [("de-DE", "german", "228"), ("fr-FR", "french", "227"), ("es-ES", "spanish", "226"),
                                      ("ru-RU", "russian", "225"), ("it-IT", "italian", "232"), ("ko-KR", "koreana", "229")] {
            let files = hl2.files.filter { $0.locale == locale }
            XCTAssertFalse(files.isEmpty, locale)
            XCTAssertTrue(files.allSatisfy { $0.name.hasPrefix("hl2_sound_vo_\(word)") || $0.name.contains(word) }, locale)
            XCTAssertEqual(Set(files.compactMap { $0.source?.steam?.depots.first?.id }), [depot])
            XCTAssertEqual(files.compactMap(\.size).reduce(0, +), files.first?.source?.steam?.depots.first?.bytes)
            XCTAssertEqual(SteamFetcher.chosenNames(recipe: hl2, locales: [locale], optionalNames: []), Set(files.map(\.name)))
        }
        XCTAssertEqual(SteamFetcher.chosenNames(recipe: hl2, locales: [], optionalNames: []), [])
        XCTAssertNil(hl2.source)
        XCTAssertTrue(SteamFetcher.fetchesInJob(hl2))
    }

}
