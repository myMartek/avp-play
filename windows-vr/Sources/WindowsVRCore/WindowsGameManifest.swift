import Foundation

public enum WindowsRuntimeBackend: String, Codable, Sendable, Equatable {
    case windowsWineFEX
    case nativeARM64
}

public enum WindowsGraphicsAPI: String, Codable, Sendable, Equatable {
    case direct3D11
    case direct3D12
    case vulkan
}

public enum WindowsGameManifestError: Error, LocalizedError, Sendable, Equatable {
    case invalidExecutableRelativePath
    case unsupportedSchemaVersion(Int)
    case invalidIdentity
    case invalidLaunchConfiguration

    public var errorDescription: String? {
        switch self {
        case .invalidExecutableRelativePath: "The executable must be a safe relative Windows path inside the selected game folder."
        case .unsupportedSchemaVersion(let version): "Windows game manifest schema " + String(version) + " is unsupported."
        case .invalidIdentity: "The game ID and title must be nonempty, bounded text without embedded NUL bytes."
        case .invalidLaunchConfiguration: "Launch arguments or environment variables exceed runtime limits or include a reserved/invalid value."
        }
    }
}

/// Describes a Windows-compatible game without asserting that a runtime is installed.
public struct WindowsGameManifest: Codable, Sendable, Equatable {
    public static let supportedSchemaVersion = 1

    public let id: String
    public let title: String
    public let executableRelativePath: String
    public let backend: WindowsRuntimeBackend
    public let graphics: WindowsGraphicsAPI
    public let launchArguments: [String]
    public let environment: [String: String]
    public let schemaVersion: Int

    public init(
        id: String,
        title: String,
        executableRelativePath: String,
        backend: WindowsRuntimeBackend,
        graphics: WindowsGraphicsAPI,
        launchArguments: [String],
        environment: [String: String] = [:],
        schemaVersion: Int
    ) throws {
        self.id = id
        self.title = title
        self.executableRelativePath = executableRelativePath
        self.backend = backend
        self.graphics = graphics
        self.launchArguments = launchArguments
        self.environment = environment
        self.schemaVersion = schemaVersion
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw WindowsGameManifestError.unsupportedSchemaVersion(schemaVersion)
        }
        guard !id.isEmpty, id.utf8.count <= 4096, !id.utf8.contains(0),
              !title.isEmpty, title.utf8.count <= 4096, !title.utf8.contains(0) else {
            throw WindowsGameManifestError.invalidIdentity
        }
        guard launchArguments.count <= 64,
              launchArguments.allSatisfy({ $0.utf8.count <= 4096 && !$0.utf8.contains(0) }),
              environment.count <= 128,
              environment.allSatisfy({ Self.isAllowedEnvironmentKey($0.key) && $0.value.utf8.count <= 4096 && !$0.value.utf8.contains(0) }) else {
            throw WindowsGameManifestError.invalidLaunchConfiguration
        }
        guard Self.isSafeRelativePath(executableRelativePath) else {
            throw WindowsGameManifestError.invalidExecutableRelativePath
        }
    }

    private static func isAllowedEnvironmentKey(_ key: String) -> Bool {
        guard !key.isEmpty, key.utf8.count <= 256,
              key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { return false }
        let reserved: Set<String> = ["HOME", "WINEPREFIX", "WINESERVERSOCKET", "VR_OVERRIDE", "XR_RUNTIME_JSON", "WINEDLLPATH", "WVR_REQUIRE_COMPOSITOR_DEVICE", "WVR_GRAPHICS_API", "WINEDLLOVERRIDES"]
        return !reserved.contains(key) && !["DYLD_", "WINE_IOS_JIT_", "MADEIRA_"].contains(where: { key.hasPrefix($0) })
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("\\"),
              !path.contains("\0"),
              !path.contains(":"),
              path.utf8.count <= 350
        else {
            return false
        }

        // Treat both separators as path separators so Windows paths are checked on every host.
        let components = path.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" })
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            return false
        }

        // Reject drive-qualified paths (including drive-relative forms such as C:game.exe).
        if let first = components.first, first.count >= 2 {
            let characters = Array(first)
            if characters[0].isASCII && characters[0].isLetter && characters[1] == ":" {
                return false
            }
        }

        return true
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case executableRelativePath
        case backend
        case graphics
        case launchArguments
        case environment
        case schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        executableRelativePath = try container.decode(String.self, forKey: .executableRelativePath)
        backend = try container.decode(WindowsRuntimeBackend.self, forKey: .backend)
        graphics = try container.decode(WindowsGraphicsAPI.self, forKey: .graphics)
        launchArguments = try container.decode([String].self, forKey: .launchArguments)
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(executableRelativePath, forKey: .executableRelativePath)
        try container.encode(backend, forKey: .backend)
        try container.encode(graphics, forKey: .graphics)
        try container.encode(launchArguments, forKey: .launchArguments)
        try container.encode(environment, forKey: .environment)
        try container.encode(schemaVersion, forKey: .schemaVersion)
    }
}
