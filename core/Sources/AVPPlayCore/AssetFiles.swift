import Foundation

/// One asset pack of a game that lies on the device as a file of its own (Marvel's Deadpool VR's `.lang` voice
/// packs). The game asks the platform which asset files are installed; the toolchain's runtime answers from the
/// list built from these entries (`AssetFilesList`).
public struct AssetFileEntry: Codable, Sendable, Hashable {
    /// The store's asset ID of the pack (digits only).
    public var id: String
    /// The file, relative to the game's OBB folder on the device (`android-files/Android/obb/<package>`).
    public var file: String
    /// The exact size in bytes. The runtime reports the pack as installed only at exactly this size.
    public var size: Int64
    /// The language tag the game is told; without it, the runtime takes the file name up to its first dot.
    public var tag: String?
    /// The store's metadata of the file. Without it: the recipe's `versionName`.
    public var meta: String?

    public init(id: String, file: String, size: Int64, tag: String? = nil, meta: String? = nil) {
        self.id = id
        self.file = file
        self.size = size
        self.tag = tag
        self.meta = meta
    }
}

/// The list `Documents/android-files/klepton-asset-files.txt` in the game's data container, written from the recipe's
/// `assetFiles` on every install and update (the stage step). Format, one line per pack, as the runtime reads it:
///
///     asset <store asset id> <file relative to the OBB folder> <size in bytes> [<tag>] [meta=<text>]
///
/// A title without `assetFiles` (also a newer store build the project has not tested, whose draft drops them) gets no
/// list. A list already on the device is emptied only when its first line shows that AVP Play wrote it (`clearOwn`);
/// any other file there is left alone.
public enum AssetFilesList {
    public static let fileName = "klepton-asset-files.txt"
    /// Where the list goes in the app's data container.
    public static let destination = "Documents/android-files/\(fileName)"
    /// The runtime keeps at most this many entries from one list.
    public static let maxEntries = 32
    /// The first line of every list, so that whoever finds the file on a device knows where it came from.
    public static let header = "# Written by AVP Play from the game's recipe on every install and update. Do not edit."
    /// How a list written by AVP Play begins: the start of `header`, which stays the same when the rest of its
    /// wording changes. A file whose first line does not begin with it is not ours.
    public static let ownerMark = "# Written by AVP Play"

    /// The list for a recipe, or `nil` when the recipe has no `assetFiles`.
    public static func contents(for recipe: Recipe) -> String? {
        guard let entries = recipe.assetFiles else { return nil }
        // The recipe's identifier names the game; a line break in it must not start a line of its own.
        let id = recipe.id.filter { !$0.isNewline }
        var lines = [header, "# \(id) versionCode \(recipe.versionCode)"]
        for e in entries {
            var fields = ["asset", e.id, e.file, String(e.size)]
            if let tag = e.tag { fields.append(tag) }
            fields.append("meta=\(e.meta ?? recipe.versionName)")
            lines.append(fields.joined(separator: " "))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the list into a temporary file, renames it to its final name and hands it to `copy` together with its
    /// destination in the container. Does nothing for a recipe without `assetFiles`.
    /// - Returns: the number of entries written, or `nil` when there was nothing to write.
    @discardableResult
    public static func write(recipe: Recipe, copy: (URL, String) throws -> Void) throws -> Int? {
        guard let text = contents(for: recipe), let count = recipe.assetFiles?.count else { return nil }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("avpplay-assetfiles-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let partial = folder.appendingPathComponent(fileName + ".tmp")
        let final = folder.appendingPathComponent(fileName)
        try Data(text.utf8).write(to: partial)
        try fm.moveItem(at: partial, to: final)
        try copy(final, destination)
        return count
    }

    // MARK: A list left over on the device

    /// The game's data container on the device, as far as the leftover list needs it. `Installer` fills it with
    /// devicectl calls; tests with a dictionary.
    public struct Container {
        /// The size of the regular file at a path in the container, `nil` when there is none.
        public var size: (String) throws -> Int64?
        /// Copies the file at a path in the container to a local file. Nothing on the device changes.
        public var fetch: (String, URL) throws -> Void
        /// Copies a local file to a path in the container, replacing what is there.
        public var put: (URL, String) throws -> Void

        public init(size: @escaping (String) throws -> Int64?, fetch: @escaping (String, URL) throws -> Void,
                    put: @escaping (URL, String) throws -> Void) {
            self.size = size
            self.fetch = fetch
            self.put = put
        }
    }

    /// What `clearOwn` found at `destination`, and did.
    public enum Leftover: Equatable, Sendable {
        /// No file there (or the folder could not be listed), or it is already empty: nothing to do.
        case none
        /// A list AVP Play wrote: it is now empty.
        case cleared
        /// A file AVP Play did not write: left as it is.
        case foreign
        /// The file could not be read: left as it is, since nothing shows it is ours.
        case unreadable
    }

    /// Whether a list's first line is the header AVP Play writes.
    static func isOwn(_ data: Data) -> Bool {
        guard let line = String(decoding: data.prefix(4096), as: UTF8.self).split(separator: "\n", maxSplits: 1,
                                                                                   omittingEmptySubsequences: false).first
        else { return false }
        return line.hasPrefix(ownerMark)
    }

    /// For a recipe without `assetFiles`: empties a list at `destination` that AVP Play wrote for an earlier recipe,
    /// so the runtime no longer reports packs whose IDs and sizes belong to another build. Everything else stays:
    /// a file without AVP Play's header, an empty file, and a file that cannot be listed or read.
    ///
    /// devicectl can copy into an app's data container but not delete in it, so the list is replaced by an empty
    /// file, the same way withdrawn content is taken off the device. The runtime still finds a list then, with no
    /// entries: no asset file is reported as installed.
    /// - Throws: only when emptying the list fails; the list then stays as it was.
    public static func clearOwn(in container: Container) throws -> Leftover {
        guard let size = try? container.size(destination), size > 0 else { return .none }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("avpplay-assetfiles-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: folder) }
        let fetched = folder.appendingPathComponent("fetched", isDirectory: true).appendingPathComponent(fileName)
        let data: Data
        do {
            try fm.createDirectory(at: fetched.deletingLastPathComponent(), withIntermediateDirectories: true)
            try container.fetch(destination, fetched)
            data = try Data(contentsOf: fetched)
        } catch {
            return .unreadable
        }
        guard isOwn(data) else { return .foreign }
        // Under the list's own name, as `write` hands it over.
        let empty = folder.appendingPathComponent("empty", isDirectory: true).appendingPathComponent(fileName)
        try fm.createDirectory(at: empty.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: empty)
        try container.put(empty, destination)
        return .cleared
    }

    /// The rules the runtime applies to each line, checked when the recipe is loaded: a list the runtime would
    /// partly reject should never reach a device.
    static func validate(_ entries: [AssetFileEntry], recipe: Recipe) throws {
        func invalid(_ en: String, _ de: String) -> RecipeError { .invalid(L("asset files: \(en)", "Asset-Dateien: \(de)")) }
        guard !entries.isEmpty else {
            throw invalid("the list is empty; leave 'assetFiles' out instead", "die Liste ist leer; dann 'assetFiles' weglassen")
        }
        guard entries.count <= maxEntries else {
            throw invalid("\(entries.count) entries, at most \(maxEntries) are allowed",
                          "\(entries.count) Einträge, erlaubt sind höchstens \(maxEntries)")
        }
        var ids = Set<String>(), files = Set<String>()
        for e in entries {
            guard (1...20).contains(e.id.count), e.id.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let n = UInt64(e.id), n > 0 else {
                throw invalid("asset ID '\(e.id)' is not a number above 0", "Asset-ID '\(e.id)' ist keine Zahl über 0")
            }
            guard isSafeFile(e.file) else {
                throw invalid("file '\(e.file)' must be a relative path inside the OBB folder, without '.', '..' or blanks",
                              "Datei '\(e.file)' muss ein relativer Pfad im OBB-Ordner sein, ohne '.', '..' oder Leerzeichen")
            }
            guard e.size > 0 else {
                throw invalid("size of '\(e.file)' must be above 0", "Größe von '\(e.file)' muss über 0 liegen")
            }
            // Without a tag the runtime takes the file name up to its first dot; that has to be a valid tag then.
            let base = e.file.split(separator: "/").last.map(String.init) ?? e.file
            let tag = e.tag ?? String(base.prefix { $0 != "." })
            guard isToken(tag, max: 31, extra: "_-") else {
                throw invalid("language tag '\(tag)' of '\(e.file)'", "Sprachkennung '\(tag)' von '\(e.file)'")
            }
            let meta = e.meta ?? recipe.versionName
            guard isToken(meta, max: 63, extra: "._+-") else {
                throw invalid("metadata '\(meta)' of '\(e.file)'", "Metadaten '\(meta)' von '\(e.file)'")
            }
            guard ids.insert(e.id).inserted else {
                throw invalid("asset ID '\(e.id)' appears twice", "Asset-ID '\(e.id)' kommt doppelt vor")
            }
            guard files.insert(e.file).inserted else {
                throw invalid("file '\(e.file)' appears twice", "Datei '\(e.file)' kommt doppelt vor")
            }
            // The same pack as a file of the recipe: the sizes must agree, or the runtime would never call it installed.
            if let listed = recipe.files.first(where: { $0.id == e.id }), let size = listed.size, size != e.size {
                throw invalid("size of '\(e.file)' differs from the recipe's file '\(listed.name)'",
                              "Größe von '\(e.file)' weicht von der Rezeptdatei '\(listed.name)' ab")
            }
        }
    }

    /// Relative, every component a real name, nothing the runtime's line parser would split or reject.
    static func isSafeFile(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count < 256, !s.hasPrefix("/") else { return false }
        guard s.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value != 0x7f && $0 != "\\"
                                             && !CharacterSet.whitespacesAndNewlines.contains($0) }) else { return false }
        return s.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func isToken(_ s: String, max: Int, extra: String) -> Bool {
        (1...max).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || extra.contains($0)) }
    }
}
