import Foundation

public enum WindowsRuntimeError: Error, LocalizedError, Sendable, Equatable {
    /// No native Wine, FEX, graphics translation, or process-launch adapter is connected.
    case integrationMissing
    case invalidGameDirectory
    case missingExecutable
    case executableNotRegularFile
    case pluginRejectedRequest(Int32)

    public var errorDescription: String? {
        switch self {
        case .integrationMissing:
            return "The Windows runtime plugin is missing or did not accept the request."
        case .invalidGameDirectory:
            return "The game directory must be a local file URL."
        case .missingExecutable:
            return "The manifest executable does not exist in the game directory."
        case .executableNotRegularFile:
            return "The manifest executable path does not refer to a regular file."
        case .pluginRejectedRequest(let status):
            return "The Windows runtime plugin rejected the launch request with status \(status)."
        }
    }
}

public protocol WindowsRuntime: Sendable {
    func launch(manifest: WindowsGameManifest, gameDirectory: URL) async throws
    func stop() async throws
}

/// Honest placeholder for platform integration that has not been implemented yet.
public struct UnavailableWindowsRuntime: WindowsRuntime {
    public init() {}

    public func launch(manifest: WindowsGameManifest, gameDirectory: URL) async throws {
        try manifest.validate()
        throw WindowsRuntimeError.integrationMissing
    }

    public func stop() async throws {
        throw WindowsRuntimeError.integrationMissing
    }
}
