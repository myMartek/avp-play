import XCTest
@testable import AVPPlayCore

final class GameServerTests: XCTestCase {
    func recipe(servers: ServerListSupport? = .init(dest: "android-files/xash", file: "avpplay-servers.txt", defaultPort: 27015)) -> Recipe {
        var r = RecipeTests().recipe(files: [])
        r.servers = servers
        return r
    }

    func store() throws -> GameServerStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qi-servers-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return GameServerStore(directory: dir, service: "avpplay-server-test")
    }

    func testAnAddressIsBroughtIntoTheGamesSpelling() {
        XCTAssertEqual(GameServerStore.normalize(" Play.Example.org ", defaultPort: 27015), "play.example.org:27015")
        XCTAssertEqual(GameServerStore.normalize("203.0.113.7:27016", defaultPort: 27015), "203.0.113.7:27016")
        for bad in ["", "a b", "a:b", "a:0", "a:70000", "a:1:2", "-a", ".a", "a.", "http://a", "a/b", "a;rm", "ä.de", String(repeating: "a", count: 90)] {
            XCTAssertNil(GameServerStore.normalize(bad, defaultPort: 27015), bad)
        }
    }

    /// Das Passwort wird als ein Wort verschickt und geht als ein Wort durch `security -i`.
    func testAnAdminPasswordIsOneHarmlessWord() {
        for good in ["HelloPlanet", "a", "x-1_2.3!?#$%&*+=", String(repeating: "p", count: 64)] { XCTAssertTrue(GameServerStore.isUsablePassword(good), good) }
        for bad in ["", "two words", "tab\tbed", "quote\"d", "it's", "back\\slash", "zeile\n", "ümlaut", String(repeating: "p", count: 65)] {
            XCTAssertFalse(GameServerStore.isUsablePassword(bad), bad)
        }
    }

    func testTheListIsKeptPerGameAndWrittenForTheGame() throws {
        let store = try store()
        let r = recipe()
        XCTAssertTrue(store.load(recipe: r).isEmpty)
        XCTAssertEqual(try store.add(address: "152.53.113.187", name: " InSpaze ", recipe: r), GameServer(address: "152.53.113.187:27015", name: "InSpaze"))
        try store.add(address: "play.example.org:27016", name: "", recipe: r)
        // Dieselbe Adresse noch einmal ändert den Namen, statt sie doppelt zu führen.
        try store.add(address: "152.53.113.187:27015", name: "InSpaze 2\nzweite Zeile", recipe: r)
        XCTAssertEqual(store.load(recipe: r).map(\.name), ["InSpaze 2zweite Zeile", "play.example.org:27016"])
        XCTAssertThrowsError(try store.add(address: "kein server", name: "x", recipe: r))
        XCTAssertThrowsError(try store.add(address: "a.b", name: "x", recipe: recipe(servers: nil)))

        let secrets = ["152.53.113.187:27015": "geheim"]
        XCTAssertEqual(store.deviceFile(recipe: r) { secrets[$0] }, """
        # avpplay-servers v1
        server 152.53.113.187:27015 InSpaze 2zweite Zeile
        admin 152.53.113.187:27015 geheim
        server play.example.org:27016 play.example.org:27016

        """)
        // Was auf der Platte liegt, enthält kein Passwort.
        let onDisk = try String(contentsOf: store.url(for: r), encoding: .utf8)
        XCTAssertFalse(onDisk.contains("geheim"))
        XCTAssertEqual(GameServerStore.account(recipe: r, address: "152.53.113.187:27015"), "demo-152.53.113.187_27015")
    }

    /// Ein eingebauter Server steht bei jedem in der Liste, auch ohne eigenen Eintrag; der Nutzer ergänzt nur
    /// weitere Server oder sein Admin-Passwort.
    func testABuiltInServerIsAlwaysThere() throws {
        let store = try store()
        let r = recipe(servers: .init(dest: "android-files/xash", file: "avpplay-servers.txt", defaultPort: 27015,
                                      builtin: [GameServer(address: "152.53.113.187", name: "InSpaze")]))
        try r.validate()
        XCTAssertEqual(store.all(recipe: r), [GameServer(address: "152.53.113.187:27015", name: "InSpaze")])
        XCTAssertEqual(store.deviceFile(recipe: r) { _ in nil }, "# avpplay-servers v1\nserver 152.53.113.187:27015 InSpaze\n")
        // Ihn noch einmal einzutragen legt nichts doppelt an; das Admin-Passwort hängt an seiner Adresse.
        XCTAssertEqual(try store.add(address: "152.53.113.187:27015", name: "meiner", recipe: r).name, "InSpaze")
        XCTAssertTrue(store.load(recipe: r).isEmpty)
        try store.add(address: "play.example.org", name: "Zweiter", recipe: r)
        XCTAssertEqual(store.deviceFile(recipe: r) { $0.hasPrefix("152.") ? "geheim" : nil },
                       "# avpplay-servers v1\nserver 152.53.113.187:27015 InSpaze\nadmin 152.53.113.187:27015 geheim\nserver play.example.org:27015 Zweiter\n")
        // Ein eingebauter Server ohne Namen oder mit unbrauchbarer Adresse ist kein gültiges Rezept.
        for bad in [GameServer(address: "kein server", name: "x"), GameServer(address: "a.b", name: ""), GameServer(address: "a.b", name: "zwei\nZeilen")] {
            XCTAssertThrowsError(try recipe(servers: .init(dest: "a", file: "a.txt", defaultPort: nil, builtin: [bad])).validate(), "\(bad)")
        }
    }

    func testARecipeSaysWhereTheListGoes() throws {
        try recipe().validate()
        try recipe(servers: nil).validate()
        for bad in [ServerListSupport(dest: "../x", file: "a.txt", defaultPort: nil), ServerListSupport(dest: "a", file: "../a.txt", defaultPort: nil),
                    ServerListSupport(dest: "a", file: "", defaultPort: nil), ServerListSupport(dest: "a", file: "a.txt", defaultPort: 0)] as [ServerListSupport] {
            XCTAssertThrowsError(try recipe(servers: bad).validate(), "\(bad)")
        }
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
        let cs = try RecipeStore(directory: dir).load(id: "csvr")
        XCTAssertEqual(cs.servers?.dest, "android-files/xash")
        XCTAssertEqual(cs.servers?.file, "avpplay-servers.txt")
        XCTAssertEqual(GameServerStore.builtin(recipe: cs).map(\.name), ["InSpaze"])
        // Ein älteres Rezept ohne die Angabe wird weiter gelesen.
        XCTAssertNil(try RecipeStore(directory: dir).load(id: "doom3quest").servers)
    }
}
