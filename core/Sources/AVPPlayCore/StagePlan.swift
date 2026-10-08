import Foundation

/// Eine Datei, die auf das Gerät kopiert werden muss.
public struct StageItem: Equatable, Sendable {
    public let source: URL
    /// Ziel im Datencontainer, z. B. `Documents/android-files/obb/main.1716.….obb`
    public let destination: String
    public let size: Int64
}

/// Ergänzendes Kopieren: Es wird nur übertragen, was auf dem Gerät fehlt oder eine andere Größe hat.
/// Ein Containerpfad wird nirgends gespeichert – er wechselt bei jeder Installation (Schritt 0, F18, F50);
/// adressiert wird immer über die Bundle-ID und den Pfad unterhalb von `Documents/`.
public enum StagePlan {
    /// Zielordner unterhalb von `Documents/` (ohne Dateinamen); `nil`, wenn die Datei nicht aufs Gerät gehört.
    public static func directory(for file: RecipeFile) -> String? {
        guard let dest = file.dest else { return nil }
        return dest.isEmpty ? "Documents" : "Documents/\(dest)"
    }

    public static func destination(for file: RecipeFile) -> String? {
        directory(for: file).map { "\($0)/\(file.localName ?? file.name)" }
    }

    /// - Parameters:
    ///   - local: die gewünschten Dateien mit ihrem Ort im Bestand und ihrer Größe
    ///   - remote: was auf dem Gerät liegt, Zielpfad -> Größe
    public static func plan(local: [(file: RecipeFile, url: URL, size: Int64)], remote: [String: Int64]) -> [StageItem] {
        local.compactMap { entry in
            guard let destination = destination(for: entry.file) else { return nil }
            if remote[destination] == entry.size { return nil }
            return StageItem(source: entry.url, destination: destination, size: entry.size)
        }
    }
}

/// Die kleinen Dateien, über die der Shim erfährt, was freigeschaltet ist. Sie entstehen auf dem Mac aus
/// Metas Antworten; auf das Gerät gelangen nur sie, nie ein Token.
public enum AddonFiles {
    public static let entitlementsName = "klepton-entitlements.txt"
    public static let assetIndexName = "index.txt"

    /// Kaufliste für Spiele, deren Zusatzinhalte über `viewer_purchases` freigeschaltet werden.
    public static func entitlements(appId: String, skus: [String], verified: Date) -> String {
        let stamp = ISO8601DateFormatter().string(from: verified)
        let lines = ["# klepton-entitlements v1 — vom Store bestätigte Käufe. Nicht von Hand pflegen.",
                     "app_id \(appId)", "verified \(stamp)"] + skus.sorted().map { "sku \($0)" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Index der vom Store ausgelieferten Zusatzdateien.
    public static func assetIndex(_ items: [AddonItem]) -> String {
        let lines = ["# klepton-assets v1 — vom Store gelieferte Zusatzdateien"]
            + items.sorted { $0.name < $1.name }.map { "asset \($0.id) \($0.name)" }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Der zuletzt von Meta bestätigte Stand der Käufe für ein Spiel.
/// Eine erfolgreiche Abfrage ersetzt ihn (nur so fällt eine Rückgabe auf); eine fehlgeschlagene – etwa
/// wegen eines abgelaufenen Tokens – lässt ihn stehen, damit ein einmal bestätigter Kauf aktiv bleibt.
public struct PurchaseRecord: Codable, Sendable, Equatable {
    public var appId: String
    public var skus: [String]
    public var verified: Date

    public static func url(in store: ContentStore, recipe: Recipe) -> URL {
        store.directory(for: recipe).appendingPathComponent(".confirmed-purchases.json")
    }

    public static func load(store: ContentStore, recipe: Recipe) -> PurchaseRecord? {
        guard let data = try? Data(contentsOf: url(in: store, recipe: recipe)) else { return nil }
        return try? JSONDecoder.iso.decode(PurchaseRecord.self, from: data)
    }

    public func save(store: ContentStore, recipe: Recipe) throws {
        try FileManager.default.createDirectory(at: store.directory(for: recipe), withIntermediateDirectories: true)
        try JSONEncoder.iso.encode(self).write(to: PurchaseRecord.url(in: store, recipe: recipe), options: .atomic)
    }

    public enum Source: Equatable, Sendable { case fresh, cached(reason: String) }

    /// Fragt die Käufe ab und wendet die Regel an. Liefert `nil`, wenn es weder eine Antwort noch einen
    /// früheren Stand gibt – dann wird nichts freigeschaltet.
    public static func refresh(store: ContentStore, recipe: Recipe, now: Date = Date(),
                               query: (String) async throws -> [String]) async -> (record: PurchaseRecord, source: Source)? {
        guard let appId = recipe.store.appId else { return load(store: store, recipe: recipe).map { ($0, .cached(reason: "\(MetaError.missingAppId)")) } }
        do {
            let record = PurchaseRecord(appId: appId, skus: try await query(appId).sorted(), verified: now)
            try? record.save(store: store, recipe: recipe)
            return (record, .fresh)
        } catch {
            return load(store: store, recipe: recipe).map { ($0, .cached(reason: "\(error)")) }
        }
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }
}
