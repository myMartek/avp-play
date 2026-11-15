import XCTest
@testable import AVPPlayCore

/// A game whose parts are built on the user's Mac before the toolchain builds its app (Minecraft): the recipe that
/// names the builder, fetching it, running it, and what the installer makes of the result.
final class PartsBuilderTests: XCTestCase {
    func temp() -> URL {
        // No blank in the path: a builder refuses one for its working folder.
        let url = URL(fileURLWithPath: "/tmp/avpplay-parts-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    static let commit = "0123456789abcdef0123456789abcdef01234567"

    func source(_ commit: String = PartsBuilderTests.commit, version: Int = 3, path: String? = nil) -> ToolchainSource {
        ToolchainSource(repository: "https://github.com/someone/block-game-port", commit: commit, version: version, path: path)
    }

    func recipe(_ source: ToolchainSource? = nil, pictures: Recipe.ArchivePictures? = nil) -> Recipe {
        var r = Recipe(schema: 1, id: "blockgame", title: "Block Game", package: "block-game", versionName: "26.3", versionCode: 260301,
                       store: .init(appId: nil), toolchain: .init(target: "blockgame", minCommit: "0123456"), files: [],
                       addons: nil, status: .init(playability: "verified", download: "special", notes: nil), icon: nil)
        r.builder = PartsBuilder(source: source ?? self.source(), notes: [LocalizedText(en: "Takes an hour.", de: "Dauert eine Stunde.")])
        if let pictures { r.icon = .init(archive: pictures) }
        return r
    }

    /// A picture, as a PNG.
    func png(red: CGFloat, opaque: Bool = true) throws -> Data {
        try XCTUnwrap(AppIcon.layer(opaque: opaque) { ctx, rect in
            ctx.setFillColor(CGColor(srgbRed: red, green: 0.5, blue: 0.2, alpha: 1))
            ctx.fill(opaque ? rect : rect.insetBy(dx: 200, dy: 200))
        })
    }

    /// An archive shaped like the parts of a game: an app folder with a payload, two pictures among its files.
    func partsZip(in dir: URL) throws -> URL {
        let tree = dir.appendingPathComponent("zip-\(UUID().uuidString)", isDirectory: true)
        let objects = tree.appendingPathComponent("Payload/Game.app/klepton-payload/root/inst-1/assets/objects", isDirectory: true)
        try FileManager.default.createDirectory(at: objects.appendingPathComponent("aa"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: objects.appendingPathComponent("bb"), withIntermediateDirectories: true)
        try png(red: 0.2, opaque: false).write(to: objects.appendingPathComponent("aa/aa11"))
        try png(red: 0.9).write(to: objects.appendingPathComponent("bb/bb22"))
        try Data("payload".utf8).write(to: tree.appendingPathComponent("Payload/Game.app/klepton-payload/payload-version"))
        let zip = dir.appendingPathComponent("parts-\(UUID().uuidString).zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = ["-q", "-r", zip.path, "Payload"]
        p.currentDirectoryURL = tree
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return zip
    }

    /// A builder that obeys the contract: `--check`, stages, a result line – and, told to by a file beside it,
    /// fails in a step, names a wrong checksum, or hangs with a child of its own.
    func builder(in dir: URL, parts: URL) throws -> URL {
        let folder = dir.appendingPathComponent("builder-\(UUID().uuidString)", isDirectory: true)
        let tools = folder.appendingPathComponent("tools/avpplay", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: parts, to: folder.appendingPathComponent("parts.zip"))
        let script = """
        #!/bin/sh
        here="$(cd "$(dirname "$0")/../.." && pwd)"
        if [ "$1" = "--check" ]; then
          if [ -f "$here/problems.txt" ]; then cat "$here/problems.txt"; exit 1; fi
          exit 0
        fi
        mkdir -p "$AVPPLAY_WORK"
        echo run >> "$AVPPLAY_WORK/runs.txt"
        echo "STAGE 1/3 download"
        echo "fetching the client"
        echo "STAGE 2/3 native image"
        if [ -f "$here/fail.txt" ]; then echo "compiling"; echo "error: not enough memory for the image" >&2; exit 3; fi
        if [ -f "$here/hang.txt" ]; then sleep 300 & echo $! > "$AVPPLAY_WORK/child.pid"; wait; fi
        echo "STAGE 3/3 pack"
        cp "$here/parts.zip" "$AVPPLAY_OUT"
        if [ -f "$here/wrongsum.txt" ]; then echo "PARTS $AVPPLAY_OUT 0000000000000000000000000000000000000000000000000000000000000000"; exit 0; fi
        if [ -f "$here/silent.txt" ]; then echo "done"; exit 0; fi
        echo "PARTS $AVPPLAY_OUT $(/usr/bin/shasum -a 256 "$AVPPLAY_OUT" | cut -d' ' -f1)"
        """
        let entry = folder.appendingPathComponent(PartsBuilders.entry)
        try script.write(to: entry, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entry.path)
        return folder
    }

    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        private var stages: [InstallProgress.FileProgress] = []
        func say(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        func show(_ p: InstallProgress) { lock.lock(); if let f = p.file { stages.append(f) }; lock.unlock() }
        var said: [String] { lock.lock(); defer { lock.unlock() }; return lines }
        var shown: [InstallProgress.FileProgress] { lock.lock(); defer { lock.unlock() }; return stages }
    }

    // MARK: The recipe

    func testARecipeNamesItsBuilderSanelyOrIsRefused() throws {
        XCTAssertNoThrow(try recipe().validate())
        XCTAssertNoThrow(try recipe(source(path: "tools/parts")).validate())
        var r = recipe(ToolchainSource(repository: "https://example.org/a/b", commit: Self.commit, version: 1))
        XCTAssertThrowsError(try r.validate())
        r = recipe(source("0123456"))
        XCTAssertThrowsError(try r.validate(), "a short commit is not a pinned state")
        r = recipe()
        r.builder?.notes = []
        XCTAssertThrowsError(try r.validate(), "the user is told what the build asks of the Mac")
        r.builder?.notes = [LocalizedText("line\nbreak")]
        XCTAssertThrowsError(try r.validate())
        // The builder is a field of its own: the game is still built with the usual toolchain.
        XCTAssertNil(recipe().toolchain.kind)
        XCTAssertNil(ExternalToolchains(root: temp()).directory(for: recipe()))
    }

    func testPicturesInTheArchiveArePlainPathsAndNeedABuilder() throws {
        let fine = Recipe.ArchivePictures(icon: "assets/objects/aa/aa11", background: "assets/objects/bb/bb22")
        XCTAssertNoThrow(try recipe(pictures: fine).validate())
        for bad in ["", "/abs/path", "a/../b", "-x", "a/*.png", "a/b?c", "a/[b]", "a\\b"] {
            XCTAssertThrowsError(try recipe(pictures: .init(icon: bad)).validate(), bad)
            XCTAssertThrowsError(try recipe(pictures: .init(icon: "a/b", background: bad)).validate(), bad)
        }
        var r = recipe(pictures: fine)
        r.builder = nil
        XCTAssertThrowsError(try r.validate(), "there is no archive to take them from")
    }

    func testTheNoteOnTheGamesOwnAccountIsPlainText() throws {
        var r = recipe()
        r.gameAccount = .init(title: LocalizedText(en: "You need the game", de: "Du brauchst das Spiel"), notes: [LocalizedText(en: "Sign in there.", de: "Melde dich dort an.")])
        XCTAssertNoThrow(try r.validate())
        r.gameAccount?.notes = []
        XCTAssertThrowsError(try r.validate())
        r.gameAccount?.notes = Array(repeating: "x", count: 7)
        XCTAssertThrowsError(try r.validate())
        r.gameAccount = .init(title: LocalizedText(String(repeating: "x", count: 81)), notes: ["y"])
        XCTAssertThrowsError(try r.validate())
    }

    func testAGameOfBuiltPartsCarriesItsDataInItsApp() {
        XCTAssertTrue(recipe().carriesItsData)
        var r = recipe()
        r.files = [RecipeFile(name: "extra.pak", role: "data", id: "", size: 1, sha256: nil, required: false, dest: "data", localName: nil, locale: nil,
                              source: FileSource(kind: .user, url: nil, hint: nil, steam: nil, archive: nil))]
        XCTAssertFalse(r.carriesItsData, "something belongs into the app's data folder")
        r = recipe()
        r.builder = nil
        XCTAssertFalse(r.carriesItsData)
    }

    /// The recipe the project ships: it loads, names a builder and the usual toolchain, and says what the player needs
    /// in both languages.
    func testTheShippedMinecraftRecipe() throws {
        let recipes = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
        let r = try RecipeStore(directory: recipes).load(id: "vivecraft")
        XCTAssertEqual(r.toolchain.target, "vivecraft")
        XCTAssertNil(r.toolchain.kind, "built with Klepton, not with a toolchain of its own")
        let builder = try XCTUnwrap(r.builder)
        XCTAssertEqual(builder.source.repository, "https://github.com/myMartek/vivecraft-visionos")
        XCTAssertTrue(r.files.isEmpty, "nothing of the game is downloaded ready-made")
        XCTAssertTrue(r.carriesItsData)
        XCTAssertNil(r.source, "no store confirms ownership to AVP Play")
        let account = try XCTUnwrap(r.gameAccount)
        for text in [account.title] + account.notes + builder.notes + (r.status.notes ?? []) {
            XCTAssertNotNil(text.values["en"]); XCTAssertNotNil(text.values["de"])
        }
        XCTAssertTrue(account.notes.contains { $0.values["de"]?.contains("Bedrock") == true })
        XCTAssertTrue(builder.notes.contains { $0.values["en"]?.contains("16 GB") == true })
        XCTAssertNotNil(r.icon?.archive)
    }

    // MARK: Fetching the builder

    func testFetchTakesExactlyTheNamedCommit() throws {
        try XCTSkipUnless(DeveloperTools.present)
        let dir = temp()
        let origin = try builder(in: dir, parts: try partsZip(in: dir))
        func git(_ arguments: [String]) throws -> String {
            try Toolchain.capture(["/usr/bin/git", "-C", origin.path, "-c", "user.name=t", "-c", "user.email=t@example.invalid",
                                   "-c", "commit.gpgsign=false"] + arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "--quiet"])
        _ = try git(["add", "-A"])
        _ = try git(["commit", "--quiet", "-m", "one"])
        let first = try git(["rev-parse", "HEAD"])
        try "changed\n".write(to: origin.appendingPathComponent("later.txt"), atomically: true, encoding: .utf8)
        _ = try git(["add", "-A"])
        _ = try git(["commit", "--quiet", "-m", "two"])

        let builders = PartsBuilders(root: dir.appendingPathComponent("builders", isDirectory: true))
        let r = recipe(source(first))
        XCTAssertNil(builders.installed(for: r))
        var said: [String] = []
        let fetched = try builders.fetch(for: r, from: { _ in origin.path }, report: { said.append($0) })
        XCTAssertEqual(fetched.standardizedFileURL.path, builders.directory(for: r)?.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fetched.appendingPathComponent(PartsBuilders.entry).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fetched.appendingPathComponent("later.txt").path), "the pinned state, not the newest")
        XCTAssertEqual(said.count, 1)
        XCTAssertNotNil(builders.installed(for: r))
        // A second fetch finds it; another state of the builder is another folder.
        XCTAssertEqual(try builders.fetch(for: r, from: { _ in "/nowhere" }).path, fetched.path)
        XCTAssertNotEqual(builders.directory(for: recipe(source(first, version: 4)))?.path, fetched.path)
        // A commit the repository does not have is an error that says so, and leaves nothing half-fetched.
        XCTAssertThrowsError(try builders.fetch(for: recipe(source()), from: { _ in origin.path })) { error in
            guard case PartsError.fetchFailed = error else { return XCTFail("\(error)") }
        }
        XCTAssertNil(builders.installed(for: recipe(source())))
        // A repository without the entry point is no builder.
        try FileManager.default.removeItem(at: origin.appendingPathComponent(PartsBuilders.entry))
        _ = try git(["add", "-A"])
        _ = try git(["commit", "--quiet", "-m", "three"])
        let third = try git(["rev-parse", "HEAD"])
        XCTAssertThrowsError(try builders.fetch(for: recipe(source(third)), from: { _ in origin.path })) { error in
            guard case PartsError.notABuilder = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: Running it

    func testLinesOfTheContract() {
        XCTAssertEqual(PartsBuild.Stage.parse("STAGE 3/7 native image"), .init(index: 3, count: 7, name: "native image"))
        XCTAssertEqual(PartsBuild.Stage.parse("STAGE 1/1"), .init(index: 1, count: 1, name: ""))
        for other in ["STAGE", "STAGE 0/3 x", "STAGE 4/3 x", "STAGE a/b x", "stage 1/3 x", " STAGE 1/3 x", "STAGE 1/100 x", "compiling STAGE 1/3"] {
            XCTAssertNil(PartsBuild.Stage.parse(other), other)
        }
        let sum = String(repeating: "ab", count: 32)
        XCTAssertEqual(PartsBuild.parseResult("PARTS /tmp/out/a.zip \(sum)")?.path, "/tmp/out/a.zip")
        XCTAssertEqual(PartsBuild.parseResult("PARTS /Volumes/Disk/Application Support/a.zip \(sum.uppercased())")?.sha256, sum)
        XCTAssertEqual(PartsBuild.parseResult("PARTS /Volumes/Disk/Application Support/a.zip \(sum)")?.path, "/Volumes/Disk/Application Support/a.zip")
        for other in ["PARTS", "PARTS /tmp/a.zip", "PARTS relative.zip \(sum)", "PARTS /tmp/a.zip abc", "parts /tmp/a.zip \(sum)"] {
            XCTAssertNil(PartsBuild.parseResult(other), other)
        }
    }

    func testARunReportsItsStepsAndNamesWhatItBuilt() throws {
        let dir = temp()
        let zip = try partsZip(in: dir)
        let build = PartsBuild(builder: try builder(in: dir, parts: zip), work: dir.appendingPathComponent("work"))
        XCTAssertEqual(try build.check(), [])
        let seen = Collected()
        let out = dir.appendingPathComponent("out/result.zip"), log = dir.appendingPathComponent("logs/build.log")
        let result = try build.run(out: out, log: log) { seen.say("\($0.index)/\($0.count) \($0.name)") }
        XCTAssertEqual(seen.said, ["1/3 download", "2/3 native image", "3/3 pack"])
        XCTAssertEqual(result.sha256, try Hashing.sha256(of: zip))
        XCTAssertEqual(try Hashing.sha256(of: out), result.sha256)
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("fetching the client") && text.contains("STAGE 2/3") && text.contains("PARTS "), "everything it said is kept")
    }

    func testAFailedStepLeavesAReasonAndTheLog() throws {
        let dir = temp()
        let folder = try builder(in: dir, parts: try partsZip(in: dir))
        try Data().write(to: folder.appendingPathComponent("fail.txt"))
        let log = dir.appendingPathComponent("build.log")
        XCTAssertThrowsError(try PartsBuild(builder: folder, work: dir.appendingPathComponent("work")).run(out: dir.appendingPathComponent("o.zip"), log: log)) { error in
            XCTAssertEqual(error as? PartsError, .buildFailed(stage: "2/3 (native image)", reason: "error: not enough memory for the image", log: log))
            for language in [Language.en, .de] {
                L10n.language = language
                let text = "\(error)"
                XCTAssertTrue(text.contains("2/3 (native image)") && text.contains("not enough memory") && text.contains(log.path), text)
            }
            L10n.language = .en
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("o.zip").path))
    }

    func testAResultThatIsNotWhatWasNamedIsRefused() throws {
        let dir = temp()
        let zip = try partsZip(in: dir)
        for mark in ["wrongsum.txt", "silent.txt"] {
            let folder = try builder(in: dir, parts: zip)
            try Data().write(to: folder.appendingPathComponent(mark))
            XCTAssertThrowsError(try PartsBuild(builder: folder, work: dir.appendingPathComponent("work")).run(out: dir.appendingPathComponent("o.zip"), log: dir.appendingPathComponent("l.log")), mark) { error in
                guard case PartsError.badResult = error else { return XCTFail("\(error)") }
            }
        }
        // No builder there at all, and a working folder with a blank in its path.
        XCTAssertThrowsError(try PartsBuild(builder: dir.appendingPathComponent("none"), work: dir.appendingPathComponent("work")).check())
        let folder = try builder(in: dir, parts: zip)
        XCTAssertThrowsError(try PartsBuild(builder: folder, work: dir.appendingPathComponent("with blank/work")).check()) { error in
            guard case PartsError.blankInPath = error else { return XCTFail("\(error)") }
        }
    }

    func testTheCheckNamesWhatIsMissing() throws {
        let dir = temp()
        let folder = try builder(in: dir, parts: try partsZip(in: dir))
        try "This Mac has 8 GB of memory; 16 GB are needed.\nXcode is not installed.\n".write(to: folder.appendingPathComponent("problems.txt"), atomically: true, encoding: .utf8)
        let problems = try PartsBuild(builder: folder, work: dir.appendingPathComponent("work")).check()
        XCTAssertEqual(problems, ["This Mac has 8 GB of memory; 16 GB are needed.", "Xcode is not installed."])
        XCTAssertTrue("\(PartsError.prerequisites(problems))".contains("16 GB are needed"))
    }

    /// Cancelling ends the builder and what it started: nothing of the group is left running.
    func testCancellingEndsTheWholeGroup() throws {
        let dir = temp()
        let folder = try builder(in: dir, parts: try partsZip(in: dir))
        try Data().write(to: folder.appendingPathComponent("hang.txt"))
        let work = dir.appendingPathComponent("work")
        let stop = ProcessGroupStop(grace: 2)
        let ended = expectation(description: "the run ends")
        let outcome = Collected()
        Thread.detachNewThread {
            do {
                _ = try PartsBuild(builder: folder, work: work).run(out: dir.appendingPathComponent("o.zip"), log: dir.appendingPathComponent("l.log"), stop: stop)
                outcome.say("finished")
            } catch is CancellationError { outcome.say("cancelled") } catch { outcome.say("\(error)") }
            ended.fulfill()
        }
        let pidFile = work.appendingPathComponent("child.pid")
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: pidFile.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        Thread.sleep(forTimeInterval: 0.2)
        let child = try XCTUnwrap(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(child, 0), 0, "the builder's own child is running")
        stop.stop()
        wait(for: [ended], timeout: 15)
        XCTAssertEqual(outcome.said, ["cancelled"])
        let gone = Date().addingTimeInterval(5)
        while kill(child, 0) == 0, Date() < gone { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertNotEqual(kill(child, 0), 0, "and is gone with it")
    }

    // MARK: The installer

    func installer(_ r: Recipe, store: ContentStore, builders: PartsBuilders, local: URL?, seen: Collected, toolchain: String = "/nowhere",
                   offline: Bool = false) -> Installer {
        var request = InstallRequest(toolchain: toolchain)
        request.builder = local?.path
        request.offline = offline
        var installer = Installer(recipe: r, request: request, store: store, progress: { seen.show($0) }) { seen.say($0) }
        installer.builders = builders
        return installer
    }

    func testTheFetchStepBuildsThePartsIntoTheLibraryAndTheBuildIsToldWhere() async throws {
        let dir = temp()
        let zip = try partsZip(in: dir)
        let folder = try builder(in: dir, parts: zip)
        let store = ContentStore(root: dir.appendingPathComponent("store with blank", isDirectory: true))
        let builders = PartsBuilders(root: dir.appendingPathComponent("builders", isDirectory: true))
        let r = recipe()
        XCTAssertEqual(GameStatus.of(recipe: r, store: store, apps: nil, toolchainVersion: nil).parts, .missing)
        XCTAssertFalse(GameStatus.of(recipe: r, store: store, apps: nil, toolchainVersion: nil).stockComplete)

        let seen = Collected()
        let first = installer(r, store: store, builders: builders, local: folder, seen: seen)
        XCTAssertThrowsError(try first.partsEnvironment()) { XCTAssertEqual($0 as? PartsError, .notBuilt("Block Game")) }
        try await first.perform(.fetch)
        // The steps showed as steps, the user was told beforehand what the build asks, and the parts are in the library.
        XCTAssertEqual(seen.shown.map { "\($0.index)/\($0.count) \($0.name) \($0.isStage)" }, ["1/3 download true", "2/3 native image true", "3/3 pack true"])
        XCTAssertTrue(seen.said.contains("Takes an hour."))
        let parts = try XCTUnwrap(GameParts.built(recipe: r, store: store, local: true))
        XCTAssertEqual(parts.url.lastPathComponent, "blockgame-parts-local.zip")
        XCTAssertEqual(parts.record.sha256, try Hashing.sha256(of: zip))
        XCTAssertEqual(try first.partsEnvironment(), [Toolchain.gameArchiveVariable: parts.url.standardizedFileURL.path])
        XCTAssertTrue(parts.url.path.hasPrefix("/"), "an absolute path, as the toolchain asks")
        XCTAssertFalse(FileManager.default.fileExists(atPath: builders.outbox(for: r).appendingPathComponent(parts.url.lastPathComponent).path), "moved, not copied")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory(for: r).appendingPathComponent(".last-parts.log").path))

        // Nothing is copied to the device afterwards, and the device is not asked.
        let before = seen.said.count
        try await first.perform(.stage)
        XCTAssertEqual(seen.said.count, before + 1)
        XCTAssertTrue(seen.said.last?.contains("nothing to copy") == true)

        // A builder chosen by hand builds anew every time (it skips what is finished itself) …
        try await first.perform(.fetch)
        XCTAssertEqual(try String(contentsOf: builders.work(for: r).appendingPathComponent("runs.txt"), encoding: .utf8), "run\nrun\n")

        // … the one the recipe pins builds once per state, under a name of its own, and replaces what another left.
        let pinnedPlace = try XCTUnwrap(builders.directory(for: r))
        try FileManager.default.createDirectory(at: pinnedPlace.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: folder, to: pinnedPlace)
        try JSONEncoder().encode(["commit": Self.commit]).write(to: pinnedPlace.appendingPathComponent("x.json"))
        try Data("{\"commit\":\"\(Self.commit)\",\"version\":3}".utf8).write(to: pinnedPlace.appendingPathComponent(".avpplay-builder.json"))
        XCTAssertNotNil(builders.installed(for: r))
        let pinned = installer(r, store: store, builders: builders, local: nil, seen: seen)
        XCTAssertThrowsError(try pinned.partsEnvironment(), "parts of a hand-chosen builder are not the pinned builder's")
        try await pinned.perform(.fetch)
        let made = try XCTUnwrap(GameParts.built(recipe: r, store: store, local: false))
        XCTAssertEqual(made.url.lastPathComponent, "blockgame-parts-3-0123456.zip")
        XCTAssertNil(GameParts.built(recipe: r, store: store, local: true), "the other builder's parts are gone")
        try await pinned.perform(.fetch)
        XCTAssertEqual(try String(contentsOf: builders.work(for: r).appendingPathComponent("runs.txt"), encoding: .utf8), "run\nrun\nrun\n", "not built twice")
        XCTAssertTrue(seen.said.last?.contains("nothing to build") == true)
        if case .built(_, let bytes)? = GameParts.state(recipe: r, store: store) { XCTAssertEqual(bytes, ContentStore.fileSize(zip)) }
        else if !GameParts.usesLocalBuilder(r) { XCTFail("the page says they are built") }

        // A new state of the builder is not this file; a damaged file is none either.
        XCTAssertNil(GameParts.built(recipe: recipe(source(version: 4)), store: store, local: false))
        try Data("short".utf8).write(to: made.url)
        XCTAssertNil(GameParts.built(recipe: r, store: store, local: false))
    }

    func testOfflineAndProblemsStopBeforeAnythingIsBuilt() async throws {
        let dir = temp()
        let folder = try builder(in: dir, parts: try partsZip(in: dir))
        let store = ContentStore(root: dir.appendingPathComponent("store", isDirectory: true))
        let builders = PartsBuilders(root: dir.appendingPathComponent("builders", isDirectory: true))
        let seen = Collected()
        let offline = installer(recipe(), store: store, builders: builders, local: folder, seen: seen, offline: true)
        do { try await offline.perform(.fetch); XCTFail("offline") } catch { XCTAssertEqual(error as? PartsError, .offline("Block Game")) }
        try "Not enough free disk space.\n".write(to: folder.appendingPathComponent("problems.txt"), atomically: true, encoding: .utf8)
        let checked = installer(recipe(), store: store, builders: builders, local: folder, seen: seen)
        do { try await checked.perform(.fetch); XCTFail("problems") } catch { XCTAssertEqual(error as? PartsError, .prerequisites(["Not enough free disk space."])) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: builders.work(for: recipe()).appendingPathComponent("runs.txt").path))
    }

    /// The toolchain is prepared for such a game without an APK and without folders: only a picture for the start window.
    func testTheToolchainIsPreparedWithoutAnAPK() throws {
        let dir = temp()
        let root = dir.appendingPathComponent("toolchain", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("visionos"), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: root.appendingPathComponent("visionos/run.sh"), atomically: true, encoding: .utf8)
        let store = ContentStore(root: dir.appendingPathComponent("store", isDirectory: true))
        let toolchain = try Toolchain(root: root)
        XCTAssertNoThrow(try toolchain.prepare(recipe: recipe(), store: store))
        XCTAssertFalse(FileManager.default.fileExists(atPath: toolchain.iconDirectory(target: "blockgame").path), "the icon is left to the toolchain")
        var plain = recipe()
        plain.builder = nil
        XCTAssertThrowsError(try toolchain.prepare(recipe: plain, store: store))
        // The app a Mach-O guest is built into lies in the Release folder: found all the same.
        let app = root.appendingPathComponent("visionos/build/dd-device-blockgame/Build/Products/Release-xros/Game.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertEqual(toolchain.builtApps(recipe: recipe()).map(\.lastPathComponent), ["Game.app"])
    }

    // MARK: The picture

    func testThePictureOfTheGameComesOutOfItsOwnParts() throws {
        let dir = temp()
        let store = ContentStore(root: dir.appendingPathComponent("store", isDirectory: true))
        let r = recipe(pictures: .init(icon: "assets/objects/aa/aa11", background: "assets/objects/bb/bb22"))
        XCTAssertNil(ArchiveArt.hero(recipe: r, store: store), "no parts, no picture")
        XCTAssertNil(StartHero.choose(recipe: r, store: store))
        let zip = try partsZip(in: dir)
        XCTAssertNotNil(ArchiveArt.read("assets/objects/aa/aa11", from: zip))
        XCTAssertNil(ArchiveArt.read("assets/objects/aa/none", from: zip))
        XCTAssertNil(ArchiveArt.read("objects/aa/aa1", from: zip), "a whole path below a folder, not any ending")
        let copy = dir.appendingPathComponent("result.zip")
        try FileManager.default.copyItem(at: zip, to: copy)
        _ = try GameParts.adopt(copy, sha256: try Hashing.sha256(of: zip), recipe: r, store: store, local: false)
        let hero = try XCTUnwrap(ArchiveArt.hero(recipe: r, store: store))
        let image = try XCTUnwrap(AppIcon.image(hero))
        XCTAssertEqual([image.width, image.height], [1920, 1080])
        XCTAssertEqual(try Data(contentsOf: ArchiveArt.heroURL(store: store, recipe: r)), hero, "kept beside the parts")
        XCTAssertEqual(StartHero.choose(recipe: r, store: store)?.image, hero)
        // Without a background the icon stands on a plain ground; without the icon there is no picture.
        XCTAssertNotNil(ArchiveArt.compose(icon: try png(red: 0.3, opaque: false), background: nil))
        XCTAssertNil(ArchiveArt.compose(icon: Data("no picture".utf8), background: try png(red: 0.3)))
        // Parts removed from this Mac take their picture with them.
        try FileManager.default.removeItem(at: try XCTUnwrap(GameParts.url(recipe: r, store: store, local: false)))
        XCTAssertNil(StartHero.choose(recipe: r, store: store))
    }

    /// The whole way on this Mac with a real archive of game parts, as far as it goes without a headset: set
    /// `AVPPLAY_PARTS_DRYRUN` to such an archive (and `AVPPLAY_PARTS_DRYRUN_OUT` to a folder for what is made).
    func testDryRunWithARealArchive() async throws {
        guard let given = ProcessInfo.processInfo.environment["AVPPLAY_PARTS_DRYRUN"] else { throw XCTSkip("AVPPLAY_PARTS_DRYRUN not set") }
        let dir = temp()
        let keep = ProcessInfo.processInfo.environment["AVPPLAY_PARTS_DRYRUN_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? dir
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        let recipes = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
        let r = try RecipeStore(directory: recipes).load(id: "vivecraft")
        let folder = try builder(in: dir, parts: URL(fileURLWithPath: given))
        let store = ContentStore(root: dir.appendingPathComponent("store", isDirectory: true))
        // A toolchain whose run.sh only writes down what it was given.
        let root = dir.appendingPathComponent("toolchain", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("visionos"), withIntermediateDirectories: true)
        let seenEnvironment = keep.appendingPathComponent("run-sh-environment.txt")
        try "#!/bin/sh\nenv | grep -E '^(KLEPTON_|KL_)' | sort > '\(seenEnvironment.path)'\necho \"args: $*\" >> '\(seenEnvironment.path)'\necho '** BUILD SUCCEEDED **'\n"
            .write(to: root.appendingPathComponent("visionos/run.sh"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("visionos/run.sh").path)
        try "KLEPTON_EVA KLEPTON_ROOM_GUARD KLEPTON_GAME_LANGUAGE\n".write(to: root.appendingPathComponent("visionos/gen_xcodeproj.py"), atomically: true, encoding: .utf8)
        let seen = Collected()
        let job = installer(r, store: store, builders: PartsBuilders(root: dir.appendingPathComponent("builders", isDirectory: true)), local: folder, seen: seen, toolchain: root.path)
        try await job.perform(.account)
        try await job.perform(.fetch)
        let toolchain = try Toolchain(root: root)
        try toolchain.prepare(recipe: r, store: store)
        let device = Device(udid: "00000000-0000000000000000", name: "nobody's headset", osVersion: "27.2", reachable: false, paired: false, developerMode: false)
        try toolchain.buildAndInstall(recipe: r, team: "ABCDE12345", device: device, bundleId: "example.dev.klepton.target.vivecraft",
                                      log: keep.appendingPathComponent("build.log"), extraEnvironment: try job.partsEnvironment())
        try await job.perform(.stage)
        let text = try String(contentsOf: seenEnvironment, encoding: .utf8)
        let parts = try XCTUnwrap(GameParts.built(recipe: r, store: store, local: true))
        XCTAssertTrue(text.contains("KLEPTON_MACHO_IPA=\(parts.url.standardizedFileURL.path)\n"), text)
        XCTAssertTrue(text.contains("KLEPTON_TARGET=vivecraft\n"))
        let hero = try XCTUnwrap(StartHero.choose(recipe: r, store: store), "the game's pictures are in the archive where the recipe says")
        try hero.image.write(to: keep.appendingPathComponent("vivecraft-hero.png"))
        try (seen.said.joined(separator: "\n") + "\n").write(to: keep.appendingPathComponent("job-lines.txt"), atomically: true, encoding: .utf8)
    }

    /// AVP Play's own `AVPPLAY_…` switches must not reach the builder: `AVPPLAY_JOBS` is a folder here, and a builder
    /// once read the same name as its number of compiler jobs and stopped in the middle of the build.
    func testTheBuilderGetsNoneOfTheAppsOwnSwitches() {
        setenv("AVPPLAY_JOBS", "/tmp/a-jobs-folder", 1)
        setenv("AVPPLAY_STORE", "/tmp/a-store", 1)
        defer { unsetenv("AVPPLAY_JOBS"); unsetenv("AVPPLAY_STORE") }
        let build = PartsBuild(builder: URL(fileURLWithPath: "/tmp/builder"), work: URL(fileURLWithPath: "/tmp/work"))
        let env = build.environment(out: URL(fileURLWithPath: "/tmp/out.zip"))
        XCTAssertEqual(env["AVPPLAY_WORK"], "/tmp/work")
        XCTAssertEqual(env["AVPPLAY_OUT"], "/tmp/out.zip")
        XCTAssertEqual(env.keys.filter { $0.hasPrefix("AVPPLAY_") }.sorted(), ["AVPPLAY_OUT", "AVPPLAY_WORK"])
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
    }
}
