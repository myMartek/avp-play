import Foundation

public enum WindowsVRLibraryError: Error, LocalizedError, Sendable {
    case corruptLibrary
    case unsupportedLibraryVersion(Int)
    case invalidBookmark
    case noActiveGame
    case noSavedGame
    case noSelectedProfile
    case invalidProfileName
    case invalidProfileArguments

    public var errorDescription: String? {
        switch self {
        case .corruptLibrary:
            L("The local Windows VR library could not be decoded. The saved file was left untouched.", "Die lokale Windows-VR-Bibliothek konnte nicht gelesen werden. Die gespeicherte Datei blieb unverändert.")
        case .unsupportedLibraryVersion(let version):
            L("The local Windows VR library uses unsupported schema version \(version).", "Die lokale Windows-VR-Bibliothek verwendet die nicht unterstützte Schemaversion \(version).")
        case .invalidBookmark:
            L("The saved game folder permission is no longer valid. Select the folder again to restore access.", "Die gespeicherte Berechtigung für den Spielordner ist nicht mehr gültig. Wähle den Ordner erneut aus, um den Zugriff wiederherzustellen.")
        case .noActiveGame:
            L("Import a manifest and select its game folder before saving it to the library.", "Importiere ein Manifest und wähle den zugehörigen Spielordner aus, bevor du das Spiel in der Bibliothek speicherst.")
        case .noSavedGame:
            L("Save this game to the local library before saving profiles.", "Speichere dieses Spiel zuerst in der lokalen Bibliothek, bevor du Profile speicherst.")
        case .noSelectedProfile:
            L("Select a saved profile first.", "Wähle zuerst ein gespeichertes Profil aus.")
        case .invalidProfileName:
            L("A profile name must contain between 1 and 80 characters.", "Ein Profilname muss zwischen 1 und 80 Zeichen lang sein.")
        case .invalidProfileArguments:
            L("A profile may contain at most 64 launch arguments, and arguments cannot contain NUL characters.", "Ein Profil darf höchstens 64 Startargumente enthalten. Argumente dürfen keine Nullzeichen enthalten.")
        }
    }
}

/// A named, per-game launch configuration. It is stored separately from the
/// version-1 manifest so existing manifest and plugin JSON contracts stay intact.
public struct WindowsVRLaunchProfile: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var backend: WindowsRuntimeBackend
    public var graphics: WindowsGraphicsAPI
    public var launchArguments: [String]
    public var environment: [String: String]
    public var renderScale: Float

    public init(
        id: String = UUID().uuidString,
        name: String,
        backend: WindowsRuntimeBackend,
        graphics: WindowsGraphicsAPI,
        launchArguments: [String],
        environment: [String: String] = [:],
        renderScale: Float = 1
    ) throws {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.count <= 80 else {
            throw WindowsVRLibraryError.invalidProfileName
        }
        guard renderScale.isFinite, renderScale >= 0.5, renderScale <= 1,
              launchArguments.count <= 64,
              launchArguments.allSatisfy({ !$0.contains("\0") }) else {
            throw WindowsVRLibraryError.invalidProfileArguments
        }
        self.id = id
        self.name = cleanName
        self.backend = backend
        self.graphics = graphics
        self.launchArguments = launchArguments
        self.environment = environment
        self.renderScale = renderScale
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, backend, graphics, launchArguments, environment, renderScale
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(String.self, forKey: .id),
            name: values.decode(String.self, forKey: .name),
            backend: values.decode(WindowsRuntimeBackend.self, forKey: .backend),
            graphics: values.decode(WindowsGraphicsAPI.self, forKey: .graphics),
            launchArguments: values.decode([String].self, forKey: .launchArguments),
            environment: values.decodeIfPresent([String: String].self, forKey: .environment) ?? [:],
            renderScale: values.decodeIfPresent(Float.self, forKey: .renderScale) ?? 1
        )
    }

    public func validate() throws {
        guard !id.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 80 else { throw WindowsVRLibraryError.invalidProfileName }
        guard renderScale.isFinite, renderScale >= 0.5, renderScale <= 1,
              launchArguments.count <= 64,
              launchArguments.allSatisfy({ !$0.utf8.contains(0) && $0.utf8.count <= 4096 }),
              environment.count <= 128,
              environment.allSatisfy({ !$0.key.isEmpty && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) }) else {
            throw WindowsVRLibraryError.invalidProfileArguments
        }
    }

    public func applying(to manifest: WindowsGameManifest) throws -> WindowsGameManifest {
        try validate()
        return try WindowsGameManifest(
            id: manifest.id,
            title: manifest.title,
            executableRelativePath: manifest.executableRelativePath,
            backend: backend,
            graphics: graphics,
            launchArguments: launchArguments,
            environment: environment,
            schemaVersion: manifest.schemaVersion
        )
    }
}

/// One locally stored game and its bookmark-backed folder permission.
public struct WindowsVRLibraryEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var manifest: WindowsGameManifest
    public var folderBookmark: Data
    public var profiles: [WindowsVRLaunchProfile]
    public var selectedProfileID: String?
    public var addedAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        manifest: WindowsGameManifest,
        folderBookmark: Data,
        profiles: [WindowsVRLaunchProfile],
        selectedProfileID: String?,
        addedAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.manifest = manifest
        self.folderBookmark = folderBookmark
        self.profiles = profiles
        self.selectedProfileID = selectedProfileID
        self.addedAt = addedAt
        self.updatedAt = updatedAt
    }

    public var selectedProfile: WindowsVRLaunchProfile? {
        profiles.first(where: { $0.id == selectedProfileID }) ?? profiles.first
    }
}

/// File-backed, app-container-local library. Bookmarks are resolved only when
/// the user selects a library item; callers must start and later stop its scope.
public enum WindowsVRLibraryStore {
    private static let schemaVersion = 1
    private static let fileName = "windows-vr-library-v1.json"

    public static func load() throws -> [WindowsVRLibraryEntry] {
        let url = try libraryURL(createDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 32 * 1024 * 1024 else { throw WindowsVRLibraryError.corruptLibrary }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(LibraryFile.self, from: data)
            guard file.schemaVersion == schemaVersion else {
                throw WindowsVRLibraryError.unsupportedLibraryVersion(file.schemaVersion)
            }
            try validateEntries(file.entries)
            return file.entries
        } catch let error as WindowsVRLibraryError {
            throw error
        } catch {
            throw WindowsVRLibraryError.corruptLibrary
        }
    }

    public static func save(_ entries: [WindowsVRLibraryEntry]) throws {
        try validateEntries(entries)
        let url = try libraryURL(createDirectory: true)
        let file = LibraryFile(schemaVersion: schemaVersion, entries: entries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(file).write(to: url, options: .atomic)
        } catch {
            throw error
        }
    }

    public static func makeFolderBookmark(for url: URL) throws -> Data {
        guard url.isFileURL else { throw WindowsVRLibraryError.invalidBookmark }
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public static func resolveFolderBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard url.isFileURL else { throw WindowsVRLibraryError.invalidBookmark }
            return (url, isStale)
        } catch {
            throw WindowsVRLibraryError.invalidBookmark
        }
    }

    private static func validateEntries(_ entries: [WindowsVRLibraryEntry]) throws {
        guard entries.count <= 10_000, Set(entries.map { $0.id }).count == entries.count else {
            throw WindowsVRLibraryError.corruptLibrary
        }
        for entry in entries {
            guard !entry.id.isEmpty, !entry.folderBookmark.isEmpty,
                  entry.profiles.count <= 256,
                  Set(entry.profiles.map { $0.id }).count == entry.profiles.count,
                  entry.selectedProfileID == nil || entry.profiles.contains(where: { $0.id == entry.selectedProfileID }) else {
                throw WindowsVRLibraryError.corruptLibrary
            }
            try entry.manifest.validate()
            for profile in entry.profiles { try profile.validate() }
        }
    }

    private static func libraryURL(createDirectory: Bool) throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = support.appendingPathComponent("WindowsVRLibrary", isDirectory: true)
        if createDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }

    private struct LibraryFile: Codable {
        let schemaVersion: Int
        let entries: [WindowsVRLibraryEntry]
    }
}
