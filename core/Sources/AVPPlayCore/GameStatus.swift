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
        /// Von diesem Werkzeug gebaut, aber mit einer älteren Toolchain als der jetzt installierten – oder, wo für
        /// das Spiel eine Toolchain gewählt ist, mit einer anderen als der gewählten.
        case olderToolchain(stamp: String)
        /// Von diesem Werkzeug gebaut, aber aus einer älteren Fassung des SPIELS als der des Rezepts – das Rezept
        /// wurde inzwischen für eine neuere geprüft, oder der Nutzer hat die neueste aus dem Store gewählt.
        case olderGame(stamp: String)
        /// Installiert, aber eine andere Spielversion oder ohne Stempel dieses Werkzeugs.
        case unstamped(stamp: String)
        /// Installiert ist dasselbe Spiel aus einer anderen Kaufquelle (die Meta-Fassung, wo Steam gewählt ist,
        /// oder umgekehrt). Darüber wird nicht installiert.
        case otherSource(stamp: String)
    }

    /// Pflichtdateien, die vollständig im Bestand liegen, und ihre Gesamtzahl.
    public var filesPresent: Int
    public var filesRequired: Int
    /// Ordnerbestände (Sonderapps), deren Kennzeichen stimmen, und ihre Gesamtzahl.
    public var treesPresent: Int
    public var treesRequired: Int
    /// Bekannte Größe der fehlenden Pflichtdateien, die das Werkzeug laden kann.
    public var bytesToDownload: Int64
    /// Wie viele Pflichtdateien fehlen, die das Werkzeug laden kann. Bei einem nachgeschlagenen, ungetesteten Spiel
    /// kennt vorab niemand die Größen; dass es etwas zu laden gibt, steht trotzdem fest.
    public var filesToDownload: Int = 0
    /// Fehlende Pflichtdateien und Ordner, die der Nutzer selbst bereitstellen muss, mit dem Hinweis des Rezepts.
    public var userProvidedMissing: [String]
    public var onDevice: OnDevice
    /// Womit die installierte App gebaut wurde, soweit ihr Stempel von diesem Werkzeug stammt.
    public var builtWith: AppStamp.Built?

    public var stockComplete: Bool { filesPresent == filesRequired && treesPresent == treesRequired }

    /// - Parameter toolchainVersion: ab welcher Toolchain-Nummer ein gebautes Spiel als aktuell gilt
    ///   (`Toolchain.appRevision()`), nicht zwingend die Nummer der installierten Toolchain.
    /// - Parameter pin: der Stand, der für dieses Spiel gewählt ist (`ToolchainChoices`). Dann ist aktuell, was
    ///   genau mit ihm gebaut wurde, und alles andere – auch ein Bau mit einer neueren – ist es nicht.
    /// - Parameter bundlePrefix: das Präfix, unter dem die Spiele installiert werden; ohne Angabe das übliche.
    /// - Parameter otherSourceBuilds: die Versionscodes, unter denen dasselbe Spiel aus einer anderen Kaufquelle
    ///   installiert wäre.
    /// - Parameter experimental: ob ein aktueller Bau die experimentellen Implementierungen von Anfang an
    ///   eingeschaltet haben soll (die Einstellung des Programms). Ein Bau, der es anders hält, gilt dann als
    ///   aktualisierbar – so stellt „Alle aktualisieren“ nach dem Umlegen der Einstellung alle Spiele um. `nil`:
    ///   nicht vergleichen (keine Toolchain, die das kann, oder eine für das Spiel gewählte).
    public static func of(recipe r: Recipe, store: ContentStore, apps: [InstalledApp]?, toolchainVersion: Int?,
                          pin: ToolchainChoices.Pin? = nil, bundlePrefix: String? = nil, otherSourceBuilds: Set<Int> = [],
                          experimental: Bool? = nil) -> GameStatus {
        // Was Meta diesem Konto nicht ausliefert (ein nicht gekaufter Zusatzinhalt, siehe `ContentStore.Withheld`),
        // fehlt nicht: Es wird nie geladen und steht dem Spiel nicht im Weg. Ohne das stünde bei einem Spiel wie
        // Maestro für immer „3 von 11 Dateien“, obwohl alles da ist, was dem Konto zusteht.
        // Ohne Pflichtdateien (ein Platzhalter aus dem Katalog) gibt es nichts zurückzuhalten – und keinen Grund, die
        // Datei zu lesen: Die Übersicht bestimmt so den Stand von tausenden Platzhaltern auf dem Hauptthread.
        let withheld = r.files.contains(where: \.required) ? store.withheld(for: r) : []
        let required = r.files.filter { $0.required && !withheld.contains($0.id) }
        func present(_ f: RecipeFile) -> Bool {
            ContentStore.fileSize(store.url(for: f, in: r)).map { f.size == nil || f.size == $0 } ?? false
        }
        let missing = required.filter { !present($0) }
        let trees = r.trees ?? []
        let treesMissing = TreeStore(store: store).missing(recipe: r)
        // Bei einem Spiel aus Steam holt das Programm die Dateien selbst aus dem Steam-Kauf, als Teil des Auftrags;
        // sie sind dort kein „selbst bereitzustellen“, sondern ein Download wie aus dem Meta-Store.
        func ownToProvide(_ f: RecipeFile) -> Bool { f.source?.kind == .user && !(r.source == .steam && f.source?.steam != nil) }
        var byUser = missing.filter(ownToProvide).map { f in f.source?.hint.map { "\(f.name) – \($0)" } ?? f.name }
        byUser += treesMissing.filter { $0.source.kind == .user }.map { t in t.source.hint.map { "\(t.name) – \($0)" } ?? t.name }

        var onDevice = OnDevice.unknown
        var builtWith: AppStamp.Built?
        if let apps {
            let bundle = Toolchain.bundleId(target: r.toolchain.target, prefix: bundlePrefix)
            if let app = apps.first(where: { $0.bundleIdentifier == bundle }) {
                let stamp = "\(app.version ?? "?") (\(app.bundleVersion ?? "?"))"
                let built = app.bundleVersion.flatMap(AppStamp.parse)
                if app.version == AppStamp.short(versionName: r.versionName), let b = app.bundleVersion,
                   b.hasPrefix("\(r.versionCode).") {
                    builtWith = built
                    let number = built?.toolchain ?? 0
                    let otherSetting = pin == nil && experimental.map { $0 != (built?.experimental ?? false) } ?? false
                    let outdated = pin.map { number != $0.version || built?.modified != $0.modified } ?? toolchainVersion.map { number < $0 } ?? false
                        || otherSetting
                    onDevice = outdated ? .olderToolchain(stamp: stamp) : .current(stamp: stamp)
                } else if let installed = built?.versionCode, otherSourceBuilds.contains(installed) {
                    onDevice = .otherSource(stamp: stamp)
                } else if let installed = built?.versionCode, installed > 0, installed < r.versionCode {
                    builtWith = built
                    // Der Stempel dieses Werkzeugs ist „<Versionscode>.<Toolchain>“: Eine kleinere erste Zahl ist
                    // dasselbe Spiel in einer älteren Fassung.
                    onDevice = .olderGame(stamp: stamp)
                } else {
                    onDevice = .unstamped(stamp: stamp)
                }
            } else {
                onDevice = .notInstalled
            }
        }
        return GameStatus(filesPresent: required.count - missing.count, filesRequired: required.count,
                          treesPresent: trees.count - treesMissing.count, treesRequired: trees.count,
                          bytesToDownload: missing.filter { !ownToProvide($0) }.reduce(0) { $0 + ($1.size ?? 0) }
                              + treesMissing.filter { $0.source.kind == .url }.reduce(0) { $0 + ($1.source.archive?.size ?? 0) },
                          filesToDownload: missing.filter { !ownToProvide($0) }.count + treesMissing.filter { $0.source.kind == .url }.count,
                          userProvidedMissing: byUser, onDevice: onDevice, builtWith: builtWith)
    }
}
