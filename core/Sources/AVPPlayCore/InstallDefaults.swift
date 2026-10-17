import Foundation

/// Vorgaben für jedes Spiel, das gebaut wird – aus den Einstellungen der App, in einer kleinen Datei bei den Daten
/// des Programms, damit die Oberfläche, die Kommandozeile und das Erneuern der Signaturen dieselben benutzen.
public enum InstallDefaults {
    static func file(base: URL) -> URL { base.appendingPathComponent("install-defaults.json") }

    private struct Values: Codable {
        /// Die Raumvermessung (Spielbereich) in gebauten Spielen. Fehlt der Eintrag: an.
        var roomMeasuring: Bool?
    }

    private static func values(base: URL) -> Values {
        guard let data = try? Data(contentsOf: file(base: base)),
              let v = try? JSONDecoder().decode(Values.self, from: data) else { return Values() }
        return v
    }

    /// Ob ein Spiel, das gebaut wird, die Raumvermessung von Anfang an eingeschaltet hat (`Toolchain.roomMeasuringVariable`).
    /// Im Spiel lässt sie sich danach für sich ein- und ausschalten (Einstellungen › Spielbereich); was dort gewählt
    /// ist, gilt. Ohne Einstellung: an.
    public static func roomMeasuring(base: URL = DataLocation.base) -> Bool {
        values(base: base).roomMeasuring ?? true
    }

    public static func setRoomMeasuring(_ on: Bool, base: URL = DataLocation.base) throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var v = values(base: base)
        v.roomMeasuring = on ? nil : false
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(v).write(to: file(base: base), options: .atomic)
    }
}
