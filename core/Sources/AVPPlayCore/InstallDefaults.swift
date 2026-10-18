import Foundation

/// Vorgaben für jedes Spiel, das gebaut wird – aus den Einstellungen der App, in einer kleinen Datei bei den Daten
/// des Programms, damit die Oberfläche, die Kommandozeile und das Erneuern der Signaturen dieselben benutzen.
public enum InstallDefaults {
    static func file(base: URL) -> URL { base.appendingPathComponent("install-defaults.json") }

    private struct Values: Codable {
        /// Die Raumvermessung (Spielbereich) in gebauten Spielen. Fehlt der Eintrag: an.
        var roomMeasuring: Bool?
        /// Die Sprache, die gebaute Spiele gemeldet bekommen (`GameLanguage`). Fehlt der Eintrag: die des Spiels.
        var gameLanguage: String?
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
        var v = values(base: base)
        v.roomMeasuring = on ? nil : false
        try write(v, base: base)
    }

    /// Mit welcher Sprache ein Spiel, das gebaut wird, beginnt (`Toolchain.gameLanguageVariable`, ein Wert aus
    /// `GameLanguage`). `nil`: keine Vorgabe, das Spiel hält es wie bisher (meist Englisch). Was im Spiel unter
    /// „Sprache des Spiels“ gewählt ist, gilt dort danach und bleibt bei Updates erhalten.
    public static func gameLanguage(base: URL = DataLocation.base) -> String? {
        values(base: base).gameLanguage.flatMap { GameLanguage.isValid($0) ? $0 : nil }
    }

    public static func setGameLanguage(_ code: String?, base: URL = DataLocation.base) throws {
        var v = values(base: base)
        v.gameLanguage = code.flatMap { GameLanguage.isValid($0) ? $0 : nil }
        try write(v, base: base)
    }

    private static func write(_ v: Values, base: URL) throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(v).write(to: file(base: base), options: .atomic)
    }
}
