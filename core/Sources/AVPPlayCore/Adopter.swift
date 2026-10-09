import Foundation

/// Übernimmt bereits vorhandene Dateien in den Bestand, statt sie erneut zu laden – etwa aus einer früheren
/// Einrichtung oder aus einem Quest-Import. Übernommen wird nur, was nachweislich die Datei aus dem Rezept
/// ist: Größe und SHA-256 müssen stimmen. Die Quelle bleibt unverändert; auf APFS entsteht eine
/// platzsparende Kopie (Klon).
public struct Adopter: Sendable {
    public struct Result: Sendable, Equatable {
        public var adopted: [String] = []
        public var alreadyPresent = 0
        /// Gefunden, aber Größe oder Prüfsumme passen nicht (z. B. andere Spielversion).
        public var mismatched: [String] = []
        /// Gefunden, aber das Rezept kennt keine Prüfsumme – ohne Beleg wird nichts übernommen.
        public var unverifiable: [String] = []
        public var notFound: [String] = []
    }

    let store: ContentStore
    public init(store: ContentStore) { self.store = store }

    public func adopt(recipe: Recipe, from sources: [URL], maxDepth: Int = 4) throws -> Result {
        var result = Result()
        let index = Adopter.index(sources, maxDepth: maxDepth)
        let files = recipe.files + (recipe.addons?.items ?? []).map { $0.asFile(dest: recipe.addons?.dest) }
        try FileManager.default.createDirectory(at: store.directory(for: recipe), withIntermediateDirectories: true)

        for file in files {
            let target = store.url(for: file, in: recipe)
            if FileManager.default.fileExists(atPath: target.path) { result.alreadyPresent += 1; continue }
            // Das APK liegt lokal oft unter dem Namen, den die Toolchain erwartet, nicht unter dem des Stores.
            let named = index[file.name] ?? []
            let candidates = named + (file.localName.flatMap { index[$0] } ?? [])
            guard !candidates.isEmpty else { result.notFound.append(file.name); continue }
            guard let expected = file.sha256?.lowercased() else { result.unverifiable.append(file.name); continue }

            var taken = false
            for candidate in candidates {
                if let size = file.size, ContentStore.fileSize(candidate) != size { continue }
                guard try Hashing.sha256(of: candidate) == expected else { continue }
                try FileManager.default.copyItem(at: candidate, to: target)
                // Spuren der Herkunft (z. B. eine Download-URL in den Metadaten) wandern nicht mit.
                Adopter.stripDownloadMetadata(target)
                result.adopted.append(file.name)
                taken = true
                break
            }
            // Unter dem Zielnamen einer wählbaren Datei kann etwas ganz anderes liegen – das Archiv einer Sprachausgabe
            // heißt am Ziel wie eines des Spiels. Das ist dann keine „andere Fassung“, sondern schlicht nicht da.
            if !taken {
                if named.isEmpty, !file.required { result.notFound.append(file.name) } else { result.mismatched.append(file.name) }
            }
        }
        return result
    }

    /// Dateiname -> Fundorte, bis zu einer begrenzten Tiefe. Symbolischen Links wird nicht gefolgt.
    static func index(_ sources: [URL], maxDepth: Int) -> [String: [URL]] {
        var index: [String: [URL]] = [:]
        for source in sources {
            // Eine einzelne Datei als Quelle ist erlaubt (z. B. ein APK neben anderen Dingen).
            if (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                index[source.lastPathComponent, default: []].append(source)
                continue
            }
            let base = source.standardizedFileURL.pathComponents.count
            guard let walker = FileManager.default.enumerator(
                at: source, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                if url.standardizedFileURL.pathComponents.count - base > maxDepth { walker.skipDescendants(); continue }
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    index[url.lastPathComponent, default: []].append(url)
                }
            }
        }
        return index
    }

    static func stripDownloadMetadata(_ url: URL) {
        for name in ["com.apple.metadata:kMDItemWhereFroms", "com.apple.quarantine"] {
            _ = url.withUnsafeFileSystemRepresentation { removexattr($0, name, 0) }
        }
    }
}
