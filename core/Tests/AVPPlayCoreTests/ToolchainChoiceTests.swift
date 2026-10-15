import XCTest
@testable import AVPPlayCore

final class ToolchainChoiceTests: XCTestCase {
    func temp() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-toolchain-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func recipe(id: String = "moss", minCommit: String = "bbbbbbb") -> Recipe {
        Recipe(schema: 1, id: id, title: "Moss", package: "com.x.moss", versionName: "1.0", versionCode: 7,
               store: .init(appId: nil), toolchain: .init(target: "moss", minCommit: minCommit), files: [],
               addons: nil, status: .init(playability: "untested", download: "unknown", notes: nil), icon: nil)
    }

    /// Ein Ordner, der wie eine Toolchain aussieht: das Startskript und die Beschreibung.
    @discardableResult
    func plant(_ manifest: ToolchainManifest, at dir: URL) throws -> Toolchain {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("visionos"), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: dir.appendingPathComponent("visionos/run.sh"), atomically: true, encoding: .utf8)
        try ToolchainPackager.encoder.encode(manifest).write(to: dir.appendingPathComponent("toolchain.json"))
        return try Toolchain(root: dir)
    }

    /// Die Stände 1 bis 4, jeder enthält seine Vorgänger – wie `git rev-list` sie nennt, den neuesten zuerst.
    static let history = ["ddddddd", "ccccccc", "bbbbbbb", "aaaaaaa"]
    func manifest(_ version: Int, modified: Bool? = nil) -> ToolchainManifest {
        var m = ToolchainManifest(format: 1, version: version, commit: Self.history[4 - version],
                                  ancestors: Array(Self.history[(4 - version)...]), created: Date(timeIntervalSince1970: 1_800_000_000))
        m.modified = modified
        return m
    }

    @discardableResult
    func install(_ version: Int, in packager: ToolchainPackager) throws -> Toolchain {
        try plant(manifest(version), at: packager.directory(for: manifest(version)))
    }

    // MARK: Der Stempel

    func testStampSaysWhenTheToolchainWasModified() {
        XCTAssertEqual(AppStamp.build(versionCode: 89922, toolchainVersion: 315), "89922.315")
        XCTAssertEqual(AppStamp.build(versionCode: 89922, toolchainVersion: 315, modified: true), "89922.315.1")
        XCTAssertEqual(AppStamp.parse("89922.315"), .init(versionCode: 89922, toolchain: 315, modified: false))
        XCTAssertEqual(AppStamp.parse("89922.315.1"), .init(versionCode: 89922, toolchain: 315, modified: true))
        XCTAssertEqual(AppStamp.parse("89922.315.0"), .init(versionCode: 89922, toolchain: 315, modified: false))
        for other in ["1", "", "1.2.3.4", "a.b", "7.x", "7.5.x", "7..1"] { XCTAssertNil(AppStamp.parse(other), other) }
        // Was der Fork als CFBundleVersion annimmt: bis zu drei Zahlen mit Punkten.
        let accepted = try! NSRegularExpression(pattern: #"^\d{1,9}(\.\d{1,9}){0,2}$"#)
        let stamp = AppStamp.build(versionCode: 999_999_999, toolchainVersion: 999_999_999, modified: true)
        XCTAssertEqual(accepted.numberOfMatches(in: stamp, range: NSRange(stamp.startIndex..., in: stamp)), 1)
    }

    /// Die Beschreibung wird gemerkt, aber neu gelesen, sobald sich die Datei ändert oder verschwindet.
    func testManifestIsReadAgainAfterTheFileChanges() throws {
        let dir = temp()
        let toolchain = try plant(manifest(2), at: dir.appendingPathComponent("t"))
        XCTAssertEqual(toolchain.manifest?.version, 2)
        XCTAssertEqual(toolchain.manifest?.version, 2)
        let file = dir.appendingPathComponent("t/toolchain.json")
        // An Ort und Stelle überschrieben, nicht atomar: dieselbe Datei, anderer Inhalt.
        try ToolchainPackager.encoder.encode(manifest(3, modified: true)).write(to: file)
        XCTAssertEqual(toolchain.manifest?.version, 3)
        XCTAssertTrue(toolchain.isModified)
        try FileManager.default.removeItem(at: file)
        XCTAssertNil(toolchain.manifest)
        try ToolchainPackager.encoder.encode(manifest(1)).write(to: file)
        XCTAssertEqual(toolchain.manifest?.version, 1)
    }

    func testModifiedMarkIsReadAndWrittenAndOlderDescriptionsStillLoad() throws {
        let dir = temp()
        let packager = ToolchainPackager(root: dir.appendingPathComponent("toolchains"))
        let installed = try install(3, in: packager)
        XCTAssertFalse(installed.isModified)
        XCTAssertEqual(installed.name, "3")
        // Ein installiertes Paket ist der Stand des Projekts und wird nicht gekennzeichnet.
        XCTAssertThrowsError(try packager.markModified(installed.root)) { XCTAssertEqual($0 as? PackageError, .installedPackage(installed.root.path)) }
        XCTAssertFalse(try Toolchain(root: installed.root).isModified)

        let copy = try plant(manifest(3), at: dir.appendingPathComponent("avpplay-fix/moss"))
        try packager.markModified(copy.root)
        XCTAssertTrue(copy.isModified)
        XCTAssertEqual(copy.version(), 3)
        XCTAssertEqual(copy.commit(), "ccccccc", "Nummer und Commit bleiben die des Pakets, aus dem die Kopie entstand")
        XCTAssertTrue(["3 (modified)", "3 (modifiziert)"].contains(copy.name))
        try packager.markModified(copy.root)      // ein zweites Mal ändert nichts
        XCTAssertTrue(copy.isModified)
        XCTAssertThrowsError(try packager.markModified(dir.appendingPathComponent("nichts")))

        // Eine Beschreibung aus der Zeit vor der Kennzeichnung nennt sie nicht.
        let old = #"{"format":1,"version":2,"commit":"bbbbbbb","ancestors":["bbbbbbb"],"created":"2026-10-01T00:00:00Z"}"#
        XCTAssertNil(try ToolchainPackager.decoder.decode(ToolchainManifest.self, from: Data(old.utf8)).modified)
        // Und eine ohne Kennzeichnung schreibt auch keine.
        XCTAssertFalse(String(decoding: try ToolchainPackager.encoder.encode(manifest(2)), as: UTF8.self).contains("modified"))
    }

    // MARK: Die Wahl

    func testChoicesAreKeptPerGameAndNameWhatMustStay() throws {
        let file = temp().appendingPathComponent("toolchain-choices.json")
        XCTAssertEqual(ToolchainChoices.load(from: file), ToolchainChoices())
        var choices = ToolchainChoices()
        choices.choose(.init(version: 2, commit: "bbbbbbb"), for: "moss")
        choices.choose(.init(version: 3, commit: "ccccccc", modified: true, path: "/tmp/avpplay-fix/golf"), for: "golf")
        try choices.save(to: file)
        let read = ToolchainChoices.load(from: file)
        XCTAssertEqual(read, choices)
        // Nur ein gewähltes Paket schützt etwas vor dem Aufräumen; eine Arbeitskopie liegt nicht bei den Paketen.
        XCTAssertEqual(read.packageCommits, ["bbbbbbb"])
        choices.choose(nil, for: "moss")
        XCTAssertNil(choices.games["moss"])
        XCTAssertTrue(choices.packageCommits.isEmpty)
    }

    func testAChosenToolchainIsFoundOrReportedMissingAndSurvivesPruning() throws {
        let dir = temp()
        let packager = ToolchainPackager(root: dir.appendingPathComponent("toolchains"))
        for version in 1...4 { try install(version, in: packager) }
        let second = try XCTUnwrap(packager.installed().first { $0.version() == 2 })
        let pin = packager.pin(for: second)
        XCTAssertEqual(pin, .init(version: 2, commit: "bbbbbbb"))
        XCTAssertEqual(packager.toolchain(for: pin)?.root.lastPathComponent, "2-bbbbbbb")

        var choices = ToolchainChoices()
        choices.choose(pin, for: "moss")
        let removed = try packager.prune(keep: 1, protecting: choices.packageCommits)
        XCTAssertEqual(removed.map(\.version), [3, 1])
        XCTAssertEqual(packager.installed().map { $0.version() }, [4, 2], "die gewählte bleibt neben der neuesten")

        // Ist sie doch weg, wird sie nicht stillschweigend durch eine andere ersetzt.
        try FileManager.default.removeItem(at: second.root)
        XCTAssertNil(packager.toolchain(for: pin))

        // Eine Arbeitskopie wird an ihrem Ort gesucht und trägt ihn in der Wahl.
        let copy = try plant(manifest(3, modified: true), at: dir.appendingPathComponent("avpplay-fix/moss"))
        let copyPin = packager.pin(for: copy)
        XCTAssertEqual(copyPin, .init(version: 3, commit: "ccccccc", modified: true, path: copy.root.standardizedFileURL.path))
        XCTAssertEqual(packager.toolchain(for: copyPin)?.root.standardizedFileURL.path, copy.root.standardizedFileURL.path)
        try FileManager.default.removeItem(at: copy.root)
        XCTAssertNil(packager.toolchain(for: copyPin))
    }

    func testWorkspaceListsOnlyMarkedCopies() throws {
        let workspace = temp().appendingPathComponent("avpplay-fix")
        try plant(manifest(2, modified: true), at: workspace.appendingPathComponent("moss"))
        try plant(manifest(3, modified: true), at: workspace.appendingPathComponent("golf"))
        try plant(manifest(4), at: workspace.appendingPathComponent("unmarked"))
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("no-toolchain"), withIntermediateDirectories: true)
        XCTAssertEqual(FixWorkspace.modifiedToolchains(in: workspace).map(\.root.lastPathComponent), ["golf", "moss"])
        XCTAssertTrue(FixWorkspace.modifiedToolchains(in: workspace.appendingPathComponent("fehlt")).isEmpty)
    }

    // MARK: Der Stand auf dem Gerät

    func testStatusFollowsTheChosenToolchain() {
        let store = ContentStore(root: temp())
        let bundle = Toolchain.bundleId(target: "moss", prefix: "com.example")
        func status(_ installed: String, newest: Int = 4, pin: ToolchainChoices.Pin? = nil) -> GameStatus {
            GameStatus.of(recipe: recipe(), store: store,
                          apps: [InstalledApp(bundleIdentifier: bundle, name: "Moss", version: "1.0", bundleVersion: installed)],
                          toolchainVersion: newest, pin: pin, bundlePrefix: "com.example")
        }
        // Ohne Wahl wie bisher: ein Bau mit einer älteren Toolchain kann aktualisiert werden.
        XCTAssertEqual(status("7.3").onDevice, .olderToolchain(stamp: "1.0 (7.3)"))
        XCTAssertEqual(status("7.4").onDevice, .current(stamp: "1.0 (7.4)"))
        // Mit Wahl ist aktuell, was genau mit ihr gebaut ist – auch wenn es eine neuere gibt.
        let second = ToolchainChoices.Pin(version: 2, commit: "bbbbbbb")
        XCTAssertEqual(status("7.2", pin: second).onDevice, .current(stamp: "1.0 (7.2)"))
        XCTAssertEqual(status("7.4", pin: second).onDevice, .olderToolchain(stamp: "1.0 (7.4)"), "ein Bau mit der neuesten ist dann nicht der gewählte")
        // Eine bearbeitete Arbeitskopie hat die Nummer ihres Pakets; den Unterschied macht die dritte Zahl.
        let copy = ToolchainChoices.Pin(version: 3, commit: "ccccccc", modified: true, path: "/tmp/avpplay-fix/moss")
        XCTAssertEqual(status("7.3.1", pin: copy).onDevice, .current(stamp: "1.0 (7.3.1)"))
        XCTAssertEqual(status("7.3", pin: copy).onDevice, .olderToolchain(stamp: "1.0 (7.3)"))
        XCTAssertEqual(status("7.3.1", pin: .init(version: 3, commit: "ccccccc")).onDevice, .olderToolchain(stamp: "1.0 (7.3.1)"))
        // Ohne Wahl sagt der Stand, dass der Bau aus einer bearbeiteten Kopie stammt.
        XCTAssertEqual(status("7.3.1").builtWith, .init(versionCode: 7, toolchain: 3, modified: true))
        XCTAssertEqual(status("7.3.1").onDevice, .olderToolchain(stamp: "1.0 (7.3.1)"))
        XCTAssertEqual(status("7.4.1").onDevice, .current(stamp: "1.0 (7.4.1)"))
        XCTAssertEqual(status("7.4").builtWith?.modified, false)
        // Eine ältere Fassung des Spiels bleibt eine ältere Fassung, auch mit drei Zahlen.
        XCTAssertEqual(status("6.3.1").onDevice, .olderGame(stamp: "1.0 (6.3.1)"))
        XCTAssertEqual(status("1").onDevice, .unstamped(stamp: "1.0 (1)"))
    }

    // MARK: Die experimentelle Einstellung

    func testTheStampCarriesTheExperimentalBuild() {
        XCTAssertEqual(AppStamp.build(versionCode: 7, toolchainVersion: 4, experimental: true), "7.4.2")
        XCTAssertEqual(AppStamp.build(versionCode: 7, toolchainVersion: 4, modified: true, experimental: true), "7.4.3")
        XCTAssertEqual(AppStamp.parse("7.4.2"), .init(versionCode: 7, toolchain: 4, modified: false, experimental: true))
        XCTAssertEqual(AppStamp.parse("7.4.3"), .init(versionCode: 7, toolchain: 4, modified: true, experimental: true))
        XCTAssertEqual(AppStamp.parse("7.4.1")?.experimental, false)
        XCTAssertEqual(AppStamp.parse("7.4")?.experimental, false)
        // Eine dritte Zahl, die dieses Werkzeug nicht schreibt, sagt nichts – der Bau bleibt aber erkannt.
        XCTAssertEqual(AppStamp.parse("7.4.9"), .init(versionCode: 7, toolchain: 4, modified: false, experimental: false))
    }

    func testABuildThatDiffersFromTheExperimentalSettingCanBeUpdated() {
        let store = ContentStore(root: temp())
        let bundle = Toolchain.bundleId(target: "moss", prefix: "com.example")
        func status(_ installed: String, experimental: Bool?, pin: ToolchainChoices.Pin? = nil) -> GameStatus.OnDevice {
            GameStatus.of(recipe: recipe(), store: store,
                          apps: [InstalledApp(bundleIdentifier: bundle, name: "Moss", version: "1.0", bundleVersion: installed)],
                          toolchainVersion: 4, pin: pin, bundlePrefix: "com.example", experimental: experimental).onDevice
        }
        // Einstellung an: Ein Bau mit der neuesten Toolchain, aber ohne die Schalter, ist nicht mehr aktuell …
        XCTAssertEqual(status("7.4", experimental: true), .olderToolchain(stamp: "1.0 (7.4)"))
        XCTAssertEqual(status("7.4.2", experimental: true), .current(stamp: "1.0 (7.4.2)"))
        // … und nach dem Ausschalten gilt dasselbe andersherum.
        XCTAssertEqual(status("7.4.2", experimental: false), .olderToolchain(stamp: "1.0 (7.4.2)"))
        XCTAssertEqual(status("7.4", experimental: false), .current(stamp: "1.0 (7.4)"))
        // Ohne Vergleich (keine Toolchain, die es kann) ändert sich nichts am bisherigen Urteil.
        XCTAssertEqual(status("7.4.2", experimental: nil), .current(stamp: "1.0 (7.4.2)"))
        XCTAssertEqual(status("7.3.2", experimental: nil), .olderToolchain(stamp: "1.0 (7.3.2)"))
        // Ein Spiel mit eigens gewählter Toolchain bleibt, wie es ist.
        let pin = ToolchainChoices.Pin(version: 4, commit: "ddddddd")
        XCTAssertEqual(status("7.4", experimental: true, pin: pin), .current(stamp: "1.0 (7.4)"))
        XCTAssertEqual(status("7.4.2", experimental: false, pin: pin), .current(stamp: "1.0 (7.4.2)"))
    }

    func testAnInstallRequestWithoutTheFieldIsNotExperimental() throws {
        // Aufträge, die vor dieser Einstellung gespeichert wurden, haben das Feld nicht.
        var request = InstallRequest(toolchain: "/tmp/t")
        let old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        XCTAssertNil(old?["experimental"])
        XCTAssertNil(try JSONDecoder().decode(InstallRequest.self, from: JSONEncoder().encode(request)).experimental)
        request.experimental = true
        XCTAssertEqual(try JSONDecoder().decode(InstallRequest.self, from: JSONEncoder().encode(request)).experimental, true)
    }

    // MARK: Das MetalFX-Hochskalieren

    func testTheStampCarriesTheMetalFXBuild() {
        XCTAssertEqual(AppStamp.build(versionCode: 7, toolchainVersion: 4, metalFX: true), "7.4.4")
        XCTAssertEqual(AppStamp.build(versionCode: 7, toolchainVersion: 4, modified: true, experimental: true, metalFX: true), "7.4.7")
        // Ohne die Einstellung bleibt der Stempel, wie er war.
        XCTAssertEqual(AppStamp.build(versionCode: 7, toolchainVersion: 4), "7.4")
        XCTAssertEqual(AppStamp.build(versionCode: 7, toolchainVersion: 4, experimental: true), "7.4.2")
        XCTAssertEqual(AppStamp.parse("7.4.4"), .init(versionCode: 7, toolchain: 4, modified: false, experimental: false, metalFX: true))
        XCTAssertEqual(AppStamp.parse("7.4.6"), .init(versionCode: 7, toolchain: 4, modified: false, experimental: true, metalFX: true))
        XCTAssertEqual(AppStamp.parse("7.4.7"), .init(versionCode: 7, toolchain: 4, modified: true, experimental: true, metalFX: true))
        XCTAssertEqual(AppStamp.parse("7.4.3")?.metalFX, false)
        XCTAssertEqual(AppStamp.parse("7.4.8"), .init(versionCode: 7, toolchain: 4, modified: false, experimental: false, metalFX: false))
    }

    func testABuildThatDiffersFromTheMetalFXSettingCanBeUpdated() {
        let store = ContentStore(root: temp())
        let bundle = Toolchain.bundleId(target: "moss", prefix: "com.example")
        func status(_ installed: String, experimental: Bool? = nil, metalFX: Bool?) -> GameStatus.OnDevice {
            GameStatus.of(recipe: recipe(), store: store,
                          apps: [InstalledApp(bundleIdentifier: bundle, name: "Moss", version: "1.0", bundleVersion: installed)],
                          toolchainVersion: 4, bundlePrefix: "com.example", experimental: experimental, metalFX: metalFX).onDevice
        }
        XCTAssertEqual(status("7.4", metalFX: true), .olderToolchain(stamp: "1.0 (7.4)"))
        XCTAssertEqual(status("7.4.4", metalFX: true), .current(stamp: "1.0 (7.4.4)"))
        XCTAssertEqual(status("7.4.4", metalFX: false), .olderToolchain(stamp: "1.0 (7.4.4)"))
        XCTAssertEqual(status("7.4", metalFX: false), .current(stamp: "1.0 (7.4)"))
        // Beide Einstellungen zugleich: jede für sich verglichen.
        XCTAssertEqual(status("7.4.6", experimental: true, metalFX: true), .current(stamp: "1.0 (7.4.6)"))
        XCTAssertEqual(status("7.4.2", experimental: true, metalFX: true), .olderToolchain(stamp: "1.0 (7.4.2)"))
        // Keine Toolchain, die es kann: kein Vergleich, das Urteil bleibt das bisherige.
        XCTAssertEqual(status("7.4.4", metalFX: nil), .current(stamp: "1.0 (7.4.4)"))
    }

    func testOnlyAToolchainWithTheCompositorSwitchAndAnInstallDefaultSupportsMetalFX() throws {
        let dir = temp()
        let toolchain = try plant(manifest(4), at: dir)
        let sources = dir.appendingPathComponent("visionos/Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "KLEPTON_TEST_ON".write(to: dir.appendingPathComponent("visionos/gen_xcodeproj.py"), atomically: true, encoding: .utf8)
        XCTAssertFalse(toolchain.supportsMetalFX)
        // Klepton PR #2 allein: der Schalter im Spiel, aber nichts, womit eine Installation ihn vorbelegt.
        try "UserDefaults.standard.bool(forKey: \"klepton.metalfxUpscale\")"
            .write(to: sources.appendingPathComponent("KleptonCompositor.swift"), atomically: true, encoding: .utf8)
        XCTAssertFalse(toolchain.supportsMetalFX)
        try "onFromInstall.contains(\"\(Toolchain.metalFXSwitch)\")"
            .write(to: sources.appendingPathComponent("KleptonTuning.swift"), atomically: true, encoding: .utf8)
        XCTAssertTrue(toolchain.supportsMetalFX)
        // Ohne KLEPTON_TEST_ON kommt der Name nicht ins Spiel.
        try "".write(to: dir.appendingPathComponent("visionos/gen_xcodeproj.py"), atomically: true, encoding: .utf8)
        XCTAssertFalse(toolchain.supportsMetalFX)
    }

    func testAnInstallRequestWithoutTheFieldHasNoMetalFX() throws {
        var request = InstallRequest(toolchain: "/tmp/t")
        let old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        XCTAssertNil(old?["metalFX"])
        XCTAssertNil(try JSONDecoder().decode(InstallRequest.self, from: JSONEncoder().encode(request)).metalFX)
        request.metalFX = true
        XCTAssertEqual(try JSONDecoder().decode(InstallRequest.self, from: JSONEncoder().encode(request)).metalFX, true)
        XCTAssertNil(try JSONDecoder().decode(InstallRequest.self, from: JSONEncoder().encode(request)).resolution)
        request.resolution = 75
        XCTAssertEqual(try JSONDecoder().decode(InstallRequest.self, from: JSONEncoder().encode(request)).resolution, 75)
    }

    // MARK: Die Auflösung zum MetalFX-Schalter

    func testSwitchingMetalFXOnPresetsTheResolution() {
        let on = MetalFXResolution.switched(metalFX: true, was: false, state: .init(resolution: 100))
        XCTAssertEqual(on, .init(resolution: 75, before: 100))
        // Ein eigener Wert von vorher wird gemerkt.
        XCTAssertEqual(MetalFXResolution.switched(metalFX: true, was: false, state: .init(resolution: 90)),
                       .init(resolution: 75, before: 90))
    }

    func testThePlayersOwnValueCountsWhileMetalFXStaysOn() {
        // Der Spieler ändert die Vorbelegung; ein erneutes Setzen desselben Schalterstands lässt sie stehen.
        let changed = MetalFXResolution.State(resolution: 60, before: 100)
        XCTAssertEqual(MetalFXResolution.switched(metalFX: true, was: true, state: changed), changed)
        XCTAssertEqual(MetalFXResolution.switched(metalFX: false, was: false, state: .init(resolution: 85)),
                       .init(resolution: 85))
    }

    func testSwitchingMetalFXOffRestoresThePreviousValueOrFull() {
        XCTAssertEqual(MetalFXResolution.switched(metalFX: false, was: true, state: .init(resolution: 60, before: 90)),
                       .init(resolution: 90))
        XCTAssertEqual(MetalFXResolution.switched(metalFX: false, was: true, state: .init(resolution: 75)),
                       .init(resolution: 100))
        // Ein, aus, ein: wieder 75, und davor gilt der Wert, der nach dem Ausschalten stand.
        var state = MetalFXResolution.State(resolution: 80)
        state = MetalFXResolution.switched(metalFX: true, was: false, state: state)
        state.resolution = 55
        state = MetalFXResolution.switched(metalFX: false, was: true, state: state)
        XCTAssertEqual(state, .init(resolution: 80))
        XCTAssertEqual(MetalFXResolution.switched(metalFX: true, was: false, state: state), .init(resolution: 75, before: 80))
    }

    func testTheResolutionHandedToTheToolchain() {
        XCTAssertEqual(MetalFXResolution.environmentValue(75), "0.75")
        XCTAssertEqual(MetalFXResolution.environmentValue(50), "0.50")
        // 100 % und ohne Angabe: keine Vorgabe, es bleibt bei der des Targets.
        XCTAssertNil(MetalFXResolution.environmentValue(100))
        XCTAssertNil(MetalFXResolution.environmentValue(nil))
        // Außerhalb des Bereichs oder zwischen den Schritten: auf den nächsten gültigen Wert.
        XCTAssertEqual(MetalFXResolution.environmentValue(10), "0.50")
        XCTAssertNil(MetalFXResolution.environmentValue(140))
        XCTAssertEqual(MetalFXResolution.environmentValue(73), "0.75")
    }

    func testOnlyAToolchainThatReadsItCanPresetTheResolution() throws {
        let dir = temp()
        let toolchain = try plant(manifest(4), at: dir)
        try "KLEPTON_TEST_ON".write(to: dir.appendingPathComponent("visionos/gen_xcodeproj.py"), atomically: true, encoding: .utf8)
        XCTAssertFalse(toolchain.supportsRenderScalePreset)
        try "KLEPTON_TEST_ON \(Toolchain.renderScaleVariable)"
            .write(to: dir.appendingPathComponent("visionos/gen_xcodeproj.py"), atomically: true, encoding: .utf8)
        XCTAssertTrue(toolchain.supportsRenderScalePreset)
    }

    /// Gegen einen echten Klepton-Stand (Klepton PR #4): `AVPPLAY_KLEPTON_CHECKOUT=<Klon>` – sonst übersprungen.
    func testAKleptonCheckoutWithTheInstallSwitchesIsRecognised() throws {
        guard let path = ProcessInfo.processInfo.environment["AVPPLAY_KLEPTON_CHECKOUT"] else {
            throw XCTSkip("AVPPLAY_KLEPTON_CHECKOUT not set")
        }
        let toolchain = try Toolchain(root: URL(fileURLWithPath: path))
        XCTAssertTrue(toolchain.supportsMetalFX)
        XCTAssertTrue(toolchain.supportsRenderScalePreset)
    }

    func testTheStampCarriesTheStartingResolution() {
        XCTAssertEqual(AppStamp.build(versionCode: 7, toolchainVersion: 4, metalFX: true, resolution: 75), "7.4.44")
        XCTAssertEqual(AppStamp.build(versionCode: 7, toolchainVersion: 4, experimental: true, metalFX: true, resolution: 50), "7.4.86")
        // Ohne MetalFX und bei 100 % kein Vermerk.
        XCTAssertEqual(AppStamp.build(versionCode: 7, toolchainVersion: 4, resolution: 75), "7.4")
        XCTAssertEqual(AppStamp.build(versionCode: 7, toolchainVersion: 4, metalFX: true, resolution: 100), "7.4.4")
        XCTAssertEqual(AppStamp.parse("7.4.44"),
                       .init(versionCode: 7, toolchain: 4, modified: false, experimental: false, metalFX: true, resolution: 75))
        XCTAssertEqual(AppStamp.parse("7.4.87"),
                       .init(versionCode: 7, toolchain: 4, modified: true, experimental: true, metalFX: true, resolution: 50))
        XCTAssertNil(AppStamp.parse("7.4.4")?.resolution)
        for percent in stride(from: 50, through: 95, by: 5) {
            let stamp = AppStamp.build(versionCode: 1, toolchainVersion: 2, metalFX: true, resolution: percent)
            XCTAssertEqual(AppStamp.parse(stamp)?.resolution, percent, stamp)
        }
        // Eine Stufe ohne MetalFX oder jenseits von 50 % stammt nicht von hier und sagt nichts.
        XCTAssertEqual(AppStamp.parse("7.4.40"), .init(versionCode: 7, toolchain: 4, modified: false))
        XCTAssertEqual(AppStamp.parse("7.4.92"), .init(versionCode: 7, toolchain: 4, modified: false))
    }

    func testTheCommandLineWarnsAboutAResolutionItCannotUse() {
        // Ohne --metalfx: nicht übernommen, aber gesagt.
        let alone = MetalFXResolution.commandLine(metalFX: false, value: "60")
        XCTAssertNil(alone.resolution)
        XCTAssertTrue(alone.warning?.contains("--metalfx") == true)
        XCTAssertEqual(MetalFXResolution.commandLine(metalFX: false, value: nil).warning, nil)
        // Mit --metalfx: ohne Angabe die Vorbelegung, ein gültiger Wert still.
        XCTAssertEqual(MetalFXResolution.commandLine(metalFX: true, value: nil).resolution, 75)
        XCTAssertNil(MetalFXResolution.commandLine(metalFX: true, value: nil).warning)
        XCTAssertEqual(MetalFXResolution.commandLine(metalFX: true, value: "60").resolution, 60)
        XCTAssertNil(MetalFXResolution.commandLine(metalFX: true, value: "60").warning)
        // Was so nicht geht, wird angepasst und gesagt.
        let low = MetalFXResolution.commandLine(metalFX: true, value: "30")
        XCTAssertEqual(low.resolution, 50)
        XCTAssertNotNil(low.warning)
        XCTAssertEqual(MetalFXResolution.commandLine(metalFX: true, value: "73").resolution, 75)
        XCTAssertNotNil(MetalFXResolution.commandLine(metalFX: true, value: "73").warning)
        let word = MetalFXResolution.commandLine(metalFX: true, value: "high")
        XCTAssertEqual(word.resolution, 75)
        XCTAssertNotNil(word.warning)
    }

    func testRenewalKeepsTheStartingResolutionOfTheBuild() {
        func renewed(_ stamp: String) -> InstallRequest {
            var request = InstallRequest(toolchain: "/tmp/t")
            Renewal.keepBuild(AppStamp.parse(stamp), in: &request)
            return request
        }
        XCTAssertEqual(renewed("7.4.68").resolution, 60)
        XCTAssertEqual(renewed("7.4.68").metalFX, true)
        XCTAssertEqual(renewed("7.4.46").experimental, true)
        XCTAssertEqual(renewed("7.4.46").resolution, 75)
        // Ein MetalFX-Bau ohne Vorgabe bleibt ohne – nie die 75 % der Einstellung.
        XCTAssertEqual(renewed("7.4.4").metalFX, true)
        XCTAssertNil(renewed("7.4.4").resolution)
        XCTAssertNil(renewed("7.4").metalFX)
        XCTAssertNil(renewed("7.4").resolution)
        XCTAssertNil(renewed("7.4.2").resolution)
    }

    // MARK: Die XR-Vorhersage (Test-Option je Spiel)

    func testTheStampCarriesTheXRPrediction() {
        XCTAssertEqual(AppStamp.build(versionCode: 7, toolchainVersion: 4, xrPrediction: true), "7.4.128")
        XCTAssertEqual(AppStamp.build(versionCode: 7, toolchainVersion: 4, modified: true, experimental: true, metalFX: true,
                                      resolution: 50, xrPrediction: true), "7.4.215")
        // Ohne die Option bleibt der Stempel, wie er war.
        XCTAssertEqual(AppStamp.build(versionCode: 7, toolchainVersion: 4, metalFX: true, resolution: 75), "7.4.44")
        XCTAssertEqual(AppStamp.parse("7.4.128"),
                       .init(versionCode: 7, toolchain: 4, modified: false, xrPrediction: true))
        XCTAssertEqual(AppStamp.parse("7.4.215"),
                       .init(versionCode: 7, toolchain: 4, modified: true, experimental: true, metalFX: true, resolution: 50,
                             xrPrediction: true))
        XCTAssertEqual(AppStamp.parse("7.4.44")?.xrPrediction, false)
        // Eine Stufe ohne MetalFX bleibt ungültig, auch mit dem Bit der Vorhersage; darüber stammt nichts von hier.
        XCTAssertEqual(AppStamp.parse("7.4.168"), .init(versionCode: 7, toolchain: 4, modified: false))
        XCTAssertEqual(AppStamp.parse("7.4.256"), .init(versionCode: 7, toolchain: 4, modified: false))
        for percent in stride(from: 50, through: 100, by: 5) {
            let stamp = AppStamp.build(versionCode: 1, toolchainVersion: 2, metalFX: true, resolution: percent, xrPrediction: true)
            XCTAssertEqual(AppStamp.parse(stamp)?.xrPrediction, true, stamp)
            XCTAssertEqual(AppStamp.parse(stamp)?.resolution, percent == 100 ? nil : percent, stamp)
        }
    }

    func testABuildThatDiffersFromTheGamesXRPredictionOptionCanBeUpdated() {
        let store = ContentStore(root: temp())
        let bundle = Toolchain.bundleId(target: "moss", prefix: "com.example")
        func status(_ installed: String, metalFX: Bool? = nil, xrPrediction: Bool?,
                    pin: ToolchainChoices.Pin? = nil) -> GameStatus.OnDevice {
            GameStatus.of(recipe: recipe(), store: store,
                          apps: [InstalledApp(bundleIdentifier: bundle, name: "Moss", version: "1.0", bundleVersion: installed)],
                          toolchainVersion: 4, pin: pin, bundlePrefix: "com.example", metalFX: metalFX,
                          xrPrediction: xrPrediction).onDevice
        }
        XCTAssertEqual(status("7.4", xrPrediction: true), .olderToolchain(stamp: "1.0 (7.4)"))
        XCTAssertEqual(status("7.4.128", xrPrediction: true), .current(stamp: "1.0 (7.4.128)"))
        XCTAssertEqual(status("7.4.128", xrPrediction: false), .olderToolchain(stamp: "1.0 (7.4.128)"))
        XCTAssertEqual(status("7.4", xrPrediction: false), .current(stamp: "1.0 (7.4)"))
        // Zusammen mit MetalFX: jede für sich verglichen.
        XCTAssertEqual(status("7.4.172", metalFX: true, xrPrediction: true), .current(stamp: "1.0 (7.4.172)"))
        XCTAssertEqual(status("7.4.44", metalFX: true, xrPrediction: true), .olderToolchain(stamp: "1.0 (7.4.44)"))
        // Keine Toolchain, die es kann, oder eine für das Spiel gewählte: kein Vergleich.
        XCTAssertEqual(status("7.4.128", xrPrediction: nil), .current(stamp: "1.0 (7.4.128)"))
        XCTAssertEqual(status("7.4", xrPrediction: true, pin: .init(version: 4, commit: "abc")),
                       .current(stamp: "1.0 (7.4)"))
    }

    func testRenewalKeepsTheXRPrediction() {
        func renewed(_ stamp: String) -> InstallRequest {
            var request = InstallRequest(toolchain: "/tmp/t")
            Renewal.keepBuild(AppStamp.parse(stamp), in: &request)
            return request
        }
        XCTAssertEqual(renewed("7.4.128").xrPrediction, true)
        XCTAssertEqual(renewed("7.4.172").xrPrediction, true)
        XCTAssertEqual(renewed("7.4.172").resolution, 75)
        XCTAssertNil(renewed("7.4.44").xrPrediction)
        XCTAssertNil(renewed("7.4").xrPrediction)
    }

    func testOnlyAToolchainWithTheTestSwitchSupportsXRPrediction() throws {
        let dir = temp()
        let toolchain = try plant(manifest(4), at: dir)
        let sources = dir.appendingPathComponent("visionos/Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "KLEPTON_TEST_ON".write(to: dir.appendingPathComponent("visionos/gen_xcodeproj.py"), atomically: true, encoding: .utf8)
        XCTAssertFalse(toolchain.supportsXRPrediction)
        // Toolchain 507: KL_XR_PREDICT nur als Variable der Laufzeit, kein Test-Schalter – sie sagt immer voraus.
        try "kl_openxr_set_predict(kl_openxr_predict() != 0 ? 0 : 1) // KL_XR_PREDICT"
            .write(to: sources.appendingPathComponent("KleptonTuning.swift"), atomically: true, encoding: .utf8)
        XCTAssertFalse(toolchain.supportsXRPrediction)
        try "Entry(env: \"\(Toolchain.xrPredictionSwitch)\", value: \"1\","
            .write(to: sources.appendingPathComponent("KleptonTuning.swift"), atomically: true, encoding: .utf8)
        XCTAssertTrue(toolchain.supportsXRPrediction)
        // Ohne KLEPTON_TEST_ON kommt der Name nicht ins Spiel.
        try "".write(to: dir.appendingPathComponent("visionos/gen_xcodeproj.py"), atomically: true, encoding: .utf8)
        XCTAssertFalse(toolchain.supportsXRPrediction)
    }

    func testAnInstallRequestWithoutTheFieldHasNoXRPrediction() throws {
        var request = InstallRequest(toolchain: "/tmp/t")
        let old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        XCTAssertNil(old?["xrPrediction"])
        XCTAssertNil(try JSONDecoder().decode(InstallRequest.self, from: JSONEncoder().encode(request)).xrPrediction)
        request.xrPrediction = true
        XCTAssertEqual(try JSONDecoder().decode(InstallRequest.self, from: JSONEncoder().encode(request)).xrPrediction, true)
    }

    /// Gegen einen echten Klepton-Stand mit der XR-Vorhersage als Test-Schalter: `AVPPLAY_KLEPTON_CHECKOUT=<Klon>` –
    /// sonst übersprungen.
    func testAKleptonCheckoutWithTheXRPredictionSwitchIsRecognised() throws {
        guard let path = ProcessInfo.processInfo.environment["AVPPLAY_KLEPTON_CHECKOUT"] else {
            throw XCTSkip("AVPPLAY_KLEPTON_CHECKOUT not set")
        }
        XCTAssertTrue(try Toolchain(root: URL(fileURLWithPath: path)).supportsXRPrediction)
    }

    // MARK: Was zur Wahl steht

    func testOptionsOfferOnlyWhatCanBuildTheRecipe() throws {
        let dir = temp()
        let packager = ToolchainPackager(root: dir.appendingPathComponent("toolchains"))
        let workspace = dir.appendingPathComponent("avpplay-fix")
        try install(2, in: packager)
        let newest = try install(4, in: packager)
        try plant(manifest(3, modified: true), at: workspace.appendingPathComponent("moss"))
        try plant(manifest(1, modified: true), at: workspace.appendingPathComponent("old"))
        func released(_ version: Int, app: String) -> ReleasedToolchain {
            let commit = Self.history[4 - version]
            return ReleasedToolchain(version: version, commit: commit, appVersion: app,
                                     archive: URL(string: "https://example.org/klepton-toolchain-\(version)-\(commit).tar.gz")!,
                                     sidecar: URL(string: "https://example.org/klepton-toolchain-\(version)-\(commit).tar.gz.json")!,
                                     size: 25_000_000, sha256: nil)
        }
        let list = [released(4, app: "1.3"), released(3, app: "1.2"), released(2, app: "1.1"), released(1, app: "1.0")]

        // Das Rezept braucht Stand 2: Stand 1 fällt überall heraus.
        var options = ToolchainOptions.make(recipe: recipe(minCommit: "bbbbbbb"), pin: nil, packager: packager, newest: newest,
                                            released: list, workspace: workspace)
        XCTAssertEqual(options.newest?.version, 4)
        XCTAssertEqual(options.installed.map(\.version), [4, 2])
        XCTAssertEqual(options.copies.map(\.version), [3])
        XCTAssertEqual(options.copies.first?.modified, true)
        XCTAssertEqual(options.released.map(\.version), [3], "nur ältere, die noch nicht auf dem Mac liegen und das Rezept bauen können")
        XCTAssertEqual(options.released.first?.appVersion, "1.2")
        XCTAssertNil(options.missing)

        // Ohne Liste von GitHub steht dort nichts.
        options = ToolchainOptions.make(recipe: recipe(), pin: nil, packager: packager, newest: newest, released: nil, workspace: workspace)
        XCTAssertTrue(options.released.isEmpty)

        // Ein Rezept, das die neueste braucht, lässt nichts Älteres zu.
        options = ToolchainOptions.make(recipe: recipe(minCommit: "ddddddd"), pin: nil, packager: packager, newest: newest,
                                        released: list, workspace: workspace)
        XCTAssertEqual(options.installed.map(\.version), [4])
        XCTAssertTrue(options.copies.isEmpty)
        XCTAssertTrue(options.released.isEmpty)

        // Ein Entwurf, der noch keinen Mindeststand nennt, lässt alles zu.
        options = ToolchainOptions.make(recipe: recipe(minCommit: ""), pin: nil, packager: packager, newest: newest,
                                        released: list, workspace: workspace)
        XCTAssertEqual(options.copies.map(\.version), [3, 1])
        XCTAssertEqual(options.released.map(\.version), [3, 1])

        // Eine Wahl, die nicht mehr da ist, steht als solche da.
        let gone = ToolchainChoices.Pin(version: 3, commit: "ccccccc")
        options = ToolchainOptions.make(recipe: recipe(), pin: gone, packager: packager, newest: newest, released: nil, workspace: workspace)
        XCTAssertEqual(options.missing?.version, 3)
        XCTAssertEqual(ToolchainOption.key(for: gone), "ccccccc")
        let copy = packager.pin(for: try Toolchain(root: workspace.appendingPathComponent("moss")))
        XCTAssertEqual(options.copies.first?.id, ToolchainOption.key(for: copy))
    }

    // MARK: Pakete von GitHub

    func testReleaseListNamesEachToolchainOnceWithItsFirstRelease() throws {
        func asset(_ name: String, digest: String? = nil) -> String {
            #"{"name":"\#(name)","browser_download_url":"https://github.com/myMartek/avp-play/releases/download/x/\#(name)","size":123\#(digest.map { #","digest":"sha256:\#($0)""# } ?? "")}"#
        }
        let sum = String(repeating: "AB", count: 32)
        let json = """
        [{"tag_name":"v1.1.4","assets":[\(asset("AVP-Play-1.1.4.dmg")),\(asset("klepton-toolchain-304-bb9f621.tar.gz", digest: sum)),\(asset("klepton-toolchain-304-bb9f621.tar.gz.json"))]},
         {"tag_name":"v1.1.5","assets":[\(asset("klepton-toolchain-315-868877a.tar.gz")),\(asset("klepton-toolchain-315-868877a.tar.gz.json"))]},
         {"tag_name":"v1.1.3","assets":[\(asset("klepton-toolchain-304-bb9f621.tar.gz")),\(asset("klepton-toolchain-304-bb9f621.tar.gz.json"))]},
         {"tag_name":"xrizer-0989a7f-avpplay1","assets":[\(asset("klepton-toolchain-999-0989a7f.tar.gz")),\(asset("klepton-toolchain-999-0989a7f.tar.gz.json"))]},
         {"tag_name":"v1.0.0","assets":[\(asset("klepton-toolchain-204-eee6b61.tar.gz"))]},
         {"tag_name":"v0.9","assets":[\(asset("klepton-toolchain-../../x-eee6b61.tar.gz")),\(asset("evil-toolchain-1-eee6b61.tar.gz"))]}]
        """
        let (found, releases) = try ToolchainReleases.parse(Data(json.utf8))
        XCTAssertEqual(releases, 6)
        XCTAssertEqual(found.map(\.version), [304, 315, 304], "ohne Beschreibung, mit anderem Namen oder aus einer Komponenten-Veröffentlichung zählt nichts")
        let merged = ToolchainReleases.merged(found)
        XCTAssertEqual(merged.map(\.version), [315, 304])
        XCTAssertEqual(merged.map(\.appVersion), ["1.1.5", "1.1.3"])
        XCTAssertEqual(merged.first?.sidecar.lastPathComponent, "klepton-toolchain-315-868877a.tar.gz.json")
        XCTAssertEqual(found.first?.sha256, sum.lowercased())
        XCTAssertThrowsError(try ToolchainReleases.parse(Data(#"{"message":"rate limit"}"#.utf8)))
    }

    /// Ein Paket, wie eine Veröffentlichung es trägt: Archiv und Beschreibung mit Größe und Prüfsumme.
    func package(_ manifest: ToolchainManifest, named version: Int? = nil, in dir: URL) throws -> ReleasedToolchain {
        let tree = dir.appendingPathComponent("tree-\(UUID().uuidString)")
        try plant(manifest, at: tree)
        let archive = dir.appendingPathComponent("klepton-toolchain-\(version ?? manifest.version)-\(manifest.commit).tar.gz")
        _ = try ToolchainPackager.run(["/usr/bin/tar", "-czf", archive.path, "-C", tree.path, "."])
        var described = manifest
        described.archive = archive.lastPathComponent
        described.sha256 = try Hashing.sha256(of: archive)
        described.size = ContentStore.fileSize(archive)
        try ToolchainPackager.encoder.encode(described).write(to: ToolchainPackager.sidecar(for: archive))
        return ReleasedToolchain(version: version ?? manifest.version, commit: manifest.commit, appVersion: "1.0", archive: archive,
                                 sidecar: ToolchainPackager.sidecar(for: archive), size: described.size, sha256: described.sha256)
    }

    func testAReleasedToolchainIsCheckedBeforeItIsInstalled() async throws {
        let dir = temp()
        let packager = ToolchainPackager(root: dir.appendingPathComponent("toolchains"))
        try install(4, in: packager)

        let good = try package(manifest(2), in: dir)
        let installed = try await ToolchainReleases.install(good, with: packager)
        XCTAssertEqual(installed.version(), 2)
        XCTAssertEqual(packager.installed().map { $0.version() }, [4, 2], "die neueste bleibt die neueste")
        // Ein zweites Mal wird nichts geladen: die Quelle darf dann fehlen.
        try FileManager.default.removeItem(at: good.archive)
        let again = try await ToolchainReleases.install(good, with: packager)
        XCTAssertEqual(again.root.resolvingSymlinksInPath(), installed.root.resolvingSymlinksInPath())

        // Die Liste nennt eine andere Prüfsumme als das, was ankommt.
        var tampered = try package(manifest(3), in: dir)
        tampered.sha256 = String(repeating: "0", count: 64)
        do { _ = try await ToolchainReleases.install(tampered, with: packager); XCTFail("hätte scheitern müssen") }
        catch { XCTAssertEqual(error as? PackageError, .checksumMismatch) }

        // Der Name verspricht Stand 3, drin ist Stand 1.
        let mislabeled = try package(manifest(1), named: 3, in: dir)
        do { _ = try await ToolchainReleases.install(mislabeled, with: packager); XCTFail("hätte scheitern müssen") }
        catch { XCTAssertEqual(error as? PackageError, .contentMismatch) }

        // Eine bearbeitete Kopie ist kein Paket des Projekts.
        let marked = try package(manifest(3, modified: true), in: dir)
        do { _ = try await ToolchainReleases.install(marked, with: packager); XCTFail("hätte scheitern müssen") }
        catch { XCTAssertEqual(error as? PackageError, .contentMismatch) }
        XCTAssertEqual(packager.installed().map { $0.version() }, [4, 2])
    }

    // MARK: Erneuern

    func testRenewalBuildsWithTheChosenToolchainAndLeavesAModifiedBuildAlone() throws {
        let dir = temp()
        let packager = ToolchainPackager(root: dir.appendingPathComponent("toolchains"))
        let second = try install(2, in: packager)
        let newest = try install(4, in: packager)
        func app(_ build: String) -> InstalledApp { InstalledApp(bundleIdentifier: "x.moss", name: "Moss", version: "1.0", bundleVersion: build) }
        func chosen(_ choices: ToolchainChoices, installed: String = "7.2", recipe r: Recipe? = nil) -> (toolchain: Toolchain?, why: String?) {
            var why: String?
            let t = Renewal.chosenToolchain(for: r ?? recipe(), app: app(installed), newest: newest, choices: choices, packager: packager,
                                            skip: { why = $0 })
            return (t, why)
        }
        // Ohne Wahl die neueste.
        XCTAssertEqual(chosen(ToolchainChoices()).toolchain?.version(), 4)
        // Mit Wahl die gewählte – das Erneuern tauscht den Bau nicht gegen einen aus einem anderen Stand.
        var choices = ToolchainChoices()
        choices.choose(packager.pin(for: second), for: "moss")
        XCTAssertEqual(chosen(choices).toolchain?.version(), 2)
        // Reicht die gewählte dem Rezept nicht, wird nicht gebaut.
        XCTAssertNil(chosen(choices, recipe: recipe(minCommit: "ccccccc")).toolchain)
        // Ist sie weg, wird nicht mit einer anderen gebaut, und der Grund steht da.
        try FileManager.default.removeItem(at: second.root)
        let gone = chosen(choices)
        XCTAssertNil(gone.toolchain)
        XCTAssertNotNil(gone.why)
        // Ein Bau aus einer bearbeiteten Kopie, die nicht gewählt ist, bleibt, wie er ist.
        let foreign = chosen(ToolchainChoices(), installed: "7.3.1")
        XCTAssertNil(foreign.toolchain)
        XCTAssertNotNil(foreign.why)
        // Ist die Kopie gewählt, wird mit ihr erneuert.
        let copy = try plant(manifest(3, modified: true), at: dir.appendingPathComponent("avpplay-fix/moss"))
        choices.choose(packager.pin(for: copy), for: "moss")
        XCTAssertEqual(chosen(choices, installed: "7.3.1").toolchain?.root.standardizedFileURL.path, copy.root.standardizedFileURL.path)
    }
}
