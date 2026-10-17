import Foundation

/// Die Spiele, die ein Horizon+-Abo jederzeit laden lässt – nicht die Monatsspiele, sondern die beiden Kataloge, die
/// Meta im Store unter „Horizon+“ führt: den Spielekatalog und den Indie-Katalog. Für den Filter „Horizon+“.
public struct HorizonPlusGame: Codable, Sendable, Equatable {
    public enum Catalogue: String, Codable, Sendable {
        case games, indie
    }
    public var appId: String
    public var title: String
    public var catalogue: Catalogue
    public init(appId: String, title: String, catalogue: Catalogue) {
        self.appId = appId
        self.title = title
        self.catalogue = catalogue
    }
}

/// Die zuletzt geladenen Horizon+-Kataloge, im Bestand abgelegt wie die Bibliothek (`MetaLibrary`).
public struct HorizonPlusCatalog: Codable, Sendable, Equatable {
    public var checked: Date
    public var games: [HorizonPlusGame]
    public init(checked: Date, games: [HorizonPlusGame]) {
        self.checked = checked
        self.games = games
    }

    public var appIds: Set<String> { Set(games.map(\.appId)) }

    public func catalogue(of appId: String) -> HorizonPlusGame.Catalogue? {
        games.first { $0.appId == appId }?.catalogue
    }

    /// Ist er alt genug für eine neue Abfrage? Einen Tag: Meta wechselt die Kataloge etwa einmal im Monat.
    /// Eine Zeit in der Zukunft gilt als alt.
    public func isStale(now: Date = Date(), maxAge: TimeInterval = 86_400) -> Bool {
        now.timeIntervalSince(checked) > maxAge || checked > now
    }
}

public struct HorizonPlusCache: Sendable {
    public let url: URL
    public init(store: ContentStore) { url = store.root.appendingPathComponent("horizon-plus.json") }

    public func load() -> HorizonPlusCatalog? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.iso.decode(HorizonPlusCatalog.self, from: data)
    }

    public func save(_ catalog: HorizonPlusCatalog) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder.iso
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(catalog).write(to: url, options: .atomic)
    }

    public func clear() { try? FileManager.default.removeItem(at: url) }
}

extension MetaClient {
    /// Die Store-Abschnitte der beiden Kataloge, wie Metas Horizon-App sie fest kennt
    /// (`PLATFORM_SUB_CATALOG_SECTION_ID`, `PLATFORM_SUB_INDIE_SECTION_ID`); auf meta.com dieselben Abschnitte
    /// („Games catalogue“, „Indie catalogue“).
    static let horizonPlusSections: [(id: String, catalogue: HorizonPlusGame.Catalogue)] = [
        ("746836817401205", .games), ("3170833353093973", .indie),
    ]

    /// Die hinterlegte Abfrage „Einträge eines Store-Abschnitts, seitenweise“, unter der Nummer, unter der Metas
    /// Horizon-App (Android 393, `OCStoreSectionStandardPaginationQuery`) einen Abschnitt lädt.
    static let storeSectionQuery = "29324768007113310"

    /// Beide Horizon+-Kataloge: je Spiel Kennung, Name und Katalog.
    ///
    /// Auch diese Abfrage steht in keiner Dokumentation für Entwickler. Der Nutzer hat ihr am 2026-10-17 zugestimmt,
    /// als dritter solcher Abfrage. Sie liest nur. Meta liefert höchstens 50 Einträge je Seite und blättert über die
    /// Kennung des letzten Eintrags weiter; eine leere Seite oder eine ohne neue Einträge ist das Ende. Eine Seite,
    /// die anders aussieht als erwartet, beendet die Abfrage mit einem Fehler – keine halbe Liste, die als ganze gälte.
    public func horizonPlusCatalog(pageSize: Int = 50, maxPages: Int = 10) async throws -> [HorizonPlusGame] {
        var all: [HorizonPlusGame] = []
        for section in MetaClient.horizonPlusSections {
            var seen = Set<String>()
            var cursor: String?
            var done = false
            for _ in 0..<maxPages {
                var variables: [String: Any] = [
                    "id": section.id, "count": pageSize,
                    // Ein Wert, den die Horizon-App selbst einsetzt; ohne ihn lehnt Meta die Abfrage ab.
                    "__relay_internal__pv__horizonPlusBadgerelayprovider": false,
                ]
                if let cursor { variables["cursor"] = cursor }
                let json = String(decoding: try JSONSerialization.data(withJSONObject: variables, options: [.sortedKeys]), as: UTF8.self)
                let data = try await graph(path: "/graphql", form: ["doc_id": MetaClient.storeSectionQuery, "variables": json])
                guard let page = MetaClient.sectionPage(inAnswer: data, sectionId: section.id) else {
                    throw MetaError.unexpected(status: 200)
                }
                let fresh = page.games.filter { seen.insert($0.appId).inserted }
                all += fresh.map { HorizonPlusGame(appId: $0.appId, title: $0.title, catalogue: section.catalogue) }
                guard !fresh.isEmpty, let next = page.last else { done = true; break }
                cursor = next
            }
            // So viele Seiten hat kein Katalog; was danach käme, fehlte.
            guard done else { throw MetaError.unexpected(status: 200) }
        }
        return all
    }

    /// Eine Seite eines Store-Abschnitts: `data.node` mit der erwarteten `id` und `connection_units.edges[]`, je
    /// Eintrag `node.id` und `node.display_unit_title`; `last` ist die Marke des letzten Eintrags (`cursor`).
    /// `nil`, wenn die Seite nicht so aussieht.
    static func sectionPage(inAnswer data: Data, sectionId: String) -> (games: [(appId: String, title: String)], last: String?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], root["errors"] == nil,
              let payload = root["data"] as? [String: Any], let node = payload["node"] as? [String: Any],
              node["id"] as? String == sectionId,
              let connection = node["connection_units"] as? [String: Any],
              let edges = connection["edges"] as? [[String: Any]] else { return nil }
        var games: [(appId: String, title: String)] = []
        var last: String?
        for edge in edges {
            guard let item = edge["node"] as? [String: Any],
                  let id = item["id"] as? String, CatalogGame.isIdentifier(id) else { continue }
            let title = (item["display_unit_title"] as? String ?? item["display_name"] as? String).map { String($0.prefix(200)) } ?? ""
            games.append((id, title))
            if let mark = edge["cursor"] as? String, isPageMark(mark) { last = mark } else { last = nil }
        }
        return (games, last)
    }
}
