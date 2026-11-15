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

    // MARK: Spiele, deren Programm auf dem Mac gebaut wird

    /// Ein Rezeptordner mit einem Spiel, das hier gebaut wird, und einem aus dem Meta-Store.
    private func recipesWithABuiltGame(in folder: URL) throws -> URL {
        let recipes = folder.appendingPathComponent("recipes")
        try FileManager.default.createDirectory(at: recipes, withIntermediateDirectories: true)
        try """
        {"schema": 1, "id": "blockgame", "title": "Block Game", "package": "block-game", "versionName": "26.3", "versionCode": 260301,
         "store": {}, "toolchain": {"target": "blocktarget", "minCommit": ""},
         "builder": {"source": {"repository": "https://github.com/example/builder", "commit": "0123456789abcdef0123456789abcdef01234567", "version": 3},
                     "notes": [{"en": "Takes a while.", "de": "Dauert eine Weile."}]},
         "gameAccount": {"title": {"en": "You need an account", "de": "Du brauchst ein Konto"}, "notes": [{"en": "Sign in in the game.", "de": "Melde dich im Spiel an."}]},
         "files": [], "status": {"playability": "verified", "download": "special"}}
        """.write(to: recipes.appendingPathComponent("blockgame.json"), atomically: true, encoding: .utf8)
        try """
        {"schema": 1, "id": "meta", "title": "meta", "package": "com.example.meta", "versionName": "1.0", "versionCode": 7,
         "store": {"appId": "1234567890"}, "toolchain": {"target": "meta", "minCommit": ""},
         "files": [{"name": "game.apk", "role": "apk", "id": "12345", "required": true, "dest": "", "localName": "meta.apk"}],
         "status": {"playability": "verified", "download": "listed"}}
        """.write(to: recipes.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
        return recipes
    }

    /// Legt Spielteile in den Bestand, wie der Bau sie hinterlässt.
    private func buildParts(_ recipes: URL, store: ContentStore, bytes: Int = 5000) throws -> URL {
        let recipe = try RecipeStore(directory: recipes).load(url: recipes.appendingPathComponent("blockgame.json"))
        let made = store.root.appendingPathComponent("made.zip")
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try Data(repeating: 9, count: bytes).write(to: made)
        return try GameParts.adopt(made, sha256: try Hashing.sha256(of: made), recipe: recipe, store: store, local: GameParts.usesLocalBuilder(recipe))
    }

    func testABuiltGameIsListedWithTheStateOfItsParts() throws {
        let folder = try scratch()
        let recipes = try recipesWithABuiltGame(in: folder)
        let store = ContentStore(root: folder.appendingPathComponent("store"))

        // Nie gebaut: Das Spiel steht in der Liste, damit die Remote es sagen kann; mit geht nichts – auch nicht auf Wunsch.
        var built = CompanionHandover.builtGames(in: recipes, store: store, agreed: ["blockgame"])
        XCTAssertEqual(built.map(\.game.id), ["blockgame"], "only the game with a builder, not the Meta one")
        XCTAssertEqual(built[0].game.parts, .init(state: "missing", name: nil, size: nil, sha256: nil))
        XCTAssertNil(built[0].parts)
        XCTAssertEqual(built[0].game.target, "blocktarget")
        XCTAssertEqual(built[0].game.versionCode, 260301)
        XCTAssertEqual(built[0].game.account?.title["de"], "Du brauchst ein Konto")
        XCTAssertEqual(built[0].game.playability, "verified")
        XCTAssertEqual(CompanionHandover.partsOffers(in: recipes, store: store), [.init(id: "blockgame", title: "Block Game", bytes: nil)])

        // Gebaut, aber nicht zugestimmt: Der Stand geht mit, die Datei nicht.
        let zip = try buildParts(recipes, store: store)
        built = CompanionHandover.builtGames(in: recipes, store: store, agreed: [])
        XCTAssertEqual(built[0].game.parts.state, "built")
        XCTAssertEqual(built[0].game.parts.name, zip.lastPathComponent)
        XCTAssertEqual(built[0].game.parts.size, 5000)
        XCTAssertEqual(built[0].game.parts.sha256, try Hashing.sha256(of: zip))
        XCTAssertNil(built[0].parts, "nothing is copied without the user's yes")
        XCTAssertEqual(built[0].archive, zip)
        let offer = try XCTUnwrap(CompanionHandover.partsOffers(in: recipes, store: store).first)
        XCTAssertEqual(offer.bytes, 5000)
        XCTAssertEqual(offer.spaceOnHeadset, 5000 * 17 / 4 + (1 << 30))

        // Zugestimmt: Die Datei geht mit. Die Zustimmung für ein anderes Spiel zählt nicht.
        XCTAssertNil(CompanionHandover.builtGames(in: recipes, store: store, agreed: ["other"])[0].parts)
        built = CompanionHandover.builtGames(in: recipes, store: store, agreed: ["blockgame"])
        XCTAssertEqual(built[0].game.parts.state, "handedOver")
        XCTAssertEqual(built[0].parts, zip)
        XCTAssertEqual(built[0].bytes, 5000)
    }

    func testThePartsGoIntoTheirOwnFolderAndTheirNoteComesLast() throws {
        let folder = try scratch()
        let recipes = try recipesWithABuiltGame(in: folder)
        let store = ContentStore(root: folder.appendingPathComponent("store"))
        let zip = try buildParts(recipes, store: store)
        let macho = folder.appendingPathComponent("klepton-macho-blocktarget-900-abc1234.zip")
        try Data(repeating: 1, count: 300).write(to: macho)

        // Ohne Zustimmung: die Liste und die Vorlage, keine Spielteile.
        var inputs = CompanionHandover.Inputs(bundlePrefix: "user.dev.klepton.target")
        inputs.built = CompanionHandover.builtGames(in: recipes, store: store, agreed: [])
        inputs.machoTemplates = [macho]
        var items = try CompanionHandover.prepare(inputs, staging: folder.appendingPathComponent("staging-a"))
        XCTAssertEqual(items.map(\.destination), ["Documents/handover/handover.json", "Documents/handover/built-games.json",
                                                  "Documents/handover/klepton-macho-blocktarget-900-abc1234.zip"])
        struct Manifest: Decodable { var format: Int; var games: [CompanionHandover.BuiltGame] }
        var manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: items[1].source))
        XCTAssertEqual(manifest.format, 1)
        XCTAssertEqual(manifest.games.first?.parts.state, "built")

        // Mit Zustimmung: die Spielteile unter „Documents/parts/<Kennung>“, ihre Notiz danach.
        inputs.built = CompanionHandover.builtGames(in: recipes, store: store, agreed: ["blockgame"])
        items = try CompanionHandover.prepare(inputs, staging: folder.appendingPathComponent("staging-b"))
        XCTAssertEqual(items.map(\.destination), ["Documents/handover/handover.json", "Documents/handover/built-games.json",
                                                  "Documents/handover/klepton-macho-blocktarget-900-abc1234.zip",
                                                  "Documents/parts/blockgame/\(zip.lastPathComponent)", "Documents/parts/blockgame/parts.json"])
        XCTAssertFalse(items.contains(where: \.secret))
        manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: items[1].source))
        XCTAssertEqual(manifest.games.first?.parts.state, "handedOver")
        let note = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: items[4].source)) as? [String: Any])
        XCTAssertEqual(note["name"] as? String, zip.lastPathComponent)
        XCTAssertEqual(note["size"] as? Int, 5000)
        XCTAssertEqual(note["sha256"] as? String, try Hashing.sha256(of: zip))
        XCTAssertEqual(note["versionCode"] as? Int, 260301)
        // Der Satz fürs Protokoll nennt die Spielteile mit ihrer Größe, nicht die Notiz.
        let summary = CompanionHandover.summary(items)
        XCTAssertTrue(summary.contains("blockgame") && summary.contains("0 MB"), summary)
        XCTAssertFalse(summary.contains("parts.json"))

        // Was gleich groß schon auf der Brille liegt, wird nicht noch einmal kopiert – die Liste und die Notiz immer.
        var copied: [String] = [], asked: [String] = []
        try CompanionHandover.push(items, present: [RemoteFile(relativePath: "built-games.json", size: 1, isDirectory: false)],
                                   elsewhere: { folder in
                                       asked.append(folder)
                                       return [RemoteFile(relativePath: zip.lastPathComponent, size: 5000, isDirectory: false),
                                               RemoteFile(relativePath: "parts.json", size: Int64((try? Data(contentsOf: items[4].source).count) ?? 0), isDirectory: false)]
                                   }, copy: { _, destination in copied.append(destination) }, report: { _ in })
        XCTAssertEqual(asked, ["Documents/parts/blockgame"])
        XCTAssertEqual(copied, ["Documents/handover/handover.json", "Documents/handover/built-games.json",
                                "Documents/handover/klepton-macho-blocktarget-900-abc1234.zip", "Documents/parts/blockgame/parts.json"])
        // Liegt dort eine andere Größe (eine halbe Kopie, ältere Spielteile), wird kopiert.
        copied = []
        try CompanionHandover.push(items, present: [], elsewhere: { _ in [RemoteFile(relativePath: zip.lastPathComponent, size: 4999, isDirectory: false)] },
                                   copy: { _, destination in copied.append(destination) }, report: { _ in })
        XCTAssertTrue(copied.contains("Documents/parts/blockgame/\(zip.lastPathComponent)"))
        XCTAssertEqual(copied.last, "Documents/parts/blockgame/parts.json")
    }

    func testWhatIsSaidAboutBuiltGamesBeforeAnythingIsCopied() throws {
        let folder = try scratch()
        let recipes = try recipesWithABuiltGame(in: folder)
        let store = ContentStore(root: folder.appendingPathComponent("store"))
        var notes = CompanionHandover.builtNotes(CompanionHandover.builtGames(in: recipes, store: store, agreed: ["blockgame"]), templates: [])
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].contains("Block Game") && (notes[0].contains("not been built") || notes[0].contains("noch nicht gebaut")), notes[0])
        _ = try buildParts(recipes, store: store, bytes: 3 << 20)
        notes = CompanionHandover.builtNotes(CompanionHandover.builtGames(in: recipes, store: store, agreed: []), templates: [])
        XCTAssertTrue(notes[0].contains("3 MB") && (notes[0].contains("not handed over") || notes[0].contains("nicht übergeben")), notes[0])
        let macho = folder.appendingPathComponent("klepton-macho-blocktarget-900-abc1234.zip")
        let agreed = CompanionHandover.builtGames(in: recipes, store: store, agreed: ["blockgame"])
        notes = CompanionHandover.builtNotes(agreed, templates: [macho])
        XCTAssertTrue(notes[0].contains("3 MB") && (notes[0].contains("are copied") || notes[0].contains("werden auf die Vision Pro kopiert")), notes[0])
        XCTAssertFalse(notes[0].contains("runtime template") || notes[0].contains("Laufzeit-Vorlage"))
        // Ohne die Vorlage für dieses Spiel steht dabei, dass es sich auf der Brille noch nicht installieren lässt.
        notes = CompanionHandover.builtNotes(agreed, templates: [folder.appendingPathComponent("klepton-macho-other-900-abc1234.zip")])
        XCTAssertTrue(notes[0].contains("runtime template") || notes[0].contains("Laufzeit-Vorlage"), notes[0])
    }

    private static func stamp(_ toolchain: Toolchain) -> String { "\(toolchain.version())-\(toolchain.commit())" }

    /// Ein Ordner, der wie eine Toolchain aussieht und dessen Skript die Vorlagen „baut“: die einfache und die eines
    /// Spiels, dessen Programm auf dem Mac gebaut wird. Es hält fest, welche Spielteile ihm genannt wurden.
    private func toolchainThatBuildsTemplates(macho: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("handover-toolchain-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("visionos"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("visionos/run.sh"))
        try Data(#"{"version": 900, "commit": "abc1234", "files": 1}"#.utf8).write(to: root.appendingPathComponent("toolchain.json"))
        // Wie die Toolchain sich nennt, entscheidet `Toolchain`; das Skript schreibt die Archive unter diesem Namen.
        let stamp = Self.stamp(try Toolchain(root: root))
        var script = """
        #!/bin/bash
        cd "$(dirname "$0")"
        mkdir -p build
        echo run >> build/runs.txt
        printf '%s' "${KLEPTON_MACHO_IPA:-}" > build/archive.txt
        echo plain > build/klepton-template-\(stamp).zip

        """
        if macho { script += "echo macho > build/klepton-macho-blocktarget-\(stamp).zip\n" }
        try script.write(to: root.appendingPathComponent("visionos/mktemplate.sh"), atomically: true, encoding: .utf8)
        return root
    }

    func testTheTemplateOfABuiltGameComesWithThePlainOne() throws {
        let root = try toolchainThatBuildsTemplates(macho: true)
        let toolchain = try Toolchain(root: root)
        let cache = try scratch().appendingPathComponent("cache")
        let archive = try scratch().appendingPathComponent("parts.zip")
        try Data("x".utf8).write(to: archive)
        XCTAssertTrue(CompanionHandover.canBuildMachoTemplates(toolchain))
        func runs() -> Int { ((try? String(contentsOf: root.appendingPathComponent("visionos/build/runs.txt"), encoding: .utf8)) ?? "").split(separator: "\n").count }

        let plain = try XCTUnwrap(CompanionHandover.template(toolchain: toolchain, cache: cache, wantsMacho: true, gameArchive: archive, report: { _ in }))
        let stamp = Self.stamp(toolchain)
        XCTAssertEqual(plain.lastPathComponent, "klepton-template-\(stamp).zip")
        let macho = CompanionHandover.machoTemplates(toolchain: toolchain, cache: cache)
        XCTAssertEqual(macho.map(\.lastPathComponent), ["klepton-macho-blocktarget-\(stamp).zip"])
        XCTAssertEqual(CompanionHandover.machoTarget(macho[0], toolchain: toolchain), "blocktarget")
        XCTAssertNil(CompanionHandover.machoTarget(cache.appendingPathComponent("klepton-macho-blocktarget-1-\(stamp).zip.old"), toolchain: toolchain))
        XCTAssertNil(CompanionHandover.machoTarget(cache.appendingPathComponent("klepton-template-\(stamp).zip"), toolchain: toolchain))
        // Die Spielteile wurden dem Skript genannt (für das Icon des Spiels), unter dem Namen, den auch der Bau benutzt.
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("visionos/build/archive.txt"), encoding: .utf8), archive.standardizedFileURL.path)
        XCTAssertEqual(runs(), 1)
        // Beim nächsten Mal liegt alles im Zwischenspeicher: Es wird nicht noch einmal gebaut.
        _ = try CompanionHandover.template(toolchain: toolchain, cache: cache, wantsMacho: true, report: { _ in })
        XCTAssertEqual(runs(), 1)
        // Fehlt nur die Vorlage des Spiels (ein Zwischenspeicher von früher), wird sie nachgebaut – aber nur, wenn eine gebraucht wird.
        try FileManager.default.removeItem(at: macho[0])
        _ = try CompanionHandover.template(toolchain: toolchain, cache: cache, report: { _ in })
        XCTAssertEqual(runs(), 1)
        _ = try CompanionHandover.template(toolchain: toolchain, cache: cache, wantsMacho: true, report: { _ in })
        XCTAssertEqual(runs(), 2)
        XCTAssertEqual(CompanionHandover.machoTemplates(toolchain: toolchain, cache: cache).count, 1)
    }

    func testAToolchainWithoutSuchTemplatesIsNotBuiltAgainAndAgain() throws {
        let root = try toolchainThatBuildsTemplates(macho: false)
        let toolchain = try Toolchain(root: root)
        let cache = try scratch().appendingPathComponent("cache")
        XCTAssertFalse(CompanionHandover.canBuildMachoTemplates(toolchain))
        _ = try CompanionHandover.template(toolchain: toolchain, cache: cache, wantsMacho: true, report: { _ in })
        _ = try CompanionHandover.template(toolchain: toolchain, cache: cache, wantsMacho: true, report: { _ in })
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("visionos/build/runs.txt"), encoding: .utf8), "run\n")
        XCTAssertEqual(CompanionHandover.machoTemplates(toolchain: toolchain, cache: cache), [])
    }

    func testTheWholeHandoverCopiesPartsOnlyWithTheUsersYes() throws {
        let folder = try scratch()
        let recipes = try recipesWithABuiltGame(in: folder)
        let store = ContentStore(root: folder.appendingPathComponent("store"))
        let zip = try buildParts(recipes, store: store)
        let root = try toolchainThatBuildsTemplates(macho: true)
        let stamp = Self.stamp(try Toolchain(root: root))
        func deliver(_ plan: CompanionHandover.Plan, markers: [String] = [CompanionHandover.marker, CompanionHandover.builtMarker],
                     knows: Bool = false) throws -> (copied: [String], said: [String]) {
            var copied: [String] = [], said: [String] = []
            try CompanionHandover.deliver(plan, cache: folder.appendingPathComponent("cache"), knowsBuiltGames: knows, secrets: noSecrets,
                                          tokens: TokenStore(service: "avpplay-test-absent"),
                                          list: { $0 == "Documents" ? markers.map { RemoteFile(relativePath: $0, size: 20, isDirectory: false) } : [] },
                                          copy: { _, destination in copied.append(destination) }, report: { said.append($0) })
            return (copied, said)
        }
        // Wie die App den Plan bisher schrieb: ohne Bestand, ohne Zustimmung – von dem Spiel geht nichts mit.
        let old = try JSONDecoder().decode(CompanionHandover.Plan.self, from: Data(#"{"bundlePrefix": "user.dev.klepton.target", "withToken": false, "account": "default"}"#.utf8))
        XCTAssertNil(old.store)
        XCTAssertNil(old.parts)
        XCTAssertFalse(try deliver(old).copied.contains { $0.contains("parts") || $0.contains("built-games") })

        // Mit dem Bestand, ohne Zustimmung: Liste und Vorlage, keine Spielteile – und es steht da, wie groß sie wären.
        var plan = CompanionHandover.Plan(bundlePrefix: "user.dev.klepton.target", recipes: recipes, toolchain: root, store: store.root)
        var result = try deliver(plan)
        XCTAssertTrue(result.copied.contains("Documents/handover/built-games.json"))
        XCTAssertTrue(result.copied.contains("Documents/handover/klepton-macho-blocktarget-\(stamp).zip"))
        XCTAssertFalse(result.copied.contains { $0.hasPrefix("Documents/parts/") })
        XCTAssertTrue(result.said.contains { $0.contains("Block Game") && ($0.contains("not handed over") || $0.contains("nicht übergeben")) })

        // Mit Zustimmung: die Spielteile gehen mit, und das Protokoll nennt sie vor dem Kopieren.
        plan.parts = ["blockgame"]
        result = try deliver(plan)
        XCTAssertTrue(result.copied.contains("Documents/parts/blockgame/\(zip.lastPathComponent)"))
        XCTAssertEqual(result.copied.last, "Documents/parts/blockgame/parts.json")
        XCTAssertTrue(result.said.contains { $0.contains("Block Game") && ($0.contains("are copied") || $0.contains("kopiert")) })

        // Eine Remote, die solche Spiele nicht kennt (eine ältere), bekommt nichts davon – auch mit Zustimmung nicht:
        // Sie könnte die Spielteile weder nutzen noch entfernen. Das steht dann da.
        result = try deliver(plan, markers: [CompanionHandover.marker])
        XCTAssertFalse(result.copied.contains { $0.contains("parts") || $0.contains("built-") || $0.contains("klepton-macho-") }, "\(result.copied)")
        XCTAssertTrue(result.said.contains(CompanionHandover.builtNotTaken))
        // Hat AVP Play die Remote eben selbst aus einem Quellcode gebaut, der sie kennt, braucht es das Kennzeichen nicht.
        result = try deliver(plan, markers: [CompanionHandover.marker], knows: true)
        XCTAssertTrue(result.copied.contains("Documents/parts/blockgame/\(zip.lastPathComponent)"))
        XCTAssertFalse(CompanionHandover.takesBuiltGames([RemoteFile(relativePath: CompanionHandover.builtMarker, size: 0, isDirectory: false)]))
        XCTAssertFalse(CompanionHandover.takesBuiltGames([RemoteFile(relativePath: CompanionHandover.builtMarker, size: 9, isDirectory: true)]))
    }
}
