import XCTest
@testable import AVPPlayCore

/// Wenn Meta oder Steam nicht antworten, gilt ihre letzte Antwort; offline werden sie gar nicht erst gefragt.
final class OfflineInstallTests: XCTestCase {
    private var root: URL!
    private var store: ContentStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ContentStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func recipe(steam: Bool = false, name: String = "game.apk", id: String = "1234") -> Recipe {
        var recipe = try! JSONDecoder().decode(Recipe.self, from: Data("""
        {"schema":1,"id":"offlinetest","title":"Offline Test","package":"com.example.offline","versionName":"1.0","versionCode":7,
         "store":{\(steam ? "\"steamAppId\":\"555\"" : "\"appId\":\"999\"")},
         "toolchain":{"target":"offlinetest","minCommit":""},
         "status":{"playability":"ok","download":"ok"},
         "files":[{"id":"\(id)","name":"\(name)","role":"apk","dest":"","required":true}]}
        """.utf8))
        recipe.trees = nil
        return recipe
    }

    /// Ein Konto ohne Eintrag im Schlüsselbund: Die Frage bei Meta scheitert, ohne dass etwas ins Netz geht.
    private func installer(_ recipe: Recipe, offline: Bool? = true, lines: Lines = Lines()) -> Installer {
        var request = InstallRequest(toolchain: "/nonexistent")
        request.account = "offline-test-no-such-account"
        request.offline = offline
        var installer = Installer(recipe: recipe, request: request, store: store, report: { lines.add($0) })
        installer.sealOverride = mine
        return installer
    }

    /// Die Siegel dieses Testlaufs: dasselbe Geheimnis, derselbe Mac, dasselbe Konto.
    private var mine: OwnershipSeal.Bound { seal().bound(to: "meta:me") }

    private func seal(machine: String = "mac-1", secret: UInt8 = 7) -> OwnershipSeal {
        OwnershipSeal(directory: root.appendingPathComponent("seals", isDirectory: true), secret: Data(repeating: secret, count: 32), machine: machine)
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        func add(_ line: String) { lock.lock(); all.append(line); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return all.joined(separator: "\n") }
    }

    private func put(_ recipe: Recipe) throws {
        let file = recipe.files[0]
        let url = store.url(for: file, in: recipe)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("apk".utf8).write(to: url)
    }

    func testMetaThatCannotBeAskedFallsBackToTheSealedYes() async throws {
        mine.record(key: "999", owned: true)
        let lines = Lines()
        try await installer(recipe(), offline: false, lines: lines).checkAccount()
        XCTAssertTrue(lines.text.contains("last confirmed") || lines.text.contains("zuletzt bestätigte"), lines.text)
    }

    func testASealedNoStaysANoWhenNobodyCanBeAsked() async throws {
        let r = recipe()
        mine.record(key: "999", owned: false)
        for offline in [false, true] {
            do {
                try await installer(r, offline: offline).checkAccount()
                XCTFail("ein Nein bleibt ein Nein")
            } catch { XCTAssertEqual(error as? InstallError, .notOwned(r.title)) }
        }
    }

    /// Wer Spiele weitergibt, gibt auch `ownership.json`, `library.json` und die Kaufliste weiter. Sie zählen nicht.
    func testCopiedPlainAnswersCountForNothing() async throws {
        let r = recipe()
        OwnershipCache(store: store).record(appId: "999", owned: true)
        try MetaLibraryCache(store: store).save(MetaLibrary(checked: Date(), apps: [LibraryApp(appId: "999", title: "Offline Test")]))
        try put(r)
        for offline in [false, true] {
            do {
                try await installer(r, offline: offline).checkAccount()
                XCTFail("ohne Siegel geht es nicht weiter")
            } catch {
                XCTAssertEqual(error as? InstallError, .notConfirmedHere(r.title, store: "Meta"))
                XCTAssertEqual(FailureKind.of(error), .signIn)
            }
        }
    }

    func testPurchasesComeFromTheSealAndNotFromTheCopiedFile() throws {
        var r = recipe()
        r.addons = try JSONDecoder().decode(Addons.self, from: Data(#"{"kind":"purchase-list","dest":"android-files"}"#.utf8))
        try PurchaseRecord(appId: "999", skus: ["copied"], verified: Date()).save(store: store, recipe: r)
        XCTAssertNil(installer(r).confirmedPurchases(), "die Datei im Spielordner gilt nicht")
        mine.record(key: "999", owned: true, skus: ["dlc1", "dlc2"])
        XCTAssertEqual(installer(r).confirmedPurchases()?.skus, ["dlc1", "dlc2"])
    }

    /// Eine neue Fassung liegt in einem neuen Ordner. Ihre Zusatzinhalte kommen trotzdem, auch wenn Meta nicht antwortet.
    func testANewVersionKeepsItsPurchasesWhenMetaIsDown() async throws {
        var r = recipe()
        r.addons = try JSONDecoder().decode(Addons.self, from: Data(#"{"kind":"purchase-list","dest":"android-files"}"#.utf8))
        mine.record(key: "999", owned: true, skus: ["dlc1"])
        var newer = r
        newer.versionCode = 8
        XCTAssertNil(PurchaseRecord.load(store: store, recipe: newer))
        try await installer(newer, offline: false).checkAccount()
        XCTAssertEqual(PurchaseRecord.load(store: store, recipe: newer)?.skus, ["dlc1"], "für die Anzeige der neuen Fassung")
    }

    func testASealOpensOnlyOnThisMacWithThisAccount() {
        mine.record(key: "999", owned: true, skus: ["dlc"])
        XCTAssertEqual(mine.read(key: "999")?.skus, ["dlc"])
        XCTAssertNil(seal(machine: "mac-2").bound(to: "meta:me").read(key: "999"), "anderer Mac")
        XCTAssertNil(seal().bound(to: "meta:someone").read(key: "999"), "anderes Konto")
        XCTAssertNil(seal(secret: 8).bound(to: "meta:me").read(key: "999"), "anderer Schlüsselbund")
        XCTAssertNil(mine.read(key: "1000"), "anderes Spiel")
    }

    /// Auch wenn die Datei unter den Namen kommt, den das fremde Konto erwartet, lässt sie sich dort nicht öffnen.
    func testACopiedSealFileIsUselessUnderAnyName() throws {
        mine.record(key: "999", owned: true)
        let folder = root.appendingPathComponent("other-mac", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let other = OwnershipSeal(directory: folder, secret: Data(repeating: 7, count: 32), machine: "mac-2").bound(to: "meta:me")
        try FileManager.default.copyItem(at: mine.file("999"), to: other.file("999"))
        XCTAssertEqual(mine.file("999").lastPathComponent, other.file("999").lastPathComponent, "der Name hängt nicht am Mac")
        XCTAssertNil(other.read(key: "999"))
        // Ein Siegel für ein anderes Spiel lässt sich nicht umwidmen.
        mine.record(key: "1000", owned: true)
        try FileManager.default.removeItem(at: mine.file("999"))
        try FileManager.default.copyItem(at: mine.file("1000"), to: mine.file("999"))
        XCTAssertNil(mine.read(key: "999"))
    }

    func testATamperedSealIsRefused() throws {
        mine.record(key: "999", owned: false)
        var bytes = try Data(contentsOf: mine.file("999"))
        bytes[bytes.count / 2] ^= 1
        try bytes.write(to: mine.file("999"))
        XCTAssertNil(mine.read(key: "999"))
    }

    func testASealTellsNothingInPlainText() throws {
        mine.record(key: "999", owned: true, skus: ["walkabout_dlc"])
        let text = String(decoding: try Data(contentsOf: mine.file("999")), as: UTF8.self)
        XCTAssertFalse(text.contains("walkabout_dlc"))
        XCTAssertFalse(mine.file("999").lastPathComponent.contains("999"))
    }

    func testANewAnswerKeepsTheConfirmedPurchasesUnlessItNamesThem() {
        mine.record(key: "999", owned: true, skus: ["a"])
        mine.record(key: "999", owned: true)
        XCTAssertEqual(mine.read(key: "999")?.skus, ["a"])
        mine.record(key: "999", owned: true, skus: [])
        XCTAssertEqual(mine.read(key: "999")?.skus, [], "ein Rückkauf entfernt den Inhalt")
    }

    func testSteamAnswersAreKeptUnderTheirOwnKey() {
        let r = recipe(steam: true)
        mine.record(key: "555", owned: true)
        XCTAssertNil(installer(r).lastAnswer(), "eine Meta-Nummer gilt nicht für Steam")
        mine.record(key: "steam:555", owned: true)
        XCTAssertEqual(installer(r).lastAnswer()?.owned, true)
    }

    func testAFetchStartsOnlyAfterASealedYesAndNeverWithARejectedToken() {
        let yes = OwnershipSeal.Answer(owned: true), no = OwnershipSeal.Answer(owned: false)
        XCTAssertTrue(Installer.mayFetch(after: MetaError.transport("offline"), lastAnswer: yes))
        XCTAssertTrue(Installer.mayFetch(after: MetaError.api(status: 503, message: "down"), lastAnswer: yes))
        XCTAssertFalse(Installer.mayFetch(after: MetaError.transport("offline"), lastAnswer: no))
        XCTAssertFalse(Installer.mayFetch(after: MetaError.transport("offline"), lastAnswer: nil))
        XCTAssertFalse(Installer.mayFetch(after: MetaError.tokenRejected("expired"), lastAnswer: yes))
    }

    func testOfflineFetchNeedsEverythingOnThisMacAndAsksNobody() async throws {
        let r = recipe()
        do {
            try await installer(r).fetch()
            XCTFail("es fehlt eine Datei")
        } catch {
            XCTAssertEqual(error as? InstallError, .offlineFilesMissing(r.title, names: ["game.apk"]))
            XCTAssertEqual(FailureKind.of(error), .download)
        }
        try put(r)
        try await installer(r).fetch()
    }

    func testOfflineFollowsTheSettingUnlessTheRequestSaysSo() throws {
        let base = root.appendingPathComponent("base", isDirectory: true)
        XCTAssertFalse(InstallDefaults.offline(base: base))
        try InstallDefaults.setOffline(true, base: base)
        XCTAssertTrue(InstallDefaults.offline(base: base))
        try InstallDefaults.setRoomMeasuring(false, base: base)
        XCTAssertTrue(InstallDefaults.offline(base: base), "die anderen Vorgaben lassen sie stehen")
        try InstallDefaults.setOffline(false, base: base)
        XCTAssertFalse(InstallDefaults.offline(base: base))
        XCTAssertFalse(InstallDefaults.roomMeasuring(base: base))
    }

    func testOldJobsDecodeWithoutTheField() throws {
        let encoded = try JSONEncoder().encode(InstallRequest(toolchain: "/t"))
        XCTAssertNil(try JSONDecoder().decode(InstallRequest.self, from: encoded).offline)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("offline"))
    }

    // Wörtlich aus einem Lauf von SteamCMD ohne Netz (2026-10-31).
    private let noNetwork = """
    Logging in using cached credentials.
    Logging in user 'someone' [U:1:1] to Steam Public...Retrying...
    Retrying...
    Retrying...
    Retrying...
    ERROR (No Connection)
    Unloading Steam API...OK
    """

    func testSteamWithoutNetworkIsNoRejectedSignIn() {
        XCTAssertEqual(SteamRun.failure(noNetwork), .noConnection("ERROR (No Connection)"))
        XCTAssertFalse(SteamRun.storedLoginRejected(noNetwork), "die gemerkte Anmeldung darf nicht verworfen werden")
        XCTAssertEqual(FailureKind.of(SteamRun.failure(noNetwork)), .download)
        // Eine echte Absage bleibt eine.
        let rejected = "Logging in using cached credentials.\nLogging in user 'someone' to Steam Public...\nFAILED (Invalid Password)\n"
        XCTAssertEqual(SteamRun.failure(rejected), .notSignedIn("FAILED (Invalid Password)"))
        XCTAssertTrue(SteamRun.storedLoginRejected(rejected))
    }
}
