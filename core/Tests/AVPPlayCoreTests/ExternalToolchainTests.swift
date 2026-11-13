import XCTest
@testable import AVPPlayCore

/// A game's own toolchain, fetched from the repository its recipe names.
final class ExternalToolchainTests: XCTestCase {
    func temp() -> URL {
        // No blank in the path: a toolchain of this kind refuses one.
        let url = URL(fileURLWithPath: "/tmp/avpplay-external-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    static let commit = "0123456789abcdef0123456789abcdef01234567"

    func recipe(source: ToolchainSource?, kind: String? = "vxruntime", minCommit: String = "0123456") -> Recipe {
        Recipe(schema: 1, id: "skyrimvr", title: "Skyrim VR", package: "steam-app-611670", versionName: "Steam-Build 7", versionCode: 7,
               store: .init(appId: nil), toolchain: .init(target: "skyrimvr", minCommit: minCommit, kind: kind, source: source), files: [],
               addons: nil, status: .init(playability: "untested", download: "special", notes: nil), icon: nil)
    }

    func source(_ commit: String = ExternalToolchainTests.commit, path: String? = "tools/avpplay_toolchain") -> ToolchainSource {
        ToolchainSource(repository: "https://github.com/someone/Some-Game.Port", commit: commit, version: 410, path: path)
    }

    func testOnlyAPlainGitHubAddressAndAFullCommitAreTaken() {
        XCTAssertTrue(source().isSane)
        XCTAssertTrue(source(path: nil).isSane)
        var s = source()
        for bad in ["http://github.com/a/b", "https://gitlab.com/a/b", "https://github.com/a", "https://github.com/a/b/c", "https://github.com/a/b.git",
                    "https://github.com/a/b?x=1", "https://github.com/a/..", "https://github.com/a b/c", "https://github.com/a/b --upload-pack=x"] {
            s.repository = bad
            XCTAssertFalse(s.isSane, bad)
        }
        s = source()
        for bad in ["0123456", String(Self.commit.dropLast()), Self.commit.uppercased(), String(Self.commit.dropLast()) + "g", "main"] {
            s.commit = bad
            XCTAssertFalse(s.isSane, bad)
        }
        s = source()
        for bad in ["", "/abs", "a/../b", "a//b", "a b", "-x/..", "."] {
            s.path = bad
            XCTAssertFalse(s.isSane, bad)
        }
        s = source()
        for bad in [0, -1, 1_000_000_000] {
            s.version = bad
            XCTAssertFalse(s.isSane, "\(bad)")
        }
    }

    func testARecipeNamesItsToolchainOnlyWithItsKindAndTheSameCommit() throws {
        XCTAssertNoThrow(try recipe(source: source()).validate())
        XCTAssertNoThrow(try recipe(source: nil).validate())
        XCTAssertThrowsError(try recipe(source: source(), kind: nil).validate())
        XCTAssertThrowsError(try recipe(source: source(), minCommit: "7654321").validate())
        XCTAssertThrowsError(try recipe(source: source(), minCommit: "").validate())
        XCTAssertThrowsError(try recipe(source: nil, kind: "klepton").validate())
        XCTAssertThrowsError(try recipe(source: nil, kind: "VX Runtime").validate())
        var bad = source()
        bad.repository = "https://example.com/a/b"
        XCTAssertThrowsError(try recipe(source: bad).validate())

        // The recipe round-trips with the new fields, and one without them reads as before.
        let data = try JSONEncoder().encode(recipe(source: source()))
        let back = try JSONDecoder().decode(Recipe.self, from: data)
        XCTAssertEqual(back.toolchain.kind, "vxruntime")
        XCTAssertEqual(back.toolchain.source, source())
        let plain = try JSONDecoder().decode(Recipe.self, from: JSONEncoder().encode(recipe(source: nil, kind: nil)))
        XCTAssertNil(plain.toolchain.kind)
        XCTAssertNil(plain.toolchain.source)
    }

    func testTheRecipesToolchainCountsWhereNothingElseIsChosen() {
        let external = ExternalToolchains(root: URL(fileURLWithPath: "/tmp/x/toolchains"))
        let special = recipe(source: source())
        var choices = ToolchainChoices()
        let pin = choices.pin(for: special, external: external)
        XCTAssertEqual(pin, ToolchainChoices.Pin(version: 410, commit: "0123456", path: "/tmp/x/toolchains/vxruntime-410-0123456/tools/avpplay_toolchain"))
        XCTAssertTrue(choices.usesRecipeToolchain(special))
        // What the user chose wins, and then nothing is fetched behind their back.
        let own = ToolchainChoices.Pin(version: 3, commit: "abcdef0", modified: true, path: "/somewhere")
        choices.choose(own, for: "skyrimvr")
        XCTAssertEqual(choices.pin(for: special, external: external), own)
        XCTAssertFalse(choices.usesRecipeToolchain(special))
        // A game without a toolchain of its own has no such choice.
        XCTAssertNil(ToolchainChoices().pin(for: recipe(source: nil, kind: nil), external: external))
        XCTAssertNil(ToolchainChoices().pin(for: recipe(source: nil), external: external))
    }

    /// Fetching: exactly the named commit, described from the recipe, found again by the choice the recipe makes.
    func testFetchTakesExactlyTheNamedCommitAndDescribesIt() throws {
        try XCTSkipUnless(DeveloperTools.present)
        let dir = temp()
        let origin = dir.appendingPathComponent("origin", isDirectory: true)
        let inside = origin.appendingPathComponent("tools/avpplay_toolchain/visionos", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try "#!/bin/sh\necho one\n".write(to: inside.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
        // What the repository says about itself is not what counts.
        try "{\"format\":1,\"version\":9999,\"commit\":\"fffffff\",\"ancestors\":[],\"created\":\"2026-01-01T00:00:00Z\"}"
            .write(to: origin.appendingPathComponent("tools/avpplay_toolchain/toolchain.json"), atomically: true, encoding: .utf8)
        func git(_ arguments: [String]) throws -> String {
            try Toolchain.capture(["/usr/bin/git", "-C", origin.path, "-c", "user.name=t", "-c", "user.email=t@example.invalid",
                                   "-c", "commit.gpgsign=false"] + arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "--quiet"])
        _ = try git(["add", "-A"])
        _ = try git(["commit", "--quiet", "-m", "one"])
        let first = try git(["rev-parse", "HEAD"])
        XCTAssertEqual(first.count, 40)

        let external = ExternalToolchains(root: dir.appendingPathComponent("toolchains", isDirectory: true))
        let special = recipe(source: source(first), minCommit: String(first.prefix(7)))
        XCTAssertNil(external.installed(for: special))
        var said: [String] = []
        let fetched = try external.fetch(for: special, from: { _ in origin.path }, report: { said.append($0) })
        XCTAssertEqual(fetched.root.standardizedFileURL.path, external.directory(for: special)?.standardizedFileURL.path)
        XCTAssertEqual(fetched.kind, "vxruntime")
        XCTAssertEqual(fetched.version(), 410)
        XCTAssertEqual(fetched.commit(), String(first.prefix(7)))
        XCTAssertTrue(fetched.builds(special))
        XCTAssertTrue(fetched.satisfies(minCommit: special.toolchain.minCommit))
        XCTAssertFalse(fetched.isModified)
        XCTAssertEqual(said.count, 2)
        XCTAssertNotNil(external.installed(for: special))

        // The choice the recipe makes finds it, through the same door as a working copy someone chose.
        let pin = try XCTUnwrap(ToolchainChoices().pin(for: special, external: external))
        let packager = ToolchainPackager(root: dir.appendingPathComponent("packages"))
        XCTAssertEqual(packager.toolchain(for: pin)?.root.standardizedFileURL.path, fetched.root.standardizedFileURL.path)

        // Fetching again changes nothing and asks nobody.
        said = []
        _ = try external.fetch(for: special, from: { _ in "/nonexistent" }, report: { said.append($0) })
        XCTAssertTrue(said.isEmpty)

        // A folder that is no toolchain is refused and leaves nothing behind.
        var elsewhere = source(first)
        elsewhere.path = "tools"
        elsewhere.version = 411
        let wrong = recipe(source: elsewhere, minCommit: String(first.prefix(7)))
        XCTAssertThrowsError(try external.fetch(for: wrong, from: { _ in origin.path }))
        XCTAssertNil(external.installed(for: wrong))
        let left = try FileManager.default.contentsOfDirectory(atPath: external.root.path)
        XCTAssertEqual(left, ["vxruntime-410-\(first.prefix(7))"])

        // A commit the repository does not have: an error, nothing installed.
        let missing = recipe(source: source(Self.commit), minCommit: "0123456")
        XCTAssertThrowsError(try external.fetch(for: missing, from: { _ in origin.path }))
        XCTAssertNil(external.installed(for: missing))
    }

    func testAFolderWithABlankIsRefusedBeforeAnythingIsFetched() {
        let external = ExternalToolchains(root: URL(fileURLWithPath: "/tmp/avpplay external \(UUID().uuidString)/toolchains"))
        XCTAssertThrowsError(try external.fetch(for: recipe(source: source()), from: { _ in "/nonexistent" })) { error in
            guard case ExternalToolchainError.blankInPath = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.root.path))
    }
}
