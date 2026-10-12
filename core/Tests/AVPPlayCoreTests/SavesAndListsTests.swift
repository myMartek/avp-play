import XCTest
@testable import AVPPlayCore

final class SavesAndListsTests: XCTestCase {
    func recipe(id: String = "demo", title: String = "Demo: The Game", appId: String? = "1654565391314903", files: [RecipeFile] = []) -> Recipe {
        Recipe(schema: 1, id: id, title: title, package: "com.example.demo", versionName: "1.0", versionCode: 7,
               store: .init(appId: appId), toolchain: .init(target: "demo", minCommit: "abc"), files: files,
               addons: nil, status: .init(playability: "untested", download: "unknown", notes: nil), icon: nil)
    }
    func temp() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: Spielstände

    func testWhatCountsAsASavedGame() {
        // Wie die Ordner auf einer Vision Pro aussahen (Moss, Beat Saber, SUPERHOT; 2026-10-11).
        for path in ["UE4Game/MossGame/MossGame/Saved/SaveGames/SaveGame_0.sav", "files/PlayerData.dat", "files/PlayerData.dat.bak",
                     "no_backup/settings.ini", "shared_prefs/com.example.v2.playerprefs.xml", "cloudstorage/slot1", "2056371762",
                     "UE4Game/MossGame/MossGame/Saved/Config/Android/GameUserSettings.ini", "login-identifier.txt",
                     "Doom3Quest/saves_v1.3/base/savegames/Autosave_game_mars_city1.save", "files/Profiles/Backups/Campaign_00#9/career.bin"] {
            XCTAssertTrue(SaveRules.isSave(path, size: 1500), path)
        }
        for path in ["Android/obb/com.polyarc.MossGame/main.151047.com.polyarc.MossGame.obb", "obb/main.obb", "klepton-assets/freebird",
                     "klepton-entitlements.txt", "files/il2cpp/Metadata/global-metadata.dat", "VulkanProgramBinaryCache/VulkanPSO_1.106b",
                     "cache/thumb.bin", "UE4Game/Moss/Moss/Saved/Logs/Moss.log", "Engine/Saved/Crashes/x.dmp", "files/Unity/abc/Analytics/config",
                     "UE4Game/Moss/.klepton_synth.uproject", "Doom3Quest/base/pak000.pk4",
                     "xash/cstrike/downloaded/media/angel.mp3", "eyedump/eye0_005.png", "../outside", "/absolute", "files/../../x"] {
            XCTAssertFalse(SaveRules.isSave(path, size: 1500), path)
        }
        XCTAssertFalse(SaveRules.isSave("files/save.dat", size: 0))                          // leer ist kein Stand
        XCTAssertFalse(SaveRules.isSave("files/save.dat", size: SaveRules.largestFile + 1))  // zu groß für einen
        // Was der Mac selbst kopiert hat, ist kein Spielstand – es sei denn, das Spiel hat es verändert.
        var staged = SaveRules.Staged()
        staged.files["xash/cstrike/config.cfg"] = 900
        staged.closedFolders = ["Doom3Quest"]
        XCTAssertFalse(SaveRules.isSave("xash/cstrike/config.cfg", size: 900, staged: staged))
        XCTAssertTrue(SaveRules.isSave("xash/cstrike/config.cfg", size: 950, staged: staged))
        XCTAssertFalse(SaveRules.isSave("Doom3Quest/base/savegames/quick.save", size: 950, staged: staged))
        XCTAssertTrue(SaveRules.isSave("Doom3Questionable/save", size: 950, staged: staged))
    }

    func testTheDeviceListingBecomesAnOrderedListOfSaves() {
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        let remote = [RemoteFile(relativePath: "files", size: 96, isDirectory: true),
                      RemoteFile(relativePath: "files/b.dat", size: 20, isDirectory: false, modified: when),
                      RemoteFile(relativePath: "files/a.dat", size: 10, isDirectory: false),
                      RemoteFile(relativePath: "obb/main.obb", size: 2_000_000_000, isDirectory: false)]
        XCTAssertEqual(SaveSync.select(remote, staged: .init()),
                       [SaveFile(path: "files/a.dat", size: 10, modified: nil), SaveFile(path: "files/b.dat", size: 20, modified: when)])
    }

    func testWhatTheMacStagesIsKnownFromTheRecipe() throws {
        let root = temp()
        let store = ContentStore(root: root)
        let obb = RecipeFile(name: "main.7.obb", role: "obb", id: "1", size: 500, sha256: nil, required: true, dest: "android-files/obb")
        let apk = RecipeFile(name: "demo.apk", role: "apk", id: "2", size: 300, sha256: nil, required: true, dest: "")
        let r = recipe(files: [obb, apk])
        XCTAssertEqual(SaveSync.staged(recipe: r, store: store).files, ["obb/main.7.obb": 500])   // das APK liegt nicht unter android-files
        // Liegt die Datei im Bestand, gilt ihre wirkliche Größe.
        try FileManager.default.createDirectory(at: store.directory(for: r), withIntermediateDirectories: true)
        try Data(count: 480).write(to: store.url(for: obb, in: r))
        XCTAssertEqual(SaveSync.staged(recipe: r, store: store).files, ["obb/main.7.obb": 480])
    }

    func testSnapshotsAreKeptPerGameUnderAReadableNameAndPruned() throws {
        let saves = SaveStore(root: temp())
        let r = recipe()
        XCTAssertEqual(saves.directory(for: r).lastPathComponent, "Demo The Game [1654565391314903]")
        XCTAssertEqual(SaveStore.key(for: recipe(appId: nil)), "demo")
        XCTAssertTrue(saves.snapshots(for: r).isEmpty)
        let encoder = JSONEncoder.iso
        for n in 1...4 {
            let taken = Date(timeIntervalSince1970: 1_790_000_000 + Double(n) * 60)
            let snapshot = SaveSnapshot(id: SaveSync.stampName(taken), taken: taken, title: r.title, bundle: "me.dev.klepton.target.demo",
                                        files: [SaveFile(path: "files/a.dat", size: Int64(n), modified: taken)])
            let folder = saves.directory(for: r).appendingPathComponent(snapshot.id)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("files/files"), withIntermediateDirectories: true)
            try encoder.encode(snapshot).write(to: SaveStore.manifestURL(folder))
            try Data(count: n).write(to: saves.url(of: snapshot.files[0], in: snapshot, for: r))
        }
        let all = saves.snapshots(for: r)
        XCTAssertEqual(all.map { $0.files[0].size }, [4, 3, 2, 1])                              // der neueste zuerst
        XCTAssertEqual(ContentStore.fileSize(saves.url(of: all[0].files[0], in: all[0], for: r)), 4)
        saves.prune(recipe: r, keep: 2)
        XCTAssertEqual(saves.snapshots(for: r).map { $0.files[0].size }, [4, 3])
        // Derselbe Ordner bleibt, auch wenn das Spiel später anders heißt oder aus dem Entwurf ein Rezept wird.
        XCTAssertEqual(saves.directory(for: recipe(id: "store-1654565391314903", title: "Demo – Remastered")).lastPathComponent,
                       "Demo The Game [1654565391314903]")
    }

    func testSavesLiveBesideAChosenDownloadsFolderAndMoveWithIt() throws {
        let base = temp(), disk = temp()
        // Ohne gewählten Ordner: bei den Daten des Programms. Mit einem: daneben, nicht darin.
        XCTAssertEqual(SaveStore.root(forStore: StoreLocation.standard(base: base), base: base).path, base.appendingPathComponent("saves").path)
        let chosen = disk.appendingPathComponent("AVP Play/AVP Play Downloads")
        let beside = SaveStore.root(forStore: chosen, base: base)
        XCTAssertEqual(beside.path, disk.appendingPathComponent("AVP Play/AVP Play Saved Games").standardizedFileURL.path)

        let fm = FileManager.default
        let old = base.appendingPathComponent("saves")
        for (game, snapshot) in [("Moss [1]", "2026-10-11 17.42.43"), ("Moss [1]", "2026-10-11 18.00.00"), ("Doom 3 [doom3quest]", "2026-10-11 17.45.00")] {
            let folder = old.appendingPathComponent(game).appendingPathComponent(snapshot)
            try fm.createDirectory(at: folder.appendingPathComponent("files"), withIntermediateDirectories: true)
            try Data(snapshot.utf8).write(to: folder.appendingPathComponent("manifest.json"))
        }
        // Am Ziel liegt schon ein Stand gleichen Namens: der bleibt, und der alte bleibt am alten Ort.
        let taken = beside.appendingPathComponent("Moss [1]/2026-10-11 18.00.00")
        try fm.createDirectory(at: taken, withIntermediateDirectories: true)
        try Data("newer".utf8).write(to: taken.appendingPathComponent("manifest.json"))

        XCTAssertEqual(SaveStore.move(from: old, to: beside), 2)
        XCTAssertEqual(try String(contentsOf: beside.appendingPathComponent("Moss [1]/2026-10-11 17.42.43/manifest.json"), encoding: .utf8), "2026-10-11 17.42.43")
        XCTAssertEqual(try String(contentsOf: taken.appendingPathComponent("manifest.json"), encoding: .utf8), "newer")
        XCTAssertTrue(fm.fileExists(atPath: beside.appendingPathComponent("Doom 3 [doom3quest]/2026-10-11 17.45.00/files").path))
        XCTAssertFalse(fm.fileExists(atPath: old.appendingPathComponent("Doom 3 [doom3quest]").path))            // leer geworden: weg
        XCTAssertTrue(fm.fileExists(atPath: old.appendingPathComponent("Moss [1]/2026-10-11 18.00.00").path))     // nicht überschrieben: noch da
        XCTAssertEqual(SaveStore.move(from: old, to: beside), 0)
        XCTAssertEqual(SaveStore.move(from: beside, to: beside), 0)
    }

    // MARK: Gerät

    func testTheConnectionAndFileDatesAreRead() throws {
        func device(_ transport: String) -> String {
            #"{"result":{"devices":[{"hardwareProperties":{"platform":"visionOS","reality":"physical","udid":"U1"},"connectionProperties":{"tunnelState":"connected","pairingState":"paired"\#(transport)},"deviceProperties":{"name":"VP","osVersionNumber":"27.2","developerModeStatus":"enabled"}}]}}"#
        }
        // Wie devicectl es am 2026-10-11 schrieb: "wired" am Developer Strap, "localNetwork" im WLAN.
        XCTAssertEqual(try DeviceControl.parseDevices(Data(device(#","transportType":"wired""#).utf8)).first?.transport, .cable)
        XCTAssertEqual(try DeviceControl.parseDevices(Data(device(#","transportType":"localNetwork""#).utf8)).first?.transport, .wifi)
        XCTAssertEqual(try DeviceControl.parseDevices(Data(device(#","transportType":"carrierPigeon""#).utf8)).first?.transport, .other("carrierPigeon"))
        XCTAssertNil(try DeviceControl.parseDevices(Data(device("").utf8)).first?.transport)
        let files = #"{"result":{"files":[{"metadata":{"lastModDate":"2026-10-08T20:42:01.000Z","size":1518},"name":"SaveGlobal.sav","relativePath":"SaveGlobal.sav","resources":{"isDirectory":false}}]}}"#
        let parsed = try DeviceControl.parseFiles(Data(files.utf8))
        XCTAssertEqual(parsed.first?.modified, ISO8601DateFormatter().date(from: "2026-10-08T20:42:01Z"))
    }

    // MARK: Katalog, Aufträge

    func testManyIdentifiersAreAskedInSeveralRequests() {
        let ids = (0..<230).map { String(1_000_000 + $0) }
        let batches = CatalogClient.batches(of: ids + ["not-an-id", "12"])
        XCTAssertEqual(batches.map(\.count), [100, 100, 30])
        XCTAssertEqual(batches.flatMap { $0 }, ids)                                             // keine fehlt, keine doppelt
        XCTAssertTrue(CatalogClient.batches(of: []).isEmpty)
    }

    func testAJobLeavesTheListWithItsLog() throws {
        let store = JobStore(directory: temp())
        let job = Job(recipe: recipe(appId: "123"), request: InstallRequest(toolchain: "/t"), toolchainCommit: "abc")
        try store.save(job)
        try Data("log".utf8).write(to: store.directory.appendingPathComponent("\(job.id).log"))
        XCTAssertEqual(store.all().map(\.id), [job.id])
        store.remove("../" + job.id)                                                            // kein Name eines Auftrags: nichts passiert
        XCTAssertEqual(store.all().count, 1)
        store.remove(job.id)
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), [])
    }

    // MARK: Verzeichnis und Liste

    func testTheIndexNamesEveryFolderAndIsOnlyRewrittenWhenItChanges() throws {
        let root = temp()
        let entries = [StoreIndex.Entry(folder: "store-24882487241367228-526346", title: "Alien: Rogue Incursion", detail: "Version 526346", bytes: 12_310_000_000),
                       StoreIndex.Entry(folder: "moss-151047", title: "Moss", detail: "Version 1.0.3", bytes: 2_670_000_000)]
        let before = L10n.language
        defer { L10n.language = before }
        L10n.language = .en
        let text = StoreIndex.text(entries.reversed())
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains { $0.hasPrefix("Alien: Rogue Incursion  store-24882487241367228-526346  Version 526346  12.31 GB") }, text)
        XCTAssertTrue(lines.contains { $0.hasPrefix("Moss                    moss-151047                     Version 1.0.3   2.67 GB") }, text)
        XCTAssertTrue(StoreIndex.write(root: root, entries: entries))
        XCTAssertFalse(StoreIndex.write(root: root, entries: entries.reversed()))                // dasselbe: nicht neu geschrieben
        XCTAssertTrue(StoreIndex.write(root: root, entries: Array(entries.prefix(1))))
        XCTAssertEqual(StoreIndex.fileSafe("Assassin\u{2019}s Creed\u{00AE}: Nexus/VR. "), "Assassin\u{2019}s Creed\u{00AE} Nexus VR")
        XCTAssertEqual(StoreIndex.fileSafe(" /: "), "Game")
    }

    func testTheGameListSaysWhatSomeoneHasAndNothingElse() {
        let before = L10n.language
        defer { L10n.language = before }
        L10n.language = .en
        let moss = GameList.Entry(title: "Moss", storeId: "1654565391314903", version: "1.0.3", label: "verified", downloaded: true, installed: true)
        let alyx = GameList.Entry(title: "Half-Life: Alyx", storeId: "", version: "25487405", label: "verified", downloaded: true, installed: nil)
        let text = GameList.text(downloaded: [moss, alyx], owned: [moss], favourites: [], appVersion: "1.1.1", toolchain: "281", made: "11 Oct 2026")
        XCTAssertTrue(text.contains("## Downloaded to this Mac (2)"))
        XCTAssertTrue(text.contains("Half-Life: Alyx\t–\t25487405\tverified\tyes\tunknown\nMoss\t1654565391314903\t1.0.3\tverified\tyes\tyes"), text)
        XCTAssertTrue(text.contains("## Favourites (0)\n\nNo favourites."))
        XCTAssertTrue(text.contains("AVP Play 1.1.1, toolchain 281"))
        // Aus der Übersicht: genau eine Liste, benannt nach dem, was gezeigt wird.
        let shown = GameList.text(title: "Games shown: installed, favourites", entries: [moss], appVersion: "1.1.1", toolchain: "", made: "11 Oct 2026")
        XCTAssertTrue(shown.contains("## Games shown: installed, favourites (1)"))
        XCTAssertTrue(shown.contains("Moss\t1654565391314903"))
        XCTAssertFalse(shown.contains("Downloaded to this Mac"))
    }
}

final class WithheldStatusTests: XCTestCase {
    func testAFileMetaWithholdsIsNotMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ContentStore(root: root)
        let apk = RecipeFile(name: "game.apk", role: "apk", id: "1", size: 4, sha256: nil, required: true, dest: "")
        let bought = RecipeFile(name: "pakchunk4.pak", role: "content-bundle", id: "2", size: nil, sha256: nil, required: true, dest: "android-files/obb")
        let notBought = RecipeFile(name: "pakchunk5.pak", role: "content-bundle", id: "3", size: nil, sha256: nil, required: true, dest: "android-files/obb")
        let r = Recipe(schema: 1, id: "demo", title: "Demo", package: "com.example.demo", versionName: "1.0", versionCode: 7,
                       store: .init(appId: "123456"), toolchain: .init(target: "demo", minCommit: "abc"), files: [apk, bought, notBought],
                       addons: nil, status: .init(playability: "verified", download: "listed", notes: nil), icon: nil)
        try FileManager.default.createDirectory(at: store.directory(for: r), withIntermediateDirectories: true)
        try Data(count: 4).write(to: store.url(for: apk, in: r))
        try Data(count: 9).write(to: store.url(for: bought, in: r))
        var status = GameStatus.of(recipe: r, store: store, apps: nil, toolchainVersion: nil)
        XCTAssertEqual([status.filesPresent, status.filesRequired, status.filesToDownload], [2, 3, 1])
        XCTAssertFalse(status.stockComplete)
        // Meta hat die dritte Datei für dieses Konto abgelehnt: Sie gehört nicht mehr zu dem, was fehlt.
        try store.noteWithheld(notBought, in: r)
        status = GameStatus.of(recipe: r, store: store, apps: nil, toolchainVersion: nil)
        XCTAssertEqual([status.filesPresent, status.filesRequired, status.filesToDownload], [2, 2, 0])
        XCTAssertTrue(status.stockComplete)
    }
}
