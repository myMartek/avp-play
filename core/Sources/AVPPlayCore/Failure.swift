import Foundation

/// Woran ein Auftrag hängen geblieben ist, als Art – damit eine Oberfläche den nächsten Handgriff anbieten kann,
/// ohne Fehlertexte zu deuten. Der Text des Fehlers bleibt daneben erhalten.
public enum FailureKind: String, Codable, Sendable {
    /// Das Spiel läuft gerade auf dem Gerät; eine Installation würde es beenden.
    case gameRunning
    /// Das Konto besitzt das Spiel nicht.
    case notOwned
    /// Kein gültiger Zugang zu Meta.
    case signIn
    /// Das Gerät ist nicht erreichbar oder nimmt den Befehl nicht an.
    case device
    /// Bauen oder Installieren ist gescheitert.
    case build
    /// Das Kopieren der Daten aufs Gerät ist gescheitert.
    case copy
    /// Ein Download ist gescheitert oder unvollständig.
    case download
    /// Es fehlen Dateien, die der Nutzer selbst bereitstellt.
    case ownFiles
    /// Etwas an der Einrichtung fehlt (Team, Toolchain).
    case setup
    case other

    public static func of(_ error: Error) -> FailureKind {
        switch error {
        case let e as InstallError:
            switch e {
            case .appRunning: return .gameRunning
            case .notOwned: return .notOwned
            case .userFilesNeeded, .missingTrees: return .ownFiles
            case .missingFiles: return .download
            case .teamMissing: return .setup
            case .appNotInstalled: return .build
            case .badIcon: return .other
            }
        case let e as MetaError:
            if case .tokenRejected = e { return .signIn }
            return .download
        case is TokenError: return .signIn
        case is DeviceError: return .device
        case let e as ToolchainError:
            switch e {
            case .buildFailed: return .build
            case .syncFailed: return .copy
            case .notAToolchain, .tooOld: return .setup
            }
        case is FetchError, is URLError: return .download
        default: return .other
        }
    }
}
