import Foundation

/// Ein Ordnerbestand: ein ganzer Verzeichnisbaum, der zu einem Spiel gehört, das kein APK ist – etwa ein
/// Linux-Spiel aus Steam samt der Laufzeitumgebung, auf der es läuft. Anders als bei einzelnen Dateien steht
/// nicht jede Datei im Rezept; der Baum wird an wenigen Kenndateien mit Prüfsumme erkannt.
public struct RecipeTree: Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable, CaseIterable {
        /// Das Installationsverzeichnis des Spiels.
        case game
        /// Die Laufzeitumgebung (Systembibliotheken), auf der das Spiel läuft.
        case sysroot
        /// Die Brücke von OpenVR nach OpenXR.
        case xrizer

        /// Unter diesem Namen erfährt die Toolchain, wo der Baum liegt.
        var toolchainVariable: String {
            switch self {
            case .game: return "KL_LX_GAME"
            case .sysroot: return "KL_LX_SYSROOT"
            case .xrizer: return "KL_LX_XRIZER"
            }
        }
    }

    public struct Marker: Codable, Sendable, Hashable {
        /// Pfad unterhalb des Baums.
        public var path: String
        public var size: Int64?
        public var sha256: String
    }

    /// Ordnername im Bestand.
    public var name: String
    public var role: Role
    public var source: FileSource
    /// Dateien, an denen der richtige Baum in der richtigen Version erkannt wird.
    public var markers: [Marker]
}

/// Ordnerbestände im lokalen Bestand: prüfen und übernehmen.
public struct TreeStore: Sendable {
    public struct AdoptResult: Sendable, Equatable {
        public var adopted: [String] = []
        public var alreadyPresent: [String] = []
        public var notFound: [String] = []
    }

    let store: ContentStore
    public init(store: ContentStore) { self.store = store }

    public func url(for tree: RecipeTree, in recipe: Recipe) -> URL {
        store.directory(for: recipe).appendingPathComponent(tree.name, isDirectory: true)
    }

    /// Welche Kenndateien fehlen oder abweichen. Leer heißt: das ist der Baum aus dem Rezept.
    public static func failingMarkers(of tree: RecipeTree, at directory: URL) -> [String] {
        tree.markers.compactMap { marker in
            let url = directory.appendingPathComponent(marker.path)
            guard let size = ContentStore.fileSize(url.resolvingSymlinksInPath()) else { return marker.path }
            if let want = marker.size, want != size { return marker.path }
            guard (try? Hashing.sha256(of: url)) == marker.sha256.lowercased() else { return marker.path }
            return nil
        }
    }

    /// Bäume, die im Bestand fehlen oder nicht (mehr) zum Rezept passen.
    public func missing(recipe: Recipe) -> [RecipeTree] {
        (recipe.trees ?? []).filter { !TreeStore.failingMarkers(of: $0, at: url(for: $0, in: recipe)).isEmpty }
    }

    /// Wo die Toolchain die Bäume findet.
    public func toolchainEnvironment(recipe: Recipe) -> [String: String] {
        var env: [String: String] = [:]
        for tree in recipe.trees ?? [] { env[tree.role.toolchainVariable] = url(for: tree, in: recipe).path }
        return env
    }

    /// Übernimmt Bäume aus vorhandenen Ordnern. Ein Ordner wird nur genommen, wenn alle Kenndateien stimmen.
    /// Die Quelle bleibt unverändert; auf APFS entsteht eine platzsparende Kopie (Klon). Symbolische Links
    /// werden als Links übernommen, Dateiattribute der Quelle nicht angefasst.
    public func adopt(recipe: Recipe, from sources: [URL]) throws -> AdoptResult {
        var result = AdoptResult()
        let fm = FileManager.default
        try fm.createDirectory(at: store.directory(for: recipe), withIntermediateDirectories: true)
        for tree in recipe.trees ?? [] {
            let target = url(for: tree, in: recipe)
            if TreeStore.failingMarkers(of: tree, at: target).isEmpty { result.alreadyPresent.append(tree.name); continue }
            guard let source = sources.first(where: { TreeStore.failingMarkers(of: tree, at: $0).isEmpty }) else {
                result.notFound.append(tree.name); continue
            }
            // Erst vollständig daneben anlegen, dann umbenennen: ein abgebrochener Lauf hinterlässt keinen halben Baum.
            let fresh = store.directory(for: recipe).appendingPathComponent(".\(tree.name).new", isDirectory: true)
            try? fm.removeItem(at: fresh)
            try fm.copyItem(at: source, to: fresh)
            try? fm.removeItem(at: target)
            try fm.moveItem(at: fresh, to: target)
            result.adopted.append(tree.name)
        }
        return result
    }

    /// Reguläre Dateien unterhalb eines Ordners: relativer Pfad -> Größe. Symbolischen Links wird nicht gefolgt.
    public static func listing(of directory: URL) -> [String: Int64] {
        var out: [String: Int64] = [:]
        // Relative Pfade direkt vom Durchlauf: so spielt es keine Rolle, über welchen Weg der Ordner erreicht wird.
        guard let walker = FileManager.default.enumerator(atPath: directory.path) else { return out }
        for case let relative as String in walker {
            guard let attrs = walker.fileAttributes, (attrs[.type] as? FileAttributeType) == .typeRegular else { continue }
            out[relative] = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        }
        return out
    }
}
