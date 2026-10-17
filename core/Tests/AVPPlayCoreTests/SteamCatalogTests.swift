import XCTest
@testable import AVPPlayCore

/// Steht für den Katalogdienst: beantwortet jede Anfrage mit dem, was `answer` dazu sagt, und merkt sich die
/// Anfragen samt Inhalt. Es geht nichts ins Netz.
final class CatalogStub: URLProtocol {
    struct Seen { let method: String; let path: String; let query: String?; let body: Data? }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _answer: (Seen) -> (Int, String) = { _ in (404, "") }
    nonisolated(unsafe) private static var _seen: [Seen] = []

    static var answer: (Seen) -> (Int, String) {
        get { lock.withLock { _answer } }
        set { lock.withLock { _answer = newValue; _seen = [] } }
    }
    static var seen: [Seen] { lock.withLock { _seen } }

    static func client() -> CatalogClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogStub.self]
        return CatalogClient(base: URL(string: "https://catalog.test")!, session: URLSession(configuration: config))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            body = data
        }
        let url = request.url!
        let seen = Seen(method: request.httpMethod ?? "GET", path: url.path, query: URLComponents(url: url, resolvingAgainstBaseURL: false)?.query, body: body)
        let (status, text) = CatalogStub.lock.withLock { () -> (Int, String) in
            CatalogStub._seen.append(seen)
            return CatalogStub._answer(seen)
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class SteamCatalogTests: XCTestCase {
    /// So schickt der Dienst einen Eintrag der Steam-Liste (Go, `Game` als JSON).
    static let moss = #"{"appId":"846470","title":"Moss","package":"com.polyarc.MossGame","status":"verified","noteEn":"Runs.","noteDe":"Läuft.","metaAppId":"1654565391314903","target":"moss","works":3,"problems":1,"fails":0}"#
    static let spt = #"{"appId":"418650","title":"Space Pirate Trainer","package":"","status":"untested","verifiedPending":true,"mixedReality":true,"works":0,"problems":0,"fails":0}"#

    func testIdentifiersAndServiceKey() {
        for good in ["846470", "1", "4294967295"] { XCTAssertTrue(SteamCatalogGame.isIdentifier(good), good) }
        for bad in ["", "0", "0846470", "12345678901", "84647a", "steam-846470", " 846470", "８４６"] {
            XCTAssertFalse(SteamCatalogGame.isIdentifier(bad), bad)
        }
        XCTAssertEqual(SteamCatalogGame.serviceKey(steamAppId: "846470"), "steam-846470")
        XCTAssertNil(SteamCatalogGame.serviceKey(steamAppId: "steam-846470"))
        XCTAssertNil(SteamCatalogGame.serviceKey(steamAppId: ""))
    }

    func testDecodesWhatTheServiceSends() throws {
        let moss = try JSONDecoder().decode(SteamCatalogGame.self, from: Data(Self.moss.utf8))
        XCTAssertTrue(moss.isSane)
        XCTAssertEqual(moss.id, "846470")
        XCTAssertEqual(moss.metaAppId, "1654565391314903")
        XCTAssertEqual(moss.works, 3)
        let before = L10n.language
        defer { L10n.language = before }
        L10n.language = .de
        XCTAssertEqual(moss.note, "Läuft.")
        let spt = try JSONDecoder().decode(SteamCatalogGame.self, from: Data(Self.spt.utf8))
        XCTAssertTrue(spt.isSane)
        XCTAssertEqual(spt.verifiedPending, true)
        XCTAssertEqual(spt.mixedReality, true)
        XCTAssertNil(spt.note)

        var bad = moss
        bad.appId = "0123"
        XCTAssertFalse(bad.isSane)
        bad = moss
        bad.title = "Moss\u{0}"
        XCTAssertFalse(bad.isSane)
        bad = moss
        bad.metaAppId = "not a number"
        XCTAssertFalse(bad.isSane)
        bad = moss
        bad.target = "moss; rm"
        XCTAssertFalse(bad.isSane)
    }

    func testSteamGamesAsksByIdentifierInBatches() async throws {
        CatalogStub.answer = { seen in
            // The service answers only for what it was asked, and sends one entry nobody asked for and one broken one.
            (200, #"{"games":[\#(SteamCatalogTests.moss),\#(SteamCatalogTests.spt),{"appId":"0","title":"bad","status":"untested","works":0,"problems":0,"fails":0}],"page":0,"more":false,"total":2}"#)
        }
        let client = CatalogStub.client()
        let games = try await client.steamGames(appIds: ["846470", "steam-418650", "0123", "999"])
        XCTAssertEqual(games.map(\.appId), ["846470"], "only sane entries that were asked for")
        XCTAssertEqual(CatalogStub.seen.count, 1)
        XCTAssertEqual(CatalogStub.seen.first?.path, "/api/v1/steam")
        XCTAssertEqual(CatalogStub.seen.first?.query, "ids=846470,999")

        CatalogStub.answer = { _ in (200, #"{"games":[]}"#) }
        let many = (1...250).map { String(100_000 + $0) }
        _ = try await client.steamGames(appIds: many)
        XCTAssertEqual(CatalogStub.seen.count, 3)
        XCTAssertEqual(CatalogStub.seen.map { $0.query?.split(separator: ",").count ?? 0 }, [100, 100, 50])

        CatalogStub.answer = { _ in (200, "") }
        let none = try await client.steamGames(appIds: ["", "x"])
        XCTAssertTrue(none.isEmpty)
        XCTAssertTrue(CatalogStub.seen.isEmpty, "nothing to ask, nothing asked")

        // A service from before the Steam list.
        CatalogStub.answer = { _ in (404, "404 page not found") }
        do {
            _ = try await client.steamGames(appIds: ["846470"])
            XCTFail("expected an error")
        } catch let error as CatalogError {
            XCTAssertEqual(error, .refused(404))
        }
        CatalogStub.answer = { _ in (200, "not json") }
        do {
            _ = try await client.steamGames(appIds: ["846470"])
            XCTFail("expected an error")
        } catch let error as CatalogError {
            XCTAssertEqual(error, .unexpected)
        }
    }

    func testSteamCatalogPages() async throws {
        CatalogStub.answer = { _ in
            (200, #"{"games":[\#(SteamCatalogTests.moss),\#(SteamCatalogTests.spt),{"appId":"x","title":"bad","status":"untested","works":0,"problems":0,"fails":0}],"page":1,"more":true,"total":125}"#)
        }
        let client = CatalogStub.client()
        let page = try await client.steamCatalog(query: "  moss ", page: 1)
        XCTAssertEqual(page.games.map(\.appId), ["846470", "418650"])
        XCTAssertTrue(page.more)
        XCTAssertEqual(page.total, 125)
        XCTAssertEqual(CatalogStub.seen.first?.path, "/api/v1/steam")
        XCTAssertEqual(CatalogStub.seen.first?.query, "page=1&q=moss")
        _ = try await client.steamCatalog(page: -3)
        XCTAssertEqual(CatalogStub.seen.last?.query, "page=0")
        CatalogStub.answer = { _ in (404, "404 page not found") }
        do {
            _ = try await client.steamCatalog()
            XCTFail("expected an error")
        } catch let error as CatalogError {
            XCTAssertEqual(error, .refused(404))
        }
    }

    func testSteamGame() async throws {
        CatalogStub.answer = { seen in seen.path == "/api/v1/steam/846470" ? (200, SteamCatalogTests.moss) : (404, #"{"error":"unknown game"}"#) }
        let client = CatalogStub.client()
        let moss = try await client.steamGame(appId: "846470")
        XCTAssertEqual(moss.title, "Moss")
        do {
            _ = try await client.steamGame(appId: "418650")
            XCTFail("expected an error")
        } catch let error as CatalogError {
            XCTAssertEqual(error, .refused(404))
        }
        // Not a Steam app ID: nothing is asked.
        CatalogStub.answer = { _ in (200, SteamCatalogTests.moss) }
        do {
            _ = try await client.steamGame(appId: "../846470")
            XCTFail("expected an error")
        } catch let error as CatalogError {
            XCTAssertEqual(error, .unexpected)
        }
        XCTAssertTrue(CatalogStub.seen.isEmpty)
        // An answer about another game is not taken.
        CatalogStub.answer = { _ in (200, SteamCatalogTests.spt) }
        do {
            _ = try await client.steamGame(appId: "846470")
            XCTFail("expected an error")
        } catch let error as CatalogError {
            XCTAssertEqual(error, .unexpected)
        }
    }

    func sent(_ seen: CatalogStub.Seen) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: seen.body ?? Data())) as? [String: Any] ?? [:]
    }

    func testSteamFeedbackGoesToTheSteamListAndFallsBackForAnOldService() async throws {
        let feedback = CatalogFeedback(appId: "", versionCode: 117010, result: .problems, comment: "  stutters  ", appVersion: "1.2.2", toolchain: "604", lang: "de")
        let client = CatalogStub.client()

        // A service with the Steam list takes it at once.
        CatalogStub.answer = { _ in (202, #"{"status":"received"}"#) }
        try await client.sendSteam(feedback, steamAppId: "846470", metaAppId: "1654565391314903")
        XCTAssertEqual(CatalogStub.seen.count, 1)
        XCTAssertEqual(CatalogStub.seen[0].path, "/api/v1/feedback")
        XCTAssertEqual(sent(CatalogStub.seen[0])["appId"] as? String, "steam-846470")
        XCTAssertEqual(sent(CatalogStub.seen[0])["comment"] as? String, "stutters")
        XCTAssertNil(sent(CatalogStub.seen[0])["store"], "no field an older service would refuse")

        // One from before refuses the identifier: the report goes to the Meta page, marked, as before.
        CatalogStub.answer = { seen in
            (self.sent(seen)["appId"] as? String)?.hasPrefix("steam-") == true ? (400, #"{"error":"not an app identifier"}"#) : (202, #"{"status":"received"}"#)
        }
        try await client.sendSteam(feedback, steamAppId: "846470", metaAppId: "1654565391314903")
        XCTAssertEqual(CatalogStub.seen.count, 2)
        XCTAssertEqual(sent(CatalogStub.seen[1])["appId"] as? String, "1654565391314903")
        XCTAssertEqual(sent(CatalogStub.seen[1])["comment"] as? String, "[Steam] stutters")
        let empty = CatalogFeedback(appId: "", versionCode: 1, result: .works, comment: "", appVersion: "1.2.2", toolchain: "604", lang: "de")
        try await client.sendSteam(empty, steamAppId: "846470", metaAppId: "1654565391314903")
        XCTAssertEqual(sent(CatalogStub.seen[3])["comment"] as? String, "[Steam]", "what the old app sent without a comment")
        let long = CatalogFeedback(appId: "", versionCode: 1, result: .works, comment: String(repeating: "x", count: 1000), appVersion: "1.2.2", toolchain: "604", lang: "de")
        try await client.sendSteam(long, steamAppId: "846470", metaAppId: "1654565391314903")
        XCTAssertEqual((sent(CatalogStub.seen[5])["comment"] as? String)?.count, 1000, "the mark must not push it over the limit")

        // Without a Meta page there is nowhere else to go.
        do {
            try await client.sendSteam(feedback, steamAppId: "418650", metaAppId: nil)
            XCTFail("expected an error")
        } catch let error as CatalogError {
            XCTAssertEqual(error, .refused(400))
        }
        // Other refusals are not retried.
        CatalogStub.answer = { _ in (429, #"{"error":"too many reports"}"#) }
        do {
            try await client.sendSteam(feedback, steamAppId: "846470", metaAppId: "1654565391314903")
            XCTFail("expected an error")
        } catch let error as CatalogError {
            XCTAssertEqual(error, .refused(429))
        }
        XCTAssertEqual(CatalogStub.seen.count, 1)
        // Not a Steam app ID: nothing is sent.
        CatalogStub.answer = { _ in (202, "") }
        do {
            try await client.sendSteam(feedback, steamAppId: "steam-846470", metaAppId: "1654565391314903")
            XCTFail("expected an error")
        } catch let error as CatalogError {
            XCTAssertEqual(error, .unexpected)
        }
        XCTAssertTrue(CatalogStub.seen.isEmpty)
    }
}
