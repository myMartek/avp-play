import XCTest
@testable import AVPPlayCore

/// Die Steam-Spiele mit Android-Fassung: was aus SteamCMDs Ausgaben gelesen wird, und wie aus einem Depot ein
/// Entwurf entsteht.
final class SteamLibraryTests: XCTestCase {
    /// Gekürzte Ausgabe von `licenses_print`, in der Form des Werkzeugs.
    private let licences = """
    Logging in using cached credentials.
    License packageID 0:
     - State   : Active (flags 0x200) - Purchased : Fri Oct 10 16:43:20 2003 in "", Complimentary
     - Apps\t: 5, 7, 8, 90, ... (196 in total)
     - Depots : 0, 1, ... (300 in total)
    License packageID 12345:
     - State   : Active (flags 0x0) - Purchased : Mon Jan 1 10:00:00 2024 in "DE", Wallet
     - Apps\t: 885000,  (1 in total)
    License packageID 999:
     - State   : Expired (flags 0x0) - Purchased : Mon Jan 1 10:00:00 2024 in "DE", Wallet
     - Apps\t: 111111,  (1 in total)
    """

    func testLicencesNameActiveAppsAndShortenedPackages() {
        let read = SteamLibraryRead.licensed(licences)
        XCTAssertEqual(read.apps, ["5", "7", "8", "90", "885000"])
        XCTAssertEqual(read.truncated, ["0"])
    }

    func testPackageAppsComeFromAppIds() {
        let output = """
        PackageID : 8664, change number : 26253459/26253459
        "8664"
        {
        \t"packageid"\t\t"8664"
        \t"appids"
        \t{
        \t\t"0"\t\t"3900"
        \t\t"1"\t\t"3910"
        \t}
        }
        """
        XCTAssertEqual(SteamLibraryRead.packageApps(SteamKeyValues.blocks(output, header: "PackageID")), ["3900", "3910"])
    }

    /// App-Daten in der Form von `app_info_print`: ein Spiel mit Android-Depot, Zusatzinhalt und Windows-Depot, ein
    /// Spiel nur für Windows und ein Zusatzinhalt.
    private let appInfo = """
    AppID : 885000, change number : 39880928/0, last change : Sat Oct 17 14:16:53 2026
    "885000"
    {
    \t"common"
    \t{
    \t\t"name"\t\t"Synth \\"Riders\\""
    \t\t"type"\t\t"Game"
    \t\t"oslist"\t\t"windows,android"
    \t}
    \t"config"
    \t{
    \t\t"launch"
    \t\t{
    \t\t\t"0"
    \t\t\t{
    \t\t\t\t"executable"\t\t"SynthRiders.exe"
    \t\t\t\t"config"
    \t\t\t\t{
    \t\t\t\t\t"oslist"\t\t"windows"
    \t\t\t\t}
    \t\t\t}
    \t\t\t"1"
    \t\t\t{
    \t\t\t\t"executable"\t\t"SynthRidersFrame.apk"
    \t\t\t\t"config"
    \t\t\t\t{
    \t\t\t\t\t"oslist"\t\t"android"
    \t\t\t\t}
    \t\t\t}
    \t\t}
    \t}
    \t"depots"
    \t{
    \t\t"885001"
    \t\t{
    \t\t\t"config"
    \t\t\t{
    \t\t\t\t"oslist"\t\t"windows"
    \t\t\t}
    \t\t\t"manifests"
    \t\t\t{
    \t\t\t\t"public"
    \t\t\t\t{
    \t\t\t\t\t"gid"\t\t"111"
    \t\t\t\t\t"size"\t\t"5"
    \t\t\t\t}
    \t\t\t}
    \t\t}
    \t\t"885002"
    \t\t{
    \t\t\t"config"
    \t\t\t{
    \t\t\t\t"oslist"\t\t"android"
    \t\t\t}
    \t\t\t"manifests"
    \t\t\t{
    \t\t\t\t"public"
    \t\t\t\t{
    \t\t\t\t\t"gid"\t\t"4910607680297335048"
    \t\t\t\t\t"size"\t\t"763448501"
    \t\t\t\t}
    \t\t\t}
    \t\t}
    \t\t"885009"
    \t\t{
    \t\t\t"config"
    \t\t\t{
    \t\t\t\t"oslist"\t\t"android"
    \t\t\t}
    \t\t\t"dlcappid"\t\t"885010"
    \t\t\t"manifests"
    \t\t\t{
    \t\t\t\t"public"
    \t\t\t\t{
    \t\t\t\t\t"gid"\t\t"222"
    \t\t\t\t}
    \t\t\t}
    \t\t}
    \t\t"branches"
    \t\t{
    \t\t\t"public"
    \t\t\t{
    \t\t\t\t"buildid"\t\t"1"
    \t\t\t}
    \t\t}
    \t}
    }
    AppID : 620980, change number : 1/0, last change : Thu Oct 15 19:17:21 2026
    "620980"
    {
    \t"common"
    \t{
    \t\t"name"\t\t"Beat Saber"
    \t\t"type"\t\t"Game"
    \t}
    \t"depots"
    \t{
    \t\t"620981"
    \t\t{
    \t\t\t"config"
    \t\t\t{
    \t\t\t\t"oslist"\t\t"windows"
    \t\t\t}
    \t\t}
    \t}
    }
    AppID : 885010, change number : 1/0, last change : Thu Oct 15 19:17:21 2026
    "885010"
    {
    \t"common"
    \t{
    \t\t"name"\t\t"Synth Riders – DLC"
    \t\t"type"\t\t"DLC"
    \t}
    }
    """

    func testOnlyGamesWithAnOwnAndroidDepotAreKept() {
        let apps = SteamLibraryRead.androidApps(SteamKeyValues.blocks(appInfo, header: "AppID"))
        XCTAssertEqual(apps, [SteamAndroidApp(appId: "885000", name: "Synth \"Riders\"",
                                              depots: [.init(id: "885002", manifest: "4910607680297335048", bytes: 763_448_501)],
                                              apks: ["SynthRidersFrame.apk"])])
        XCTAssertEqual(apps.first?.bytes, 763_448_501)
    }

    func testDepotWithoutPublicVersionIsLeftOut() {
        let noManifest = appInfo.replacingOccurrences(of: "\"4910607680297335048\"", with: "\"not a number\"")
        XCTAssertEqual(SteamLibraryRead.androidApps(SteamKeyValues.blocks(noManifest, header: "AppID")), [])
    }

    private let app = SteamAndroidApp(appId: "2059670", name: "Moss II VR",
                                      depots: [.init(id: "2059672", manifest: "8991431504875240653", bytes: 5_157_251_648)],
                                      apks: ["Moss2-arm64.apk", "Moss2-Android-Test-arm64.apk", "Moss2-Android-Shipping-arm64.apk"])

    func testApkIsTheShippingOneFromTheLaunchOptions() {
        let files = [SteamDraft.DepotFile(path: "Moss2-Android-Test-arm64.apk", size: 1),
                     SteamDraft.DepotFile(path: "Moss2-Android-Shipping-arm64.apk", size: 2)]
        XCTAssertEqual(SteamDraft.apk(in: files, launch: app.apks)?.name, "Moss2-Android-Shipping-arm64.apk")
        // Ohne passende Startoption: das einzige APK im Depot, sonst keins.
        XCTAssertEqual(SteamDraft.apk(in: [.init(path: "game.apk", size: 1)], launch: [])?.name, "game.apk")
        XCTAssertNil(SteamDraft.apk(in: files, launch: []))
    }

    func testFilesArePlacedLikeOnAQuest() {
        let pkg = "com.polyarc.Moss2"
        XCTAssertEqual(SteamDraft.placement(of: .init(path: "main.1.com.polyarc.Moss2.obb", size: 1), package: pkg).role, "main-obb")
        XCTAssertEqual(SteamDraft.placement(of: .init(path: "main.1.com.polyarc.Moss2.obb", size: 1), package: pkg).dest, DraftRecipe.obbPlaceholder)
        XCTAssertEqual(SteamDraft.placement(of: .init(path: "Android/obb/com.polyarc.Moss2/patch.1.obb", size: 1), package: pkg).dest,
                       "android-files/Android/obb/com.polyarc.Moss2")
        XCTAssertEqual(SteamDraft.placement(of: .init(path: "bundles/a.bundle", size: 1), package: pkg).dest,
                       "android-files/Android/obb/com.polyarc.Moss2/bundles")
        XCTAssertEqual(SteamDraft.placement(of: .init(path: "a.bundle", size: 1), package: pkg).dest, "android-files/Android/obb/com.polyarc.Moss2")
    }

    func testDraftCarriesChecksumsAndTheSteamSource() throws {
        let files = [SteamDraft.DepotFile(path: "Moss2-Android-Shipping-arm64.apk", size: 200),
                     SteamDraft.DepotFile(path: "Moss2-Android-Test-arm64.apk", size: 100),
                     SteamDraft.DepotFile(path: "main.42.com.polyarc.Moss2.obb", size: 300)]
        let recipe = try SteamDraft.make(app: app, files: files, package: "com.polyarc.Moss2", versionCode: 42, versionName: "1.0",
                                         target: "x2059670", minCommit: "") { String(repeating: "a", count: 63) + String($0.size % 10) }
        XCTAssertEqual(recipe.id, "steam-2059670")
        XCTAssertEqual(recipe.source, .steam)
        XCTAssertEqual(recipe.store.steamAppId, "2059670")
        XCTAssertEqual(recipe.files.map(\.role), ["apk", "main-obb"], "die Testfassung des APKs gehört nicht dazu")
        XCTAssertEqual(recipe.files[0].localName, "x2059670.apk")
        XCTAssertEqual(recipe.files.map(\.size), [200, 300])
        XCTAssertTrue(recipe.files.allSatisfy { $0.sha256 != nil && $0.source?.steam?.depots.first?.manifest == "8991431504875240653" })
        XCTAssertEqual(SteamDraft.appId(of: recipe.id), "2059670")
        XCTAssertNil(SteamDraft.appId(of: "store-2059670"))
    }

    func testDraftRefusesTwoFilesOfTheSameName() {
        let files = [SteamDraft.DepotFile(path: "Moss2-arm64.apk", size: 1),
                     SteamDraft.DepotFile(path: "a/data.bin", size: 1), SteamDraft.DepotFile(path: "b/data.bin", size: 1)]
        XCTAssertThrowsError(try SteamDraft.make(app: app, files: files, package: "p", versionCode: 1, versionName: "", target: "x2059670",
                                                 minCommit: "") { _ in String(repeating: "b", count: 64) }) { error in
            XCTAssertEqual(error as? SteamDraftError, .duplicateName("data.bin"))
        }
        XCTAssertThrowsError(try SteamDraft.make(app: app, files: [.init(path: "readme.txt", size: 1)], package: "p", versionCode: 1,
                                                 versionName: "", target: "x2059670", minCommit: "") { _ in "" }) { error in
            XCTAssertEqual(error as? SteamDraftError, .noApk)
        }
    }

    func testPlaceholderIsASteamGameWithoutFiles() {
        let placeholder = SteamDraft.placeholder(app: app)
        XCTAssertEqual(placeholder.id, "steam-2059670")
        XCTAssertEqual(placeholder.source, .steam)
        XCTAssertTrue(placeholder.files.isEmpty)
        XCTAssertEqual(OwnershipCache.key(for: placeholder), "steam:2059670")
    }

    func testListingSkipsSteamsOwnFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qi-depot-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Android/obb/p"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("game.apk"))
        try Data("1".utf8).write(to: dir.appendingPathComponent("steam_appid.txt"))
        try Data("yy".utf8).write(to: dir.appendingPathComponent("Android/obb/p/main.1.p.obb"))
        let listed = SteamDraft.listFiles(in: [dir]).map(\.file).sorted { $0.path < $1.path }
        XCTAssertEqual(listed, [.init(path: "Android/obb/p/main.1.p.obb", size: 2), .init(path: "game.apk", size: 1)])
    }

    func testLibraryCacheGoesStaleAfterADay() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qi-steamlib-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let cache = SteamLibraryCache(store: ContentStore(root: dir))
        XCTAssertNil(cache.load())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let library = SteamLibrary(checked: now, apps: [app])
        try cache.save(library)
        XCTAssertEqual(cache.load(), library)
        XCTAssertFalse(library.isStale(now: now.addingTimeInterval(3600)))
        XCTAssertTrue(library.isStale(now: now.addingTimeInterval(25 * 3600)))
        cache.clear()
        XCTAssertNil(cache.load())
    }
}
