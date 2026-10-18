import Foundation

/// Die Sprache, die ein gebautes Spiel als Systemsprache der Brille gemeldet bekommt
/// (`Toolchain.gameLanguageVariable`, im Spiel „Sprache des Spiels“, `KLGameLanguageDefault`).
///
/// Ein Wert ist `device` (wie die Vision Pro eingestellt ist), `en` (Englisch, wie bisher jedes Spiel ohne
/// Vorgabe) oder eine Sprache mit Region wie `fr_FR`. Dieselbe Liste bietet das Spiel selbst an. Was im Spiel
/// gewählt ist, gilt dort danach, auch über Updates hinweg; die Vorgabe zählt nur für ein Spiel, in dem noch
/// nichts gewählt wurde.
public enum GameLanguage {
    public struct Choice: Hashable, Sendable {
        public let code: String
        public let name: String
    }

    /// Die Sprachen, die Quest-Spiele am häufigsten mitbringen, jeweils in ihrem eigenen Namen.
    public static let choices: [Choice] = [
        Choice(code: "en", name: "English"),
        Choice(code: "en_GB", name: "English (UK)"),
        Choice(code: "de_DE", name: "Deutsch"),
        Choice(code: "fr_FR", name: "Français"),
        Choice(code: "es_ES", name: "Español"),
        Choice(code: "es_MX", name: "Español (Latinoamérica)"),
        Choice(code: "it_IT", name: "Italiano"),
        Choice(code: "pt_BR", name: "Português (Brasil)"),
        Choice(code: "pt_PT", name: "Português (Portugal)"),
        Choice(code: "nl_NL", name: "Nederlands"),
        Choice(code: "pl_PL", name: "Polski"),
        Choice(code: "sv_SE", name: "Svenska"),
        Choice(code: "da_DK", name: "Dansk"),
        Choice(code: "nb_NO", name: "Norsk"),
        Choice(code: "fi_FI", name: "Suomi"),
        Choice(code: "cs_CZ", name: "Čeština"),
        Choice(code: "tr_TR", name: "Türkçe"),
        Choice(code: "ru_RU", name: "Русский"),
        Choice(code: "uk_UA", name: "Українська"),
        Choice(code: "ja_JP", name: "日本語"),
        Choice(code: "ko_KR", name: "한국어"),
        Choice(code: "zh_CN", name: "简体中文"),
        Choice(code: "zh_TW", name: "繁體中文"),
    ]

    /// Wie die Vision Pro eingestellt ist.
    public static let device = "device"

    /// Ob ein Wert einer ist, den das Spiel versteht: `device`, `en` oder `xx_YY`.
    public static func isValid(_ code: String) -> Bool {
        code == device || code == "en" || code.range(of: "^[a-z]{2,3}_[A-Z]{2}$", options: .regularExpression) != nil
    }

    /// Für die Anzeige: der Name der Sprache, oder der Wert selbst.
    public static func name(_ code: String) -> String {
        if code == device { return L("Like the Vision Pro", "Wie die Vision Pro") }
        return choices.first { $0.code == code }?.name ?? code
    }
}
