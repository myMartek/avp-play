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
