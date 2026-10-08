import Foundation

/// Die Sprachen, in denen Bibliothek und Programme sprechen.
public enum Language: String, Sendable, CaseIterable, Codable {
    case en, de
}

/// Die eingestellte Sprache der Meldungen.
///
/// Beide Fassungen eines Satzes stehen dort, wo er gebraucht wird (`L("English", "Deutsch")`), nicht in
/// Tabellen neben dem Programm: Fehlermeldungen und Fortschrittszeilen enthalten fast immer Werte, und so
/// bleiben Satz und Werte in beiden Sprachen zusammen lesbar. Ohne Einstellung gilt Englisch.
public enum L10n {
    private static let lock = NSLock()
    private static var current: Language = .en

    public static var language: Language {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }

    /// Die Sprache des Systems, soweit eine der unterstützten: die erste bevorzugte Sprache entscheidet,
    /// alles außer Deutsch ist Englisch.
    public static func systemLanguage(preferred: [String] = Locale.preferredLanguages) -> Language {
        (preferred.first?.lowercased().hasPrefix("de") ?? false) ? .de : .en
    }

    /// Für Datums- und Zahlenformate: die eingestellte Sprache mit der Region des Systems.
    public static var locale: Locale {
        Locale(identifier: "\(language.rawValue)_\(Locale.current.region?.identifier ?? "US")")
    }
}

/// Der Satz in der eingestellten Sprache. Ausgewertet wird nur die Fassung, die gebraucht wird.
public func L(_ en: @autoclosure () -> String, _ de: @autoclosure () -> String) -> String {
    L10n.language == .de ? de() : en()
}

/// Ein Text aus einem Rezept: entweder ein einzelner Satz (gilt dann in jeder Sprache) oder je Sprache einer,
/// als `{"en": "…", "de": "…"}`.
public struct LocalizedText: Codable, Sendable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    /// Schlüssel sind Sprachkürzel; ein einzelner Satz ohne Sprachangabe liegt unter "".
    public var values: [String: String]

    public init(_ single: String) { values = ["": single] }
    public init(en: String, de: String) { values = ["en": en, "de": de] }
    public init(stringLiteral value: String) { self.init(value) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let single = try? container.decode(String.self) {
            values = ["": single]
        } else {
            values = try container.decode([String: String].self)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if values.count == 1, let single = values[""] { try container.encode(single) } else { try container.encode(values) }
    }

    /// In der eingestellten Sprache; fehlt sie, auf Englisch; fehlt auch das, in der Sprache, die es gibt.
    public var text: String {
        values[L10n.language.rawValue] ?? values[""] ?? values["en"] ?? values.sorted { $0.key < $1.key }.first?.value ?? ""
    }
    public var description: String { text }
}
