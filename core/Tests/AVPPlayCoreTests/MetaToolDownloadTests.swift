import XCTest
@testable import AVPPlayCore

/// Der Ausweg über Metas Werkzeug, wenn die direkte Adresse eine Datei mit HTTP 404 verweigert – hier mit einem
/// nachgemachten Werkzeug, das sich an Argumente und Ablageform des echten hält.
final class MetaToolDownloadTests: XCTestCase {
    private let token = String(repeating: "FRLabc123", count: 6)
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tool-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// Ein Werkzeug, das die Argumente festhält und dann `body` ausführt; `$OUT` ist der Ordner nach `-d`.
    private func tool(_ body: String) throws -> URL {
        let url = dir.appendingPathComponent("ovr-platform-util")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(dir.path)/args"
        OUT=""
        while [ $# -gt 0 ]; do [ "$1" = "-d" ] && OUT="$2"; shift; done
        \(body)
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testBuildDownloadLandsAndIsFound() async throws {
        let fake = try tool("""
        mkdir -p "$OUT/main.1149.com.meta.curio.toybox.obb"
        printf apk > "$OUT/CurioAPK-20603176502.patched.apk"
        printf obb > "$OUT/main.1149.com.meta.curio.toybox.obb/main.1149.com.meta.curio.toybox.obb"
        for i in $(seq 1 3000); do echo '{"message":"progress line that fills the pipe"}'; done
        exit 0
        """)
        let target = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try await MetaToolDownload(tool: fake, token: token).fetch(.build("25603160476013000"), into: target)

        let args = try String(contentsOf: dir.appendingPathComponent("args"), encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(args.prefix(3)), ["download-quest-build", "-b", "25603160476013000"])
        XCTAssertTrue(args.contains(target.path))
        let apk = try XCTUnwrap(MetaToolDownload.find("CurioAPK-20603176502.patched.apk", in: target))
        XCTAssertEqual(try String(contentsOf: apk, encoding: .utf8), "apk")
        // Das Haupt-OBB liegt in einem Unterordner gleichen Namens; gefunden wird die Datei, nicht der Ordner.
        let obb = try XCTUnwrap(MetaToolDownload.find("main.1149.com.meta.curio.toybox.obb", in: target))
        XCTAssertEqual(try String(contentsOf: obb, encoding: .utf8), "obb")
        XCTAssertNil(MetaToolDownload.find("other.obb", in: target))
        // Das Protokoll des Werkzeugs bleibt nicht liegen.
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(".tool-tmp").path))
    }

    func testAssetUsesItsOwnId() async throws {
        let fake = try tool("exit 0")
        try await MetaToolDownload(tool: fake, token: token).fetch(.asset("8904417192929387"), into: dir)
        let args = try String(contentsOf: dir.appendingPathComponent("args"), encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(args.prefix(3)), ["download-asset-file", "--asset-file-id", "8904417192929387"])
    }

    func testRefusalCarriesTheToolsReasonWithoutToken() async throws {
        let fake = try tool("""
        echo '{"message":"Not entitled to download (token \(token))"}'
        echo '{"message":"Logs are written to /tmp/x"}'
        exit 1
        """)
        do {
            try await MetaToolDownload(tool: fake, token: token).fetch(.build("25603160476013000"), into: dir)
            XCTFail("should fail")
        } catch let error as ToolDownloadError {
            guard case .refused(let why) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.hasPrefix("Not entitled to download"), why)
            XCTAssertFalse(why.contains(token))
            XCTAssertEqual(FailureKind.of(error), .download)
        }
    }

    func testRejectsIdsThatAreNotIdentifiers() async throws {
        let fake = try tool("exit 0")
        do {
            try await MetaToolDownload(tool: fake, token: token).fetch(.build("12; rm -rf /"), into: dir)
            XCTFail("should fail")
        } catch let error as ToolDownloadError {
            XCTAssertEqual(error, .refused("–"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("args").path))
    }
}

/// Die Dateiliste aus Metas Build-Details, wenn das Werkzeug dem Konto „Cannot find …“ antwortet.
final class BinaryDetailsTests: XCTestCase {
    private func answer(_ node: String) -> Data { Data("{\"data\":{\"node\":\(node)}}".utf8) }

    func testReadsApkObbAndAssets() {
        let data = answer("""
        {"id":"8904428142928292","file_name":"Wrath2-Android-Shipping-arm64.apk","size":"96788480","uri":"https://x",
         "obb_binary":{"id":"8904427186261721","file_name":"main.5513.com.Sanzaru.Wrath2.obb","size":"4600000000"},
         "asset_files":{"nodes":[{"id":"8904423199595453","file_name":"patch.pakchunk27-Android_ASTC.com.Sanzaru.Wrath2.obb","size":"3"},
                                 {"id":"8904423199595453","file_name":"patch.pakchunk27-Android_ASTC.com.Sanzaru.Wrath2.obb","size":"3"},
                                 {"id":"nope","file_name":"bad.obb"}]}}
        """)
        let files = MetaClient.files(inBinaryDetails: data, buildId: "8904428142928292")
        XCTAssertEqual(files.map(\.kind), ["APK", "OBB", "ASSET"])
        XCTAssertEqual(files.map(\.id), ["8904428142928292", "8904427186261721", "8904423199595453"])
        XCTAssertEqual(files[0].name, "Wrath2-Android-Shipping-arm64.apk")
        // Daraus entsteht ein Entwurf wie aus der Liste des Werkzeugs.
        let game = CatalogGame(appId: "2603836099654226", title: "Wrath", package: "com.Sanzaru.Wrath2", publisher: nil, status: "untested",
                               noteEn: nil, noteDe: nil, target: nil, works: 0, problems: 0, fails: 0, build: nil)
        let build = CatalogBuild(buildId: "8904428142928292", version: "1", versionCode: 5513, fileName: nil)
        let recipe = try? DraftRecipe.make(game: game, build: build, files: files, target: "x2603836099654226", minCommit: "")
        XCTAssertEqual(recipe?.files.map(\.role), ["apk", "main-obb", "content-bundle"])
    }

    func testEdgesAndApkOnly() {
        let edges = answer("""
        {"id":"25603160476013000","file_name":"CurioAPK-20603176502.patched.apk","size":325900000,
         "asset_files":{"edges":[{"node":{"id":"1234567890123","file_name":"extra.bundle","size":"10"}}]}}
        """)
        XCTAssertEqual(MetaClient.files(inBinaryDetails: edges, buildId: "25603160476013000").map(\.kind), ["APK", "ASSET"])
    }

    func testUnexpectedAnswersGiveNothing() {
        XCTAssertEqual(MetaClient.files(inBinaryDetails: answer("{\"id\":\"111111\",\"file_name\":\"a.apk\"}"), buildId: "222222"), [])
        XCTAssertEqual(MetaClient.files(inBinaryDetails: answer("null"), buildId: "222222"), [])
        XCTAssertEqual(MetaClient.files(inBinaryDetails: Data("{\"errors\":[]}".utf8), buildId: "222222"), [])
        XCTAssertEqual(MetaClient.files(inBinaryDetails: answer("{\"id\":\"222222\",\"file_name\":\"../evil.apk\"}"), buildId: "222222"), [])
    }

    func testOnlyCannotFindCountsAsNotFound() {
        XCTAssertTrue(MetaListing.isNotFound(ListingError.refused("❌ ERROR:\nCannot find apk with ID: 27614884714838255")))
        XCTAssertFalse(MetaListing.isNotFound(ListingError.refused("Not entitled to download")))
        XCTAssertFalse(MetaListing.isNotFound(ListingError.nothingListed))
    }
}

final class MegabytesTests: XCTestCase {
    func testDownloadSizesReadAsMegabytes() {
        XCTAssertEqual(Installer.megabytes(0), "0.0 MB")
        XCTAssertEqual(Installer.megabytes(1_695), "< 0.1 MB")
        XCTAssertEqual(Installer.megabytes(7_027_867), "7.0 MB")
        XCTAssertEqual(Installer.megabytes(43_406_683), "43.4 MB")
        XCTAssertEqual(Installer.megabytes(325_900_000), "326 MB")
        XCTAssertEqual(Installer.megabytes(4_600_000_000), "4600 MB")
    }
}

/// Der Build des Kontos als Ausweg, wenn Metas Werkzeug den Build eines Entwurfs mit „Not entitled“ ablehnt
/// (HITMAN 3 VR: Reloaded: Katalog 3645, Konto 3641).
final class AccountBuildTests: XCTestCase {
    private let appId = "8012387035448196"

    private func draft(versionCode: Int) throws -> Recipe {
        let game = CatalogGame(appId: appId, title: "HITMAN 3 VR: Reloaded", package: "com.xrgames.hitman3reloaded", publisher: nil,
                               status: "untested", noteEn: nil, noteDe: nil, target: nil, works: 0, problems: 0, fails: 0, build: nil)
        let build = CatalogBuild(buildId: "9179370045416550", version: "0.0.\(versionCode)", versionCode: versionCode, fileName: nil)
        let files = [ListedFile(name: "apps.engine-retail.apk", id: "9179370045416550", kind: "APK", sizeText: "1GB"),
                     ListedFile(name: "chunk7.rpkg", id: "9179368442083377", kind: "ASSET", sizeText: "1GB")]
        return try DraftRecipe.make(game: game, build: build, files: files, target: "x\(appId)", minCommit: "a459856")
    }

    private func build(_ code: Int, id: String) -> CatalogBuild {
        CatalogBuild(buildId: id, version: "0.0.\(code)", versionCode: code, fileName: nil)
    }

    func testOnlyTheToolsNotEntitledCounts() {
        XCTAssertTrue(AccountBuild.isNotEntitled(ToolDownloadError.refused("❌ ERROR:\nNot entitled to download")))
        XCTAssertFalse(AccountBuild.isNotEntitled(ToolDownloadError.refused("❌ ERROR:\nCannot find apk with ID: 1")))
        XCTAssertFalse(AccountBuild.isNotEntitled(ToolDownloadError.missingFile("a.apk")))
        XCTAssertFalse(AccountBuild.isNotEntitled(ListingError.refused("Not entitled to download")))
    }

    func testReplacementIsTheAccountsNewestWhenTheDraftsBuildIsNotOffered() throws {
        let recipe = try draft(versionCode: 3645)
        let account = [build(3641, id: "9100000000000001"), build(3600, id: "9100000000000002")]
        XCTAssertEqual(AccountBuild.replacement(for: recipe, accountBuilds: account)?.versionCode, 3641)
        // Steht die Fassung des Entwurfs in Metas Liste, hilft ein anderer Build nicht.
        XCTAssertNil(AccountBuild.replacement(for: recipe, accountBuilds: [build(3645, id: "9100000000000003")] + account))
        XCTAssertNil(AccountBuild.replacement(for: recipe, accountBuilds: []))
        // Kein Entwurf (ein Rezept des Projekts): nie.
        var tested = recipe
        tested.id = "hitman3"
        XCTAssertNil(AccountBuild.replacement(for: tested, accountBuilds: account))
    }

    func testRedraftKeepsGameAndToolchainAndTakesTheNewFiles() throws {
        let old = try draft(versionCode: 3645)
        let files = [ListedFile(name: "apps.engine-retail.apk", id: "9100000000000001", kind: "APK", sizeText: "1GB"),
                     ListedFile(name: "chunk6.rpkg", id: "9100000000000009", kind: "ASSET", sizeText: "1GB")]
        let new = try DraftRecipe.forBuild(old, build: build(3641, id: "9100000000000001"), files: files)
        XCTAssertEqual(new.id, old.id)
        XCTAssertEqual(new.title, old.title)
        XCTAssertEqual(new.package, old.package)
        XCTAssertEqual(new.versionCode, 3641)
        XCTAssertEqual(new.toolchain.target, "x\(appId)")
        XCTAssertEqual(new.toolchain.minCommit, "a459856")
        XCTAssertEqual(new.files.map(\.id), ["9100000000000001", "9100000000000009"])
        XCTAssertEqual(new.files[1].dest, "android-files/Android/obb/com.xrgames.hitman3reloaded")
        XCTAssertEqual(new.status.download, "listed")
    }
}
