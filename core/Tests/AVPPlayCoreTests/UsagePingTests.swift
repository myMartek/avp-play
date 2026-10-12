import XCTest
@testable import AVPPlayCore

final class UsagePingTests: XCTestCase {
    func at(_ day: String, hour: Int = 12) -> Date { UsagePing.date(ofDay: day)!.addingTimeInterval(Double(hour) * 3600) }

    func testAPingSaysOnlyWhetherItIsTheFirstOfItsDayWeekAndMonth() {
        // Sonntag, 11. Oktober 2026.
        let now = at("2026-10-11")
        XCTAssertEqual(UsagePing.day(now), "2026-10-11")
        XCTAssertEqual(UsagePing.due(last: nil, now: now, appVersion: "1.0.16"), UsagePing(appVersion: "1.0.16", first: true, week: true, month: true))
        XCTAssertEqual(UsagePing.due(last: "kaputt", now: now, appVersion: "1")?.first, true)
        XCTAssertNil(UsagePing.due(last: "2026-10-11", now: now, appVersion: "1"))
        XCTAssertNil(UsagePing.due(last: "2026-10-11", now: at("2026-10-11", hour: 23), appVersion: "1"))
        // Die Woche beginnt am Montag: Samstag und Montag davor gehören dazu, der Sonntag davor nicht.
        XCTAssertEqual(UsagePing.due(last: "2026-10-10", now: now, appVersion: "1"), UsagePing(appVersion: "1", first: false, week: false, month: false))
        XCTAssertEqual(UsagePing.due(last: "2026-10-05", now: now, appVersion: "1")?.week, false)
        XCTAssertEqual(UsagePing.due(last: "2026-10-04", now: now, appVersion: "1"), UsagePing(appVersion: "1", first: false, week: true, month: false))
        // Eine Woche über den Monatswechsel: neuer Monat, dieselbe Woche.
        XCTAssertEqual(UsagePing.due(last: "2026-09-29", now: at("2026-10-01"), appVersion: "1"), UsagePing(appVersion: "1", first: false, week: false, month: true))
        XCTAssertEqual(UsagePing.due(last: "2025-10-11", now: now, appVersion: "1"), UsagePing(appVersion: "1", first: false, week: true, month: true))
    }

    func testAPingCarriesNothingElse() throws {
        let sent = try JSONSerialization.jsonObject(with: JSONEncoder().encode(UsagePing(appVersion: "1.0.16", first: false, week: true, month: false))) as? [String: Any]
        XCTAssertEqual(sent?.keys.sorted(), ["appVersion", "first", "month", "week"])
    }

    func testGamesAreCountedByStoreNumberOrRecipeName() {
        XCTAssertEqual(UsagePing.gameKey(appId: "1654565391314903", recipe: "moss"), "1654565391314903")
        XCTAssertEqual(UsagePing.gameKey(appId: nil, recipe: "alyx"), "alyx")
        XCTAssertEqual(UsagePing.gameKey(appId: nil, recipe: "doom3quest"), "doom3quest")
        XCTAssertNil(UsagePing.gameKey(appId: "12", recipe: "moss"))
        XCTAssertNil(UsagePing.gameKey(appId: nil, recipe: "Mein Spiel"))
        XCTAssertNil(UsagePing.gameKey(appId: nil, recipe: "3d"))
    }
}
