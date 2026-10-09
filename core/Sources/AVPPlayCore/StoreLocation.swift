import Foundation

/// Wo die heruntergeladenen Spieldateien liegen. Üblicherweise neben den übrigen Daten des Programms; wer den
/// Platz dafür lieber auf einer anderen Platte hat – Spiele belegen schnell zweistellige Gigabyte –, wählt
/// einen eigenen Ordner. Die Wahl steht in einer kleinen Datei bei den Daten des Programms, damit die
/// Oberfläche und die Kommandozeile denselben Ort benutzen.
public enum StoreLocation {
    /// Der Ordner, den das Programm in einem gewählten Ordner anlegt: Die Spiele sollen nicht lose zwischen
    /// fremden Dateien liegen.
    public static let folderName = "AVP Play Downloads"

    /// Der Ort, wenn nichts gewählt ist.
    public static func standard(base: URL = DataLocation.base) -> URL {
        base.appendingPathComponent("store", isDirectory: true)
    }

    static func settingsFile(base: URL) -> URL { base.appendingPathComponent("settings.json") }

    private struct Settings: Codable {
        var store: String?
        /// Die Kennung des Laufwerks, auf dem der gewählte Ordner lag, als er gewählt wurde.
        var volume: String?
    }

    private static func settings(base: URL) -> Settings? {
        guard let data = try? Data(contentsOf: settingsFile(base: base)) else { return nil }
        return try? JSONDecoder().decode(Settings.self, from: data)
    }

    /// Die Kennung des Laufwerks, auf dem ein Pfad gerade liegt (gemessen am nächsten vorhandenen Ordner).
    static func volumeIdentity(of url: URL) -> String? {
        let fm = FileManager.default
        var dir = url.standardizedFileURL
        while !fm.fileExists(atPath: dir.path), dir.path != "/" { dir.deleteLastPathComponent() }
        return try? dir.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }

    /// Der gewählte Ort; `nil`, wenn der übliche gilt.
    public static func custom(base: URL = DataLocation.base) -> URL? {
        guard let path = settings(base: base)?.store, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Der Ort, der gilt.
    public static func current(base: URL = DataLocation.base) -> URL { custom(base: base) ?? standard(base: base) }

    /// Legt den Ort fest; `nil` stellt den üblichen wieder her. Verschoben wird dabei nichts.
    public static func set(_ url: URL?, base: URL = DataLocation.base) throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let file = settingsFile(base: base)
        guard let url, url.standardizedFileURL.path != standard(base: base).standardizedFileURL.path else {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Settings(store: url.standardizedFileURL.path, volume: volumeIdentity(of: url))).write(to: file, options: .atomic)
    }

    /// Der Ordner, der für einen vom Nutzer gewählten Ordner benutzt wird: ein eigener Unterordner – es sei denn,
    /// der gewählte heißt schon so.
    public static func folder(in chosen: URL) -> URL {
        chosen.lastPathComponent == folderName ? chosen : chosen.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Ist der Ort gerade erreichbar? Ein Ordner auf einer externen Platte ist es nicht, solange die Platte nicht
    /// angeschlossen ist – dann darf nichts geladen werden, als gäbe es die Dateien nicht.
    ///
    /// Erkannt wird das am Laufwerk selbst: Für den gewählten Ordner ist vermerkt, auf welchem Laufwerk er lag.
    /// Fehlt die Platte, führt derselbe Pfad auf ein anderes Laufwerk (oder ins Leere unter `/Volumes`).
    public static func isAvailable(_ root: URL, base: URL = DataLocation.base) -> Bool {
        let fm = FileManager.default
        var dir = root.standardizedFileURL
        // Der nächste vorhandene Ordner oberhalb: Ist das der Sammelordner der Laufwerke, fehlt das Laufwerk.
        while !fm.fileExists(atPath: dir.path), dir.path != "/" { dir.deleteLastPathComponent() }
        if dir.path == "/Volumes" { return false }
        if let chosen = settings(base: base), let path = chosen.store, let volume = chosen.volume,
           URL(fileURLWithPath: path).standardizedFileURL.path == root.standardizedFileURL.path {
            return volumeIdentity(of: root) == volume
        }
        return true
    }

    /// Wie viel Platz an einem Ort frei ist (gemessen am nächsten vorhandenen Ordner). Für das Startlaufwerk nennt
    /// macOS eine Zahl, die Löschbares mitzählt; für andere Laufwerke – externe Platten – ist genau diese Zahl
    /// null, und es gilt die schlichte.
    public static func freeBytes(at url: URL) -> Int64? {
        let fm = FileManager.default
        var dir = url.standardizedFileURL
        while !fm.fileExists(atPath: dir.path), dir.path != "/" { dir.deleteLastPathComponent() }
        let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let generous = values?.volumeAvailableCapacityForImportantUsage ?? 0
        let plain = Int64(values?.volumeAvailableCapacity ?? 0)
        guard values != nil else { return nil }
        return max(generous, plain)
    }

    /// Liegen zwei Orte auf demselben Laufwerk? Dann kostet Verschieben nichts und eine Kopie keinen Platz.
    public static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        func volume(_ url: URL) -> AnyHashable? {
            let fm = FileManager.default
            var dir = url.standardizedFileURL
            while !fm.fileExists(atPath: dir.path), dir.path != "/" { dir.deleteLastPathComponent() }
            return (try? dir.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier) as? AnyHashable
        }
        guard let va = volume(a), let vb = volume(b) else { return false }
        return va == vb
    }
}

public enum StoreMoveError: Error, CustomStringConvertible, Equatable {
    case sameFolder
    case notAvailable(String)
    case incomplete(String)
    case stopped

    public var description: String {
        switch self {
        case .sameFolder: return L("That is the folder already in use.", "Das ist der Ordner, der schon benutzt wird.")
        case .notAvailable(let path):
            return L("\(path) cannot be reached – is the disk connected?", "\(path) ist nicht erreichbar – ist die Platte angeschlossen?")
        case .incomplete(let name):
            return L("“\(name)” did not arrive complete at the new place. It was left where it was.", "„\(name)“ ist am neuen Ort nicht vollständig angekommen. Es bleibt, wo es war.")
        case .stopped: return L("Stopped.", "Angehalten.")
        }
    }
}

/// Zieht die heruntergeladenen Dateien an einen anderen Ort um – Spiel für Spiel, und jedes erst dann am alten
/// Ort gelöscht, wenn es am neuen vollständig liegt. Ein abgebrochener Umzug lässt sich wiederholen: Was schon
/// drüben ist, bleibt drüben, der Rest wartet am alten Ort.
public enum StoreMove {
    public struct Progress: Sendable, Equatable {
        public var done: Int64
        public var total: Int64
        public var item: String
        public init(done: Int64, total: Int64, item: String) {
            self.done = done
            self.total = total
            self.item = item
        }
    }

    public struct Result: Sendable, Equatable {
        public var moved: [String] = []
        /// Am neuen Ort gab es schon etwas mit diesem Namen; das am alten Ort blieb liegen.
        public var skipped: [String] = []
    }

    /// Was am alten Ort liegt und umzöge. Halbfertiges eines früheren Versuchs zählt nicht dazu.
    public static func items(in root: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".moving-") && $0.lastPathComponent != ".DS_Store" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Was unter einem Eintrag an Bytes und Dateien liegt (symbolischen Links wird nicht gefolgt).
    public static func measure(_ url: URL) -> (bytes: Int64, files: Int) {
        let fm = FileManager.default
        if let size = ContentStore.fileSize(url) { return (size, 1) }
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return (0, 0) }
        var bytes: Int64 = 0, files = 0
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true { bytes += Int64(values?.fileSize ?? 0); files += 1 }
        }
        return (bytes, files)
    }

    @discardableResult
    /// - Parameter copying: `nil` entscheidet nach dem Laufwerk; `true` erzwingt den Weg über die Kopie, den ein
    ///   Umzug auf ein anderes Laufwerk nimmt.
    public static func run(from old: URL, to new: URL, copying: Bool? = nil, shouldStop: @Sendable () -> Bool = { false },
                           progress: @Sendable (Progress) -> Void = { _ in }) throws -> Result {
        let fm = FileManager.default
        guard old.standardizedFileURL.path != new.standardizedFileURL.path else { throw StoreMoveError.sameFolder }
        guard StoreLocation.isAvailable(new) else { throw StoreMoveError.notAvailable(new.path) }
        try fm.createDirectory(at: new, withIntermediateDirectories: true)

        let items = StoreMove.items(in: old)
        let sizes = items.map { StoreMove.measure($0) }
        let total = sizes.map(\.bytes).reduce(0, +)
        var done: Int64 = 0
        var result = Result()
        let near = copying.map { !$0 } ?? StoreLocation.sameVolume(old, new)

        for (item, size) in zip(items, sizes) {
            if shouldStop() { throw StoreMoveError.stopped }
            let name = item.lastPathComponent
            let target = new.appendingPathComponent(name)
            progress(Progress(done: done, total: total, item: name))
            if fm.fileExists(atPath: target.path) {
                result.skipped.append(name)
                done += size.bytes
                continue
            }
            if near {
                // Dasselbe Laufwerk: umbenennen, fertig.
                try fm.moveItem(at: item, to: target)
            } else {
                let staging = new.appendingPathComponent(".moving-\(name)")
                try? fm.removeItem(at: staging)
                let base = done
                try copy(item, to: staging, shouldStop: shouldStop) { copied in
                    progress(Progress(done: base + copied, total: total, item: name))
                }
                // Erst wenn drüben dasselbe liegt, verschwindet es hier.
                guard StoreMove.measure(staging) == size else {
                    try? fm.removeItem(at: staging)
                    throw StoreMoveError.incomplete(name)
                }
                try fm.moveItem(at: staging, to: target)
                try fm.removeItem(at: item)
            }
            done += size.bytes
            result.moved.append(name)
        }
        progress(Progress(done: total, total: total, item: ""))
        return result
    }

    /// Kopiert einen Eintrag Datei für Datei, damit sich sagen lässt, wie weit es ist. Ordner und symbolische Links
    /// entstehen als das, was sie sind.
    private static func copy(_ source: URL, to target: URL, shouldStop: () -> Bool, copied report: (Int64) -> Void) throws {
        let fm = FileManager.default
        if ContentStore.fileSize(source) != nil {
            try fm.copyItem(at: source, to: target)
            report(ContentStore.fileSize(target) ?? 0)
            return
        }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        guard let walker = fm.enumerator(atPath: source.path) else { return }
        var bytes: Int64 = 0
        for case let relative as String in walker {
            if shouldStop() {
                try? fm.removeItem(at: target)
                throw StoreMoveError.stopped
            }
            let from = source.appendingPathComponent(relative), to = target.appendingPathComponent(relative)
            switch walker.fileAttributes?[.type] as? FileAttributeType {
            case .typeDirectory?:
                try fm.createDirectory(at: to, withIntermediateDirectories: true)
            case .typeSymbolicLink?:
                try fm.createSymbolicLink(atPath: to.path, withDestinationPath: try fm.destinationOfSymbolicLink(atPath: from.path))
            default:
                try fm.copyItem(at: from, to: to)
                bytes += (walker.fileAttributes?[.size] as? NSNumber)?.int64Value ?? 0
                report(bytes)
            }
        }
    }
}
