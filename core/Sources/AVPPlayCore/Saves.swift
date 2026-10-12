import Foundation

/// Eine Datei eines Spielstands, wie sie auf dem Gerät lag: ihr Pfad unterhalb von `SaveRules.root`, ihre Größe und
/// wann das Spiel sie zuletzt geändert hat.
public struct SaveFile: Codable, Sendable, Equatable {
    public var path: String
    public var size: Int64
    public var modified: Date?
}

/// Ein Stand der Spielstände eines Spiels, vom Gerät geholt. Jeder Stand ist ein eigener Ordner auf dem Mac: Ein
/// Abgleich, der eine leere oder kaputte Datei holt, überschreibt so nie den letzten guten.
public struct SaveSnapshot: Codable, Sendable, Equatable, Identifiable {
    /// Der Name des Ordners: der Zeitpunkt, lesbar.
    public var id: String
    public var taken: Date
    public var title: String
    public var bundle: String
    public var files: [SaveFile]

    public var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

/// Was als Spielstand gilt.
///
/// Ein Spiel aus einem APK schreibt alles, was es behält, unter einen Ordner: Spielstände, Einstellungen, aber auch
/// Zwischenspeicher – und daneben liegt, was der Mac selbst dorthin kopiert hat (die großen Datendateien). Was davon
/// ein Spielstand ist, sagt kein Spiel. Die Regel hier ist deshalb: alles, was das Spiel geschrieben hat, außer dem,
/// was sich erkennbar neu erzeugen lässt oder vom Mac stammt, und nichts Großes.
public enum SaveRules {
    /// Der Ordner im Datencontainer, unter dem ein APK-Spiel schreibt.
    public static let root = "Documents/android-files"
    /// Größer ist kein Spielstand.
    public static let largestFile: Int64 = 32 << 20
    /// Mehr ist kein Spielstand, sondern ein Datenordner, den die Regel nicht erkannt hat – dann wird nichts geholt.
    public static let mostFiles = 2000
    public static let mostBytes: Int64 = 512 << 20

    /// Ordnernamen, unter denen nichts liegt, das aufzuheben wäre: neu Erzeugbares, Protokolle, vom Mac Kopiertes.
    /// „downloaded“ ist, was ein Spielserver nachgeliefert hat (Counter-Strike: Karten und Musik); „eyedump“ legt die
    /// Toolchain beim Untersuchen der Darstellung an. Beides lag am 2026-10-11 auf einer Vision Pro zwischen den Ständen.
    static let skippedFolders: Set<String> = ["il2cpp", "logs", "crashes", "paks", "obb", "klepton-assets", "unity", ".fbns", "tmp", "temp",
                                              "crashreportclient", "analytics", "automation", "downloaded", "downloads", "eyedump"]
    static let skippedExtensions: Set<String> = ["log", "apk", "obb", "pak", "pk3", "pk4", "wad", "bsp", "vpk", "so", "tmp", "dmp"]

    /// Was der Mac selbst aufs Gerät gebracht hat.
    public struct Staged: Sendable, Equatable {
        /// Pfad unterhalb von `root` -> Größe im Bestand. Liegt die Datei drüben in genau dieser Größe, ist sie unverändert.
        public var files: [String: Int64] = [:]
        /// Ordner, deren Inhalt der Mac kopiert hat, ohne dass sich gerade sagen ließe, welche Dateien es waren
        /// (die Dateien des Spiels liegen nicht mehr auf dem Mac). Darunter wird nichts geholt.
        public var closedFolders: [String] = []
        public init() {}
    }

    public static func isSave(_ path: String, size: Int64, staged: Staged = Staged()) -> Bool {
        let parts = path.split(separator: "/").map { $0.lowercased() }
        guard let name = parts.last, !parts.contains(".."), !path.hasPrefix("/"), size > 0, size <= largestFile else { return false }
        if staged.files[path] == size { return false }
        if staged.closedFolders.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return false }
        // Was die Toolchain selbst ablegt, heißt nach ihr.
        if name.hasPrefix("klepton-") || name.hasPrefix(".klepton") || name.hasPrefix(".avpplay") { return false }
        if let dot = name.lastIndex(of: "."), skippedExtensions.contains(String(name[name.index(after: dot)...])) { return false }
        return !parts.dropLast().contains { skippedFolders.contains($0) || $0.contains("cache") }
    }
}

public enum SaveError: Error, CustomStringConvertible, Equatable {
    case tooMuch(files: Int, bytes: Int64)
    case nothingSaved(String)
    case notConnected(String)

    public var description: String {
        switch self {
        case .tooMuch(let files, let bytes):
            return L("\(files) files (\(Installer.gigabytes(bytes))) on the Vision Pro look like saved games, which is more than saved games ever are. Nothing was fetched.",
                     "\(files) Dateien (\(Installer.gigabytes(bytes))) auf der Vision Pro sehen nach Spielständen aus – mehr, als Spielstände je sind. Es wurde nichts geholt.")
        case .notConnected(let path):
            return L("The folder for saved games cannot be reached – is the disk connected? (\(path))",
                     "Der Ordner für Spielstände ist nicht erreichbar – ist die Platte angeschlossen? (\(path))")
        case .nothingSaved(let title):
            return L("No saved games of \(title) are on this Mac yet.", "Von \(title) liegen noch keine Spielstände auf diesem Mac.")
        }
    }
}

/// Die Spielstände auf dem Mac: ein Ordner je Spiel, darin ein Ordner je Stand.
///
/// Sie liegen dort, wo auch die Downloads liegen, aber nicht darin: Hat der Nutzer einen eigenen Ordner gewählt
/// (etwa auf einer externen Platte), steht neben dessen „AVP Play Downloads“ ein „AVP Play Saved Games“; sonst
/// liegen sie bei den Daten des Programms. Im Ordner für Downloads selbst wären sie ein Eintrag der
/// Datenverwaltung, den „Entfernen“ mitnähme – und „Dateien des Spiels entfernen“ soll keinen Spielstand kosten.
public struct SaveStore: Sendable {
    public let root: URL
    public init(root: URL = SaveStore.defaultRoot) { self.root = root }

    /// Der Ordner, der neben einem gewählten Ordner für Downloads angelegt wird.
    public static let folderName = "AVP Play Saved Games"

    /// Wo die Spielstände liegen, wenn die Downloads an diesem Ort liegen.
    public static func root(forStore store: URL, base: URL = DataLocation.base) -> URL {
        store.standardizedFileURL.path == StoreLocation.standard(base: base).standardizedFileURL.path
            ? base.appendingPathComponent("saves", isDirectory: true)
            : store.standardizedFileURL.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true)
    }

    public static var defaultRoot: URL { root(forStore: StoreLocation.current()) }

    /// Zieht die Spielstände von einem Ort an einen anderen – wenn der Ordner für Downloads wechselt, oder einmalig
    /// von den Daten des Programms neben einen schon gewählten Ordner. Was am Ziel schon liegt, bleibt dort und am
    /// alten Ort; nichts wird überschrieben. Sagt, wie viele Stände umgezogen sind.
    @discardableResult
    public static func move(from old: URL, to new: URL) -> Int {
        let fm = FileManager.default
        guard old.standardizedFileURL.path != new.standardizedFileURL.path,
              let games = try? fm.contentsOfDirectory(atPath: old.path), !games.filter({ !$0.hasPrefix(".") }).isEmpty else { return 0 }
        var moved = 0
        for game in games where !game.hasPrefix(".") {
            let from = old.appendingPathComponent(game, isDirectory: true), to = new.appendingPathComponent(game, isDirectory: true)
            guard (try? fm.createDirectory(at: to, withIntermediateDirectories: true)) != nil else { continue }
            for snapshot in (try? fm.contentsOfDirectory(atPath: from.path)) ?? [] where !snapshot.hasPrefix(".") {
                let target = to.appendingPathComponent(snapshot)
                if !fm.fileExists(atPath: target.path), (try? fm.moveItem(at: from.appendingPathComponent(snapshot), to: target)) != nil { moved += 1 }
            }
            // Leer geworden: weg damit. Ist etwas geblieben, schlägt das fehl, und so soll es sein.
            try? fm.removeItem(at: from.appendingPathComponent(".DS_Store"))
            rmdir(from.path)
        }
        try? fm.removeItem(at: old.appendingPathComponent(".DS_Store"))
        rmdir(old.path)
        return moved
    }
    /// So viele Stände bleiben je Spiel; ältere gehen.
    public static let kept = 12

    /// Woran ein Spiel wiedererkannt wird, auch wenn aus einem Entwurf ein mitgeliefertes Rezept wird.
    public static func key(for recipe: Recipe) -> String { recipe.store.appId ?? recipe.id }

    /// Der Ordner eines Spiels: sein Name, damit ein Mensch ihn findet, und in Klammern die Kennung, an der das
    /// Programm ihn wiederfindet. Gibt es schon einen mit dieser Kennung, gilt der – auch unter älterem Namen.
    public func directory(for recipe: Recipe) -> URL {
        let suffix = " [\(SaveStore.key(for: recipe))]"
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.first { $0.hasSuffix(suffix) }
        return root.appendingPathComponent(existing ?? StoreIndex.fileSafe(recipe.title) + suffix, isDirectory: true)
    }

    static func manifestURL(_ directory: URL) -> URL { directory.appendingPathComponent("manifest.json") }

    /// Die Stände eines Spiels, der neueste zuerst.
    public func snapshots(for recipe: Recipe) -> [SaveSnapshot] {
        let directory = directory(for: recipe)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.compactMap { name -> SaveSnapshot? in
            guard let data = try? Data(contentsOf: SaveStore.manifestURL(directory.appendingPathComponent(name))),
                  var snapshot = try? JSONDecoder.iso.decode(SaveSnapshot.self, from: data) else { return nil }
            snapshot.id = name
            return snapshot
        }.sorted { $0.taken > $1.taken }
    }

    public func directory(of snapshot: SaveSnapshot, for recipe: Recipe) -> URL {
        directory(for: recipe).appendingPathComponent(snapshot.id, isDirectory: true)
    }

    /// Wo eine Datei eines Stands auf dem Mac liegt.
    public func url(of file: SaveFile, in snapshot: SaveSnapshot, for recipe: Recipe) -> URL {
        directory(of: snapshot, for: recipe).appendingPathComponent("files", isDirectory: true).appendingPathComponent(file.path)
    }

    /// Entfernt die ältesten Stände, bis höchstens `keep` bleiben.
    public func prune(recipe: Recipe, keep: Int = SaveStore.kept) {
        for old in snapshots(for: recipe).dropFirst(max(1, keep)) {
            try? FileManager.default.removeItem(at: directory(of: old, for: recipe))
        }
    }
}

/// Holt Spielstände von der Vision Pro und spielt sie dorthin zurück.
public struct SaveSync: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// Auf dem Gerät liegt nichts, das ein Spielstand wäre.
        case nothingThere
        /// Alles ist schon auf dem Mac, im genannten Stand.
        case unchanged(SaveSnapshot)
        /// Ein neuer Stand; so viele Dateien kamen dafür vom Gerät, der Rest lag schon im Stand davor.
        case saved(SaveSnapshot, fetched: Int)
    }

    let control = DeviceControl()
    public let saves: SaveStore
    public let store: ContentStore
    /// - Parameter saves: wo die Stände liegen; ohne Angabe dort, wo sie zum Ordner für Downloads gehören.
    public init(saves: SaveStore? = nil, store: ContentStore) {
        self.saves = saves ?? SaveStore(root: SaveStore.root(forStore: store.root))
        self.store = store
    }

    /// Ist der Ort der Spielstände gerade da? Neben einem Ordner auf einer externen Platte nur, solange die Platte
    /// angeschlossen ist – sonst entstünde derselbe Pfad leer auf dem Startlaufwerk.
    public var available: Bool {
        if saves.root.standardizedFileURL.path == SaveStore.root(forStore: store.root).standardizedFileURL.path {
            return StoreLocation.isAvailable(store.root)
        }
        return true
    }

    /// Was der Mac für dieses Spiel unter `SaveRules.root` kopiert: die Dateien des Rezepts und die Datenordner.
    public static func staged(recipe: Recipe, store: ContentStore) -> SaveRules.Staged {
        var staged = SaveRules.Staged()
        let prefix = SaveRules.root + "/"
        for file in recipe.files {
            guard let destination = StagePlan.destination(for: file), destination.hasPrefix(prefix) else { continue }
            let size = ContentStore.fileSize(store.url(for: file, in: recipe)) ?? file.size
            if let size { staged.files[String(destination.dropFirst(prefix.count))] = size }
        }
        let trees = TreeStore(store: store)
        for tree in TreeStore.dataTrees(of: recipe) {
            guard let dest = tree.dest, ("Documents/" + dest + "/").hasPrefix(prefix) || "Documents/" + dest == SaveRules.root else { continue }
            let below = String(("Documents/" + dest + "/").dropFirst(prefix.count))   // "" oder "Ordner/"
            let listing = TreeStore.listing(of: trees.url(for: tree, in: recipe))
            if listing.isEmpty {
                // Ohne den Baum im Bestand lässt sich nicht sagen, welche Dateien drüben vom Mac stammen.
                if !below.isEmpty { staged.closedFolders.append(String(below.dropLast())) }
            } else {
                for (path, size) in listing { staged.files[below + path] = size }
            }
        }
        return staged
    }

    /// Unter welcher Kennung das Spiel auf dem Gerät liegt: die bei der Installation gemerkte, sonst die unter dem
    /// Präfix der App, sonst die übliche. `nil`, wenn keine davon installiert ist.
    public static func installedBundle(recipe: Recipe, store: ContentStore, prefix: String?, apps: [InstalledApp]) -> String? {
        let target = recipe.toolchain.target
        let candidates = [SigningRecord.load(store: store, recipe: recipe)?.bundleId,
                          Toolchain.bundleId(target: target, prefix: prefix), Toolchain.defaultBundleId(target: target)].compactMap { $0 }
        return candidates.first { bundle in apps.contains { $0.bundleIdentifier == bundle } }
    }

    static func stampName(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: date)
    }

    /// Aus der Dateiliste des Geräts die Spielstände, nach Pfad geordnet.
    static func select(_ remote: [RemoteFile], staged: SaveRules.Staged) -> [SaveFile] {
        remote.filter { !$0.isDirectory && SaveRules.isSave($0.relativePath, size: $0.size, staged: staged) }
            .map { SaveFile(path: $0.relativePath, size: $0.size, modified: $0.modified) }
            .sorted { $0.path < $1.path }
    }

    /// Holt, was sich seit dem letzten Stand geändert hat, und legt daraus einen neuen Stand an. Auf dem Gerät ändert
    /// das nichts. Was unverändert ist, wird aus dem Stand davor übernommen (als Link, ohne Platz zu kosten).
    public func fetch(recipe: Recipe, device: Device, bundle: String, now: Date = Date(),
                      log: @Sendable (String) -> Void = { _ in }) throws -> Outcome {
        guard available else { throw SaveError.notConnected(saves.root.path) }
        let remote = try control.files(device: device, bundle: bundle, subdirectory: SaveRules.root, recursive: true)
        let wanted = SaveSync.select(remote, staged: SaveSync.staged(recipe: recipe, store: store))
        guard !wanted.isEmpty else { return .nothingThere }
        let bytes = wanted.reduce(Int64(0)) { $0 + $1.size }
        guard wanted.count <= SaveRules.mostFiles, bytes <= SaveRules.mostBytes else { throw SaveError.tooMuch(files: wanted.count, bytes: bytes) }
        let previous = saves.snapshots(for: recipe).first
        if let previous, previous.files == wanted { return .unchanged(previous) }

        let fm = FileManager.default
        let home = saves.directory(for: recipe)
        let incoming = home.appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: incoming.appendingPathComponent("files"), withIntermediateDirectories: true)
        var finished = false
        defer { if !finished { try? fm.removeItem(at: incoming) } }
        let known = Dictionary((previous?.files ?? []).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var fetched = 0
        for file in wanted {
            let target = incoming.appendingPathComponent("files").appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let previous, let before = known[file.path], before == file {
                let have = saves.url(of: before, in: previous, for: recipe)
                if ContentStore.fileSize(have) == file.size {
                    do { try fm.linkItem(at: have, to: target) } catch { try fm.copyItem(at: have, to: target) }
                    continue
                }
            }
            try control.copy(from: device, bundle: bundle, source: "\(SaveRules.root)/\(file.path)", to: target)
            fetched += 1
        }
        var snapshot = SaveSnapshot(id: SaveSync.stampName(now), taken: now, title: recipe.title, bundle: bundle, files: wanted)
        var final = home.appendingPathComponent(snapshot.id, isDirectory: true)
        // Zwei Stände in derselben Sekunde gibt es nur im Test; trotzdem geht keiner verloren.
        var n = 2
        while fm.fileExists(atPath: final.path) {
            snapshot.id = "\(SaveSync.stampName(now)) (\(n))"
            final = home.appendingPathComponent(snapshot.id, isDirectory: true)
            n += 1
        }
        let encoder = JSONEncoder.iso
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: SaveStore.manifestURL(incoming), options: .atomic)
        try fm.moveItem(at: incoming, to: final)
        finished = true
        saves.prune(recipe: recipe)
        log(L("\(recipe.title): \(wanted.count) files of saved games are on this Mac (\(fetched) fetched).",
              "\(recipe.title): \(wanted.count) Dateien mit Spielständen liegen auf diesem Mac (\(fetched) geholt)."))
        return .saved(snapshot, fetched: fetched)
    }

    public enum RestoreMode: Sendable, Equatable {
        /// Nur, wenn auf dem Gerät noch gar kein Spielstand liegt – ein frisch installiertes Spiel bekommt seine
        /// Spielstände, und bei einer Installation über ein bestehendes Spiel bleibt alles, wie es dort ist.
        case ifNoneThere
        /// Was im Stand liegt, ersetzt, was auf dem Gerät liegt. Nur auf ausdrücklichen Wunsch.
        case overwrite
    }

    /// Spielt einen Stand aufs Gerät zurück und sagt, wie viele Dateien es wurden (0: es gab nichts zu tun).
    @discardableResult
    public func restore(_ snapshot: SaveSnapshot, recipe: Recipe, device: Device, bundle: String, mode: RestoreMode) throws -> Int {
        if mode == .ifNoneThere {
            let remote = try control.files(device: device, bundle: bundle, subdirectory: SaveRules.root, recursive: true)
            guard SaveSync.select(remote, staged: SaveSync.staged(recipe: recipe, store: store)).isEmpty else { return 0 }
        }
        var copied = 0
        for file in snapshot.files {
            let local = saves.url(of: file, in: snapshot, for: recipe)
            guard ContentStore.fileSize(local) != nil, SaveRules.isSave(file.path, size: file.size) else { continue }
            try control.copy(local, to: device, bundle: bundle, destination: "\(SaveRules.root)/\(file.path)")
            copied += 1
        }
        return copied
    }
}

/// Ein Durchgang über mehrere Spiele – für den Knopf, den regelmäßigen Abgleich und den Hintergrunddienst.
public enum SaveRound {
    public struct Result: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case saved, unchanged, nothing, running, notInstalled, failed }
        public var recipe: String
        public var title: String
        public var kind: Kind
        public var detail: String
        public var snapshot: SaveSnapshot?
    }

    /// Holt die Spielstände der genannten Spiele, soweit sie installiert sind und gerade nicht laufen. Ein laufendes
    /// Spiel schreibt vielleicht gerade; es ist dran, sobald es beendet ist.
    public static func run(recipes: [Recipe], store: ContentStore, saves: SaveStore? = nil, device: Device,
                           apps: [InstalledApp], running: [String], prefix: String?,
                           log: @Sendable (String) -> Void = { _ in }) -> [Result] {
        let sync = SaveSync(saves: saves, store: store)
        return recipes.map { recipe in
            func result(_ kind: Result.Kind, _ detail: String, _ snapshot: SaveSnapshot? = nil) -> Result {
                Result(recipe: recipe.id, title: recipe.title, kind: kind, detail: detail, snapshot: snapshot)
            }
            guard let bundle = SaveSync.installedBundle(recipe: recipe, store: store, prefix: prefix, apps: apps),
                  let app = apps.first(where: { $0.bundleIdentifier == bundle }) else {
                return result(.notInstalled, L("is not on this Vision Pro.", "ist nicht auf dieser Vision Pro."))
            }
            guard !DeviceControl.isRunning(app, executables: running) else {
                return result(.running, L("is running right now; its saved games are fetched once it has been quit.",
                                          "läuft gerade; seine Spielstände werden geholt, sobald es beendet ist."))
            }
            do {
                switch try sync.fetch(recipe: recipe, device: device, bundle: bundle, log: log) {
                case .nothingThere: return result(.nothing, L("has no saved games on the Vision Pro yet.", "hat auf der Vision Pro noch keine Spielstände."))
                case .unchanged(let snapshot): return result(.unchanged, L("nothing new since the last time.", "nichts Neues seit dem letzten Mal."), snapshot)
                case .saved(let snapshot, _):
                    return result(.saved, snapshot.files.count == 1 ? L("one file fetched.", "eine Datei geholt.")
                                                                    : L("\(snapshot.files.count) files fetched.", "\(snapshot.files.count) Dateien geholt."), snapshot)
                }
            } catch {
                return result(.failed, Redaction.redact("\(error)"))
            }
        }
    }

    /// Dasselbe, wenn noch niemand das Gerät gefragt hat: sucht das Headset, fragt, was installiert ist und was läuft.
    /// `nil`, wenn das Headset nicht erreichbar ist.
    public static func run(recipes: [Recipe], store: ContentStore, saves: SaveStore? = nil, preferredDevice: String?,
                           prefix: String?, log: @Sendable (String) -> Void = { _ in }) -> [Result]? {
        let control = DeviceControl()
        let usable = ((try? control.devices()) ?? []).filter { $0.paired && $0.reachable }
        guard let device = usable.first(where: { $0.udid == preferredDevice }) ?? (usable.count == 1 ? usable[0] : nil),
              let apps = try? control.apps(device: device) else { return nil }
        let here = recipes.filter { SaveSync.installedBundle(recipe: $0, store: store, prefix: prefix, apps: apps) != nil }
        guard !here.isEmpty else { return [] }
        let running = (try? control.runningExecutables(device: device)) ?? []
        return run(recipes: here, store: store, saves: saves, device: device, apps: apps, running: running, prefix: prefix, log: log)
    }
}
