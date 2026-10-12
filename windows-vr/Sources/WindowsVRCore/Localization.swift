import Foundation

enum WindowsVRLanguage {
    case english
    case german

    static var defaultLocale: Self {
        resolve(preferredLanguages: Locale.preferredLanguages)
    }

    static func resolve(preferredLanguages: [String]) -> Self {
        preferredLanguages.first?.lowercased().hasPrefix("de") == true ? .german : .english
    }
}

/// Returns the English or German user-facing message for the system's first
/// preferred language. Unsupported languages use English.
public func L(_ english: @autoclosure () -> String, _ german: @autoclosure () -> String) -> String {
    WindowsVRLanguage.defaultLocale == .german ? german() : english()
}
