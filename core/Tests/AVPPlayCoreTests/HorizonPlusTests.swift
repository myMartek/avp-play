import XCTest
@testable import AVPPlayCore

/// Die Horizon+-Kataloge für den Filter „Horizon+“: wie eine Seite eines Store-Abschnitts gelesen wird, und der
/// Zwischenspeicher im Bestand.
final class HorizonPlusTests: XCTestCase {
    /// Eine Seite in der Form, in der Meta sie schickt (gekürzt).
    private func page(_ edges: String, section: String = "746836817401205") -> Data {
        Data("""
        {"data":{"node":{"__typename":"AppStoreCuratedSection","__isAppStoreSection":"AppStoreCuratedSection",
         "connection_units":{"__typename":"AppStoreSectionUnitsConnection","edges":[\(edges)]},"id":"\(section)"}},
         "extensions":{"is_final":true}}
        """.utf8)
    }

    private func edge(_ id: String, _ name: String) -> String {
        """
        {"__typename":"AppStoreSectionUnitsEdge","node":{"__typename":"Application","id":"\(id)","display_unit_title":"\(name)",
         "horizonPlusLabel":{"text":"Horizon+"}},"ranking_trace":"x","cursor":"\(id)"}
        """
    }

    func testPageIsReadWithTheLastEntryAsMark() throws {
        let read = try XCTUnwrap(MetaClient.sectionPage(inAnswer: page([edge("6341779295861881", "Dungeons Of Eternity"),
                                                                         edge("2462678267173943", "Walkabout Mini Golf")].joined(separator: ",")),
                                                         sectionId: "746836817401205"))
        XCTAssertEqual(read.games.map(\.appId), ["6341779295861881", "2462678267173943"])
        XCTAssertEqual(read.games.map(\.title), ["Dungeons Of Eternity", "Walkabout Mini Golf"])
        XCTAssertEqual(read.last, "2462678267173943")
    }

    func testEmptyPageIsTheEnd() throws {
        let read = try XCTUnwrap(MetaClient.sectionPage(inAnswer: page(""), sectionId: "746836817401205"))
        XCTAssertTrue(read.games.isEmpty)
        XCTAssertNil(read.last)
    }

    func testEntriesWithoutAProperIdAreLeftOut() throws {
        let odd = """
        {"node":{"id":"../1","display_unit_title":"Evil"},"cursor":"1"},{"node":null},
        """ + edge("6341779295861881", "Dungeons Of Eternity")
        let read = try XCTUnwrap(MetaClient.sectionPage(inAnswer: page(odd), sectionId: "746836817401205"))
        XCTAssertEqual(read.games.map(\.appId), ["6341779295861881"])
    }

    func testUnexpectedAnswersAreNotAList() {
        XCTAssertNil(MetaClient.sectionPage(inAnswer: Data("{\"errors\":[{\"message\":\"x\"}]}".utf8), sectionId: "746836817401205"))
        XCTAssertNil(MetaClient.sectionPage(inAnswer: Data("{\"data\":{\"node\":null}}".utf8), sectionId: "746836817401205"))
        // Ein anderer Abschnitt als der gefragte – oder ein Abschnitt ohne Liste – ist keine Antwort auf die Frage.
        XCTAssertNil(MetaClient.sectionPage(inAnswer: page(edge("6341779295861881", "x"), section: "999"), sectionId: "746836817401205"))
        XCTAssertNil(MetaClient.sectionPage(inAnswer: Data("{\"data\":{\"node\":{\"id\":\"746836817401205\",\"__typename\":\"Application\"}}}".utf8),
                                            sectionId: "746836817401205"))
        XCTAssertNil(MetaClient.sectionPage(inAnswer: Data("not json".utf8), sectionId: "746836817401205"))
    }

    func testBothCataloguesAreAsked() {
        XCTAssertEqual(MetaClient.horizonPlusSections.map(\.id), ["746836817401205", "3170833353093973"])
        XCTAssertEqual(MetaClient.horizonPlusSections.map(\.catalogue), [.games, .indie])
    }

    func testCacheKeepsTheCataloguesAndGoesStaleAfterADay() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qi-hplus-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let cache = HorizonPlusCache(store: ContentStore(root: dir))
        XCTAssertNil(cache.load())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let catalog = HorizonPlusCatalog(checked: now, games: [
            HorizonPlusGame(appId: "6341779295861881", title: "Dungeons Of Eternity", catalogue: .games),
            HorizonPlusGame(appId: "1234567890123456", title: "Indie", catalogue: .indie),
        ])
        try cache.save(catalog)
        XCTAssertEqual(cache.load(), catalog)
        XCTAssertEqual(catalog.appIds, ["6341779295861881", "1234567890123456"])
        XCTAssertEqual(catalog.catalogue(of: "1234567890123456"), .indie)
        XCTAssertNil(catalog.catalogue(of: "1"))
        XCTAssertFalse(catalog.isStale(now: now.addingTimeInterval(3600 * 20)))
        XCTAssertTrue(catalog.isStale(now: now.addingTimeInterval(3600 * 25)))
        XCTAssertTrue(catalog.isStale(now: now.addingTimeInterval(-60)), "eine Zeit in der Zukunft gilt als alt")
        cache.clear()
        XCTAssertNil(cache.load())
    }
}
