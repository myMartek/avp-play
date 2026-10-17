import XCTest
@testable import AVPPlayCore

final class CustomFiltersTests: XCTestCase {
    let bit32 = CustomFilter(id: "a", name: "32 Bit", games: ["beatsaber", "store-1"])
    let guests = CustomFilter(id: "b", name: "Für Gäste", games: ["beatsaber", "moss"])

    func testOnlyAndHideNarrowDown() {
        let filters = [bit32, guests]
        // Ohne gesetzten Filter kommt alles durch.
        XCTAssertTrue(CustomFilters.passes("moss", filters: filters, modes: [:]))
        // „Nur diese“: nur Spiele des Filters.
        XCTAssertTrue(CustomFilters.passes("store-1", filters: filters, modes: ["a": .only]))
        XCTAssertFalse(CustomFilters.passes("moss", filters: filters, modes: ["a": .only]))
        // „Ausblenden“: alles außer den Spielen des Filters – etwa Favoriten ohne die 32-Bit-Spiele.
        XCTAssertTrue(CustomFilters.passes("moss", filters: filters, modes: ["a": .hide]))
        XCTAssertFalse(CustomFilters.passes("beatsaber", filters: filters, modes: ["a": .hide]))
        // Mehrere zugleich engen weiter ein.
        XCTAssertTrue(CustomFilters.passes("moss", filters: filters, modes: ["a": .hide, "b": .only]))
        XCTAssertFalse(CustomFilters.passes("beatsaber", filters: filters, modes: ["a": .hide, "b": .only]))
        XCTAssertFalse(CustomFilters.passes("store-1", filters: filters, modes: ["a": .only, "b": .only]))
        XCTAssertTrue(CustomFilters.passes("beatsaber", filters: filters, modes: ["a": .only, "b": .only]))
        // „Aus“ zählt nicht, und die Wirkung eines gelöschten Filters auch nicht.
        XCTAssertTrue(CustomFilters.passes("moss", filters: filters, modes: ["a": .off, "gone": .only]))
    }

    func testNames() {
        let filters = [bit32, guests]
        XCTAssertEqual(CustomFilters.cleanName("  Gäste\nabends  "), "Gäste abends")
        XCTAssertEqual(CustomFilters.cleanName(String(repeating: "x", count: 100)).count, 40)
        XCTAssertNotNil(CustomFilters.nameProblem("   ", in: filters))
        XCTAssertNotNil(CustomFilters.nameProblem("32 bit", in: filters))
        XCTAssertNotNil(CustomFilters.nameProblem("fur gaste", in: filters))
        XCTAssertNil(CustomFilters.nameProblem("64 Bit", in: filters))
        // Beim Umbenennen ist der eigene Name nicht belegt.
        XCTAssertNil(CustomFilters.nameProblem("32 BIT", in: filters, except: "a"))
    }

    func testStoredRoundTrip() {
        let text = CustomFilters.encode([bit32, guests])
        XCTAssertEqual(CustomFilters.decode(text), [bit32, guests])
        XCTAssertEqual(CustomFilters.decode(nil), [])
        XCTAssertEqual(CustomFilters.decode("kaputt"), [])
        // Gespeicherte Wirkungen: unbekannte Filter, unbekannte Werte und „aus“ fallen weg.
        let modes = CustomFilters.modes(from: ["a": "hide", "b": "off", "gone": "only", "x": "nonsense"], filters: [bit32, guests])
        XCTAssertEqual(modes, ["a": .hide])
    }
}
