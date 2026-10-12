import XCTest
@testable import AVPPlayCore

final class AppleTeamsTests: XCTestCase {
    func testPaidTeamsComeFirstAndFreeTeamsAreMarked() {
        let defaults: [String: Any] = ["IDEProvisioningTeamByIdentifier": [
            "account-1": [["teamID": "Z9Y8X7W6V5", "teamName": "Jane Appleseed (Personal Team)", "isFreeProvisioningTeam": true],
                          ["teamID": "A1B2C3D4E5", "teamName": "Jane Appleseed", "isFreeProvisioningTeam": false]],
            "account-2": [["teamID": "A1B2C3D4E5", "teamName": "Jane Appleseed", "isFreeProvisioningTeam": false]],
        ]]
        XCTAssertEqual(AppleTeams.parse(defaults), [
            AppleTeam(id: "A1B2C3D4E5", name: "Jane Appleseed", free: false),
            AppleTeam(id: "Z9Y8X7W6V5", name: "Jane Appleseed (Personal Team)", free: true),
        ])
    }

    func testNoTeamsWhenXcodeKnowsNone() {
        XCTAssertEqual(AppleTeams.parse([:]), [])
        XCTAssertEqual(AppleTeams.parse(["IDEProvisioningTeamByIdentifier": [String: Any]()]), [])
    }

    func testAnEntryWithoutTheFlagCountsAsPaid() {
        let defaults: [String: Any] = ["IDEProvisioningTeamByIdentifier": ["a": [["teamID": "A1B2C3D4E5"]]]]
        XCTAssertEqual(AppleTeams.parse(defaults), [AppleTeam(id: "A1B2C3D4E5", name: "A1B2C3D4E5", free: false)])
    }

    func testExpiryIsReadFromADecodedProfile() throws {
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let data = try PropertyListSerialization.data(fromPropertyList: ["ExpirationDate": when, "TeamName": "x"], format: .xml, options: 0)
        XCTAssertEqual(SigningRecord.expiry(inDecodedProfile: data), when)
        XCTAssertNil(SigningRecord.expiry(inDecodedProfile: Data("not a plist".utf8)))
    }

    func testSigningIdentitiesAreTheTeamsValidOnesNewestFirst() {
        let a = String(repeating: "A", count: 40), b = String(repeating: "B", count: 40), c = String(repeating: "C", count: 40)
        let valid = "  1) \(a) \"Apple Development: Jane (AAAAAAAAAA)\"\n  2) \(b) \"Apple Development: Jane (BBBBBBBBBB)\"\n     2 valid identities found\n"
        func cert(_ sha: String, _ body: String) -> String {
            "SHA-256 hash: 00\nSHA-1 hash: \(sha)\n-----BEGIN CERTIFICATE-----\n\(body)\n-----END CERTIFICATE-----\n"
        }
        let certificates = cert(a, "old") + cert(b, "new") + cert(c, "other-team")
        let subjects = ["old": "subject=CN=x,OU=TEAM123456,O=Jane\nnotBefore=Sep 28 10:00:00 2026 GMT\n",
                        "new": "subject=CN=x,OU=TEAM123456,O=Jane\nnotBefore=Oct  7 16:00:00 2026 GMT\n",
                        "other-team": "subject=CN=x,OU=OTHER12345,O=Jane\nnotBefore=Oct  8 16:00:00 2026 GMT\n"]
        let found = SigningWarmUp.identities(team: "TEAM123456", validIdentities: valid, certificates: certificates) { pem in
            subjects.first { pem.contains("\n\($0.key)\n") }?.value ?? ""
        }
        XCTAssertEqual(found, [b, a])
        XCTAssertEqual(SigningWarmUp.identities(team: "NOBODY1234", validIdentities: valid, certificates: certificates) { _ in "" }, [])
    }

    func testAFreeTeamGetsItsOwnBundlePrefix() {
        XCTAssertEqual(Toolchain.defaultBundlePrefix(user: "Jane"), "jane.dev.klepton.target")
        XCTAssertEqual(Toolchain.defaultBundlePrefix(user: "Jane", freeTeam: "Z9Y8X7W6V5"), "jane.z9y8x7w6v5.dev.klepton.target")
        XCTAssertEqual(Toolchain.defaultBundlePrefix(user: "Jane", freeTeam: ""), "jane.dev.klepton.target")
    }

    /// The toolchain builds the identifier in Python (`re.sub(r"[^A-Za-z0-9-]", "-", user).strip("-").lower()`) and
    /// this library has to arrive at the same string, or it looks for an app the toolchain installed under
    /// another name (issue 10: a user name with an underscore).
    func testTheBundleScopeIsTheToolchains() {
        for (user, scope) in [("marc_intosh", "marc-intosh"), ("Jane", "jane"), ("john.doe", "john-doe"),
                              ("_x_", "x"), ("müller", "m-ller"), ("a b", "a-b"), ("r2-d2", "r2-d2"), ("___", "")] {
            XCTAssertEqual(Toolchain.bundleScope(user: user), scope, user)
        }
        XCTAssertEqual(Toolchain.defaultBundleId(target: "moss", user: "marc_intosh"), "marc-intosh.dev.klepton.target.moss")
        XCTAssertEqual(Toolchain.defaultBundlePrefix(user: "marc_intosh", freeTeam: "Z9Y8X7W6V5"), "marc-intosh.z9y8x7w6v5.dev.klepton.target")
        XCTAssertEqual(Toolchain.defaultBundleId(target: "moss", user: "___"), "dev.klepton.target.moss")
    }

    func testAFreeInstallRemindsTwoDaysBeforeAndAPaidOneThirty() {
        let expires = Date(timeIntervalSince1970: 1_800_000_000)
        let free = SigningRecord(team: "Z9Y8X7W6V5", free: true, installed: expires.addingTimeInterval(-7 * 86_400), expires: expires)
        let paid = SigningRecord(team: "A1B2C3D4E5", free: false, installed: expires.addingTimeInterval(-365 * 86_400), expires: expires)
        XCTAssertEqual(free.remindFrom, expires.addingTimeInterval(-2 * 86_400))
        XCTAssertEqual(paid.remindFrom, expires.addingTimeInterval(-30 * 86_400))
        XCTAssertNil(SigningRecord(team: "A1B2C3D4E5", free: false, installed: expires, expires: nil).remindFrom)
    }
}
