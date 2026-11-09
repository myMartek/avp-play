import Foundation

/// Ein Spiel mit Steam Workshop, dessen Items das Spiel als lokale Add-ons liest (Half-Life: Alyx). Das steht im
/// Rezept; welche Items der Nutzer haben will, steht in seiner `WorkshopList`.
///
/// Ein Workshop-Item für Alyx ist ein einziges VPK-Archiv (`<id>.vpk`). Die Engine liest ein lokales Add-on aus
/// `game/hlvr_addons/<Name>/pak01_dir.vpk`, führt es in ihrem eigenen Menü „Addons verwalten“ und hängt es ein, ohne
/// Steam zu fragen (am Mac gemessen, 2026-11-09). Jedes Item wird deshalb zu einer wählbaren Datei des Rezepts, mit
/// Ziel `<dest>/<Ordner>` und dem Namen `pak01_dir.vpk` dort. Laden, Kopieren und Wegnehmen gehen dann denselben Weg
/// wie jede andere wählbare Datei.
public struct WorkshopSupport: Codable, Sendable, Hashable {
    /// Die Steam-App, deren Workshop es ist.
    public var app: String
    /// Der Ordner unter `Documents/`, in dem je Item ein Ordner liegt.
    public var dest: String

    public init(app: String, dest: String) {
        self.app = app
        self.dest = dest
    }

    public var isSane: Bool { Workshop.isId(app) && !dest.isEmpty && Recipe.isSafeRelativePath(dest) }

    /// Die Seite des Workshops bei Steam.
    public var browseURL: URL { URL(string: "https://steamcommunity.com/app/\(app)/workshop/")! }
}

/// Ein Item, das der Nutzer haben will, so wie es geladen wurde.
public struct WorkshopItem: Codable, Sendable, Hashable, Identifiable {
    /// Die Kennung des Items im Workshop.
    public var id: String
    public var title: String
    /// Der Ordner auf dem Gerät unter `WorkshopSupport.dest`. Er wird beim ersten Laden festgelegt und bleibt: Unter
    /// diesem Namen merkt sich das Spiel, welche Add-ons eingeschaltet sind.
    public var folder: String
    /// Der Stand des Items bei Steam (Manifest), aus dem die Datei stammt.
    public var manifest: String
    public var size: Int64
    public var sha256: String
    /// Wann der Autor das Item zuletzt geändert hat (Unix-Zeit), laut Steam.
    public var updated: Int?
    /// Wurde es nur mitgeladen, weil ein anderes Item es braucht? Dann dessen Kennungen.
    public var requiredBy: [String]?
    /// Aus der Liste genommen. Es bleibt als wählbare Datei im Rezept, nie gewählt: So weiß der nächste Abgleich mit
    /// der Vision Pro noch, wo es dort liegt, und nimmt es weg. Wer es wieder lädt, holt es zurück.
    public var removed: Bool?

    public init(id: String, title: String, folder: String, manifest: String, size: Int64, sha256: String,
                updated: Int? = nil, requiredBy: [String]? = nil) {
        self.id = id; self.title = title; self.folder = folder; self.manifest = manifest
        self.size = size; self.sha256 = sha256; self.updated = updated; self.requiredBy = requiredBy
    }

    /// Unter diesem Namen liegt es im Bestand – so, wie Steam die Datei liefert.
    public var fileName: String { "\(id).vpk" }

    public var isSane: Bool {
        Workshop.isId(id) && Workshop.isId(manifest) && size >= 0 && sha256.count == 64 && sha256.allSatisfy(\.isHexDigit)
            && Workshop.isFolderName(folder)
    }
}

/// Die Items, die der Nutzer aus einem Workshop haben will, je Steam-App. Liegt bei den Daten des Programms, nicht
/// im Bestand: Sie gilt für das Spiel, nicht für eine bestimmte Fassung.
public struct WorkshopList: Codable, Sendable, Equatable {
    public var apps: [String: [WorkshopItem]] = [:]

    public init(apps: [String: [WorkshopItem]] = [:]) { self.apps = apps }

    public static var url: URL { DataLocation.base.appendingPathComponent("workshop.json") }

    public static func load(from url: URL = WorkshopList.url) -> WorkshopList {
        guard let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode(WorkshopList.self, from: data) else { return WorkshopList() }
        return list
    }

    public func save(to url: URL = WorkshopList.url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public func items(app: String) -> [WorkshopItem] { apps[app] ?? [] }

    /// Nimmt ein Item auf oder ersetzt das mit derselben Kennung. Der Ordner eines schon bekannten Items bleibt.
    public mutating func put(_ item: WorkshopItem, app: String) {
        var list = apps[app] ?? []
        if let i = list.firstIndex(where: { $0.id == item.id }) {
            var next = item
            next.folder = list[i].folder
            // Wer ein Item selbst gewählt hat, dem bleibt es, auch wenn es zugleich ein anderes braucht.
            if list[i].requiredBy == nil || item.requiredBy == nil { next.requiredBy = nil }
            else { next.requiredBy = Array(Set(list[i].requiredBy! + item.requiredBy!)).sorted() }
            next.removed = nil
            list[i] = next
        } else {
            list.append(item)
        }
        apps[app] = list
    }

    /// Nimmt ein Item aus der Liste (siehe `WorkshopItem.removed`).
    public mutating func remove(id: String, app: String) {
        guard var list = apps[app], let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].removed = true
        apps[app] = list
    }

    /// Die Items, die der Nutzer sehen soll: alle außer den weggenommenen.
    public func shown(app: String) -> [WorkshopItem] { items(app: app).filter { $0.removed != true } }

    /// Das Rezept mit den gewählten Items als wählbare Dateien. Ein Item, das sich mit einer Datei des Rezepts
    /// beißt (etwa die Sprachausgabe, die schon im Rezept steht) oder nicht stimmig ist, bleibt draußen.
    public func apply(to recipe: Recipe) -> Recipe {
        guard let support = recipe.workshop, support.isSane else { return recipe }
        var result = recipe
        var names = Set(recipe.files.map(\.name))
        var folders = Set<String>()
        for item in items(app: support.app) where item.isSane && !names.contains(item.fileName) && folders.insert(item.folder).inserted {
            names.insert(item.fileName)
            result.files.append(item.recipeFile(support: support))
        }
        return result
    }
}

extension WorkshopItem {
    /// Die wählbare Datei, die das Item im Rezept ist.
    public func recipeFile(support: WorkshopSupport) -> RecipeFile {
        let steam = SteamSource(app: support.app, depots: [.init(id: support.app, manifest: manifest, bytes: size)], folder: nil)
        let hint = LocalizedText(en: "From the Steam Workshop (item \(id)). In the game: main menu › Manage Addons, switch it on, then start a game with add-ons.",
                                 de: "Aus dem Steam Workshop (Item \(id)). Im Spiel: Hauptmenü › Addons verwalten, einschalten, dann ein Spiel mit Addons starten.")
        return RecipeFile(name: fileName, role: Workshop.role, id: id, size: size, sha256: sha256, required: false,
                          dest: "\(support.dest)/\(folder)", localName: "pak01_dir.vpk", locale: nil,
                          source: FileSource(kind: .user, url: nil, hint: hint, steam: steam, archive: nil),
                          title: LocalizedText(title), clearable: true)
    }
}

public enum Workshop {
    /// Die Rolle einer Datei, die aus dem Workshop kommt.
    public static let role = "workshop"
    /// So viele Items holt ein Auftrag höchstens (eine Sammlung kann viele enthalten).
    public static let maxItems = 100

    static func isId(_ s: String) -> Bool { (1...24).contains(s.count) && s.allSatisfy { $0.isASCII && $0.isNumber } }

    static func isFolderName(_ s: String) -> Bool {
        (1...64).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_") }
    }

    /// Der Ordner für ein Item: ein kurzer lesbarer Name aus dem Titel und die Kennung, etwa
    /// `sandbox_npc_arena_2333868769`. Diesen Namen zeigt das Spiel in seinem Menü.
    public static func folder(title: String, id: String) -> String {
        var slug = ""
        for scalar in title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en")).lowercased().unicodeScalars {
            let c = Character(scalar)
            if c.isASCII && (c.isLetter || c.isNumber) { slug.append(c) }
            else if !slug.isEmpty && !slug.hasSuffix("_") { slug.append("_") }
        }
        while slug.hasSuffix("_") { slug.removeLast() }
        if slug.count > 32 {
            slug = String(slug.prefix(32))
            while slug.hasSuffix("_") { slug.removeLast() }
        }
        return slug.isEmpty ? id : "\(slug)_\(id)"
    }

    /// Die Kennung eines Items aus einer Adresse des Workshops (`…/sharedfiles/filedetails/?id=123`, auch
    /// `…/workshop/filedetails/?id=123`), oder eine bloße Kennung.
    public static func itemId(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isId(trimmed) { return trimmed }
        guard let components = URLComponents(string: trimmed), let host = components.host?.lowercased(),
              host == "steamcommunity.com" || host.hasSuffix(".steamcommunity.com"),
              components.path.hasSuffix("/filedetails") || components.path.hasSuffix("/filedetails/"),
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value, isId(id) else { return nil }
        return id
    }
}

/// Was Steam öffentlich über ein Item sagt (ISteamRemoteStorage/GetPublishedFileDetails, ohne Schlüssel).
public struct WorkshopDetails: Sendable, Equatable {
    public var id: String
    public var found: Bool
    public var app: String?
    public var title: String
    public var size: Int64
    /// Der Stand der Datei (Manifest). Fehlt bei einer Sammlung.
    public var manifest: String?
    public var updated: Int?
    public var banned: Bool

    /// Eine Sammlung oder ein Eintrag ohne Datei: Gebraucht werden nur seine Kinder.
    public var isCollection: Bool { manifest == nil }

    /// Liest die Antwort von GetPublishedFileDetails.
    static func parse(_ data: Data) throws -> [WorkshopDetails] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let list = response["publishedfiledetails"] as? [[String: Any]] else { throw WorkshopError.unreadableAnswer }
        return list.compactMap { entry in
            guard let id = string(entry["publishedfileid"]), Workshop.isId(id) else { return nil }
            let manifest = string(entry["hcontent_file"]).flatMap { Workshop.isId($0) && $0 != "0" ? $0 : nil }
            return WorkshopDetails(id: id, found: (entry["result"] as? Int) == 1, app: string(entry["consumer_app_id"]),
                                   title: (entry["title"] as? String) ?? id, size: Int64(string(entry["file_size"]) ?? "") ?? 0,
                                   manifest: manifest, updated: entry["time_updated"] as? Int,
                                   banned: (entry["banned"] as? Int ?? 0) != 0 || (entry["banned"] as? Bool ?? false))
        }
    }

    /// Liest die Antwort von GetCollectionDetails: je Kennung ihre Kinder (bei einer Sammlung ihr Inhalt, bei einem
    /// Item die Items, die es braucht).
    static func parseChildren(_ data: Data) throws -> [String: [String]] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let list = response["collectiondetails"] as? [[String: Any]] else { throw WorkshopError.unreadableAnswer }
        var result: [String: [String]] = [:]
        for entry in list {
            guard let id = string(entry["publishedfileid"]), (entry["result"] as? Int) == 1 else { continue }
            let children = (entry["children"] as? [[String: Any]] ?? [])
                .sorted { (($0["sortorder"] as? Int) ?? 0) < (($1["sortorder"] as? Int) ?? 0) }
                .compactMap { string($0["publishedfileid"]) }.filter(Workshop.isId)
            if !children.isEmpty { result[id] = children }
        }
        return result
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    /// Fragt Steam nach Items. Öffentlich, ohne Konto und ohne Schlüssel.
    public static func fetch(ids: [String], session: URLSession? = nil) async throws -> [WorkshopDetails] {
        guard !ids.isEmpty else { return [] }
        let data = try await post("https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/",
                                  fields: [("itemcount", "\(ids.count)")] + ids.enumerated().map { ("publishedfileids[\($0.offset)]", $0.element) },
                                  session: session ?? URLSession(configuration: MetaClient.configuration()))
        return try parse(data)
    }

    public static func children(of ids: [String], session: URLSession? = nil) async throws -> [String: [String]] {
        guard !ids.isEmpty else { return [:] }
        let data = try await post("https://api.steampowered.com/ISteamRemoteStorage/GetCollectionDetails/v1/",
                                  fields: [("collectioncount", "\(ids.count)")] + ids.enumerated().map { ("publishedfileids[\($0.offset)]", $0.element) },
                                  session: session ?? URLSession(configuration: MetaClient.configuration()))
        return try parseChildren(data)
    }

    private static func post(_ address: String, fields: [(String, String)], session: URLSession) async throws -> Data {
        var request = URLRequest(url: URL(string: address)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = fields.map { "\($0.0.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed)!)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw WorkshopError.unreadableAnswer }
        return data
    }

    /// Was zu laden ist, wenn der Nutzer `wanted` wählt: Items mit Datei, aus Sammlungen deren Inhalt, und je Item die
    /// Items, die es braucht – eine Ebene tief, höchstens `Workshop.maxItems`. Gibt die Items in Reihenfolge zurück,
    /// dazu, wer welches braucht.
    public static func resolve(_ wanted: [String], app: String,
                               details: ([String]) async throws -> [WorkshopDetails] = { try await WorkshopDetails.fetch(ids: $0) },
                               children: ([String]) async throws -> [String: [String]] = { try await WorkshopDetails.children(of: $0) })
        async throws -> (items: [WorkshopDetails], requiredBy: [String: [String]]) {
        let first = try await details(wanted)
        for d in first where !d.found || d.banned { throw WorkshopError.notAvailable(d.id) }
        for d in first where d.app != app { throw WorkshopError.otherGame(d.title) }
        let kids = try await children(first.map(\.id))
        var order: [String] = []
        var requiredBy: [String: [String]] = [:]
        for d in first {
            if d.isCollection {
                for c in kids[d.id] ?? [] where !order.contains(c) { order.append(c) }
            } else {
                if !order.contains(d.id) { order.append(d.id) }
            }
        }
        // Was ein gewähltes Item braucht.
        for d in first where !d.isCollection {
            for c in kids[d.id] ?? [] where c != d.id {
                requiredBy[c, default: []].append(d.id)
                if !order.contains(c) { order.append(c) }
            }
        }
        guard order.count <= Workshop.maxItems else { throw WorkshopError.tooMany(order.count) }
        let known = Dictionary(first.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let rest = order.filter { known[$0] == nil }
        let more = try await details(rest)
        let all = known.merging(more.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [WorkshopDetails] = []
        for id in order {
            guard let d = all[id], d.found, !d.banned, d.app == app, !d.isCollection else {
                // Ein Item aus einer Sammlung, das es nicht mehr gibt, fällt weg; eines, das ein anderes braucht, nicht.
                if requiredBy[id] != nil { throw WorkshopError.notAvailable(id) }
                continue
            }
            result.append(d)
        }
        guard !result.isEmpty else { throw WorkshopError.nothingToLoad }
        return (result, requiredBy)
    }
}

public enum WorkshopError: Error, CustomStringConvertible, Equatable {
    case unreadableAnswer
    case notAvailable(String)
    case otherGame(String)
    case tooMany(Int)
    case nothingToLoad
    case notDelivered([String])
    case notSupported

    public var description: String {
        switch self {
        case .unreadableAnswer:
            return L("Steam's answer about the Workshop item could not be read. Try again in a while.",
                     "Steams Antwort zum Workshop-Item ließ sich nicht lesen. Versuch es in einer Weile noch einmal.")
        case .notAvailable(let id):
            return L("The Workshop item \(id) is not available (removed, private or blocked).",
                     "Das Workshop-Item \(id) ist nicht verfügbar (entfernt, privat oder gesperrt).")
        case .otherGame(let title):
            return L("“\(title)” is from the Workshop of another game.", "„\(title)“ stammt aus dem Workshop eines anderen Spiels.")
        case .tooMany(let n):
            return L("That is \(n) items; at most \(Workshop.maxItems) are loaded at once.",
                     "Das sind \(n) Items; mehr als \(Workshop.maxItems) werden nicht auf einmal geladen.")
        case .nothingToLoad:
            return L("There is nothing in it that could be loaded.", "Darin ist nichts, was sich laden ließe.")
        case .notDelivered(let ids):
            return L("Steam did not deliver: \(ids.joined(separator: ", ")).", "Steam hat nicht geliefert: \(ids.joined(separator: ", ")).")
        case .notSupported:
            return L("This game has no Steam Workshop in AVP Play.", "Für dieses Spiel gibt es in AVP Play keinen Steam Workshop.")
        }
    }
}

/// Lädt Workshop-Items mit Valves Werkzeug und legt sie in den Bestand des Spiels.
public struct WorkshopFetcher: Sendable {
    public var tool: SteamTool
    public var store: ContentStore
    public var account: String

    public init(tool: SteamTool = SteamTool(), store: ContentStore, account: String) {
        // Wie bei `SteamFetcher`: liegt der Bestand auf einem anderen Laufwerk, gleich dorthin laden.
        self.tool = SteamFetcher(tool: tool, store: store, account: account).tool
        self.store = store
        self.account = account
    }

    /// Lädt die Items und nimmt sie in den Bestand von `recipe` auf. Liefert sie so, wie sie in die Liste gehören.
    public func download(_ details: [WorkshopDetails], requiredBy: [String: [String]] = [:], recipe: Recipe, known: [WorkshopItem] = [],
                         shouldStop: @escaping @Sendable () -> Bool = { false },
                         report: (String) -> Void = { _ in }) throws -> [WorkshopItem] {
        guard let support = recipe.workshop, support.isSane else { throw WorkshopError.notSupported }
        guard SteamTool.isAccountName(account) else { throw SteamError.badAccountName }
        guard details.allSatisfy({ $0.manifest != nil && Workshop.isId($0.id) }) else { throw WorkshopError.nothingToLoad }
        try tool.verify()
        try tool.prepareContent()
        let landing = tool.contentRoot ?? tool.directory
        try? FileManager.default.createDirectory(at: landing, withIntermediateDirectories: true)
        let total = details.map(\.size).reduce(0, +)
        if let free = StoreLocation.freeBytes(at: landing), total * 2 + 1_000_000_000 > free {
            throw SteamError.notEnoughSpace(needed: total * 2 + 1_000_000_000, free: free)
        }

        report(L("Downloading from the Steam Workshop: \(details.count) item(s), \(Installer.gigabytes(total)) …",
                 "Aus dem Steam Workshop wird geladen: \(details.count) Item(s), \(Installer.gigabytes(total)) …"))
        let folder = tool.contentDirectory(app: support.app, depot: support.app)
        let download = try tool.run(["+@NoPromptForPassword", "1", "+login", account]
                                    + details.flatMap { ["+download_depot", support.app, support.app, $0.manifest!] } + ["+quit"],
                                    shouldStop: shouldStop) { line in
            if line.contains("Downloading depot") || line.contains("Depot download") { report("  " + line.replacingOccurrences(of: tool.directory.path, with: "…")) }
        }
        if SteamRun.loginFailed(download.output) { throw SteamRun.failure(download.output) }

        // Übernehmen: je Item die Datei, die Steam unter seiner Kennung liefert.
        try FileManager.default.createDirectory(at: store.directory(for: recipe), withIntermediateDirectories: true)
        var items: [WorkshopItem] = []
        var missing: [String] = []
        for d in details {
            let source = folder.appendingPathComponent("\(d.id).vpk")
            guard let size = ContentStore.fileSize(source), size > 0 else { missing.append(d.id); continue }
            let sha = try Hashing.sha256(of: source)
            let folderName = known.first(where: { $0.id == d.id })?.folder ?? Workshop.folder(title: d.title, id: d.id)
            let item = WorkshopItem(id: d.id, title: d.title, folder: folderName, manifest: d.manifest!, size: size, sha256: sha,
                                    updated: d.updated, requiredBy: requiredBy[d.id])
            let target = store.url(for: item.recipeFile(support: support), in: recipe)
            try? FileManager.default.removeItem(at: target)
            do { try FileManager.default.moveItem(at: source, to: target) } catch {
                try FileManager.default.copyItem(at: source, to: target)
                try? FileManager.default.removeItem(at: source)
            }
            Adopter.stripDownloadMetadata(target)
            items.append(item)
        }
        // Nur die eigenen Dateien gehen weg, nicht der Ordner der App bei SteamCMD: Darin kann gerade das Spiel selbst
        // geladen werden (dieselbe App, andere Depots).
        guard missing.isEmpty else { throw WorkshopError.notDelivered(missing) }
        report(L("Added to the library: \(items.map(\.title).joined(separator: ", "))",
                 "In den Bestand übernommen: \(items.map(\.title).joined(separator: ", "))"))
        return items
    }
}
