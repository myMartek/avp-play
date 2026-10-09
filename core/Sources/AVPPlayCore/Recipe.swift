import Foundation

/// Ein Rezept beschreibt ein Spiel in einer bestimmten Version: woran es zu erkennen ist, welche Dateien
/// dazugehören und wie Zusatzinhalte freigeschaltet werden. Es ist rein deklarativ – ein Rezept führt nie
/// Code aus. Alles Spielspezifische, das Code braucht, lebt in der Toolchain (`toolchain.target`).
public struct Recipe: Codable, Sendable, Identifiable {
    public var schema: Int
    public var id: String
    public var title: String
    public var package: String
    public var versionName: String
    public var versionCode: Int
    public var store: StoreInfo
    public var toolchain: Toolchain
    public var files: [RecipeFile]
    public var addons: Addons?
    public var status: Status
    /// Woher das App-Icon kommt, wenn es keinen Store-Eintrag bei Meta gibt.
    public var icon: IconSource?
    /// Ganze Verzeichnisbäume für Spiele, die kein APK sind (siehe `RecipeTree`).
    public var trees: [RecipeTree]?

    public struct IconSource: Codable, Sendable, Equatable {
        /// Steam-App-ID: Hintergrund und Logo aus dem lokalen Bildspeicher des Steam-Clients des Nutzers.
        public var steamAppId: String?
    }

    public struct StoreInfo: Codable, Sendable {
        /// Store-App-ID für Besitz- und Kaufabfrage. Fehlt sie, kann der Besitz nicht geprüft werden.
        public var appId: String?
    }
    public struct Toolchain: Codable, Sendable {
        public var target: String
        public var minCommit: String
    }
    public struct Status: Codable, Sendable {
        public var playability: String
        public var download: String
        public var notes: [LocalizedText]?
    }
}

public struct RecipeFile: Codable, Sendable, Hashable {
    public var name: String
    public var role: String
    /// Datei-ID im Store (Binär- oder Asset-ID). Über sie wird gezielt geladen.
    public var id: String
    public var size: Int64?
    public var sha256: String?
    public var required: Bool
    /// Zielordner unterhalb von `Documents/` im Datencontainer der App; `nil` = wird nicht kopiert.
    public var dest: String?
    /// Abweichender Dateiname am Ziel (das APK heißt im Store anders, als die Toolchain es erwartet).
    public var localName: String?
    public var locale: String?
    /// Woher die Datei kommt. Fehlt die Angabe, ist es der Meta-Store (Download per `id`).
    public var source: FileSource?
}

/// Quellen für „Sonderapps“, deren Dateien nicht aus dem Meta-Store stammen.
public struct FileSource: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// Öffentlich und frei ladbar (z. B. ein quelloffener Port). Eine Prüfsumme im Rezept ist Pflicht.
        case url
        /// Vom Nutzer bereitzustellen (z. B. Dateien aus seinem eigenen Steam-Kauf). Wird nie geladen.
        case user
    }
    public var kind: Kind
    public var url: String?
    /// Hinweis für den Nutzer, woher er die Datei bekommt.
    public var hint: LocalizedText?
    /// Wo die Datei bei Steam liegt, falls sie aus einem Steam-Kauf stammt. Dann kann Valves eigenes Werkzeug
    /// sie mit dem Konto des Nutzers holen – und tut das nur für ein Spiel, das diesem Konto gehört.
    public var steam: SteamSource?
    /// Für einen Ordnerbestand mit freier Adresse: Die Adresse führt zu einem Archiv, aus dem der Ordner entsteht.
    public var archive: ArchiveSource?
}

/// Ein Archiv (tar, auch gepackt), aus dem ein Ordnerbestand entsteht. Angenommen wird es nur mit genau dieser
/// Prüfsumme – was darin steht, ist danach so festgelegt wie eine einzelne Datei mit Prüfsumme.
public struct ArchiveSource: Codable, Sendable, Hashable {
    public var sha256: String
    public var size: Int64?
    /// Der Ordner im Archiv, der den Bestand bildet; fehlt er, ist es die oberste Ebene des Archivs.
    public var folder: String?
}

/// Ein Stand eines Steam-Spiels: die App, und die Depots in genau der Fassung, für die das Rezept gilt.
public struct SteamSource: Codable, Sendable, Hashable {
    public struct Depot: Codable, Sendable, Hashable {
        public var id: String
        /// Die Fassung des Depots (Manifest). Ohne sie käme, was Valve gerade ausliefert.
        public var manifest: String
        /// Größe laut Valve, für die Fortschrittsanzeige.
        public var bytes: Int64?
    }
    public var app: String
    /// In dieser Reihenfolge; bei einem Ordnerbestand überschreibt ein späteres Depot nichts aus einem früheren.
    public var depots: [Depot]
    /// Nur für Ordnerbestände: der Ordner im Depot, der den Bestand bildet.
    public var folder: String?

    /// Kennungen sind Ziffern, Ordner ein schlichter relativer Name – was im Rezept steht, wird zu Argumenten
    /// eines fremden Werkzeugs und zu Pfaden auf der Platte.
    public var isSane: Bool {
        func digits(_ s: String) -> Bool { (1...24).contains(s.count) && s.allSatisfy { $0.isASCII && $0.isNumber } }
        return digits(app) && !depots.isEmpty && depots.allSatisfy { digits($0.id) && digits($0.manifest) }
            && (folder ?? "x").allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") } && folder != ""
    }
}

public struct Addons: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Die Dateien bekommt jeder Besitzer; freigeschaltet wird über die vom Store bestätigte Kaufliste.
        case purchaseList = "purchase-list"
        /// Der Store liefert nur Gekauftes aus; gemeldet wird, was vorhanden ist.
        case deliveredAssets = "delivered-assets"
    }
    public var kind: Kind
    public var dest: String?
    public var items: [AddonItem]?
}

public struct AddonItem: Codable, Sendable, Hashable {
    public var sku: String
    public var name: String
    public var id: String
    public var size: Int64?
    public var sha256: String?
    public var group: String?

    /// Ein Zusatzinhalt wird wie eine wählbare Datei behandelt, sobald der Kauf bestätigt ist.
    public func asFile(dest: String?) -> RecipeFile {
        RecipeFile(name: name, role: "addon", id: id, size: size, sha256: sha256, required: false,
                   dest: dest, localName: nil, locale: nil, source: nil)
    }
}

public enum RecipeError: Error, CustomStringConvertible, Equatable {
    case unsupportedSchema(Int)
    case invalid(String)

    public var description: String {
        switch self {
        case .unsupportedSchema(let v): return L("Recipe schema \(v) is not supported.", "Rezeptschema \(v) wird nicht unterstützt.")
        case .invalid(let why): return L("Invalid recipe: \(why)", "Ungültiges Rezept: \(why)")
        }
    }
}

extension Recipe {
    public static let supportedSchema = 1

    /// Prüft, was ein Rezept aus fremder Hand nicht dürfen soll: Pfade nach außen, uneindeutige Namen,
    /// IDs, die keine sind. Wird beim Laden immer ausgeführt.
    public func validate() throws {
        guard schema == Recipe.supportedSchema else { throw RecipeError.unsupportedSchema(schema) }
        guard Recipe.isSafeName(id) else { throw RecipeError.invalid(L("identifier '\(id)'", "Kennung '\(id)'")) }
        var names = Set<String>()
        let addonFiles = (addons?.items ?? []).map { $0.asFile(dest: addons?.dest) }
        for f in files + addonFiles {
            guard Recipe.isSafeName(f.name) else { throw RecipeError.invalid(L("file name '\(f.name)'", "Dateiname '\(f.name)'")) }
            if let l = f.localName, !Recipe.isSafeName(l) { throw RecipeError.invalid(L("destination name '\(l)'", "Zielname '\(l)'")) }
            switch f.source?.kind {
            case nil:
                guard !f.id.isEmpty, f.id.allSatisfy(\.isNumber) else { throw RecipeError.invalid(L("file ID of '\(f.name)'", "Datei-ID von '\(f.name)'")) }
            case .url:
                // Ein freier Download ist nur mit https und mit Prüfsumme zulässig: sonst wüsste niemand, was ankommt.
                guard let raw = f.source?.url, let url = URL(string: raw), url.scheme == "https", url.host != nil else {
                    throw RecipeError.invalid(L("address of '\(f.name)'", "Adresse von '\(f.name)'"))
                }
                guard f.sha256 != nil else {
                    throw RecipeError.invalid(L("'\(f.name)': public download without a checksum", "'\(f.name)': freier Download ohne Prüfsumme"))
                }
            case .user:
                break
            }
            // Ein Steam-Eintrag wird zu Argumenten für Valves Werkzeug; und was daher kommt, muss sich an einer
            // Prüfsumme messen lassen.
            if let steam = f.source?.steam {
                guard steam.isSane, steam.folder == nil else { throw RecipeError.invalid(L("Steam entry of '\(f.name)'", "Steam-Eintrag von '\(f.name)'")) }
                guard f.sha256 != nil else {
                    throw RecipeError.invalid(L("'\(f.name)': from Steam without a checksum", "'\(f.name)': aus Steam ohne Prüfsumme"))
                }
            }
            guard names.insert(f.name).inserted else {
                throw RecipeError.invalid(L("file name '\(f.name)' appears twice", "Dateiname '\(f.name)' kommt doppelt vor"))
            }
            if let d = f.dest, !Recipe.isSafeRelativePath(d) { throw RecipeError.invalid(L("destination folder '\(d)'", "Zielordner '\(d)'")) }
            if let h = f.sha256, !(h.count == 64 && h.allSatisfy { $0.isHexDigit }) {
                throw RecipeError.invalid(L("checksum of '\(f.name)'", "Prüfsumme von '\(f.name)'"))
            }
            if let s = f.size, s < 0 { throw RecipeError.invalid(L("size of '\(f.name)'", "Größe von '\(f.name)'")) }
        }
        var roles = Set<RecipeTree.Role>()
        for t in trees ?? [] {
            guard Recipe.isSafeName(t.name), names.insert(t.name).inserted else {
                throw RecipeError.invalid(L("folder name '\(t.name)'", "Ordnername '\(t.name)'"))
            }
            guard roles.insert(t.role).inserted else {
                throw RecipeError.invalid(L("folder role '\(t.role.rawValue)' appears twice", "Ordnerrolle '\(t.role.rawValue)' kommt doppelt vor"))
            }
            // Ohne Kenndatei wäre jeder beliebige Ordner „der richtige“.
            guard !t.markers.isEmpty else { throw RecipeError.invalid(L("'\(t.name)': no marker file", "'\(t.name)': keine Kenndatei")) }
            for m in t.markers {
                guard !m.path.isEmpty, Recipe.isSafeRelativePath(m.path) else {
                    throw RecipeError.invalid(L("marker file '\(m.path)'", "Kenndatei '\(m.path)'"))
                }
                guard m.sha256.count == 64, m.sha256.allSatisfy({ $0.isHexDigit }) else {
                    throw RecipeError.invalid(L("checksum of '\(m.path)'", "Prüfsumme von '\(m.path)'"))
                }
                if let s = m.size, s < 0 { throw RecipeError.invalid(L("size of '\(m.path)'", "Größe von '\(m.path)'")) }
            }
            if t.source.kind == .url {
                guard let raw = t.source.url, let url = URL(string: raw), url.scheme == "https", url.host != nil else {
                    throw RecipeError.invalid(L("address of '\(t.name)'", "Adresse von '\(t.name)'"))
                }
                // Ein Ordner aus dem Netz ist ein Archiv, und ein Archiv ohne Prüfsumme könnte alles enthalten.
                guard let archive = t.source.archive, archive.sha256.count == 64, archive.sha256.allSatisfy({ $0.isHexDigit }),
                      (archive.size ?? 0) >= 0, archive.folder.map({ !$0.isEmpty && Recipe.isSafeRelativePath($0) }) ?? true else {
                    throw RecipeError.invalid(L("archive of '\(t.name)'", "Archiv von '\(t.name)'"))
                }
            }
            if let steam = t.source.steam, !steam.isSane {
                throw RecipeError.invalid(L("Steam entry of '\(t.name)'", "Steam-Eintrag von '\(t.name)'"))
            }
        }
        if let app = store.appId, !(app.allSatisfy(\.isNumber) && !app.isEmpty) {
            throw RecipeError.invalid(L("store app ID", "Store-App-ID"))
        }
        if let steam = icon?.steamAppId, !(steam.allSatisfy(\.isNumber) && !steam.isEmpty) {
            throw RecipeError.invalid(L("Steam app ID", "Steam-App-ID"))
        }
    }

    static func isSafeName(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".." && !s.contains("/") && !s.contains("\\") && !s.contains("\0")
            && !s.hasPrefix(".")
    }

    static func isSafeRelativePath(_ s: String) -> Bool {
        if s.isEmpty { return true }
        if s.hasPrefix("/") || s.contains("\\") || s.contains("\0") { return false }
        return s.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

/// Lädt Rezepte aus einem Ordner. Ein Rezept, das die Prüfung nicht besteht, wird nicht geladen.
public struct RecipeStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func loadAll() throws -> [Recipe] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try urls.map(load(url:))
    }

    public func load(id: String) throws -> Recipe {
        guard Recipe.isSafeName(id) else { throw RecipeError.invalid(L("identifier '\(id)'", "Kennung '\(id)'")) }
        return try load(url: directory.appendingPathComponent("\(id).json"))
    }

    public func load(url: URL) throws -> Recipe {
        let recipe = try JSONDecoder().decode(Recipe.self, from: Data(contentsOf: url))
        try recipe.validate()
        return recipe
    }
}
