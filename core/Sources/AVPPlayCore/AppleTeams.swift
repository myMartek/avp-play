import Foundation

/// Ein Entwicklerteam, wie Xcode es kennt.
public struct AppleTeam: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// Kostenloses „Personal Team“ eines Apple-Accounts ohne bezahlte Mitgliedschaft: Eine Installation läuft
    /// sieben Tage statt eines Jahres, und zwei der drei Berechtigungen der Toolchain gibt es dafür nicht.
    public let free: Bool

    public init(id: String, name: String, free: Bool) {
        self.id = id
        self.name = name
        self.free = free
    }
}

/// Die Teams, mit denen Xcode auf diesem Mac angemeldet ist. Gelesen wird nur diese Liste aus Xcodes
/// Einstellungen (`IDEProvisioningTeamByIdentifier`), keine Kontodaten.
public enum AppleTeams {
    /// Für Tests und zum Ausprobieren mit einem bezahlten Team: `AVPPLAY_TREAT_TEAM_AS_FREE=1` baut so, als
    /// wäre das gewählte Team ein kostenloses (ohne die beiden Berechtigungen, die es dafür nicht gibt).
    static var treatAsFree: Bool { ProcessInfo.processInfo.environment["AVPPLAY_TREAT_TEAM_AS_FREE"] == "1" }

    public static func known() -> [AppleTeam] {
        guard let exported = try? Toolchain.capture(["/usr/bin/defaults", "export", "com.apple.dt.Xcode", "-"]),
              let plist = try? PropertyListSerialization.propertyList(from: Data(exported.utf8), format: nil) as? [String: Any]
        else { return [] }
        let teams = parse(plist)
        // Beim Ausprobieren soll auch die Oberfläche zeigen, was sie bei einem kostenlosen Team zeigt.
        return treatAsFree ? teams.map { AppleTeam(id: $0.id, name: $0.name, free: true) } : teams
    }

    /// Bezahlte Teams zuerst; innerhalb der Gruppen in Xcodes Reihenfolge.
    static func parse(_ xcodeDefaults: [String: Any]) -> [AppleTeam] {
        var found: [AppleTeam] = []
        guard let byAccount = xcodeDefaults["IDEProvisioningTeamByIdentifier"] as? [String: Any] else { return [] }
        for key in byAccount.keys.sorted() {
            guard let list = byAccount[key] as? [[String: Any]] else { continue }
            for entry in list {
                guard let id = entry["teamID"] as? String, !found.contains(where: { $0.id == id }) else { continue }
                found.append(AppleTeam(id: id, name: entry["teamName"] as? String ?? id,
                                       free: (entry["isFreeProvisioningTeam"] as? Bool) ?? false))
            }
        }
        return found.filter { !$0.free } + found.filter { $0.free }
    }

    /// Ob mit diesem Team wie für ein kostenloses gebaut wird. Ein Team, das Xcode nicht kennt, gilt als bezahlt:
    /// dann scheitert der Bau mit Apples eigener Meldung statt mit einer geratenen.
    public static func isFree(_ teamId: String) -> Bool {
        if treatAsFree { return true }
        return known().first { $0.id == teamId }?.free ?? false
    }
}
