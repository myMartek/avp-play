import XCTest
@testable import AVPPlayCore

/// Was Apple ablehnt, wird am Wortlaut erkannt – und nichts anderes dafür gehalten.
final class AppleRefusalTests: XCTestCase {
    func testRefusalsAreRecognisedByTheirWording() {
        let said: [(String, AppleRefusal)] = [
            ("error: Unable to install \u{201C}Moss\u{201D}\nThe maximum number of apps for free development profiles has been reached.", .tooManyApps),
            ("ERROR: This device has reached the maximum number of installed apps using a free developer profile", .tooManyApps),
            // So steht es im Protokoll der Toolchain, die von der Ausgabe nur das Ende behält (am Gerät beobachtet).
            ("[4/5] installing…\n               LegacyErrorString = ApplicationVerificationFailed\n               LibMISErrorNumber = -402620383\n  install failed — once more in 5 s", .tooManyApps),
            ("!! install FAILED:                FunctionName = -[MIFreeProfileValidatedAppTracker _onQueue_addReferenceForApplicationIdentifier:bundle:error:]", .tooManyApps),
            ("error: Communication with Apple failed: Your maximum App ID limit has been reached. You may create up to 10 App IDs every 7 days.", .tooManyAppIds),
            // As xcodebuild printed it for the eleventh identifier of a free team within a week (Xcode 27.1, 2026-10-11):
            // two errors, and the one about the missing profile must not hide the reason for it.
            ("Klepton.xcodeproj: error: Communication with Apple failed. Your maximum App ID limit has been reached. You may create up to 10 App IDs every 7 days. (in target 'Klepton' from project 'Klepton')\nKlepton.xcodeproj: error: No profiles for 'me.team.dev.klepton.target.game' were found: Xcode couldn't find any iOS App Development provisioning profiles matching 'me.team.dev.klepton.target.game'. (in target 'Klepton' from project 'Klepton')\n** BUILD FAILED **", .tooManyAppIds),
            ("error: Personal development teams, including \"Jane Appleseed\", do not support the Extended Virtual Addressing capability.", .capability),
            ("error: Failed to register bundle identifier: The app identifier \"a.b.c\" cannot be registered to your development team because it is not available.", .identifierTaken),
            ("error: No Account for Team \"A1B2C3D4E5\". Add a new account in Accounts settings", .accountSession),
            ("xcodebuild: error: Unable to log in with account 'x'. Your session has expired. Please log in.", .accountSession),
            // As xcodebuild printed it for a user whose Xcode showed the account as signed in (2026-10-11): again two
            // errors, and the one about the missing profile comes last.
            ("Klepton.xcodeproj: error: No Accounts: Add a new account in Accounts settings. (in target 'Klepton' from project 'Klepton')\nKlepton.xcodeproj: error: No profiles for 'me.team.dev.klepton.target.game' were found: Xcode couldn't find any iOS App Development provisioning profiles matching 'me.team.dev.klepton.target.game'. (in target 'Klepton' from project 'Klepton')\n** BUILD FAILED **", .noAccount),
            ("The Apple Developer Program License Agreement has been updated and needs to be reviewed.", .agreement),
            ("Unable to launch because it has an invalid code signature, inadequate entitlements or its profile has not been explicitly trusted by the user.", .notTrusted),
            ("!! install FAILED: A valid provisioning profile for this executable was not found.", .profile),
            ("!! install FAILED: The device is locked.", .deviceLocked),
            ("!! install FAILED: There isn\u{2019}t enough space on the device.", .deviceFull),
            ("Your team has reached the maximum number of registered visionOS devices.", .tooManyDevices),
        ]
        for (text, want) in said { XCTAssertEqual(AppleMessages.refusal(in: "note: building\n\(text)\n** BUILD FAILED **"), want, text) }
    }

    func testAnOrdinaryBuildLogIsNotARefusal() {
        for text in ["** BUILD SUCCEEDED **", "error: no such module 'Foo'", "ld: symbol(s) not found for architecture arm64",
                     "No profiles for 'a.b.c' were found: Xcode couldn't find any visionOS App Development provisioning profiles matching 'a.b.c'.",
                     "warning: the app uses 3 devices", "No space left on device", "CodeSign /path/App.app (in target 'Game')"] {
            XCTAssertNil(AppleMessages.refusal(in: text), text)
        }
    }

    func testEveryRefusalHasAdviceInBothLanguages() {
        let before = L10n.language
        defer { L10n.language = before }
        for refusal in AppleRefusal.allCases {
            L10n.language = .en
            let english = AppleMessages.advice(refusal, free: true)
            L10n.language = .de
            let german = AppleMessages.advice(refusal, free: true)
            XCTAssertFalse(english.isEmpty)
            XCTAssertNotEqual(english, german, refusal.rawValue)
        }
        L10n.language = .de
        XCTAssertTrue(AppleMessages.advice(.tooManyApps, free: true).contains("3 Apps"))
        XCTAssertEqual(AppleMessages.freeAccountLimits().count, 5)
    }

    /// Eine Grenze des Kontos ist kein Baufehler: Der Auftrag sagt, dass es an Apple liegt.
    func testARefusalIsItsOwnKindOfFailure() {
        let log = URL(fileURLWithPath: "/tmp/x.log")
        XCTAssertEqual(FailureKind.of(ToolchainError.refused(.tooManyApps, free: true, log: log)), .apple)
        XCTAssertEqual(FailureKind.of(ToolchainError.refused(.tooManyAppIds, free: true, log: log)), .apple)
        XCTAssertEqual(FailureKind.of(ToolchainError.refused(.deviceLocked, free: false, log: log)), .device)
        XCTAssertEqual(FailureKind.of(InstallError.freeTeamFull("Moss", installed: ["A", "B", "C"])), .apple)
        XCTAssertTrue("\(InstallError.freeTeamFull("Moss", installed: ["A", "B", "C"]))".contains("A, B, C"))
    }
}

/// Die Grenze von drei Apps wird vorab geprüft, an dem, was das Gerät als installiert meldet.
final class FreeTeamLimitTests: XCTestCase {
    func app(_ id: String, _ name: String) -> InstalledApp { InstalledApp(bundleIdentifier: id, name: name, version: "1", bundleVersion: "1") }

    func testAFourthGameIsRefusedButAReinstallIsNot() {
        let prefix = "jane.z9y8x7w6v5.dev.klepton.target"
        let three = [app("\(prefix).moss", "Moss"), app("\(prefix).cs1", "Counter-Strike"), app("\(prefix).doom3quest", "Doom 3"),
                     app("jane.dev.klepton.target.batman", "Batman"), app("com.apple.Keynote", "Keynote")]
        XCTAssertEqual(Installer.freeTeamBlock(bundle: "\(prefix).walkabout", apps: three), ["Counter-Strike", "Doom 3", "Moss"])
        // Über eine bestehende Installation zu bauen braucht keinen neuen Platz.
        XCTAssertNil(Installer.freeTeamBlock(bundle: "\(prefix).moss", apps: three))
        XCTAssertNil(Installer.freeTeamBlock(bundle: "\(prefix).walkabout", apps: Array(three.dropFirst())))
        // Eine andere Kennung mit gleichem Anfang ist kein anderes Präfix.
        XCTAssertEqual(Installer.appsSharingPrefix(with: "\(prefix).x", in: three).count, 3)
        XCTAssertTrue(Installer.appsSharingPrefix(with: "ohnepunkt", in: three).isEmpty)
    }
}

final class RenewalTests: XCTestCase {
    let day: TimeInterval = 86_400

    func testAnInstallationIsDueFromTheReminderOn() {
        let installed = Date(timeIntervalSince1970: 1_800_000_000)
        let free = SigningRecord(team: "Z9Y8X7W6V5", free: true, installed: installed, expires: installed.addingTimeInterval(7 * day))
        XCTAssertFalse(Renewal.isDue(free, now: installed.addingTimeInterval(4.9 * day)))
        XCTAssertTrue(Renewal.isDue(free, now: installed.addingTimeInterval(5.1 * day)))
        XCTAssertTrue(Renewal.isDue(free, now: installed.addingTimeInterval(9 * day)))          // abgelaufen: erst recht
        let paid = SigningRecord(team: "A1B2C3D4E5", free: false, installed: installed, expires: installed.addingTimeInterval(365 * day))
        XCTAssertFalse(Renewal.isDue(paid, now: installed.addingTimeInterval(300 * day)))
        XCTAssertTrue(Renewal.isDue(paid, now: installed.addingTimeInterval(336 * day)))
        // Ohne bekanntes Ablaufdatum wird nicht auf Verdacht gebaut.
        XCTAssertFalse(Renewal.isDue(SigningRecord(team: "A1B2C3D4E5", free: true, installed: installed, expires: nil), now: installed.addingTimeInterval(30 * day)))
    }

    /// Hat ein Versuch nichts verlängert, baut nicht jede Prüfung dasselbe noch einmal.
    func testAFruitlessAttemptIsNotRepeatedAtOnce() {
        let installed = Date(timeIntervalSince1970: 1_800_000_000)
        var record = SigningRecord(team: "Z9Y8X7W6V5", free: true, installed: installed, expires: installed.addingTimeInterval(7 * day))
        let now = installed.addingTimeInterval(6 * day)
        record.renewalTried = now.addingTimeInterval(-3600)
        XCTAssertFalse(Renewal.isDue(record, now: now))
        record.renewalTried = now.addingTimeInterval(-Renewal.retryAfter - 60)
        XCTAssertTrue(Renewal.isDue(record, now: now))
    }

    /// Ein Eintrag aus der Zeit vor Kennung und Vermerk wird weiter gelesen.
    func testOlderSigningRecordsStillRead() throws {
        let old = #"{"expires":"2026-10-18T10:00:00Z","free":true,"installed":"2026-10-11T10:00:00Z","team":"Z9Y8X7W6V5"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(SigningRecord.self, from: Data(old.utf8))
        XCTAssertNil(record.bundleId)
        XCTAssertNil(record.renewalTried)
        XCTAssertTrue(record.free)
    }

    func testTheInstalledAppIsFoundUnderItsRememberedOrUsualIdentifier() {
        let helper = RecipeTests()
        let recipe = helper.recipe(files: [])
        func app(_ id: String) -> InstalledApp { InstalledApp(bundleIdentifier: id, name: "Demo", version: "1", bundleVersion: "1") }
        let now = Date()
        var record = SigningRecord(team: "Z9Y8X7W6V5", free: true, installed: now, expires: now, bundleId: "com.example.games.demo")
        XCTAssertEqual(Renewal.installedBundle(recipe: recipe, record: record, apps: [app("com.example.games.demo")]), "com.example.games.demo")
        record.bundleId = nil
        let usual = Toolchain.defaultBundleId(target: "demo")
        let free = Toolchain.bundleId(target: "demo", prefix: Toolchain.defaultBundlePrefix(freeTeam: "Z9Y8X7W6V5"))
        XCTAssertEqual(Renewal.installedBundle(recipe: recipe, record: record, apps: [app(free)]), free)
        // Die Kopie eines bezahlten Teams daneben ist nicht die gemeinte: Ihre Kennung gehört dem anderen Team.
        XCTAssertNil(Renewal.installedBundle(recipe: recipe, record: record, apps: [app(usual)]))
        let paid = SigningRecord(team: "A1B2C3D4E5", free: false, installed: now, expires: now)
        XCTAssertEqual(Renewal.installedBundle(recipe: recipe, record: paid, apps: [app(usual), app(free)]), usual)
        XCTAssertNil(Renewal.installedBundle(recipe: recipe, record: record, apps: [app("com.other.demo")]))
    }

    /// Ist nichts fällig, wird weder das Gerät gefragt noch gebaut – der Lauf endet sofort.
    func testNothingDueMeansNothingIsAsked() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qi-renew-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ContentStore(root: dir)
        let recipe = RecipeTests().recipe(files: [])
        try FileManager.default.createDirectory(at: store.directory(for: recipe), withIntermediateDirectories: true)
        let now = Date()
        SigningRecord(team: "Z9Y8X7W6V5", free: true, installed: now, expires: now.addingTimeInterval(6 * day)).save(store: store, recipe: recipe)
        let report = await Renewal.run(recipes: [recipe], store: store, toolchain: nil, now: now)
        XCTAssertEqual(report.known, 1)
        XCTAssertTrue(report.outcomes.isEmpty)
        // Fällig, aber ohne Toolchain: genannt, nicht versucht, und am Eintrag ändert sich nichts.
        let later = await Renewal.run(recipes: [recipe], store: store, toolchain: nil, now: now.addingTimeInterval(5 * day))
        XCTAssertEqual(later.outcomes.map(\.result), [.skipped])
        XCTAssertNil(SigningRecord.load(store: store, recipe: recipe)?.renewalTried)
        // Der Bericht übersteht das Speichern.
        let file = dir.appendingPathComponent("renewal.json")
        later.save(to: file)
        XCTAssertEqual(RenewalReport.load(from: file)?.outcomes.count, 1)
    }

    /// Vor dem Erneuern verschwindet das zwischengespeicherte Profil genau dieser App – und nur das: kein fremdes,
    /// kein von Hand angelegtes, und keines, das eben erst ausgestellt wurde.
    func testOnlyTheStaleManagedProfileOfThisAppIsRemoved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qi-prof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func profile(_ name: String, app: String, daysLeft: Double, managed: Bool = true) throws {
            let plist: [String: Any] = ["Entitlements": ["application-identifier": app], "ExpirationDate": now.addingTimeInterval(daysLeft * day),
                                        "IsXcodeManaged": managed]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: dir.appendingPathComponent(name))
        }
        let team = "Z9Y8X7W6V5", bundle = "jane.z9y8x7w6v5.dev.klepton.target.moss"
        try profile("mine-old.mobileprovision", app: "\(team).\(bundle)", daysLeft: 2)
        try profile("mine-fresh.mobileprovision", app: "\(team).\(bundle)", daysLeft: 6.9)
        try profile("mine-by-hand.mobileprovision", app: "\(team).\(bundle)", daysLeft: 2, managed: false)
        try profile("other-game.mobileprovision", app: "\(team).jane.z9y8x7w6v5.dev.klepton.target.batman", daysLeft: 2)
        try profile("other-team.mobileprovision", app: "A1B2C3D4E5.\(bundle)", daysLeft: 2)
        try profile("wildcard.mobileprovision", app: "\(team).*", daysLeft: 2)
        try Data("kein Profil".utf8).write(to: dir.appendingPathComponent("notiz.txt"))
        let plain: (URL) -> Data? = { try? Data(contentsOf: $0) }
        let removed = SigningProfiles.removeStale(team: team, bundleId: bundle, fresherThan: SigningProfiles.renewBelow(free: true), now: now,
                                                  directories: [dir, dir.appendingPathComponent("fehlt")], decode: plain)
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                       ["mine-by-hand.mobileprovision", "mine-fresh.mobileprovision", "notiz.txt", "other-game.mobileprovision",
                        "other-team.mobileprovision", "wildcard.mobileprovision"])
        // Ohne Team oder Kennung wird nichts angefasst.
        XCTAssertEqual(SigningProfiles.removeStale(team: "", bundleId: bundle, fresherThan: .infinity, now: now, directories: [dir], decode: plain), 0)
        XCTAssertEqual(SigningProfiles.removeStale(team: team, bundleId: "", fresherThan: .infinity, now: now, directories: [dir], decode: plain), 0)
        // Ein bezahltes Team: erst im letzten Monat.
        XCTAssertEqual(SigningProfiles.renewBelow(free: false), 30 * day)
    }

    func testTheLockIsHeldByOneAtATime() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("qi-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let first = try XCTUnwrap(ProcessLock.acquire(file))
        XCTAssertNil(ProcessLock.acquire(file))
        XCTAssertTrue(ProcessLock.isHeld(file))
        first.release()
        XCTAssertFalse(ProcessLock.isHeld(file))
        XCTAssertNotNil(ProcessLock.acquire(file))
    }

    func testTheBackgroundServiceIsDescribedForLaunchd() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qi-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let entry = BackgroundService.definition(program: "/Applications/AVP Play.app/Contents/MacOS/AVPPlay", hours: 6, log: dir.appendingPathComponent("r.log"))
        XCTAssertEqual(entry["Label"] as? String, "io.github.mymartek.avpplay.renew")
        XCTAssertEqual(entry["ProgramArguments"] as? [String], ["/Applications/AVP Play.app/Contents/MacOS/AVPPlay", "--renew"])
        XCTAssertEqual(entry["StartInterval"] as? Int, 21_600)
        XCTAssertEqual(entry["RunAtLoad"] as? Bool, false)
        XCTAssertEqual(BackgroundService.definition(program: "/x", hours: 0)["StartInterval"] as? Int, 3600)
        // Was eingetragen ist, lässt sich wieder lesen – ohne launchd zu fragen.
        let plist = dir.appendingPathComponent("agent.plist")
        try PropertyListSerialization.data(fromPropertyList: entry, format: .xml, options: 0).write(to: plist)
        let service = BackgroundService(plist: plist)
        XCTAssertEqual(service.installed()?.hours, 6)
        XCTAssertEqual(service.installed()?.program, "/Applications/AVP Play.app/Contents/MacOS/AVPPlay")
        XCTAssertNil(BackgroundService(plist: dir.appendingPathComponent("fehlt.plist")).installed())
        XCTAssertTrue(BackgroundService.intervals.contains(BackgroundService.defaultInterval))
    }
}

/// Laden geht, bevor irgendetwas anderes eingerichtet ist.
final class DownloadFirstTests: XCTestCase {
    func testADraftWithoutSizesStillHasSomethingToDownload() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qi-dl-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let helper = RecipeTests()
        let recipe = helper.recipe(files: [helper.file("game.apk", size: nil), helper.file("main.obb", size: nil), helper.file("lang.obb", required: false, size: nil)])
        let status = GameStatus.of(recipe: recipe, store: ContentStore(root: dir), apps: nil, toolchainVersion: nil)
        XCTAssertEqual(status.bytesToDownload, 0)
        XCTAssertEqual(status.filesToDownload, 2)
    }

    /// Ein Entwurf, der ohne Toolchain nachgeschlagen wurde, bekommt Namen und Mindeststand nachgetragen.
    func testADraftIsCompletedOnceTheToolchainIsKnown() throws {
        let game = CatalogGame(appId: "1234567890123456", title: "Demo", package: "com.example.demo", publisher: nil, status: "untested",
                               verifiedPending: nil, noteEn: nil, noteDe: nil, target: nil, works: 0, problems: 0, fails: 0, build: nil)
        let build = CatalogBuild(buildId: "9876543210987654", version: "1.2", versionCode: 12, fileName: nil)
        let files = [ListedFile(name: "demo.apk", id: "111", kind: "APK", sizeText: ""), ListedFile(name: "main.12.com.example.demo.obb", id: "222", kind: "OBB", sizeText: "")]
        let generic = DraftRecipe.genericTarget(appId: game.appId)
        let draft = try DraftRecipe.make(game: game, build: build, files: files, target: generic, minCommit: "")
        XCTAssertEqual(draft.toolchain.minCommit, "")
        let done = DraftRecipe.retargeted(draft, target: "demo", minCommit: "abc1234")
        XCTAssertEqual(done.toolchain.target, "demo")
        XCTAssertEqual(done.toolchain.minCommit, "abc1234")
        XCTAssertEqual(done.files.first { $0.role == "apk" }?.localName, "demo.apk")
        XCTAssertEqual(done.files.map(\.name), draft.files.map(\.name))
        XCTAssertEqual(done.files.map(\.id), draft.files.map(\.id))
        try done.validate()
    }
}
