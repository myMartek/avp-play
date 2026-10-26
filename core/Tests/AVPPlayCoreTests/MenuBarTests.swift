import XCTest
@testable import AVPPlayCore

final class MenuBarTests: XCTestCase {
    override func setUp() { L10n.language = .en }
    override func tearDown() { L10n.language = .en }

    func testPreferencesDefaultKeepTodaysBehaviour() {
        let suite = "menubar-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = MenuBarPreferences.load(defaults: defaults)
        XCTAssertTrue(fresh.show)
        XCTAssertFalse(fresh.keepRunning)
        XCTAssertTrue(fresh.terminatesWithLastWindow, "Ohne Wahl endet das Programm mit seinem Fenster, wie bisher")

        MenuBarPreferences(show: true, keepRunning: true).save(defaults: defaults)
        let saved = MenuBarPreferences.load(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertTrue(saved.staysInMenuBar)
        XCTAssertFalse(saved.terminatesWithLastWindow)
    }

    func testKeepRunningNeedsTheIcon() {
        let hidden = MenuBarPreferences(show: false, keepRunning: true)
        XCTAssertFalse(hidden.staysInMenuBar, "Ohne Symbol wäre das laufende Programm unsichtbar")
        XCTAssertTrue(hidden.terminatesWithLastWindow)
    }

    func testRunningJobWithProgress() {
        let status = MenuBarStatus(job: .init(title: "Beat Saber", step: .stage, done: 1_000, total: 4_000),
                                   waiting: 2, failed: 0, deviceName: "Vision Pro", remote: .connected(1), renewal: nil)
        XCTAssertEqual(status.percent, 25)
        XCTAssertEqual(status.jobLine, "Beat Saber")
        XCTAssertEqual(status.jobDetail, "Copy data to the device · 25 % · 2 waiting")
        XCTAssertEqual(status.deviceLine, "Vision Pro connected")
        XCTAssertEqual(status.remoteLine, "Remote control: 1 headset connected")
        XCTAssertFalse(status.needsAttention)
        XCTAssertNil(status.renewalLine())
    }

    func testProgressWithoutSizeAndClamping() {
        var status = MenuBarStatus(job: .init(title: "Moss", step: .build), waiting: 0, failed: 0,
                                   deviceName: nil, remote: .off, renewal: nil)
        XCTAssertNil(status.percent)
        XCTAssertEqual(status.jobDetail, "Build and install")
        status.job = .init(title: "Moss", step: .fetch, done: 9, total: 4)
        XCTAssertEqual(status.percent, 100)
        status.job = .init(title: "Moss", step: .fetch, done: 9, total: 0)
        XCTAssertNil(status.percent)
    }

    func testIdleAndFailed() {
        var status = MenuBarStatus(job: nil, waiting: 0, failed: 0, deviceName: nil, remote: .waiting, renewal: nil)
        XCTAssertEqual(status.jobLine, "No job running")
        XCTAssertNil(status.jobDetail)
        XCTAssertEqual(status.deviceLine, "No Vision Pro reachable")
        XCTAssertEqual(status.remoteLine, "Remote control on, no headset connected")
        status.failed = 2
        XCTAssertTrue(status.needsAttention)
        XCTAssertEqual(status.jobLine, "2 jobs stopped with an error")
    }

    func testRenewalLine() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var status = MenuBarStatus(job: nil, waiting: 0, failed: 0, deviceName: nil, remote: .off,
                                   renewal: .init(inBackground: true, intervalHours: 6, lastRun: now, nextExpiry: now.addingTimeInterval(3 * 86_400 + 60)))
        XCTAssertEqual(status.renewalLine(now: now), "Renewed in the background every 6 h · next expiry in 3 days")
        status.renewal = .init(inBackground: false, intervalHours: 6, lastRun: nil, nextExpiry: now.addingTimeInterval(3_600))
        XCTAssertEqual(status.renewalLine(now: now), "Background renewal off · next expiry in less than a day")
        status.renewal = .init(inBackground: true, intervalHours: 12, lastRun: nil, nextExpiry: now.addingTimeInterval(-1))
        XCTAssertEqual(status.renewalLine(now: now), "Renewed in the background every 12 h · a game has expired")
    }

    func testGermanLines() {
        L10n.language = .de
        let status = MenuBarStatus(job: nil, waiting: 0, failed: 1, deviceName: "Vision Pro", remote: .connected(2), renewal: nil)
        XCTAssertEqual(status.jobLine, "1 Auftrag mit Fehler angehalten")
        XCTAssertEqual(status.remoteLine, "Fernsteuerung: 2 Headsets verbunden")
    }

    func testNextExpiryIsTheEarliest() {
        let a = Date(timeIntervalSince1970: 1_000), b = Date(timeIntervalSince1970: 2_000)
        let report = RenewalReport(ran: b, known: 3, outcomes: [
            RenewalOutcome(recipe: "x", title: "X", result: .renewed, detail: "", expires: b),
            RenewalOutcome(recipe: "y", title: "Y", result: .failed, detail: "", expires: a),
            RenewalOutcome(recipe: "z", title: "Z", result: .skipped, detail: "", expires: nil),
        ])
        XCTAssertEqual(MenuBarStatus.nextExpiry(in: report), a)
        XCTAssertNil(MenuBarStatus.nextExpiry(in: nil))
    }
}
