import Foundation

/// Wo dieses Werkzeug seine Daten auf dem Mac hält: Bestand, Aufträge und installierte Toolchains liegen
/// gemeinsam unter `~/Library/Application Support/AVPPlay`.
public enum DataLocation {
    public static let folderName = "AVPPlay"
    /// Der Ordner aus der Zeit vor dem Namen „AVP Play“.
    static let legacyFolderName = "QuestInstaller"

    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// `AVPPLAY_HOME` verlegt alles an einen anderen Ort – zum Ausprobieren mit einem leeren Datenordner, ohne den
    /// eigentlichen anzufassen.
    public static var base: URL {
        if let home = ProcessInfo.processInfo.environment["AVPPLAY_HOME"], home.hasPrefix("/") {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return applicationSupport.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Übernimmt einmalig die Daten aus dem früheren Ordner, indem er umbenannt wird – nichts wird kopiert
    /// oder gelöscht. Gibt es den neuen Ordner schon, bleibt alles, wie es ist.
    /// - Returns: ob umbenannt wurde.
    @discardableResult
    public static func adoptLegacyData(in support: URL = applicationSupport) -> Bool {
        let fm = FileManager.default
        let old = support.appendingPathComponent(legacyFolderName, isDirectory: true)
        let new = support.appendingPathComponent(folderName, isDirectory: true)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return false }
        return (try? fm.moveItem(at: old, to: new)) != nil
    }
}
