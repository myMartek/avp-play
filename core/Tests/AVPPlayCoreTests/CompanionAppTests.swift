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
}
