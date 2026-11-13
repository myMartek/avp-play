import XCTest
@testable import AVPPlayCore

/// Mods of a game's own toolchain: what a toolchain has to bring for the "Mods" box, what its fetch script says and
/// how that is shown, and how the built sets are remembered.
final class GameModsTests: XCTestCase {
    func temp() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-mods-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    static let modsJSON = """
    {"schema": 1, "about": {"en": "From your own account.", "de": "Über dein eigenes Konto."},
     "source": {"name": "Nexus Mods", "account": "https://example.invalid/register", "key": {"variable": "NEXUS_API_KEY", "page": "https://example.invalid/keys", "premiumOnly": true}},
     "sets": [{"id": "core", "title": {"en": "Hands", "de": "Hände"}, "default": false, "macRun": true, "downloadBytes": 9000000, "entries": ["higgs"],
               "mods": [{"name": "HIGGS", "version": "1.10.10", "about": "grab"}]},
              {"id": "skyland", "title": "Textures", "downloadBytes": 2632276741}]}
    """

    func toolchain(gen: String = "KLEPTON_GAME_MODS\n", description: String? = GameModsTests.modsJSON, fetch: String? = "import sys\n") throws -> Toolchain {
        let root = temp()
        let v = root.appendingPathComponent("visionos")
        try FileManager.default.createDirectory(at: v, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: v.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
        try gen.write(to: v.appendingPathComponent("gen_xcodeproj.py"), atomically: true, encoding: .utf8)
        if let description { try description.write(to: v.appendingPathComponent("mods.json"), atomically: true, encoding: .utf8) }
        if let fetch { try fetch.write(to: v.appendingPathComponent("mods_fetch.py"), atomically: true, encoding: .utf8) }
        return try Toolchain(root: root)
    }

    func testAToolchainOffersModsOnlyWithAllThreeParts() throws {
        let mods = try XCTUnwrap(try toolchain().gameMods())
        XCTAssertEqual(mods.sets.map(\.id), ["core", "skyland"])
        XCTAssertEqual(mods.source?.key?.variable, "NEXUS_API_KEY")
        XCTAssertEqual(mods.defaultSets, [], "nothing is on unless the description says so")
        XCTAssertEqual(mods.known(["skyland", "nope", "core"]), ["core", "skyland"], "unknown sets are left out, the order is the description's")
        XCTAssertNil(try toolchain(gen: "KLEPTON_EVA\n").gameMods(), "the variable is not named")
        XCTAssertNil(try toolchain(description: nil).gameMods())
        XCTAssertNil(try toolchain(fetch: nil).gameMods())
        XCTAssertNil(try toolchain(description: "{").gameMods())
        XCTAssertNil(try toolchain(description: #"{"schema": 2, "sets": [{"id": "a", "title": "A"}]}"#).gameMods(), "a newer schema is not guessed at")
        XCTAssertNil(try toolchain(description: #"{"schema": 1, "sets": [{"id": "a b", "title": "A"}]}"#).gameMods(), "an id goes into an environment variable")
        XCTAssertNil(try toolchain(description: #"{"schema": 1, "sets": [{"id": "a", "title": "A"}, {"id": "a", "title": "B"}]}"#).gameMods())
        // a toolchain cannot have its key handed over under a name that means something else to the build
        for bad in ["PATH", "KLEPTON_TEAM", "KL_LX_GAME", "nexus_key", "A B"] {
            XCTAssertNil(try toolchain(description: #"{"schema": 1, "source": {"name": "X", "key": {"variable": "\#(bad)"}}, "sets": [{"id": "a", "title": "A"}]}"#).gameMods(), bad)
        }
    }

    func testWhatTheFetchScriptSays() {
        XCTAssertEqual(GameModsFetch.event(in: "@@mods total|6"), .total(6))
        XCTAssertEqual(GameModsFetch.event(in: "@@mods have|HIGGS 1.10.10|from the Downloads folder"), .have(name: "HIGGS 1.10.10", how: "from the Downloads folder"))
        XCTAssertEqual(GameModsFetch.event(in: "@@mods need|VRIK|https://example.invalid/mods/1?tab=files&x=a|b"), .need(name: "VRIK", page: "https://example.invalid/mods/1?tab=files&x=a|b"))
        XCTAssertEqual(GameModsFetch.event(in: "@@mods done|6"), .done(6))
        XCTAssertNil(GameModsFetch.event(in: "nexus: downloaded x"))
        XCTAssertNil(GameModsFetch.event(in: "@@mods total|many"))
        XCTAssertNil(GameModsFetch.event(in: "@@mods need|VRIK"), "a page belongs to it")
        XCTAssertNil(GameModsFetch.event(in: "@@mods launch|x"))
        // what a script prints is shown to the player: one line, of a bounded length
        guard case .have(let name, _)? = GameModsFetch.event(in: "@@mods have|" + String(repeating: "x", count: 500) + "\u{1b}[31m|") else { return XCTFail() }
        XCTAssertEqual(name.count, 200)
        XCTAssertFalse(GameModsFetch.clean("a\u{1b}[31mb\u{7}").contains("\u{1b}"))
        XCTAssertNil(GameModsFetch.sentence(for: .total(0), source: "Nexus Mods", usesKey: false))
        XCTAssertTrue(GameModsFetch.sentence(for: .total(6), source: "Nexus Mods", usesKey: false)!.contains("Nexus Mods"))
        XCTAssertNotEqual(GameModsFetch.sentence(for: .total(6), source: "N", usesKey: false), GameModsFetch.sentence(for: .total(6), source: "N", usesKey: true))
        XCTAssertTrue(GameModsFetch.sentence(for: .need(name: "VRIK", page: "https://example.invalid/p"), source: "N", usesKey: false)!.contains("https://example.invalid/p"))
    }

    /// The script's lines reach the job log as sentences, the rest goes to the log file; the key is in the script's
    /// environment under the description's name and only when it is handed over.
    func testTheFetchStepRunsTheScriptWithTheSetsAndTheKey() throws {
        let script = """
        import os, sys
        print("@@mods total|2", flush=True)
        print("sets=" + os.environ.get("KLEPTON_GAME_MODS", "?") + " key=" + ("yes" if os.environ.get("NEXUS_API_KEY") == "KEY-1234567890abcdef" else os.environ.get("NEXUS_API_KEY", "none")), flush=True)
        print("@@mods have|HIGGS|kept from before", flush=True)
        if os.environ.get("FAIL") == "2":
            print("!! mods: VRIK was not downloaded within 15 minutes.", flush=True); sys.exit(2)
        if os.environ.get("FAIL") == "1":
            print("!! mods: fetching failed", flush=True); sys.exit(1)
        print("@@mods done|2", flush=True)
        """
        let t = try toolchain(fetch: script)
        let mods = try XCTUnwrap(t.gameMods())
        let log = temp().appendingPathComponent("mods.log")
        var said: [String] = []
        try t.fetchGameMods(sets: ["core", "skyland"], mods: mods, key: "KEY-1234567890abcdef", environment: ["NEXUS_API_KEY": "from-elsewhere"], log: log) { said.append($0) }
        XCTAssertEqual(said.count, 3, "\(said)")
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("sets=core,skyland key=yes"), text)
        said = []
        try t.fetchGameMods(sets: ["core"], mods: mods, key: nil, environment: ["NEXUS_API_KEY": "from-elsewhere"], log: log) { said.append($0) }
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("sets=core key=none"), "without the player's word no key reaches the script")
        XCTAssertThrowsError(try t.fetchGameMods(sets: ["core"], mods: mods, key: nil, environment: ["FAIL": "2"], log: log) { _ in }) { error in
            guard case GameModsError.notFetched(let hint, _) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(hint.contains("VRIK"))
            XCTAssertEqual(FailureKind.of(error), .download)
        }
        XCTAssertThrowsError(try t.fetchGameMods(sets: ["core"], mods: mods, key: nil, environment: ["FAIL": "1"], log: log) { _ in }) { error in
            guard case GameModsError.fetchFailed = error else { return XCTFail("\(error)") }
        }
    }

    func testAKeyIsOneLineOfKeyCharacters() {
        XCTAssertTrue(ModsKeyStore.isPlausible("abcDEF0123456789+/=_-.xyz"))
        XCTAssertFalse(ModsKeyStore.isPlausible("short"))
        XCTAssertFalse(ModsKeyStore.isPlausible("abcdefghijklmnop qrst"), "a blank would end the keychain command")
        XCTAssertFalse(ModsKeyStore.isPlausible("abcdefghijklmnop\nqrst"))
        XCTAssertFalse(ModsKeyStore.isPlausible("abcdefghijklmnop\"qrst"))
        XCTAssertFalse(ModsKeyStore.isPlausible(String(repeating: "a", count: 600)))
        XCTAssertEqual(ModsKeyStore.account("NEXUS_API_KEY"), "nexus-api-key")
        XCTAssertNil(ModsKeyStore.account("PATH"))
        XCTAssertNil(ModsKeyStore().read(variable: "not a variable"))
    }
}
