import Foundation

/// Apples Entwicklerwerkzeuge (`xcrun`, `python3`, `git` unter `/usr/bin`) sind auf einem Mac ohne Xcode nur
/// Platzhalter: Wer sie aufruft, bekommt von macOS den Dialog „Entwicklerwerkzeuge installieren?“. Deshalb wird
/// vorher gefragt, ob es sie gibt – mit `xcode-select -p`, das nur Auskunft gibt und nichts anbietet.
public enum DeveloperTools {
    /// Der gewählte Entwicklerordner (Xcode oder die Kommandozeilenwerkzeuge); `nil`, wenn es keinen gibt.
    public static func directory() -> String? {
        guard let out = try? Toolchain.capture(["/usr/bin/xcode-select", "-p"]) else { return nil }
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        var isDirectory: ObjCBool = false
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return path
    }

    public static var present: Bool { directory() != nil }
}
