import CryptoKit
import Foundation

public struct WindowsGameTransferProgress: Sendable {
    public enum Phase: String, Sendable {
        case hashing
        case copying
    }

    public let phase: Phase
    public let currentFile: String
    public let completedFiles: Int
    public let totalFiles: Int
    public let completedBytes: Int64
    public let totalBytes: Int64

    public init(phase: Phase, currentFile: String, completedFiles: Int, totalFiles: Int,
                completedBytes: Int64, totalBytes: Int64) {
        self.phase = phase
        self.currentFile = currentFile
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }
}

public struct WindowsGameTransferSummary: Sendable, Equatable {
    public let copiedFiles: Int
    public let resumedFiles: Int
    public let totalFiles: Int
    public let totalBytes: Int64
    public let destination: String
}

/// Copies a user's locally owned Windows game files directly from their source paths through devicectl.
/// The local journal records successful copy commands; it is not remote content verification.
public struct WindowsGameTransfer: Sendable {
    public init() {}

    public func stage(from source: URL, manifest manifestURL: URL, bundleID: String,
                      deviceUDID: String? = nil, owned: Bool,
                      progress: @Sendable (WindowsGameTransferProgress) -> Void = { _ in },
                      report: @Sendable (String) -> Void = { _ in }) throws -> WindowsGameTransferSummary {
        let preflight = try Self.validateLocalInputs(source: source, manifestURL: manifestURL,
                                                     bundleID: bundleID, owned: owned)
        let fm = FileManager.default
        let canonicalRoot = preflight.canonicalRoot
        let canonicalManifest = preflight.canonicalManifest
        let manifest = preflight.manifest
        let manifestDigest = preflight.manifestDigest
        let sourceFiles = preflight.sourceFiles
        let totalBytes = preflight.totalBytes
        let gameRoot = "Documents/WindowsVR/Games/\(manifest.id)"
        let control = DeviceControl()
        let device = try control.pick(udid: deviceUDID)
        let apps = try control.apps(device: device)
        guard let app = apps.first(where: { $0.bundleIdentifier == bundleID }) else {
            throw WindowsGameTransferError.appNotInstalled(bundleID)
        }
        guard let appURL = app.url, !appURL.isEmpty else {
            throw WindowsGameTransferError.appLocationUnknown(bundleID)
        }
        let executables = try control.runningExecutables(device: device)
        guard !DeviceControl.isRunning(app, executables: executables) else {
            throw WindowsGameTransferError.appRunning(bundleID)
        }

        let identity = WindowsGameTransferJournal.Identity(deviceUDID: device.udid, bundleID: bundleID,
                                                           sourcePath: canonicalRoot.path)
        let journalURL = try WindowsGameTransferJournal.url(for: identity)
        report(L("Source: \(canonicalRoot.path) (user attestation: owned); \(sourceFiles.count) files, \(totalBytes) bytes.",
                 "Quelle: \(canonicalRoot.path) (Bestätigung: selbst besessen); \(sourceFiles.count) Dateien, \(totalBytes) Bytes."))
        report(L("Destination game library: \(device.name):\(gameRoot) in app \(bundleID).",
                 "Ziel-Spielebibliothek: \(device.name):\(gameRoot) in App \(bundleID)."))

        var prepared: [WindowsGameTransferFile] = []
        prepared.reserveCapacity(sourceFiles.count)
        var hashedBytes: Int64 = 0
        for (index, file) in sourceFiles.enumerated() {
            let safeURL = try Self.validatedSourceFile(file.relativePath, root: canonicalRoot)
            let digest = try Self.sha256(of: safeURL)
            let currentAttributes = try fm.attributesOfItem(atPath: safeURL.path)
            guard (currentAttributes[.type] as? FileAttributeType) == .typeRegular,
                  let currentSize = (currentAttributes[.size] as? NSNumber)?.int64Value,
                  currentSize == file.size else {
                throw WindowsGameTransferError.sourceChanged(file.relativePath)
            }
            let preparedFile = WindowsGameTransferFile(relativePath: file.relativePath, url: safeURL,
                                                       size: file.size, sha256: digest)
            prepared.append(preparedFile)
            hashedBytes += file.size
            progress(WindowsGameTransferProgress(phase: .hashing, currentFile: file.relativePath,
                                                 completedFiles: index + 1, totalFiles: sourceFiles.count,
                                                 completedBytes: hashedBytes, totalBytes: totalBytes))
        }

        // Immutable content generations prevent an interrupted update from
        // leaving an old completion marker beside partially replaced files.
        let indexEncoder = JSONEncoder()
        indexEncoder.outputFormatting = [.sortedKeys]
        let index = Dictionary(uniqueKeysWithValues: prepared.map {
            ($0.relativePath, WindowsGameTransferJournal.CompletedFile(size: $0.size, sha256: $0.sha256))
        })
        let generation = Self.sha256(Data(manifestDigest.utf8) + (try indexEncoder.encode(index)))
        let transferRoot = gameRoot + "/" + generation
        var journal = try WindowsGameTransferJournal.load(at: journalURL, identity: identity,
            manifestID: manifest.id, manifestDigest: generation)
        // Remote sizes are only a presence check; local digest + prior successful
        // copy remain required. An erased/reinstalled app cannot silently resume.
        let remoteFiles = try control.files(device: device, bundle: bundleID, subdirectory: transferRoot, recursive: true)
        var remoteSizes: [String: Int64] = [:]
        for remote in remoteFiles where !remote.isDirectory {
            let raw = remote.relativePath
            let relative = raw.hasPrefix(transferRoot + "/") ? String(raw.dropFirst(transferRoot.count + 1)) : raw
            remoteSizes[relative] = remote.size
        }
        report(L("Immutable transfer generation: \(transferRoot)", "Unveränderlicher Übertragungssatz: \(transferRoot)"))
        var copiedCount = 0
        var resumedCount = 0
        var completedBytes: Int64 = 0
        for (index, file) in prepared.enumerated() {
            let previous = journal.completedFiles[file.relativePath]
            if previous?.size == file.size, previous?.sha256 == file.sha256, remoteSizes[file.relativePath] == file.size {
                resumedCount += 1
                completedBytes += file.size
                progress(WindowsGameTransferProgress(phase: .copying, currentFile: file.relativePath,
                                                     completedFiles: index + 1, totalFiles: prepared.count,
                                                     completedBytes: completedBytes, totalBytes: totalBytes))
                continue
            }
            let currentDigest = try Self.sha256(of: Self.validatedSourceFile(file.relativePath, root: canonicalRoot))
            guard currentDigest == file.sha256 else { throw WindowsGameTransferError.sourceChanged(file.relativePath) }
            try control.copy(file.url, to: device, bundle: bundleID,
                             destination: "\(transferRoot)/\(file.relativePath)")
            let digestAfterCopy = try Self.sha256(of: Self.validatedSourceFile(file.relativePath, root: canonicalRoot))
            guard digestAfterCopy == file.sha256 else { throw WindowsGameTransferError.sourceChanged(file.relativePath) }
            journal.completedFiles[file.relativePath] = WindowsGameTransferJournal.CompletedFile(size: file.size,
                                                                                                 sha256: file.sha256)
            try journal.save(to: journalURL)
            copiedCount += 1
            completedBytes += file.size
            progress(WindowsGameTransferProgress(phase: .copying, currentFile: file.relativePath,
                                                 completedFiles: index + 1, totalFiles: prepared.count,
                                                 completedBytes: completedBytes, totalBytes: totalBytes))
        }

        let manifestDigestBeforeCopy = try Self.sha256(of: canonicalManifest)
        guard manifestDigestBeforeCopy == manifestDigest else { throw WindowsGameTransferError.manifestChanged }
        try control.copy(canonicalManifest, to: device, bundle: bundleID,
                         destination: "\(transferRoot)/manifest.json")
        let manifestDigestAfterCopy = try Self.sha256(of: canonicalManifest)
        guard manifestDigestAfterCopy == manifestDigest else { throw WindowsGameTransferError.manifestChanged }
        journal.manifestCopy = WindowsGameTransferJournal.CompletedFile(size: preflight.manifestBytes,
                                                                         sha256: manifestDigest)
        try journal.save(to: journalURL)
        report(L("Manifest copied last as the completion marker (SHA-256 \(manifestDigest)).",
                 "Manifest zuletzt als Abschlussmarkierung kopiert (SHA-256 \(manifestDigest))."))
        return WindowsGameTransferSummary(copiedFiles: copiedCount, resumedFiles: resumedCount,
                                          totalFiles: prepared.count, totalBytes: totalBytes,
                                          destination: transferRoot)
    }

    /// Performs every local validation before `DeviceControl` is consulted.
    /// Kept internal so regression tests can exercise the boundary without a paired device.
    static func validateLocalInputs(source: URL, manifestURL: URL, bundleID: String,
                                    owned: Bool) throws -> WindowsGameTransferPreflight {
        guard owned else { throw WindowsGameTransferError.ownershipAttestationRequired }
        guard Self.isSafeBundleID(bundleID) else { throw WindowsGameTransferError.invalidBundleID }

        let fm = FileManager.default
        let rootAttributes = try fm.attributesOfItem(atPath: source.path)
        guard (rootAttributes[.type] as? FileAttributeType) == .typeDirectory else {
            throw WindowsGameTransferError.invalidSourceFolder
        }
        let canonicalRoot = source.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let manifestAttributes = try fm.attributesOfItem(atPath: manifestURL.path)
        guard (manifestAttributes[.type] as? FileAttributeType) == .typeRegular,
              let manifestSize = (manifestAttributes[.size] as? NSNumber)?.int64Value,
              manifestSize <= WindowsGameTransferManifest.maximumBytes else {
            throw WindowsGameTransferError.invalidManifestFile
        }
        let canonicalManifest = manifestURL.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let manifestData = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        guard manifestData.count <= WindowsGameTransferManifest.maximumBytes else {
            throw WindowsGameTransferError.invalidManifestFile
        }
        let manifest: WindowsGameTransferManifest
        do {
            manifest = try JSONDecoder().decode(WindowsGameTransferManifest.self, from: manifestData)
        } catch {
            throw WindowsGameTransferError.invalidManifest(L("JSON/schema decode failed: \(error.localizedDescription)",
                                                             "JSON-/Schema-Decodierung fehlgeschlagen: \(error.localizedDescription)"))
        }
        try manifest.validate()
        let manifestDigest = Self.sha256(manifestData)

        var sourceFiles = try Self.enumerateFiles(root: canonicalRoot)
        sourceFiles.removeAll { $0.url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL == canonicalManifest }
        guard !sourceFiles.contains(where: { $0.relativePath.caseInsensitiveCompare("manifest.json") == .orderedSame }) else {
            throw WindowsGameTransferError.reservedManifestPath
        }
        let executablePath = try Self.safeRelativePath(manifest.executableRelativePath)
        guard let executable = sourceFiles.first(where: {
            $0.relativePath.caseInsensitiveCompare(executablePath) == .orderedSame
        }) else {
            throw WindowsGameTransferError.executableMissing(manifest.executableRelativePath)
        }
        try Self.requireX64PE(at: Self.validatedSourceFile(executable.relativePath, root: canonicalRoot))

        let totalBytes = try sourceFiles.reduce(Int64(0)) { partial, file in
            let (sum, overflow) = partial.addingReportingOverflow(file.size)
            guard !overflow else { throw WindowsGameTransferError.sourceTooLarge }
            return sum
        }
        return WindowsGameTransferPreflight(canonicalRoot: canonicalRoot, canonicalManifest: canonicalManifest,
            manifest: manifest, manifestDigest: manifestDigest, manifestBytes: Int64(manifestData.count),
            sourceFiles: sourceFiles, totalBytes: totalBytes)
    }

    private static func enumerateFiles(root: URL) throws -> [WindowsGameTransferFile] {
        let fm = FileManager.default
        var files: [WindowsGameTransferFile] = []
        var portablePaths = Set<String>()
        func visit(_ directory: URL, prefix: String) throws {
            let children = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let component = child.lastPathComponent
                let relative = prefix.isEmpty ? component : "\(prefix)/\(component)"
                _ = try Self.safeRelativePath(relative)
                let portableKey = relative.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                guard portablePaths.insert(portableKey).inserted else {
                    throw WindowsGameTransferError.caseInsensitivePathCollision(relative)
                }
                let attributes = try fm.attributesOfItem(atPath: child.path)
                guard let type = attributes[.type] as? FileAttributeType else {
                    throw WindowsGameTransferError.unsupportedSourceEntry(relative)
                }
                switch type {
                case .typeSymbolicLink:
                    throw WindowsGameTransferError.symbolicLink(relative)
                case .typeDirectory:
                    try Self.requireContained(child, root: root)
                    try visit(child, prefix: relative)
                case .typeRegular:
                    try Self.requireContained(child, root: root)
                    guard let size = (attributes[.size] as? NSNumber)?.int64Value, size >= 0 else {
                        throw WindowsGameTransferError.unsupportedSourceEntry(relative)
                    }
                    guard files.count < WindowsGameTransferManifest.maximumFiles else {
                        throw WindowsGameTransferError.tooManyFiles
                    }
                    files.append(WindowsGameTransferFile(relativePath: relative, url: child, size: size, sha256: ""))
                default:
                    throw WindowsGameTransferError.unsupportedSourceEntry(relative)
                }
            }
        }
        try visit(root, prefix: "")
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    private static func validatedSourceFile(_ relativePath: String, root: URL) throws -> URL {
        let safePath = try Self.safeRelativePath(relativePath)
        var current = root
        for component in safePath.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: false)
            let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
            guard (attributes[.type] as? FileAttributeType) != .typeSymbolicLink else {
                throw WindowsGameTransferError.symbolicLink(relativePath)
            }
        }
        try Self.requireContained(current, root: root)
        let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw WindowsGameTransferError.sourceChanged(relativePath)
        }
        return current
    }

    private static func requireX64PE(at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let dos = try handle.read(upToCount: 64), dos.count == 64,
              dos[0] == 0x4d, dos[1] == 0x5a else {
            throw WindowsGameTransferError.unsupportedExecutableArchitecture
        }
        let peOffset = UInt64(dos[0x3c]) | (UInt64(dos[0x3d]) << 8)
            | (UInt64(dos[0x3e]) << 16) | (UInt64(dos[0x3f]) << 24)
        guard peOffset >= 64, peOffset <= 16 * 1024 * 1024 else {
            throw WindowsGameTransferError.unsupportedExecutableArchitecture
        }
        try handle.seek(toOffset: peOffset)
        guard let header = try handle.read(upToCount: 6), header.count == 6,
              header[0] == 0x50, header[1] == 0x45, header[2] == 0, header[3] == 0,
              header[4] == 0x64, header[5] == 0x86 else {
            throw WindowsGameTransferError.unsupportedExecutableArchitecture
        }
    }

    private static func requireContained(_ url: URL, root: URL) throws {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard resolved.hasPrefix(prefix) else { throw WindowsGameTransferError.sourceEscapesRoot(url.path) }
    }

    private static func safeRelativePath(_ rawPath: String) throws -> String {
        let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty, !normalized.hasPrefix("/"), !normalized.contains("\0"),
              normalized.utf8.count <= 4096 else {
            throw WindowsGameTransferError.unsafePath(rawPath)
        }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.count <= 128 else { throw WindowsGameTransferError.unsafePath(rawPath) }
        for component in components {
            let upperBaseName = component.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init)?.uppercased() ?? ""
            let reservedNames = Set(["CON", "PRN", "AUX", "NUL"])
                .union((1...9).map { "COM\($0)" }).union((1...9).map { "LPT\($0)" })
            guard !component.isEmpty, component != ".", component != "..",
                  !component.contains(":"), !component.contains("\\"),
                  !component.contains(where: { "<>\"|?*".contains($0) }),
                  !component.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !component.hasSuffix("."), !component.hasSuffix(" "),
                  !reservedNames.contains(upperBaseName) else {
                throw WindowsGameTransferError.unsafePath(rawPath)
            }
        }
        return components.joined(separator: "/")
    }

    static func isSafeBundleID(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return value.utf8.count <= 255 && parts.count >= 2 && parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-").contains($0)
            }
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1 << 20
        while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct WindowsGameTransferFile {
    let relativePath: String
    let url: URL
    let size: Int64
    let sha256: String
}

struct WindowsGameTransferManifest: Decodable {
    enum Backend: String, Decodable { case windowsWineFEX }
    enum Graphics: String, Decodable { case direct3D11, direct3D12 }

    static let maximumBytes = 1_048_576
    static let maximumFiles = 100_000

    let id: String
    let title: String
    let executableRelativePath: String
    let backend: Backend
    let graphics: Graphics
    let launchArguments: [String]
    let environment: [String: String]?
    let schemaVersion: Int

    func validate() throws {
        guard schemaVersion == 1 else { throw WindowsGameTransferError.unsupportedSchema(schemaVersion) }
        guard !id.isEmpty, id.utf8.count <= 100, !id.hasPrefix("."),
              id.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0)
              }), id != ".", id != ".." else {
            throw WindowsGameTransferError.invalidGameID
        }
        guard !title.isEmpty, title.utf8.count <= 512, !title.contains("\0") else {
            throw WindowsGameTransferError.invalidManifest(L("title is empty or too long", "title ist leer oder zu lang"))
        }
        guard executableRelativePath.utf8.count <= 350 else {
            throw WindowsGameTransferError.invalidManifest(L("the executable path exceeds the native launch profile buffer",
                                                              "der Programmpfad überschreitet den Puffer des nativen Startprofils"))
        }
        guard launchArguments.count <= 64, launchArguments.allSatisfy({ $0.utf8.count <= 4096 && !$0.contains("\0") }) else {
            throw WindowsGameTransferError.invalidManifest(L("launchArguments must contain at most 64 short, NUL-free strings",
                                                              "launchArguments darf höchstens 64 kurze Zeichenketten ohne NUL-Zeichen enthalten"))
        }
        if let environment {
            let reserved: Set<String> = ["HOME", "WINEPREFIX", "WINESERVERSOCKET", "VR_OVERRIDE", "XR_RUNTIME_JSON", "WINEDLLPATH", "WVR_REQUIRE_COMPOSITOR_DEVICE", "WVR_GRAPHICS_API", "WINEDLLOVERRIDES"]
            guard environment.count <= 128,
                  environment.keys.allSatisfy({ key in
                      key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil &&
                      !reserved.contains(key) && !["DYLD_", "WINE_IOS_JIT_", "MADEIRA_"].contains(where: { key.hasPrefix($0) })
                  }),
                  environment.allSatisfy({ $0.key.utf8.count <= 256 && $0.value.utf8.count <= 4096
                                           && !$0.key.contains("\0") && !$0.value.contains("\0") }) else {
                throw WindowsGameTransferError.invalidManifest(L("environment is too large or contains NUL characters",
                                                                  "environment ist zu groß oder enthält NUL-Zeichen"))
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, executableRelativePath, backend, graphics, launchArguments, environment, schemaVersion
    }
}

private struct WindowsGameTransferJournal: Codable {
    struct Identity: Codable, Equatable {
        let deviceUDID: String
        let bundleID: String
        let sourcePath: String
    }

    struct CompletedFile: Codable, Equatable {
        let size: Int64
        let sha256: String
    }

    let schemaVersion: Int
    let identity: Identity
    let manifestID: String
    let manifestDigest: String
    var completedFiles: [String: CompletedFile]
    var manifestCopy: CompletedFile?

    static func url(for identity: Identity) throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw WindowsGameTransferError.journalUnavailable
        }
        let directory = support.appendingPathComponent("AVPPlay/WindowsGameTransfers", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = [identity.deviceUDID, identity.bundleID, identity.sourcePath].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest).json")
    }

    static func load(at url: URL, identity: Identity, manifestID: String,
                     manifestDigest: String) throws -> WindowsGameTransferJournal {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return WindowsGameTransferJournal(schemaVersion: 1, identity: identity, manifestID: manifestID,
                                              manifestDigest: manifestDigest, completedFiles: [:], manifestCopy: nil)
        }
        let journal: WindowsGameTransferJournal
        do {
            journal = try JSONDecoder().decode(WindowsGameTransferJournal.self, from: Data(contentsOf: url))
        } catch {
            throw WindowsGameTransferError.corruptJournal(url.path)
        }
        guard journal.schemaVersion == 1 else { throw WindowsGameTransferError.corruptJournal(url.path) }
        guard journal.identity == identity, journal.manifestID == manifestID,
              journal.manifestDigest == manifestDigest else {
            return WindowsGameTransferJournal(schemaVersion: 1, identity: identity, manifestID: manifestID,
                                              manifestDigest: manifestDigest, completedFiles: [:], manifestCopy: nil)
        }
        return journal
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(self).write(to: url, options: .atomic)
        } catch {
            throw WindowsGameTransferError.journalWriteFailed(error.localizedDescription)
        }
    }
}

enum WindowsGameTransferError: Error, LocalizedError, Equatable {
    case ownershipAttestationRequired
    case invalidBundleID
    case invalidSourceFolder
    case invalidManifestFile
    case invalidManifest(String)
    case unsupportedSchema(Int)
    case invalidGameID
    case unsafePath(String)
    case sourceEscapesRoot(String)
    case symbolicLink(String)
    case unsupportedSourceEntry(String)
    case tooManyFiles
    case sourceTooLarge
    case sourceChanged(String)
    case executableMissing(String)
    case unsupportedExecutableArchitecture
    case caseInsensitivePathCollision(String)
    case reservedManifestPath
    case appNotInstalled(String)
    case appLocationUnknown(String)
    case appRunning(String)
    case manifestChanged
    case journalUnavailable
    case corruptJournal(String)
    case journalWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .ownershipAttestationRequired:
            L("Windows staging requires the explicit --owned attestation. Files are not acquired and DRM is not bypassed.",
              "Für die Windows-Übertragung ist die ausdrückliche Bestätigung --owned nötig. Dateien werden weder beschafft noch wird DRM umgangen.")
        case .invalidBundleID: L("The --bundle-id value is not a safe bundle identifier.", "--bundle-id ist keine sichere Bundle-Kennung.")
        case .invalidSourceFolder: L("The --from path is not a regular folder.", "Der Pfad von --from ist kein gültiger Ordner.")
        case .invalidManifestFile: L("The manifest is not a small regular JSON file (maximum 1 MiB).", "Das Manifest ist keine kleine reguläre JSON-Datei (höchstens 1 MiB).")
        case .invalidManifest(let reason): L("The Windows game manifest is invalid: \(reason).", "Das Windows-Spielmanifest ist ungültig: \(reason).")
        case .unsupportedSchema(let version): L("Windows game manifest schema \(version) is unsupported; schema 1 is required.", "Das Windows-Spielmanifest-Schema \(version) wird nicht unterstützt; erforderlich ist Schema 1.")
        case .invalidGameID: L("The manifest id must be a safe single path component using letters, numbers, dot, underscore or hyphen.", "Die Manifest-ID muss ein sicherer einzelner Pfadteil aus Buchstaben, Zahlen, Punkt, Unterstrich oder Bindestrich sein.")
        case .unsafePath(let path): L("Unsafe Windows game path: \(path).", "Unsicherer Windows-Spielpfad: \(path).")
        case .sourceEscapesRoot(let path): L("The source path resolves outside the selected game folder: \(path).", "Der Quellpfad verweist außerhalb des ausgewählten Spielordners: \(path).")
        case .symbolicLink(let path): L("Symbolic links are not transferred: \(path).", "Symbolische Links werden nicht übertragen: \(path).")
        case .unsupportedSourceEntry(let path): L("Unsupported or unreadable source entry: \(path).", "Nicht unterstützter oder unlesbarer Quelleintrag: \(path).")
        case .tooManyFiles: L("The game folder exceeds the 100,000-file transfer limit.", "Der Spielordner überschreitet das Übertragungslimit von 100.000 Dateien.")
        case .sourceTooLarge: L("The total source size exceeds the supported byte-count range.", "Die Gesamtgröße der Quelle überschreitet den unterstützten Wertebereich.")
        case .sourceChanged(let path): L("A source file changed during transfer; it was not recorded as completed: \(path).", "Eine Quelldatei wurde während der Übertragung geändert und nicht als abgeschlossen gespeichert: \(path).")
        case .executableMissing(let path): L("The manifest executable is not a regular file in the selected source folder: \(path).", "Die Manifest-Programmdatei ist keine reguläre Datei im ausgewählten Quellordner: \(path).")
        case .unsupportedExecutableArchitecture: L("The manifest executable is not a PE x64 (AMD64) executable; only x64 game files are supported.", "Die Manifest-Programmdatei ist keine PE-x64-Datei (AMD64); unterstützt werden nur x64-Spieldateien.")
        case .caseInsensitivePathCollision(let path): L("The game folder contains a Windows-case-insensitive path collision near: \(path).", "Im Spielordner kollidieren Pfade ohne Beachtung der Groß-/Kleinschreibung bei Windows: \(path).")
        case .reservedManifestPath: L("The source already contains a different root manifest.json; the completion marker cannot safely replace it.", "Die Quelle enthält bereits eine andere manifest.json im Stammordner; die Abschlussmarkierung kann sie nicht sicher ersetzen.")
        case .appNotInstalled(let bundle): L("The target app \(bundle) is not installed on the selected device.", "Die Ziel-App \(bundle) ist auf dem ausgewählten Gerät nicht installiert.")
        case .appLocationUnknown(let bundle): L("The installed target app \(bundle) has no known container URL; refusing to stage while running status is uncertain.", "Für die installierte Ziel-App \(bundle) ist kein Containerpfad bekannt; die Übertragung wird bei unklarem Laufstatus abgebrochen.")
        case .appRunning(let bundle): L("The target app \(bundle) is running. Quit it before transferring game files.", "Die Ziel-App \(bundle) läuft. Beende sie vor der Übertragung der Spieldateien.")
        case .manifestChanged: L("The manifest changed during transfer; it was not recorded as the completion marker.", "Das Manifest wurde während der Übertragung geändert und nicht als Abschlussmarkierung gespeichert.")
        case .journalUnavailable: L("The local Application Support directory is unavailable for the transfer journal.", "Der lokale Ordner „Application Support“ für das Übertragungsprotokoll ist nicht verfügbar.")
        case .corruptJournal(let path): L("The transfer journal is unreadable or unsupported: \(path). Remove it only if you intend to restart the transfer.", "Das Übertragungsprotokoll ist unlesbar oder wird nicht unterstützt: \(path). Entferne es nur, wenn du die Übertragung neu starten willst.")
        case .journalWriteFailed(let reason): L("Could not persist the local transfer journal: \(reason).", "Das lokale Übertragungsprotokoll konnte nicht gespeichert werden: \(reason).")
        }
    }
}

struct WindowsGameTransferPreflight {
    let canonicalRoot: URL
    let canonicalManifest: URL
    let manifest: WindowsGameTransferManifest
    let manifestDigest: String
    let manifestBytes: Int64
    let sourceFiles: [WindowsGameTransferFile]
    let totalBytes: Int64
}
