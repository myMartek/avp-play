import Foundation

/// Ein eigener Filter: ein Name und die Spiele, die jemand ihm zugeordnet hat – etwa „32 Bit“ oder „Für Gäste“.
///
/// Gespeichert werden nur die Kennungen der Spiele (wie bei den Favoriten), nicht die Spiele selbst. Ein Spiel, das
/// der Katalog gerade nicht geladen hat, bleibt deshalb im Filter und steht wieder da, sobald es geladen ist.
public struct CustomFilter: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var games: Set<String>

    public init(id: String = UUID().uuidString, name: String, games: Set<String> = []) {
        self.id = id
        self.name = name
        self.games = games
    }
}

/// Wie ein eigener Filter in der Übersicht wirkt: gar nicht, als „nur diese zeigen“ oder umgekehrt als „diese
/// ausblenden“ – so lassen sich etwa alle Favoriten zeigen, die 32-Bit-Spiele darunter aber nicht.
public enum CustomFilterMode: String, Codable, Sendable, CaseIterable {
    case off, only, hide
}

/// Was für die eigenen Filter zu entscheiden ist: ob ein Spiel durchkommt, ob ein Name taugt, wie sie gespeichert werden.
public enum CustomFilters {
    /// Ob ein Spiel durch alle gesetzten eigenen Filter kommt. Mehrere zugleich engen weiter ein, wie die übrigen
    /// Filter der Übersicht: Ein Spiel muss in jedem „nur diese“ stehen und in keinem „ausblenden“.
    public static func passes(_ gameId: String, filters: [CustomFilter], modes: [String: CustomFilterMode]) -> Bool {
        for filter in filters {
            switch modes[filter.id] ?? .off {
            case .off: continue
            case .only: if !filter.games.contains(gameId) { return false }
            case .hide: if filter.games.contains(gameId) { return false }
            }
        }
        return true
    }

    /// Der Name, wie er gespeichert wird: ohne Leerraum außen und ohne Zeilenumbrüche, nicht endlos.
    public static func cleanName(_ name: String) -> String {
        let oneLine = name.components(separatedBy: .newlines).joined(separator: " ")
        return String(oneLine.trimmingCharacters(in: .whitespaces).prefix(40))
    }

    /// Warum ein Name nicht taugt – leer, oder schon von einem anderen Filter belegt (ohne Rücksicht auf Groß- und
    /// Kleinschreibung). `nil`: Er taugt.
    /// - Parameter except: der Filter, der umbenannt wird; sein eigener Name zählt nicht als belegt.
    public static func nameProblem(_ name: String, in filters: [CustomFilter], except: String? = nil) -> String? {
        let clean = cleanName(name)
        if clean.isEmpty { return L("Give the filter a name.", "Gib dem Filter einen Namen.") }
        if filters.contains(where: { $0.id != except && $0.name.compare(clean, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            return L("There is already a filter called “\(clean)”.", "Es gibt schon einen Filter namens „\(clean)“.")
        }
        return nil
    }

    // MARK: Speichern

    /// Liest die Filter aus dem gespeicherten Text (JSON); fehlt er oder ist er unlesbar, gibt es keine.
    public static func decode(_ text: String?) -> [CustomFilter] {
        guard let data = text?.data(using: .utf8), let filters = try? JSONDecoder().decode([CustomFilter].self, from: data) else { return [] }
        return filters
    }

    public static func encode(_ filters: [CustomFilter]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(filters)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// Die Wirkung je Filter aus dem gespeicherten Wörterbuch; was keinem Filter mehr gehört, fällt weg.
    public static func modes(from stored: [String: String]?, filters: [CustomFilter]) -> [String: CustomFilterMode] {
        let ids = Set(filters.map(\.id))
        var out: [String: CustomFilterMode] = [:]
        for (id, raw) in stored ?? [:] where ids.contains(id) {
            if let mode = CustomFilterMode(rawValue: raw), mode != .off { out[id] = mode }
        }
        return out
    }
}
