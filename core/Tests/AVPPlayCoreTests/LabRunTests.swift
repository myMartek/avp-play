import XCTest
@testable import AVPPlayCore

final class LabRunTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("labrun-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func recipe(target: String = "demo", files: [RecipeFile]) -> Recipe {
        Recipe(schema: 1, id: "demo", title: "Demo", package: "com.example.demo", versionName: "1.0", versionCode: 7,
               store: .init(appId: "123"), toolchain: .init(target: target, minCommit: "abc"), files: files,
               addons: nil, status: .init(playability: "untested", download: "unknown", notes: nil), icon: nil)
    }
    func file(_ name: String, dest: String?) -> RecipeFile {
        RecipeFile(name: name, role: "x", id: "42", size: 1, sha256: nil, required: true, dest: dest,
                   localName: nil, locale: nil, source: nil)
    }

    /// Eine Toolchain, deren `targets.py` für jedes Target dieselbe OBB-Zeile kennt.
    func toolchain(obb: String = "Android/obb/com.example.demo", labScript: Bool = true) throws -> Toolchain {
        let root = tmp.appendingPathComponent("toolchain", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("visionos"), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: root.appendingPathComponent("visionos/run.sh"), atomically: true, encoding: .utf8)
        try "import sys\nprint('\(obb)' if sys.argv[2] == 'obb' else '')\n"
            .write(to: root.appendingPathComponent("visionos/targets.py"), atomically: true, encoding: .utf8)
        if labScript {
            try fm.createDirectory(at: root.appendingPathComponent("tools"), withIntermediateDirectories: true)
            try "#!/bin/bash\n".write(to: root.appendingPathComponent("tools/lab_run.sh"), atomically: true, encoding: .utf8)
        }
        return try Toolchain(root: root)
    }

    func put(_ f: RecipeFile, of r: Recipe, in store: ContentStore) throws {
        let url = store.url(for: f, in: r)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: url)
    }

    func testLinksPutTheGamesFilesWhereItLooksAndSkipWhatIsMissing() throws {
        let store = ContentStore(root: tmp.appendingPathComponent("bestand"))
        let files = [file("main.7.com.example.demo.obb", dest: DraftRecipe.obbPlaceholder),
                     file("level1.bundle", dest: "android-files/Android/obb/com.example.demo"),
                     file("demo.apk", dest: nil),
                     file("root.dat", dest: ""),
                     file("missing.bundle", dest: "android-files/obb")]
        let r = recipe(target: "x1654565391314903", files: files)
        for f in files.prefix(4) { try put(f, of: r, in: store) }
        let links = LabRun.links(recipe: r, store: store, toolchain: try toolchain())
        // Ohne Python-Werkzeuge kennt die Toolchain den Ort der Haupt-Datei nicht; dann gilt der übliche.
        let obbFolder = DeveloperTools.present ? "Android/obb/com.example.demo" : "obb"
        XCTAssertEqual(links.map(\.relative), ["\(obbFolder)/main.7.com.example.demo.obb",
                                               "Android/obb/com.example.demo/level1.bundle"])
        XCTAssertEqual(links.first?.source, store.url(for: files[0], in: r))
    }

    func testCommandNamesThePackTheLinksAndTheGenericTarget() throws {
        let store = ContentStore(root: tmp.appendingPathComponent("bestand"))
        let f = file("level1.bundle", dest: "android-files/obb")
        let r = recipe(target: "x1654565391314903", files: [f])
        try put(f, of: r, in: store)
        let tc = try toolchain()
        var settings = LabRun.Settings()
        settings.frames = 900
        settings.every = 300
        settings.seconds = 120
        settings.keepFiles = true
        let out = tmp.appendingPathComponent("lauf")
        let pack = tmp.appendingPathComponent("lab-mac")
        let (args, env) = LabRun.command(recipe: r, store: store, toolchain: tc, settings: settings, output: out, pack: pack,
                                         base: ["PATH": "/opt/homebrew/bin", "KEEP": "1"])
        XCTAssertEqual(args, [tc.root.appendingPathComponent("tools/lab_run.sh").path, "x1654565391314903", "/dev/null", out.path,
                              "--frames", "900", "--every", "300", "--keep-files",
                              "--link", "\(store.url(for: f, in: r).path)=obb/level1.bundle"])
        XCTAssertEqual(env["KL_ANGLE_DIR"], pack.path)
        XCTAssertEqual(env["KL_MVK_DIR"], pack.path)
        XCTAssertEqual(env["KL_UE4_WAIT"], "120")
        XCTAssertEqual(env["KLEPTON_GENERIC_TARGET"], "x1654565391314903")
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(env["KEEP"], "1")
    }

    func testOlderToolchainAndMissingPackAreSaidBeforeAnythingRuns() throws {
        let store = ContentStore(root: tmp.appendingPathComponent("bestand"))
        let r = recipe(files: [])
        XCTAssertFalse(LabRun.supported(by: try toolchain(labScript: false)))
        XCTAssertThrowsError(try LabRun.run(recipe: r, store: store, toolchain: try toolchain(labScript: false),
                                            settings: .init(), folder: tmp, output: { _ in })) {
            guard case .toolchainTooOld = $0 as? LabError else { return XCTFail("\($0)") }
        }
        XCTAssertFalse(LabRun.packInstalled(at: tmp.appendingPathComponent("nichts")))
    }

    func testInstallTakesOnlyACompletePackAndKeepsTheOldOneOtherwise() throws {
        let fm = FileManager.default
        let content = tmp.appendingPathComponent("inhalt", isDirectory: true)
        try fm.createDirectory(at: content, withIntermediateDirectories: true)
        for name in LabRun.angleFiles + LabRun.angleDependencies + [LabRun.moltenVK] {
            try Data([0]).write(to: content.appendingPathComponent(name))
        }
        let good = tmp.appendingPathComponent("good.tar.gz")
        _ = try ToolchainPackager.run(["/usr/bin/tar", "-czf", good.path, "-C", content.path, "."])
        let folder = tmp.appendingPathComponent("home/lab-mac", isDirectory: true)
        try fm.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try LabRun.install(archive: good, to: folder)
        XCTAssertTrue(LabRun.packInstalled(at: folder))

        try fm.removeItem(at: content.appendingPathComponent(LabRun.moltenVK))
        let partial = tmp.appendingPathComponent("partial.tar.gz")
        _ = try ToolchainPackager.run(["/usr/bin/tar", "-czf", partial.path, "-C", content.path, "."])
        XCTAssertThrowsError(try LabRun.install(archive: partial, to: folder)) {
            guard case .notALabPack = $0 as? LabError else { return XCTFail("\($0)") }
        }
        XCTAssertTrue(LabRun.packInstalled(at: folder), "the installed pack stays")
    }
}
