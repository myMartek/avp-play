import Foundation

public enum WindowsRuntimeError: Error, LocalizedError, Sendable, Equatable {
    /// No native Wine, FEX, graphics translation, or process-launch adapter is connected.
    case integrationMissing
    case invalidGameDirectory
    case missingExecutable
    case executableNotRegularFile
    case pluginRejectedRequest(Int32)
    case stopPending
    case graphicsPackageMissing(WindowsGraphicsAPI)

    public var errorDescription: String? {
        switch self {
        case .integrationMissing:
            return L("The Windows runtime plugin is missing or did not accept the request.", "Das Windows-Laufzeit-Plugin fehlt oder hat die Anfrage nicht angenommen.")
        case .invalidGameDirectory:
            return L("The game directory must be a local file URL.", "Der Spielordner muss eine lokale Datei-URL sein.")
        case .missingExecutable:
            return L("The manifest executable does not exist in the game directory.", "Die im Manifest angegebene Programmdatei ist im Spielordner nicht vorhanden.")
        case .executableNotRegularFile:
            return L("The manifest executable path does not refer to a regular file.", "Der im Manifest angegebene Programmpfad verweist nicht auf eine reguläre Datei.")
        case .graphicsPackageMissing(let graphics):
            return L(
                "The signed runtime does not contain the required \(graphics.rawValue) graphics package. No fallback was selected.",
                "Die signierte Laufzeit enthält nicht das erforderliche Grafikpaket \(graphics.rawValue). Es wurde kein Ersatz ausgewählt."
            )
        case .stopPending:
            return L("Cooperative exit has been requested; the Wine process has not yet confirmed a stop.", "Das geordnete Beenden wurde angefordert; der Wine-Prozess hat das Ende noch nicht bestätigt.")
        case .pluginRejectedRequest(let status):
            return L("The Windows runtime plugin rejected the launch request with status \(status).", "Das Windows-Laufzeit-Plugin hat den Start mit Status \(status) abgelehnt.")
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
