import Foundation

/// Was Meta zuletzt auf die Frage geantwortet hat, ob das Konto ein Spiel besitzt.
public struct OwnershipRecord: Codable, Sendable, Equatable {
    public var owned: Bool
    public var checked: Date
    public init(owned: Bool, checked: Date) {
        self.owned = owned
        self.checked = checked
    }
}

/// Die Antworten je Store-App, im Bestand abgelegt. Damit weiß die Oberfläche auch ohne neue Abfrage, welche
/// Spiele dem Nutzer gehören. Maßgeblich bleibt die Prüfung unmittelbar vor jedem Auftrag (`Installer`);
/// dieser Stand entscheidet nur, was angezeigt und angeboten wird.
///
/// Eine neue Antwort ersetzt die alte. Eine fehlgeschlagene Abfrage ändert nichts.
public struct OwnershipCache: Sendable {
    public let url: URL
    public init(store: ContentStore) { url = store.root.appendingPathComponent("ownership.json") }

    public func load() -> [String: OwnershipRecord] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder.iso.decode([String: OwnershipRecord].self, from: data)) ?? [:]
    }

    public func save(_ records: [String: OwnershipRecord]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder.iso
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(records).write(to: url, options: .atomic)
    }

    /// Beim Abmelden: der Stand gehört zu einem Konto und gilt für das nächste nicht.
    public func clear() { try? FileManager.default.removeItem(at: url) }

    /// Ist eine neue Abfrage fällig? Ja, wenn es keine Antwort gibt oder sie älter als `maxAge` ist.
    public static func needsCheck(_ record: OwnershipRecord?, now: Date = Date(), maxAge: TimeInterval = 24 * 3600) -> Bool {
        guard let record else { return true }
        return now.timeIntervalSince(record.checked) > maxAge || record.checked > now
    }
}
