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
        let refused = refusedAsPaid()
        var teams = parse(plist).map { refused.contains($0.id) ? AppleTeam(id: $0.id, name: $0.name, free: true) : $0 }
        teams = teams.filter { !$0.free } + teams.filter { $0.free }
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

    // MARK: Von Apple als kostenlos gemeldet
    //
    // Ob ein Team kostenlos ist, steht nicht immer in Xcodes Liste: Bei einem Nutzer (2026-10-20, Xcode 27.1) war
    // sie leer, obwohl Xcode selbst sein Personal Team zeigte. Die Einrichtung bot darum nur die Team-ID aus
    // seinem Zertifikat an – die einer abgelaufenen bezahlten Mitgliedschaft, die als bezahlt galt –, und Apple
    // lehnte den Bau als „Personal development team“ ab. Dann ist Apples Absage beim Bauen die einzige
    // verlässliche Auskunft. Die merkt sich die App je Team-ID; danach baut sie für dieses
    // Team wie für ein kostenloses. Ein Team mit erneuerter Mitgliedschaft verliert so nur die beiden
    // Berechtigungen, und „Wieder als bezahlt behandeln“ in der Einrichtung macht es rückgängig.

    static let refusedAsPaidKey = "teamsAppleCallsFree"

    /// Die Team-IDs, bei denen Apple einen Bau als „Personal development team“ abgelehnt hat.
    public static func refusedAsPaid(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: refusedAsPaidKey) ?? [])
    }

    /// Apple hat einen Bau mit diesem Team als „Personal development team“ abgelehnt.
    public static func markFree(_ teamId: String, defaults: UserDefaults = .standard) {
        defaults.set((refusedAsPaid(defaults: defaults).union([teamId])).sorted(), forKey: refusedAsPaidKey)
    }

    /// Wieder nach Xcodes Liste gehen – etwa nach einer erneuerten Mitgliedschaft.
    public static func forgetFree(_ teamId: String, defaults: UserDefaults = .standard) {
        defaults.set(refusedAsPaid(defaults: defaults).subtracting([teamId]).sorted(), forKey: refusedAsPaidKey)
    }

    /// Ob mit diesem Team wie für ein kostenloses gebaut wird. Ein Team, das Xcode nicht kennt, gilt als bezahlt:
    /// dann scheitert der Bau mit Apples eigener Meldung statt mit einer geratenen – und lehnt Apple es dabei als
    /// „Personal development team“ ab, wird einmal neu gebaut, und ab dann gilt es als kostenlos (`markFree`).
    public static func isFree(_ teamId: String) -> Bool {
        if treatAsFree || refusedAsPaid().contains(teamId) { return true }
        return known().first { $0.id == teamId }?.free ?? false
    }
}
