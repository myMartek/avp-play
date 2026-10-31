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
        return Installer(recipe: recipe, request: request, store: store, report: { lines.add($0) })
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

    func testMetaThatCannotBeAskedFallsBackToTheLastYes() async throws {
        let r = recipe()
        OwnershipCache(store: store).record(appId: "999", owned: true)
        let lines = Lines()
        try await installer(r, offline: false, lines: lines).checkAccount()
        XCTAssertTrue(lines.text.contains("last confirmed") || lines.text.contains("zuletzt bestätigte"), lines.text)
    }

    func testALastNoStaysANoWhenNobodyCanBeAsked() async throws {
        let r = recipe()
        OwnershipCache(store: store).record(appId: "999", owned: false)
        do {
            try await installer(r, offline: false).checkAccount()
            XCTFail("ein Nein bleibt ein Nein")
        } catch { XCTAssertEqual(error as? InstallError, .notOwned(r.title)) }
        do {
            try await installer(r, offline: true).checkAccount()
            XCTFail("auch offline")
        } catch { XCTAssertEqual(error as? InstallError, .notOwned(r.title)) }
    }

    func testWithoutAnyAnswerTheAccountStepStillPasses() async throws {
        try await installer(recipe(), offline: false).checkAccount()
        try await installer(recipe(), offline: true).checkAccount()
    }

    func testTheLibraryCountsAsAnEarlierYes() throws {
        let r = recipe()
        try MetaLibraryCache(store: store).save(MetaLibrary(checked: Date(timeIntervalSince1970: 1000), apps: [LibraryApp(appId: "999", title: "Offline Test")]))
        XCTAssertEqual(installer(r).lastOwnership(), OwnershipRecord(owned: true, checked: Date(timeIntervalSince1970: 1000)))
        // Die eigene Antwort geht vor: Die Bibliothek führt auch Apps, die Meta einzeln nicht bestätigt.
        OwnershipCache(store: store).record(appId: "999", owned: false, checked: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(installer(r).lastOwnership()?.owned, false)
    }

    func testSteamAnswersAreKeptUnderTheirOwnKey() {
        let r = recipe(steam: true)
        OwnershipCache(store: store).record(appId: "555", owned: true)
        XCTAssertNil(installer(r).lastOwnership(), "eine Meta-Nummer gilt nicht für Steam")
        OwnershipCache(store: store).record(appId: "steam:555", owned: true)
        XCTAssertEqual(installer(r).lastOwnership()?.owned, true)
    }

    func testAFetchStartsOnlyAfterAnEarlierYesAndNeverWithARejectedToken() {
        let yes = OwnershipRecord(owned: true, checked: Date()), no = OwnershipRecord(owned: false, checked: Date())
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
