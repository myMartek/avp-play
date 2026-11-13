import XCTest
@testable import AVPPlayCore

final class CompanionAppTests: XCTestCase {
    func testLatestReleaseIsRead() throws {
        let data = Data(#"{"tag_name":"v1.2.0","html_url":"https://github.com/myMartek/avp-play-remote/releases/tag/v1.2.0","draft":false,"prerelease":false}"#.utf8)
        let release = try XCTUnwrap(CompanionApp.parseLatest(data))
        XCTAssertEqual(release.tag, "v1.2.0")
        XCTAssertEqual(release.version, "1.2.0")
        XCTAssertEqual(CompanionApp.sourceURL(tag: release.tag).absoluteString,
                       "https://codeload.github.com/myMartek/avp-play-remote/tar.gz/refs/tags/v1.2.0")
    }

    func testUnsafeOrUnfinishedReleasesAreRefused() {
        func parse(_ json: String) -> CompanionApp.Release? { CompanionApp.parseLatest(Data(json.utf8)) }
        XCTAssertNil(parse(#"{"tag_name":"../x"}"#))
        XCTAssertNil(parse(#"{"tag_name":"v1.0/../../x"}"#))
        XCTAssertNil(parse(#"{"tag_name":"nightly"}"#))
        XCTAssertNil(parse(#"{"tag_name":"v2.0.0","prerelease":true}"#))
        XCTAssertNil(parse(#"{"tag_name":"v2.0.0","draft":true}"#))
        XCTAssertNil(parse("not json"))
    }

    func testStateOnTheDevice() {
        let latest = CompanionApp.Release(tag: "v1.1.0", version: "1.1.0", page: nil)
        let bundle = CompanionApp.bundleId(prefix: "user.dev.klepton.target")
        XCTAssertEqual(bundle, "user.dev.klepton.target.avpplayremote")
        func app(_ version: String) -> InstalledApp {
            InstalledApp(bundleIdentifier: bundle, name: "AVP Play Remote", version: version, bundleVersion: "1", url: nil)
        }
        XCTAssertEqual(CompanionApp.state(apps: nil, bundleId: bundle, latest: latest), .unknown)
        XCTAssertEqual(CompanionApp.state(apps: [], bundleId: bundle, latest: latest), .notInstalled)
        XCTAssertEqual(CompanionApp.state(apps: [app("1.0.0")], bundleId: bundle, latest: latest), .updatable(installed: "1.0.0", latest: "1.1.0"))
        XCTAssertEqual(CompanionApp.state(apps: [app("1.1.0")], bundleId: bundle, latest: latest), .current(version: "1.1.0"))
        XCTAssertEqual(CompanionApp.state(apps: [app("1.0.0")], bundleId: bundle, latest: nil), .current(version: "1.0.0"))
    }

    func testJobRecipeIsValidAndKeepsTheTag() throws {
        let recipe = CompanionApp.recipe(release: CompanionApp.Release(tag: "v1.0.0", version: "1.0.0", page: nil))
        XCTAssertNoThrow(try recipe.validate())
        XCTAssertTrue(CompanionApp.isCompanion(recipe))
        XCTAssertEqual(recipe.versionName, "v1.0.0")
        XCTAssertNil(recipe.source)
        // Ein Auftrag damit lädt nicht nur: Er baut und installiert.
        let job = Job(recipe: recipe, request: InstallRequest(toolchain: ""), steps: [.fetch, .build], toolchainCommit: "")
        XCTAssertFalse(job.isDownloadOnly)
    }

    // MARK: Die Fassung mit „Auf dieser Brille“

    /// Ein Ordner, der wie eine Toolchain aussieht – mit oder ohne das Skript für die Laufzeit-Vorlage.
    private func toolchain(template: Bool, version: Int = 900, commit: String = "abc1234") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("companion-toolchain-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("visionos"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tools"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("visionos/run.sh"))
        try Data().write(to: root.appendingPathComponent("tools/klepton_ld.c"))
        if template { try Data().write(to: root.appendingPathComponent("visionos/mktemplate.sh")) }
        try Data(#"{"version": \#(version), "commit": "\#(commit)", "files": 1}"#.utf8).write(to: root.appendingPathComponent("toolchain.json"))
        return root
    }

    func testTheInstalledAppIsRebuiltWhenItCannotTakeTheHandover() throws {
        let bundle = "user.dev.klepton.target.avpplayremote"
        let root = try toolchain(template: true)
        let stamp = CompanionApp.toolchainStamp(try Toolchain(root: root))
        let plan = CompanionHandover.Plan(bundlePrefix: "user.dev.klepton.target", toolchain: root)
        func reason(_ variant: CompanionApp.Variant?, plan: CompanionHandover.Plan? = plan, free: Bool = false) -> String? {
            CompanionApp.rebuildReason(variant: variant, bundleId: bundle, handover: plan, freeTeam: free)
        }
        // Übergabe aus, kostenloses Team oder eine Toolchain ohne Vorlage: nichts zu tun.
        XCTAssertNil(reason(nil, plan: nil))
        XCTAssertNil(reason(nil, free: true))
        XCTAssertNil(reason(nil, plan: .init(bundlePrefix: "user.dev.klepton.target", toolchain: try toolchain(template: false))))
        // Noch nie von hier gebaut, ohne den Teil gebaut, oder für eine andere Kennung.
        XCTAssertNotNil(reason(nil))
        XCTAssertNotNil(reason(.init(bundleId: bundle, tag: "v1.2.0", standalone: false)))
        XCTAssertNotNil(reason(.init(bundleId: "other.avpplayremote", tag: "v1.2.0", standalone: true, toolchain: stamp)))
        // Für eine andere Toolchain gebaut: Der Satz nennt beide.
        let other = try XCTUnwrap(reason(.init(bundleId: bundle, tag: "v1.2.0", standalone: true, toolchain: "899-0000000")))
        XCTAssertTrue(other.contains("899-0000000") && other.contains(stamp))
        // Passt alles: nichts zu tun.
        XCTAssertNil(reason(.init(bundleId: bundle, tag: "v1.2.0", standalone: true, toolchain: stamp)))
    }

    func testTheLibrariesOfAReleaseAreNamedSafely() throws {
        func parse(_ json: String) -> CompanionApp.Libraries? { try? JSONDecoder().decode(CompanionApp.Libraries.self, from: Data(json.utf8)) }
        let sum = String(repeating: "ab", count: 32)
        let good = try XCTUnwrap(parse(#"{"asset": "avp-play-remote-headset-libs-1.2.0.zip", "sha256": "\#(sum)", "idevice": "x"}"#))
        XCTAssertTrue(good.isSane)
        XCTAssertEqual(CompanionApp.librariesURL(tag: "v1.2.0", asset: good.asset).absoluteString,
                       "https://github.com/myMartek/avp-play-remote/releases/download/v1.2.0/avp-play-remote-headset-libs-1.2.0.zip")
        XCTAssertEqual(parse(#"{"asset": "../x.zip", "sha256": "\#(sum)"}"#)?.isSane, false)
        XCTAssertEqual(parse(#"{"asset": "libs.tar", "sha256": "\#(sum)"}"#)?.isSane, false)
        XCTAssertEqual(parse(#"{"asset": "libs.zip", "sha256": "short"}"#)?.isSane, false)
    }

    func testTheHeadsetVariantIsBuiltOnlyWhenEverythingForItIsThere() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("companion-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let release = CompanionApp.Release(tag: "v1.2.0", version: "1.2.0", page: nil)
        let source = directory.appendingPathComponent("source-v1.2.0/avp-play-remote-1.2.0", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("AVPPlayRemote.xcodeproj"), withIntermediateDirectories: true)
        func installer(_ plan: CompanionHandover.Plan?, team: String = "ABCDE12345") -> CompanionInstaller {
            var request = InstallRequest(toolchain: "")
            request.team = team
            request.handover = plan
            return CompanionInstaller(recipe: CompanionApp.recipe(release: release), request: request, directory: directory, report: { _ in })
        }
        let root = try toolchain(template: true)
        let plan = CompanionHandover.Plan(bundlePrefix: "user.dev.klepton.target", toolchain: root)
        // Ohne Übergabe: die einfache Fassung, und kein Wort dazu.
        XCTAssertNil(installer(nil).standaloneToolchain().toolchain)
        XCTAssertNil(installer(nil).standaloneToolchain().why)
        // Der Quellcode hat den Teil nicht: die einfache Fassung, mit Grund.
        XCTAssertNil(installer(plan).standaloneToolchain().toolchain)
        XCTAssertNotNil(installer(plan).standaloneToolchain().why)
        // Mit Projekt und Angabe der Bibliotheken: die Fassung mit dem Teil.
        try FileManager.default.createDirectory(at: source.appendingPathComponent("AVPPlayRemoteStandalone.xcodeproj"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Standalone/Vendor"), withIntermediateDirectories: true)
        try Data(#"{"asset": "libs.zip", "sha256": "\#(String(repeating: "0", count: 64))"}"#.utf8).write(to: source.appendingPathComponent("Standalone/Vendor/libs.json"))
        XCTAssertEqual(installer(plan).standaloneToolchain().toolchain?.root.standardizedFileURL, root.standardizedFileURL)
        // Eine Toolchain ohne Vorlage: die einfache Fassung, mit Grund.
        let old = CompanionHandover.Plan(bundlePrefix: "user.dev.klepton.target", toolchain: try toolchain(template: false))
        XCTAssertNil(installer(old).standaloneToolchain().toolchain)
        XCTAssertNotNil(installer(old).standaloneToolchain().why)
    }

    func testAHandoverToAnAppBuiltHereNeedsNoMarker() throws {
        var copied: [String] = []
        let secrets = HandoverSecrets(appleKeyService: "avpplay-test-absent-\(UUID().uuidString)")
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("companion-cache-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: cache) }
        try CompanionHandover.deliver(.init(bundlePrefix: "user.dev.klepton.target"), cache: cache, trusted: true, secrets: secrets,
                                      tokens: TokenStore(service: "avpplay-test-absent"), list: { _ in [] },
                                      copy: { _, destination in copied.append(destination) }, report: { _ in })
        XCTAssertEqual(copied, ["Documents/handover/handover.json"])
    }
}
