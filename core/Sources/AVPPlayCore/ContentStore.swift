import Foundation

/// Der lokale Bestand geladener Spieldateien: ein Ordner je Rezept und Version.
/// Begonnene Downloads liegen als `.<name>.part` daneben und werden erst nach bestandener Prüfung umbenannt.
public struct ContentStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    /// Der Ort, der gilt: der vom Nutzer gewählte, sonst der übliche neben den Daten des Programms.
    public static var defaultRoot: URL { StoreLocation.current() }

    public enum FileState: Equatable, Sendable {
        case missing
        case partial(Int64)
        case present(size: Int64)
    }

    public func directory(for recipe: Recipe) -> URL {
        root.appendingPathComponent("\(recipe.id)-\(recipe.versionCode)", isDirectory: true)
    }

    public func url(for file: RecipeFile, in recipe: Recipe) -> URL {
        directory(for: recipe).appendingPathComponent(file.name)
    }

    public func partialURL(for file: RecipeFile, in recipe: Recipe) -> URL {
        directory(for: recipe).appendingPathComponent(".\(file.name).part")
    }

    // MARK: Was Meta diesem Konto nicht ausliefert

    /// Zusatzdateien, die Meta für dieses Konto abgelehnt hat (HTTP 404: ein Zusatzinhalt, der nicht gekauft ist).
    /// Sie stehen in der Dateiliste des Builds, gehören aber nicht zu dem, was dem Nutzer zusteht. Gemerkt wird
    /// das im Ordner des Spiels, damit keine dieser Dateien ein zweites Mal angefragt wird; mit dem Ordner
    /// verschwindet auch die Notiz (etwa nach einem späteren Kauf: Dateien des Spiels entfernen, neu laden).
    public struct Withheld: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var since: String
    }

    func withheldURL(for recipe: Recipe) -> URL { directory(for: recipe).appendingPathComponent(".withheld.json") }

    public func withheldFiles(for recipe: Recipe) -> [Withheld] {
        guard let data = try? Data(contentsOf: withheldURL(for: recipe)) else { return [] }
        return (try? JSONDecoder().decode([Withheld].self, from: data)) ?? []
    }

    /// Die Kennungen dieser Dateien – so, wie `FetchSelection.withheld` sie erwartet.
    public func withheld(for recipe: Recipe) -> Set<String> { Set(withheldFiles(for: recipe).map(\.id)) }

    public func noteWithheld(_ file: RecipeFile, in recipe: Recipe, now: Date = Date()) throws {
        guard !file.id.isEmpty else { return }
        var list = withheldFiles(for: recipe)
        guard !list.contains(where: { $0.id == file.id }) else { return }
        let day = ISO8601DateFormatter.string(from: now, timeZone: TimeZone(identifier: "UTC")!, formatOptions: [.withFullDate])
        list.append(Withheld(id: file.id, name: file.name, since: day))
        try FileManager.default.createDirectory(at: directory(for: recipe), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(list).write(to: withheldURL(for: recipe), options: .atomic)
    }

    public func state(of file: RecipeFile, in recipe: Recipe) -> FileState {
        if let size = ContentStore.fileSize(url(for: file, in: recipe)) { return .present(size: size) }
        if let size = ContentStore.fileSize(partialURL(for: file, in: recipe)), size > 0 { return .partial(size) }
        return .missing
    }

    /// Größe einer regulären Datei; `nil`, wenn es sie nicht gibt.
    public static func fileSize(_ url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.type] as? FileAttributeType) == .typeRegular,
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.int64Value
    }
}
