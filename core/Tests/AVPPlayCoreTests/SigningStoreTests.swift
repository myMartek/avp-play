import XCTest
@testable import AVPPlayCore

/// Signaturen je Kennung: Eine Testkopie neben dem Spiel lässt dessen Eintrag in Ruhe, und Einträge von vor der
/// Ablage je Kennung gelten weiter als die der eigentlichen Installation.
final class SigningStoreTests: XCTestCase {
    var dir: URL!
    var store: ContentStore!
    let recipe = RecipeTests().recipe(files: [])
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("qi-signing-\(UUID().uuidString)", isDirectory: true)
        store = ContentStore(root: dir)
        try FileManager.default.createDirectory(at: store.directory(for: recipe), withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testEachIdentifierHasItsOwnFile() throws {
        let url = try XCTUnwrap(SigningRecord.url(store: store, recipe: recipe, bundleId: "com.example.games.demo"))
        XCTAssertEqual(url.lastPathComponent, "com.example.games.demo.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, ".signing")
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent(), store.directory(for: recipe))
        XCTAssertNil(SigningRecord.url(store: store, recipe: recipe, bundleId: "../evil"))
        XCTAssertNil(SigningRecord.url(store: store, recipe: recipe, bundleId: "a/b"))
        XCTAssertNil(SigningRecord.url(store: store, recipe: recipe, bundleId: ""))
    }

    /// Ein Eintrag von vor der Ablage je Kennung: gilt als der der eigentlichen Installation und wird – ohne ihn
    /// anzufassen – auch unter seiner Kennung abgelegt.
    func testLegacyRecordIsLiveAndMigratedWithoutTouchingIt() throws {
        let legacy = #"{"bundleId":"com.example.games.demo","expires":"2026-10-18T10:00:00Z","free":false,"installed":"2026-10-11T10:00:00Z","team":"A1B2C3D4E5"}"#
        let legacyURL = SigningRecord.url(store: store, recipe: recipe)
        try Data(legacy.utf8).write(to: legacyURL)

        let live = try XCTUnwrap(SigningRecord.load(store: store, recipe: recipe))
        XCTAssertEqual(live.bundleId, "com.example.games.demo")
        XCTAssertEqual(try String(contentsOf: legacyURL, encoding: .utf8), legacy)
        let migrated = try XCTUnwrap(SigningRecord.url(store: store, recipe: recipe, bundleId: "com.example.games.demo"))
        XCTAssertEqual(SigningRecord.read(migrated), live)
        XCTAssertEqual(SigningRecord.load(store: store, recipe: recipe, bundleId: "com.example.games.demo"), live)
        XCTAssertEqual(SigningRecord.load(store: store, recipe: recipe, bundleId: nil), live)
        XCTAssertNil(SigningRecord.load(store: store, recipe: recipe, bundleId: "com.example.test.demo"))
    }

    /// Ein ganz alter Eintrag ohne Kennung: gilt für die Kennung, unter der ein Team dieser Art üblicherweise installiert.
    func testLegacyRecordWithoutIdentifierResolvesToTheUsualOne() throws {
        let legacy = #"{"expires":"2026-10-18T10:00:00Z","free":true,"installed":"2026-10-11T10:00:00Z","team":"Z9Y8X7W6V5"}"#
        try Data(legacy.utf8).write(to: SigningRecord.url(store: store, recipe: recipe))
        let usual = Toolchain.bundleId(target: "demo", prefix: Toolchain.defaultBundlePrefix(freeTeam: "Z9Y8X7W6V5"))
        let live = try XCTUnwrap(SigningRecord.load(store: store, recipe: recipe))
        XCTAssertNil(live.bundleId)
        XCTAssertEqual(live.resolvedBundleId(target: "demo"), usual)
        let migrated = try XCTUnwrap(SigningRecord.url(store: store, recipe: recipe, bundleId: usual).flatMap(SigningRecord.read))
        XCTAssertEqual(migrated.bundleId, usual)
        XCTAssertEqual(migrated.team, "Z9Y8X7W6V5")
        let paid = SigningRecord(team: "A1B2C3D4E5", free: false, installed: now, expires: nil)
        XCTAssertEqual(paid.resolvedBundleId(target: "demo"), Toolchain.defaultBundleId(target: "demo"))
    }

    /// Die Migration überschreibt keinen Eintrag, der unter der Kennung schon liegt.
    func testMigrationKeepsAnExistingPerIdentifierRecord() throws {
        let bundle = "com.example.games.demo"
        var newer = SigningRecord(team: "A1B2C3D4E5", free: false, installed: now, expires: now.addingTimeInterval(86_400), bundleId: bundle)
        newer.renewalNote = "kept"
        try newer.write(to: try XCTUnwrap(SigningRecord.url(store: store, recipe: recipe, bundleId: bundle)))
        try SigningRecord(team: "A1B2C3D4E5", free: false, installed: now.addingTimeInterval(-86_400), expires: now, bundleId: bundle)
            .write(to: SigningRecord.url(store: store, recipe: recipe))
        _ = SigningRecord.load(store: store, recipe: recipe)
        XCTAssertEqual(SigningRecord.load(store: store, recipe: recipe, bundleId: bundle)?.renewalNote, "kept")
    }

    /// Eine Testkopie unter eigener Kennung bekommt ihren Eintrag; der der eigentlichen Installation bleibt.
    func testTestCopyDoesNotReplaceTheLiveRecord() throws {
        let live = SigningRecord(team: "A1B2C3D4E5", free: false, installed: now, expires: now.addingTimeInterval(365 * 86_400),
                                 bundleId: "com.example.games.demo")
        // Wie eine Installation aus der App: ausdrücklich die eigentliche (die Kennung ist nicht die übliche).
        live.save(store: store, recipe: recipe, live: true)
        var test = SigningRecord(team: "A1B2C3D4E5", free: false, installed: now.addingTimeInterval(60), expires: now.addingTimeInterval(7 * 86_400),
                                 bundleId: "com.example.test.demo")
        test.displaySuffix = " (Test)"
        test.save(store: store, recipe: recipe)

        XCTAssertEqual(SigningRecord.load(store: store, recipe: recipe), live)
        XCTAssertEqual(SigningRecord.load(store: store, recipe: recipe, bundleId: "com.example.games.demo"), live)
        XCTAssertEqual(SigningRecord.load(store: store, recipe: recipe, bundleId: "com.example.test.demo"), test)

        // Dieselbe Kennung wie die eigentliche Installation: beide Einträge werden fortgeschrieben.
        var renewed = live
        renewed.installed = now.addingTimeInterval(3600)
        renewed.save(store: store, recipe: recipe)
        XCTAssertEqual(SigningRecord.load(store: store, recipe: recipe), renewed)
        XCTAssertEqual(SigningRecord.load(store: store, recipe: recipe, bundleId: "com.example.games.demo"), renewed)

        // Ausdrücklich als eigentliche Installation (etwa nach einem neuen Präfix in der App).
        test.save(store: store, recipe: recipe, live: true)
        XCTAssertEqual(SigningRecord.load(store: store, recipe: recipe), test)
        XCTAssertEqual(SigningRecord.load(store: store, recipe: recipe, bundleId: "com.example.games.demo"), renewed)
    }

    /// Gibt es noch keinen Eintrag der eigentlichen Installation, wird der erste es – auch ohne Kennung.
    func testFirstRecordBecomesLive() throws {
        let record = SigningRecord(team: "Z9Y8X7W6V5", free: true, installed: now, expires: now)
        record.save(store: store, recipe: recipe)
        XCTAssertEqual(SigningRecord.load(store: store, recipe: recipe), record)
        let usual = record.resolvedBundleId(target: "demo")
        XCTAssertEqual(SigningRecord.load(store: store, recipe: recipe, bundleId: usual)?.bundleId, usual)
    }

    func testNotLiveLeavesTheLiveRecordAlone() {
        let record = SigningRecord(team: "A1B2C3D4E5", free: false, installed: now, expires: now, bundleId: "com.example.games.demo")
        record.save(store: store, recipe: recipe, live: false)
        XCTAssertNil(SigningRecord.load(store: store, recipe: recipe))
        XCTAssertEqual(SigningRecord.load(store: store, recipe: recipe, bundleId: "com.example.games.demo"), record)
    }

    /// Gibt es noch keinen Eintrag der eigentlichen Installation, wird eine Testkopie unter eigener Kennung es nicht –
    /// eine Installation unter der üblichen Kennung (auch ausdrücklich genannt) dagegen schon.
    func testTestCopyDoesNotBecomeLiveWithoutLiveRecord() throws {
        let usual = Toolchain.defaultBundleId(target: "demo")
        let test = SigningRecord(team: "A1B2C3D4E5", free: false, installed: now, expires: now, bundleId: "\(usual)-test")
        test.save(store: store, recipe: recipe)
        XCTAssertNil(SigningRecord.load(store: store, recipe: recipe))
        XCTAssertEqual(SigningRecord.load(store: store, recipe: recipe, bundleId: "\(usual)-test"), test)

        let real = SigningRecord(team: "A1B2C3D4E5", free: false, installed: now.addingTimeInterval(60), expires: now, bundleId: usual)
        real.save(store: store, recipe: recipe)
        XCTAssertEqual(SigningRecord.load(store: store, recipe: recipe), real)

        // Ein kostenloses Team: üblich ist die Kennung mit seinem eigenen Präfix.
        let free = SigningRecord(team: "Z9Y8X7W6V5", free: true, installed: now, expires: now)
        let freeUsual = free.resolvedBundleId(target: "demo")
        var freeExplicit = free
        freeExplicit.bundleId = freeUsual
        XCTAssertTrue(freeExplicit.isLive(current: nil, target: "demo"))
        freeExplicit.bundleId = "\(freeUsual)-test"
        XCTAssertFalse(freeExplicit.isLive(current: nil, target: "demo"))
        // Erneuern und Installationen aus der App sagen es ausdrücklich: dann gilt es immer.
        freeExplicit.save(store: store, recipe: recipe, live: true)
        XCTAssertEqual(SigningRecord.load(store: store, recipe: recipe), freeExplicit)
    }

    /// Hat eine ältere Fassung dieses Programms nur `.signing.json` fortgeschrieben, ist der Eintrag unter der Kennung
    /// veraltet: Es gilt der jüngere, und die Kopie wird aufgefrischt.
    func testNewerLegacyRecordWinsAndRefreshesTheCopy() throws {
        let bundle = "com.example.games.demo"
        var old = SigningRecord(team: "A1B2C3D4E5", free: false, installed: now, expires: now, bundleId: bundle)
        old.renewalNote = "stale"
        let ownURL = try XCTUnwrap(SigningRecord.url(store: store, recipe: recipe, bundleId: bundle))
        try old.write(to: ownURL)
        let legacy = SigningRecord(team: "A1B2C3D4E5", free: false, installed: now.addingTimeInterval(86_400),
                                   expires: now.addingTimeInterval(7 * 86_400), bundleId: bundle)
        try legacy.write(to: SigningRecord.url(store: store, recipe: recipe))

        XCTAssertEqual(SigningRecord.load(store: store, recipe: recipe, bundleId: bundle), legacy)
        XCTAssertEqual(SigningRecord.read(ownURL), legacy)
        // Ist der Eintrag unter der Kennung der jüngere, bleibt er.
        var newer = legacy
        newer.installed = now.addingTimeInterval(2 * 86_400)
        try newer.write(to: ownURL)
        XCTAssertEqual(SigningRecord.load(store: store, recipe: recipe, bundleId: bundle), newer)
        XCTAssertEqual(SigningRecord.read(ownURL), newer)
        // Auch das Laden ohne Kennung frischt die Kopie nur auf, wenn sie älter ist.
        _ = SigningRecord.load(store: store, recipe: recipe)
        XCTAssertEqual(SigningRecord.read(ownURL), newer)
    }

    /// Lässt sich ein Eintrag nicht schreiben, geht der Grund an `note`, statt verschluckt zu werden.
    func testWriteFailuresAreReported() throws {
        let bundle = "com.example.games.demo"
        // Wo der Ordner `.signing` liegen müsste, liegt eine Datei: Weder die Migration noch `save` können schreiben.
        try Data().write(to: store.directory(for: recipe).appendingPathComponent(".signing"))
        var notes: [String] = []
        let before = SigningRecord.note
        SigningRecord.note = { notes.append($0) }
        defer { SigningRecord.note = before }

        try SigningRecord(team: "A1B2C3D4E5", free: false, installed: now, expires: now, bundleId: bundle)
            .write(to: SigningRecord.url(store: store, recipe: recipe))
        XCTAssertNotNil(SigningRecord.load(store: store, recipe: recipe))
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes.first?.contains("\(bundle).json") == true, notes.first ?? "")

        SigningRecord(team: "A1B2C3D4E5", free: false, installed: now, expires: now, bundleId: bundle).save(store: store, recipe: recipe)
        XCTAssertEqual(notes.count, 2)
    }

    func testDisplayOverrideEnvironment() {
        XCTAssertEqual(Toolchain.displayEnvironment(name: nil, suffix: nil), [:])
        XCTAssertEqual(Toolchain.displayEnvironment(name: "", suffix: ""), [:])
        XCTAssertEqual(Toolchain.displayEnvironment(name: "  ", suffix: nil), [:])
        XCTAssertEqual(Toolchain.displayEnvironment(name: "Moss Beta", suffix: nil), ["KLEPTON_DISPLAY_OVERRIDE": "Moss Beta"])
        XCTAssertEqual(Toolchain.displayEnvironment(name: nil, suffix: " (Test)"), ["KLEPTON_DISPLAY_SUFFIX": " (Test)"])
        XCTAssertEqual(Toolchain.displayEnvironment(name: "Moss", suffix: " (Test)"),
                       ["KLEPTON_DISPLAY_OVERRIDE": "Moss", "KLEPTON_DISPLAY_SUFFIX": " (Test)"])
        XCTAssertTrue(Toolchain.isValidDisplayText(" (Test)"))
        XCTAssertFalse(Toolchain.isValidDisplayText("a\nb"))
        XCTAssertFalse(Toolchain.isValidDisplayText(String(repeating: "x", count: 61)))
    }

    /// Ältere Aufträge ohne die neuen Angaben werden weiter gelesen.
    func testOlderInstallRequestsStillDecode() throws {
        let old = #"{"account":"default","locales":[],"optionalNames":[],"addons":true,"toolchain":"/tmp/t","storeArt":true,"interval":0}"#
        let request = try JSONDecoder().decode(InstallRequest.self, from: Data(old.utf8))
        XCTAssertNil(request.displayName)
        XCTAssertNil(request.displaySuffix)
        XCTAssertNil(request.live)
    }
}
