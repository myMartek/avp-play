import Foundation

/// Was der Nutzer zur Menüleiste eingestellt hat: ob AVP Play dort ein Symbol hat und ob das Programm weiterläuft,
/// wenn sein Fenster geschlossen wird. Weiterlaufen gibt es nur mit Symbol – sonst liefe ein Programm, das man
/// weder im Dock noch in der Menüleiste sieht und nur noch über die Aktivitätsanzeige beenden könnte.
public struct MenuBarPreferences: Equatable, Sendable {
    public static let showKey = "menuBarShow"
    public static let keepRunningKey = "menuBarKeepRunning"

    /// Das Symbol ist von Anfang an da: es zeigt nur, was ohnehin geschieht, und ändert am Verhalten nichts.
    public var show: Bool
    /// Ohne ausdrückliche Wahl bleibt alles wie bisher: das Programm endet mit seinem letzten Fenster.
    public var keepRunning: Bool

    public init(show: Bool = true, keepRunning: Bool = false) {
        self.show = show
        self.keepRunning = keepRunning
    }

    public static func load(defaults: UserDefaults = .standard) -> MenuBarPreferences {
        MenuBarPreferences(show: defaults.object(forKey: showKey) as? Bool ?? true,
                           keepRunning: defaults.object(forKey: keepRunningKey) as? Bool ?? false)
    }

    public func save(defaults: UserDefaults = .standard) {
        defaults.set(show, forKey: MenuBarPreferences.showKey)
        defaults.set(keepRunning, forKey: MenuBarPreferences.keepRunningKey)
    }

    /// Läuft das Programm nach dem Schließen des Fensters in der Menüleiste weiter?
    public var staysInMenuBar: Bool { show && keepRunning }

    /// Die Antwort auf `applicationShouldTerminateAfterLastWindowClosed`.
    public var terminatesWithLastWindow: Bool { !staysInMenuBar }
}

/// Die Zeilen im Fenster der Menüleiste, aus dem Zustand des Programms abgeleitet. Hier statt in der Ansicht, damit
/// sie sich ohne Oberfläche prüfen lassen.
public struct MenuBarStatus: Equatable, Sendable {
    /// Der laufende Auftrag, soweit einer läuft.
    public struct RunningJob: Equatable, Sendable {
        public var title: String
        public var step: InstallStep?
        public var done: Int64?
        public var total: Int64?
        public init(title: String, step: InstallStep?, done: Int64? = nil, total: Int64? = nil) {
            self.title = title; self.step = step; self.done = done; self.total = total
        }
    }

    public enum Remote: Equatable, Sendable {
        case off
        /// Eingeschaltet, aber das Programm lauscht nicht (etwa weil das Netz es verweigert).
        case problem(String)
        case waiting
        case connected(Int)
    }

    public struct Renewal: Equatable, Sendable {
        /// Der Hintergrunddienst ist eingetragen.
        public var inBackground: Bool
        public var intervalHours: Int
        public var lastRun: Date?
        /// Die früheste bekannte Frist einer erneuerten oder geprüften Installation.
        public var nextExpiry: Date?
        public init(inBackground: Bool, intervalHours: Int, lastRun: Date?, nextExpiry: Date?) {
            self.inBackground = inBackground; self.intervalHours = intervalHours; self.lastRun = lastRun; self.nextExpiry = nextExpiry
        }
    }

    public var job: RunningJob?
    public var waiting: Int
    public var failed: Int
    public var deviceName: String?
    public var remote: Remote
    /// Nur, wo Erneuern eine Rolle spielt: bei einem kostenlosen Apple-Konto oder wenn der Dienst eingetragen ist.
    public var renewal: Renewal?

    public init(job: RunningJob?, waiting: Int, failed: Int, deviceName: String?, remote: Remote, renewal: Renewal?) {
        self.job = job; self.waiting = waiting; self.failed = failed; self.deviceName = deviceName
        self.remote = remote; self.renewal = renewal
    }

    /// Wie weit der laufende Schritt ist, zwischen 0 und 1; `nil`, wenn er keine Größe kennt.
    public var fraction: Double? {
        guard let job, let done = job.done, let total = job.total, total > 0 else { return nil }
        return min(1, max(0, Double(done) / Double(total)))
    }

    /// Die Zahl neben dem Symbol in der Menüleiste: der Fortschritt in Prozent, solange etwas läuft und er bekannt ist.
    public var percent: Int? { fraction.map { Int(($0 * 100).rounded(.down)) } }

    /// Ob das Symbol auf etwas hinweisen soll: ein Auftrag ist gescheitert.
    public var needsAttention: Bool { failed > 0 && job == nil }

    public var jobLine: String {
        if let job { return job.title }
        if failed > 0 {
            return failed == 1 ? L("1 job stopped with an error", "1 Auftrag mit Fehler angehalten")
                               : L("\(failed) jobs stopped with an error", "\(failed) Aufträge mit Fehler angehalten")
        }
        return L("No job running", "Kein Auftrag läuft")
    }

    /// Die Zeile unter dem Titel des laufenden Auftrags: der Schritt, der Fortschritt und wie viele noch warten.
    public var jobDetail: String? {
        var parts: [String] = []
        if let job {
            if let step = job.step { parts.append(step.title) }
            if let percent { parts.append("\(percent) %") }
        }
        if waiting > 0 { parts.append(L("\(waiting) waiting", "\(waiting) warten")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public var deviceLine: String {
        deviceName.map { L("\($0) connected", "\($0) verbunden") } ?? L("No Vision Pro reachable", "Keine Vision Pro erreichbar")
    }

    public var remoteLine: String {
        switch remote {
        case .off: return L("Remote control off", "Fernsteuerung aus")
        case .problem(let why): return L("Remote control: \(why)", "Fernsteuerung: \(why)")
        case .waiting: return L("Remote control on, no headset connected", "Fernsteuerung an, kein Headset verbunden")
        case .connected(let n):
            return n == 1 ? L("Remote control: 1 headset connected", "Fernsteuerung: 1 Headset verbunden")
                          : L("Remote control: \(n) headsets connected", "Fernsteuerung: \(n) Headsets verbunden")
        }
    }

    /// Eine Zeile zur Erneuerung der Signaturen, oder `nil`, wo sie keine Rolle spielt.
    public func renewalLine(now: Date = Date()) -> String? {
        guard let renewal else { return nil }
        var parts: [String] = []
        if renewal.inBackground {
            parts.append(L("Renewed in the background every \(renewal.intervalHours) h", "Erneuerung im Hintergrund alle \(renewal.intervalHours) Std."))
        } else {
            parts.append(L("Background renewal off", "Erneuerung im Hintergrund aus"))
        }
        if let expiry = renewal.nextExpiry {
            if expiry <= now {
                parts.append(L("a game has expired", "ein Spiel ist abgelaufen"))
            } else {
                let days = Int((expiry.timeIntervalSince(now) / 86_400).rounded(.down))
                parts.append(days < 1 ? L("next expiry in less than a day", "nächste Frist in weniger als einem Tag")
                                      : L("next expiry in \(days) \(days == 1 ? "day" : "days")", "nächste Frist in \(days) \(days == 1 ? "Tag" : "Tagen")"))
            }
        }
        return parts.joined(separator: " · ")
    }

    /// Die früheste Frist aus dem letzten Lauf der Erneuerung; gescheiterte und übersprungene Spiele zählen mit,
    /// denn auch ihre Installation läuft ab.
    public static func nextExpiry(in report: RenewalReport?) -> Date? {
        report?.outcomes.compactMap(\.expires).min()
    }
}
