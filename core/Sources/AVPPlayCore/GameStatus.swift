import Foundation

/// Was der Mac über ein Spiel weiß (Bestand) neben dem, was das Gerät meldet (installierte App und ihr Stempel).
/// Kommandozeile und Oberfläche zeigen dasselbe, deshalb wird es an einer Stelle ermittelt.
public struct GameStatus: Sendable, Equatable {
    public enum OnDevice: Sendable, Equatable {
        /// Kein Gerät erreichbar – über die App lässt sich nichts sagen.
        case unknown
        case notInstalled
        /// Von diesem Werkzeug mit der jetzigen Toolchain (oder einer neueren) gebaut.
        case current(stamp: String)
        /// Von diesem Werkzeug gebaut, aber mit einer älteren Toolchain als der jetzt installierten.
        case olderToolchain(stamp: String)
        /// Installiert, aber eine andere Spielversion oder ohne Stempel dieses Werkzeugs.
        case unstamped(stamp: String)
    }

    /// Pflichtdateien, die vollständig im Bestand liegen, und ihre Gesamtzahl.
    public var filesPresent: Int
    public var filesRequired: Int
    /// Ordnerbestände (Sonderapps), deren Kennzeichen stimmen, und ihre Gesamtzahl.
    public var treesPresent: Int
    public var treesRequired: Int
    /// Bekannte Größe der fehlenden Pflichtdateien, die das Werkzeug laden kann.
    public var bytesToDownload: Int64
    /// Fehlende Pflichtdateien und Ordner, die der Nutzer selbst bereitstellen muss, mit dem Hinweis des Rezepts.
    public var userProvidedMissing: [String]
    public var onDevice: OnDevice

    public var stockComplete: Bool { filesPresent == filesRequired && treesPresent == treesRequired }

    /// - Parameter toolchainVersion: ab welcher Toolchain-Nummer ein gebautes Spiel als aktuell gilt
    ///   (`Toolchain.appRevision()`), nicht zwingend die Nummer der installierten Toolchain.
    /// - Parameter bundlePrefix: das Präfix, unter dem die Spiele installiert werden; ohne Angabe das übliche.
    public static func of(recipe r: Recipe, store: ContentStore, apps: [InstalledApp]?, toolchainVersion: Int?,
                          bundlePrefix: String? = nil) -> GameStatus {
        let required = r.files.filter(\.required)
        func present(_ f: RecipeFile) -> Bool {
            ContentStore.fileSize(store.url(for: f, in: r)).map { f.size == nil || f.size == $0 } ?? false
        }
        let missing = required.filter { !present($0) }
        let trees = r.trees ?? []
        let treesMissing = TreeStore(store: store).missing(recipe: r)
        var byUser = missing.filter { $0.source?.kind == .user }.map { f in f.source?.hint.map { "\(f.name) – \($0)" } ?? f.name }
        byUser += treesMissing.filter { $0.source.kind == .user }.map { t in t.source.hint.map { "\(t.name) – \($0)" } ?? t.name }

        var onDevice = OnDevice.unknown
        if let apps {
            let bundle = Toolchain.bundleId(target: r.toolchain.target, prefix: bundlePrefix)
            if let app = apps.first(where: { $0.bundleIdentifier == bundle }) {
                let stamp = "\(app.version ?? "?") (\(app.bundleVersion ?? "?"))"
                if app.version == AppStamp.short(versionName: r.versionName), let b = app.bundleVersion,
                   b.hasPrefix("\(r.versionCode).") {
                    let built = Int(b.split(separator: ".").last ?? "") ?? 0
                    onDevice = (toolchainVersion.map { built < $0 } ?? false) ? .olderToolchain(stamp: stamp) : .current(stamp: stamp)
                } else {
                    onDevice = .unstamped(stamp: stamp)
                }
            } else {
                onDevice = .notInstalled
            }
        }
        return GameStatus(filesPresent: required.count - missing.count, filesRequired: required.count,
                          treesPresent: trees.count - treesMissing.count, treesRequired: trees.count,
                          bytesToDownload: missing.filter { $0.source?.kind != .user }.reduce(0) { $0 + ($1.size ?? 0) },
                          userProvidedMissing: byUser, onDevice: onDevice)
    }
}
