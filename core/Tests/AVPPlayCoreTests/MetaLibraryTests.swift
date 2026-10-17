import XCTest
@testable import AVPPlayCore

/// Die Bibliothek des Meta-Kontos für den Filter „Im Besitz“: wie eine Seite der Antwort gelesen wird, und der
/// Zwischenspeicher im Bestand.
final class MetaLibraryTests: XCTestCase {
    /// Eine Seite in der Form, in der Meta sie schickt (gekürzt, Namen erfunden).
    private func page(_ edges: String, next: String?) -> Data {
        let info = next.map { "{\"end_cursor\":\"\($0)\",\"has_next_page\":true}" } ?? "{\"end_cursor\":null,\"has_next_page\":false}"
        return Data("""
        {"data":{"node":{"__typename":"User","id":"123456789012345","app_entitlements":{"edges":[\(edges)],"page_info":\(info)}}},
         "extensions":{"is_final":true}}
        """.utf8)
    }

    private func edge(_ id: String, _ name: String, grant: String? = "PAID_OFFER") -> String {
        let entitlement = grant.map { ",\"entitlement\":{\"grant_reason\":\"\($0)\",\"id\":\"1:\(id)\"}" } ?? ""
        return """
        {"node":{"__typename":"Entitlement","id":"1:\(id)","item":{"__typename":"Application","id":"\(id)",
         "icon_image":{"uri":"https://scontent.oculuscdn.com/x.png"},"display_name":"\(name)"\(entitlement)}},"cursor":"AQH"}
        """
    }

    func testPageIsReadWithItsNextMark() throws {
        let data = page([edge("1180401875303371", "Wrath"), edge("1654565391314903", "Moss", grant: "PLATFORM_SUBSCRIPTION"),
                         edge("1916519981771802", "Browser", grant: nil)].joined(separator: ","), next: "AQHT22DX-VqC_Fiw0=")
        let read = try XCTUnwrap(MetaClient.libraryPage(inAnswer: data))
        XCTAssertEqual(read.apps, [LibraryApp(appId: "1180401875303371", title: "Wrath", grant: "PAID_OFFER"),
                                   LibraryApp(appId: "1654565391314903", title: "Moss", grant: "PLATFORM_SUBSCRIPTION"),
                                   LibraryApp(appId: "1916519981771802", title: "Browser", grant: nil)])
        XCTAssertEqual(read.next, "AQHT22DX-VqC_Fiw0=")
    }

    func testLastPageHasNoNextMark() throws {
        let read = try XCTUnwrap(MetaClient.libraryPage(inAnswer: page(edge("1180401875303371", "Wrath"), next: nil)))
        XCTAssertEqual(read.apps.count, 1)
        XCTAssertNil(read.next)
        XCTAssertEqual(MetaClient.libraryPage(inAnswer: page("", next: nil))?.apps, [])
    }

    func testEntriesWithoutAProperIdAreLeftOutAndOddReasonsDropped() throws {
        let odd = """
        {"node":{"item":{"id":"../1","display_name":"Evil"}}},{"node":{"item":null}},{"node":{"item":{"display_name":"No id"}}},
        """ + edge("1180401875303371", "Wrath", grant: "paid offer; drop")
        let read = try XCTUnwrap(MetaClient.libraryPage(inAnswer: page(odd, next: nil)))
        XCTAssertEqual(read.apps, [LibraryApp(appId: "1180401875303371", title: "Wrath", grant: nil)])
    }

    func testUnexpectedAnswersAreNotAList() {
        XCTAssertNil(MetaClient.libraryPage(inAnswer: Data("{\"errors\":[{\"message\":\"x\"}]}".utf8)))
        XCTAssertNil(MetaClient.libraryPage(inAnswer: Data("{\"data\":{\"node\":null}}".utf8)))
        XCTAssertNil(MetaClient.libraryPage(inAnswer: Data("{\"data\":{\"node\":{\"app_entitlements\":{\"edges\":[]}}}}".utf8)))
        XCTAssertNil(MetaClient.libraryPage(inAnswer: Data("not json".utf8)))
        // Eine Folgeseite, deren Marke nicht nach Meta aussieht, wird nicht verfolgt.
        XCTAssertNil(MetaClient.libraryPage(inAnswer: page(edge("1180401875303371", "Wrath"), next: "a b")))
        XCTAssertNil(MetaClient.libraryPage(inAnswer: page(edge("1180401875303371", "Wrath"), next: "")))
        XCTAssertNil(MetaClient.libraryPage(inAnswer: page(edge("1180401875303371", "Wrath"), next: "x&access_token=y")))
    }

    func testCacheKeepsTheLibraryAndGoesStaleAfterAnHour() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qi-lib-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let cache = MetaLibraryCache(store: ContentStore(root: dir))
        XCTAssertNil(cache.load())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let library = MetaLibrary(checked: now, apps: [LibraryApp(appId: "1180401875303371", title: "Wrath", grant: "PAID_OFFER")])
        try cache.save(library)
        XCTAssertEqual(cache.load(), library)
        XCTAssertEqual(cache.load()?.appIds, ["1180401875303371"])
        XCTAssertFalse(library.isStale(now: now.addingTimeInterval(1800)))
        XCTAssertTrue(library.isStale(now: now.addingTimeInterval(3700)))
        XCTAssertTrue(library.isStale(now: now.addingTimeInterval(-60)), "eine Zeit in der Zukunft gilt als alt")
        cache.clear()
        XCTAssertNil(cache.load())
    }
}
