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
}
