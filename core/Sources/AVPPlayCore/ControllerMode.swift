import Foundation

/// Wire values consumed by the packaged Klepton launcher. Pairing happens on Vision Pro.
public enum ControllerMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case standard, surreal
    public var id: String { rawValue }
    public static let preferenceKey = "controllerMode"
    public var title: String {
        switch self {
        case .standard: return L("Standard Controllers", "Standard-Controller")
        case .surreal: return "Surreal Touch"
        }
    }
    public static func load(defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .standard
    }
    public func save(defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.preferenceKey) }

    /// Settings › Controllers › "Surreal Touch support". On (the default), games are built with Surreal
    /// Touch as a choice in their start window; off, for standard controllers only – no controller type
    /// there, and Surreal Interactive's software is neither downloaded nor built in.
    public static let supportKey = "surrealSupport"
    public static func supportEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: supportKey) as? Bool ?? true
    }
}
