import XCTest
@testable import AVPPlayCore

final class CompanionHandoverTests: XCTestCase {
    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("handover-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private let token = String(repeating: "A1b2", count: 12)

    func testOnlyTheFactsGoWithoutAnythingElse() throws {
        let staging = try scratch().appendingPathComponent("staging")
        let items = try CompanionHandover.prepare(.init(bundlePrefix: "user.dev.klepton.target"), staging: staging)
        XCTAssertEqual(items.map(\.name), ["handover.json"])
        XCTAssertEqual(items[0].destination, "Documents/handover/handover.json")
        let facts = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: items[0].source)) as? [String: Any])
        XCTAssertEqual(facts["bundlePrefix"] as? String, "user.dev.klepton.target")
        XCTAssertEqual(facts["pairingPort"] as? Int, 49152)
    }

    func testTheTokenGoesOnlyWhenGivenAndIsForThisUserOnly() throws {
        let folder = try scratch()
        let without = try CompanionHandover.prepare(.init(bundlePrefix: "user.dev.klepton.target"), staging: folder.appendingPathComponent("a"))
        XCTAssertFalse(without.contains { $0.name == "meta-token" })

        let staging = folder.appendingPathComponent("b")
        let with = try CompanionHandover.prepare(.init(bundlePrefix: "user.dev.klepton.target", token: token), staging: staging)
        let item = try XCTUnwrap(with.first { $0.name == "meta-token" })
        XCTAssertTrue(item.secret)
        XCTAssertEqual(try String(contentsOf: item.source, encoding: .utf8), token)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: item.source.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: staging.path)[.posixPermissions] as? Int, 0o700)
        // Nichts davon steht in dem Satz fürs Protokoll.
        XCTAssertFalse(CompanionHandover.summary(with).contains(token))

        let implausible = try CompanionHandover.prepare(.init(bundlePrefix: "user.dev.klepton.target", token: "short"),
                                                        staging: folder.appendingPathComponent("c"))
        XCTAssertFalse(implausible.contains { $0.name == "meta-token" })
    }

    func testFilesKeepTheNamesTheRemoteLooksFor() throws {
        let folder = try scratch()
        func file(_ name: String) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            return url
        }
        let key = CompanionHandover.AppleKey(keyId: "ABCDEFGH12", issuerId: "11111111-2222-4333-8444-555555555555", file: try file("AuthKey_ABCDEFGH12.p8"))
        let inputs = CompanionHandover.Inputs(bundlePrefix: "user.dev.klepton.target", pairingPort: 50000, token: token,
                                              library: try file("library.json"), template: try file("klepton-template-900-abc1234.zip"),
                                              pairing: try file("some-headset.plist"), appleKey: key)
        let items = try CompanionHandover.prepare(inputs, staging: folder.appendingPathComponent("staging"))
        XCTAssertEqual(items.map(\.name), ["handover.json", "meta-token", "library.json", "klepton-template-900-abc1234.zip",
                                           "pairing.plist", "asc.json", "asc-key.p8"])
        XCTAssertEqual(items.filter(\.secret).map(\.name), ["meta-token", "pairing.plist", "asc.json", "asc-key.p8"])
        let asc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: items[5].source)) as? [String: String])
        XCTAssertEqual(asc, ["keyID": "ABCDEFGH12", "issuerID": "11111111-2222-4333-8444-555555555555"])
        XCTAssertEqual(CompanionHandover.summary(items).contains("klepton-template"), false)
    }

    func testWhatCannotBeRightIsRefused() throws {
        let folder = try scratch()
        XCTAssertThrowsError(try CompanionHandover.prepare(.init(bundlePrefix: "not a prefix"), staging: folder.appendingPathComponent("a")))
        let missing = folder.appendingPathComponent("nowhere.zip")
        XCTAssertThrowsError(try CompanionHandover.prepare(.init(bundlePrefix: "user.dev.klepton.target", template: missing),
                                                           staging: folder.appendingPathComponent("b"))) {
            XCTAssertEqual($0 as? CompanionHandover.HandoverError, .missing("nowhere.zip"))
        }
        let key = CompanionHandover.AppleKey(keyId: "short", issuerId: "nope", file: missing)
        XCTAssertThrowsError(try CompanionHandover.prepare(.init(bundlePrefix: "user.dev.klepton.target", appleKey: key),
                                                           staging: folder.appendingPathComponent("c"))) {
            XCTAssertEqual($0 as? CompanionHandover.HandoverError, .badAppleKey)
        }
    }

    func testWhatIsThereAlreadyIsNotCopiedAgainExceptSecrets() throws {
        let folder = try scratch()
        let template = folder.appendingPathComponent("klepton-template-900-abc1234.zip")
        try Data(repeating: 7, count: 1000).write(to: template)
        let items = try CompanionHandover.prepare(.init(bundlePrefix: "user.dev.klepton.target", token: token, template: template),
                                                  staging: folder.appendingPathComponent("staging"))
        let present = [RemoteFile(relativePath: "klepton-template-900-abc1234.zip", size: 1000, isDirectory: false),
                       RemoteFile(relativePath: "meta-token", size: Int64(token.utf8.count), isDirectory: false)]
        var copied: [String] = []
        var said: [String] = []
        try CompanionHandover.push(items, present: present, copy: { _, destination in copied.append(destination) }, report: { said.append($0) })
        XCTAssertEqual(copied, ["Documents/handover/handover.json", "Documents/handover/meta-token"])
        XCTAssertEqual(said.count, 1)
    }

    func testAToolchainWithoutTheScriptBuildsNoTemplate() throws {
        let root = try scratch()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("visionos"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("visionos/run.sh"))
        guard let toolchain = try? Toolchain(root: root) else { return }   // wie streng `Toolchain` prüft, ist nicht Sache dieses Tests
        XCTAssertFalse(CompanionHandover.canBuildTemplate(toolchain))
        XCTAssertNil(try CompanionHandover.template(toolchain: toolchain, cache: root.appendingPathComponent("cache"), report: { _ in }))
    }

    func testTheRecipeListHoldsOnlyReadableMetaStoreGames() throws {
        let folder = try scratch()
        let recipes = folder.appendingPathComponent("recipes")
        try FileManager.default.createDirectory(at: recipes, withIntermediateDirectories: true)
        func recipe(_ id: String, store: String) -> String {
            """
            {"schema": 1, "id": "\(id)", "title": "\(id)", "package": "com.example.\(id)", "versionName": "1.0", "versionCode": 7,
             "store": {\(store)}, "toolchain": {"target": "\(id)", "minCommit": ""},
             "files": [{"name": "game.apk", "role": "apk", "id": "12345", "required": true, "dest": "", "localName": "\(id).apk"},
                       {"name": "de.lang", "role": "language-pack", "id": "12346", "required": false, "dest": "android-files/obb", "locale": "de"}],
             "addons": {"kind": "purchase-list", "dest": "android-files"},
             "status": {"playability": "verified", "download": "listed"}}
            """
        }
        try recipe("meta", store: "\"appId\": \"1234567890\"").write(to: recipes.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
        try recipe("steam", store: "\"steamAppId\": \"546560\"").write(to: recipes.appendingPathComponent("steam.json"), atomically: true, encoding: .utf8)
        try "{ not a recipe".write(to: recipes.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)

        let items = try CompanionHandover.prepare(.init(bundlePrefix: "user.dev.klepton.target", recipes: recipes),
                                                  staging: folder.appendingPathComponent("staging"))
        let item = try XCTUnwrap(items.first { $0.name == "recipes.json" })
        XCTAssertFalse(item.secret)
        let list = try JSONDecoder().decode([Recipe].self, from: Data(contentsOf: item.source))
        XCTAssertEqual(list.map(\.id), ["meta"])
        XCTAssertEqual(list[0].files.first { $0.locale == "de" }?.dest, "android-files/obb")
        XCTAssertEqual(list[0].addons?.kind, .purchaseList)

        // Ohne ein lesbares Rezept gibt es die Datei nicht.
        try FileManager.default.removeItem(at: recipes.appendingPathComponent("meta.json"))
        let none = try CompanionHandover.prepare(.init(bundlePrefix: "user.dev.klepton.target", recipes: recipes),
                                                 staging: folder.appendingPathComponent("staging2"))
        XCTAssertFalse(none.contains { $0.name == "recipes.json" })
    }

    // MARK: Die ganze Übergabe

    /// Ein Schlüsselbund, in dem nichts liegt: Die Tests fassen den echten nicht an.
    private var noSecrets: HandoverSecrets {
        HandoverSecrets(appleKeyService: "avpplay-test-absent-\(UUID().uuidString)")
    }

    func testNothingGoesToARemoteThatDoesNotTakeAHandover() throws {
        var copied: [String] = []
        let plan = CompanionHandover.Plan(bundlePrefix: "user.dev.klepton.target", withToken: true)
        XCTAssertThrowsError(try CompanionHandover.deliver(plan, cache: try scratch(), secrets: noSecrets,
                                                           tokens: TokenStore(service: "avpplay-test-absent"),
                                                           list: { _ in [RemoteFile(relativePath: "other.txt", size: 3, isDirectory: false)] },
                                                           copy: { _, destination in copied.append(destination) }, report: { _ in })) { error in
            XCTAssertEqual(error as? CompanionHandover.HandoverError, .notCapable)
        }
        XCTAssertEqual(copied, [])
        // Ein leeres Kennzeichen oder ein Ordner dieses Namens zählt nicht.
        XCTAssertFalse(CompanionHandover.accepts([RemoteFile(relativePath: CompanionHandover.marker, size: 0, isDirectory: false)]))
        XCTAssertFalse(CompanionHandover.accepts([RemoteFile(relativePath: CompanionHandover.marker, size: 9, isDirectory: true)]))
        XCTAssertTrue(CompanionHandover.accepts([RemoteFile(relativePath: CompanionHandover.marker, size: 9, isDirectory: false)]))
    }

    func testAHandoverWithoutSecretsSaysWhatDidNotGo() throws {
        var copied: [String] = []
        var said: [String] = []
        let plan = CompanionHandover.Plan(bundlePrefix: "user.dev.klepton.target", withToken: true)
        try CompanionHandover.deliver(plan, cache: try scratch(), secrets: noSecrets, tokens: TokenStore(service: "avpplay-test-absent"),
                                      list: { folder in
                                          folder == "Documents" ? [RemoteFile(relativePath: CompanionHandover.marker, size: 20, isDirectory: false)] : []
                                      },
                                      copy: { _, destination in copied.append(destination) }, report: { said.append($0) })
        XCTAssertEqual(copied, ["Documents/handover/handover.json"])
        let text = said.joined(separator: "\n")
        XCTAssertTrue(text.contains("handover.json"))
        // Token gewünscht, aber keiner da; kein Schlüssel, keine Vorlage: Das steht da.
        XCTAssertTrue(said.contains { $0.contains("Meta") })
        XCTAssertTrue(said.last?.contains("team key") == true || said.last?.contains("Team-Schlüssel") == true)
    }

    func testOnlyARealTeamKeyIsKept() throws {
        let pem = "-----BEGIN PRIVATE KEY-----\nMIGT\n-----END PRIVATE KEY-----\n"
        let issuer = "11111111-2222-4333-8444-555555555555"
        XCTAssertTrue(HandoverSecrets.AppleKey(keyId: "ABCDE12345", issuerId: issuer, pem: pem).isPlausible)
        XCTAssertFalse(HandoverSecrets.AppleKey(keyId: "ABCDE1234", issuerId: issuer, pem: pem).isPlausible)
        XCTAssertFalse(HandoverSecrets.AppleKey(keyId: "ABCDE12345", issuerId: "not-a-uuid", pem: pem).isPlausible)
        XCTAssertFalse(HandoverSecrets.AppleKey(keyId: "ABCDE12345", issuerId: issuer, pem: "hello").isPlausible)
        XCTAssertThrowsError(try noSecrets.setAppleKey(.init(keyId: "x", issuerId: issuer, pem: pem)))

    }
}
