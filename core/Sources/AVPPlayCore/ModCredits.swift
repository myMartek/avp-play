import Foundation

/// Die Mods, die eine Toolchain für ein Spiel mitbringt, mit ihren Autoren und Herkunft
/// (`ports/scotland2/credits.json` der Toolchain). Die App zeigt sie unter Einstellungen › Verwendete Software,
/// das Spiel in seinem Startfenster; ihre Autoren haben darum gebeten, dort genannt zu werden.
public struct ModCredits: Decodable, Sendable, Equatable {
    public struct Entry: Decodable, Sendable, Equatable, Identifiable {
        public let name: String
        public var version: String?
        public let authors: String
        public let url: String
        public let license: String
        public var role: String?
        public var id: String { name }
    }
    public let port: Entry
    public let mods: [Entry]
}

extension Toolchain {
    /// Die Mod-Liste dieser Toolchain; `nil` bei einer ohne Mods.
    public var modCredits: ModCredits? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("ports/scotland2/credits.json")) else { return nil }
        return try? JSONDecoder().decode(ModCredits.self, from: data)
    }
}
