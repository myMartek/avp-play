import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Titelbilder von Spielen, die (noch) nicht geladen sind – damit die Liste nicht nur aus Farbflächen besteht.
/// Sie kommen von der öffentlichen Store-Seite des Spiels (`StoreArt`), werden verkleinert und in einem
/// Zwischenspeicher gehalten, den macOS leeren darf und den das Programm selbst begrenzt. Zum Bestand gehören sie
/// nicht: was zu einem geladenen Spiel gehört, liegt weiter bei dessen Dateien.
public struct CoverCache: Sendable {
    public let directory: URL
    /// Längere Seite der gespeicherten Bilder in Pixeln; reicht für Karte und Kopf der Spielseite.
    public static let maxPixels = 1024
    /// So lange gilt „diese Seite hat kein passendes Bild“, bevor wieder gefragt wird.
    public static let missLifetime: TimeInterval = 7 * 24 * 3600

    public init(directory: URL = CoverCache.defaultDirectory) { self.directory = directory }

    /// `~/Library/Caches/AVPPlay/covers`; mit `AVPPLAY_HOME` darunter, damit ein Probelauf den echten nicht anfasst.
    public static var defaultDirectory: URL {
        if ProcessInfo.processInfo.environment["AVPPLAY_HOME"] != nil {
            return DataLocation.base.appendingPathComponent("cache/covers", isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(DataLocation.folderName)/covers", isDirectory: true)
    }

    /// Eine Meta-Store-Kennung, oder `steam-<App-ID>` für das Bild eines Steam-Spiels.
    static func isAppId(_ id: String) -> Bool {
        let digits = id.hasPrefix(steamPrefix) ? String(id.dropFirst(steamPrefix.count)) : id
        return !digits.isEmpty && digits.count <= 24 && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }
    public static let steamPrefix = "steam-"
    func imageFile(_ appId: String) -> URL { directory.appendingPathComponent("\(appId).jpg") }
    func missFile(_ appId: String) -> URL { directory.appendingPathComponent("\(appId).none") }

    public func cached(appId: String) -> Data? {
        guard CoverCache.isAppId(appId) else { return nil }
        return try? Data(contentsOf: imageFile(appId))
    }

    /// Wurde vor Kurzem festgestellt, dass es für dieses Spiel kein Bild gibt?
    public func isKnownMissing(appId: String, now: Date = Date()) -> Bool {
        guard CoverCache.isAppId(appId),
              let date = (try? FileManager.default.attributesOfItem(atPath: missFile(appId).path))?[.modificationDate] as? Date else { return false }
        return now.timeIntervalSince(date) < CoverCache.missLifetime
    }

    public func noteMissing(appId: String) {
        guard CoverCache.isAppId(appId) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data().write(to: missFile(appId))
    }

    /// Verkleinert ein geladenes Bild und legt es ab. Gibt zurück, was abgelegt wurde – `nil`, wenn es kein Bild war.
    @discardableResult
    public func store(appId: String, original: Data) -> Data? {
        guard CoverCache.isAppId(appId), let small = CoverCache.thumbnail(original) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? small.write(to: imageFile(appId), options: .atomic)
        try? FileManager.default.removeItem(at: missFile(appId))
        return small
    }

    /// Ein JPEG mit höchstens `maxPixels` an der längeren Seite.
    static func thumbnail(_ original: Data, maxPixels: Int = CoverCache.maxPixels) -> Data? {
        guard let source = CGImageSourceCreateWithData(original as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// Was der Zwischenspeicher belegt.
    public func size() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    public func clear() { try? FileManager.default.removeItem(at: directory) }

    /// Hält den Zwischenspeicher unter einer Grenze: die am längsten nicht mehr angefassten Bilder gehen zuerst.
    public func prune(maxBytes: Int64 = 300_000_000) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? [])
            .compactMap { url -> (URL, Int64, Date)? in
                guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
                return (url, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
            }
        var total = files.reduce(0) { $0 + $1.1 }
        for file in files.sorted(by: { $0.2 < $1.2 }) where total > maxBytes {
            try? FileManager.default.removeItem(at: file.0)
            total -= file.1
        }
    }
}

/// Besorgt Titelbilder für die Liste: erst aus dem Speicher, dann aus dem Zwischenspeicher auf der Platte, zuletzt
/// von der Store-Seite – dort höchstens zwei Abrufe zugleich, der zuletzt gefragte zuerst (wer scrollt, will das
/// sehen, was gerade vor ihm liegt), und nie zweimal für dasselbe Spiel. Zeigt die Store-Seite kein Bild und nennt
/// der Katalog eins, kommt es vom Katalogdienst.
public actor CoverLoader {
    private let cache: CoverCache
    private let fetch: @Sendable (String) async -> Data?
    private let fromCatalog: @Sendable (String) async -> Data?
    private let fromSteam: @Sendable (String) async -> Data?
    /// Spiele, bei denen der Katalogdienst in dieser Sitzung nichts geliefert hat – damit eine Karte ohne Netz
    /// nicht bei jedem Erscheinen neu fragt.
    private var catalogFailed: Set<String> = []
    private var memory: [String: Data] = [:]
    private var order: [String] = []
    private var running: [String: Task<Data?, Never>] = [:]
    private var free: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let memoryLimit = 400

    public init(cache: CoverCache = CoverCache(), concurrent: Int = 2,
                fromCatalog: @escaping @Sendable (String) async -> Data? = { await CatalogClient().cover(appId: $0) },
                fromSteam: @escaping @Sendable (String) async -> Data? = { await SteamArt().landscapeCover(steamAppId: $0) },
                fetch: @escaping @Sendable (String) async -> Data? = { await StoreArt().landscapeCover(appId: $0) }) {
        self.cache = cache
        self.fetch = fetch
        self.fromSteam = fromSteam
        self.fromCatalog = fromCatalog
        self.free = max(1, concurrent)
    }

    /// Das Bild für ein Spiel aus dem Store, verkleinert. `nil`, wenn es keins gibt, das Netz fehlt oder die
    /// Aufgabe abgebrochen wurde (die Karte ist aus dem Bild gescrollt). `catalogHasOne`: der Katalog nennt ein
    /// eigenes Bild für dieses Spiel; es wird geholt, wenn die Store-Seite keins hergibt – auch dann, wenn das
    /// schon früher festgestellt wurde.
    public func image(appId: String, catalogHasOne: Bool = false) async -> Data? {
        guard CoverCache.isAppId(appId) else { return nil }
        if let hit = memory[appId] { return hit }
        if let task = running[appId] { return await task.value }
        if let disk = cache.cached(appId: appId) { remember(appId, disk); return disk }
        let askCatalog = catalogHasOne && !catalogFailed.contains(appId)
        let storeHasNone = cache.isKnownMissing(appId: appId)
        if storeHasNone && !askCatalog { return nil }

        await acquire()
        // Wer lange gewartet hat, ist vielleicht nicht mehr gefragt – oder ein anderer hat es inzwischen geholt.
        if Task.isCancelled { release(); return nil }
        if let hit = memory[appId] { release(); return hit }
        if let task = running[appId] { release(); return await task.value }
        let cache = cache, fetch = fetch, fromCatalog = fromCatalog, fromSteam = fromSteam
        // Ein Steam-Spiel (`steam-<App-ID>`) hat sein Bild bei Valve, nicht auf einer Seite des Meta-Stores.
        let steamApp: String? = appId.hasPrefix(CoverCache.steamPrefix) ? String(appId.dropFirst(CoverCache.steamPrefix.count)) : nil
        let task = Task<Data?, Never> {
            let original: Data?
            if storeHasNone { original = nil }
            else if let steamApp { original = await fromSteam(steamApp) }
            else { original = await fetch(appId) }
            if let original, let small = cache.store(appId: appId, original: original) { return small }
            if askCatalog, let original = await fromCatalog(appId), let small = cache.store(appId: appId, original: original) { return small }
            cache.noteMissing(appId: appId)
            return nil
        }
        running[appId] = task
        let result = await task.value
        running[appId] = nil
        if let result { remember(appId, result) } else if askCatalog { catalogFailed.insert(appId) }
        release()
        return result
    }

    private func remember(_ appId: String, _ data: Data) {
        if memory[appId] == nil { order.append(appId) }
        memory[appId] = data
        while order.count > memoryLimit { memory[order.removeFirst()] = nil }
    }

    private func acquire() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if let next = waiters.popLast() { next.resume() } else { free += 1 }
    }
}
