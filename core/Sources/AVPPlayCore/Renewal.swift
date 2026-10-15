import Foundation

/// Eine Sperre zwischen Prozessen: eine Datei, auf der genau ein Prozess `flock` hält. Sie fällt weg, sobald der
/// Prozess endet – auch wenn er abstürzt –, eine vergessene Sperre gibt es also nicht.
public final class ProcessLock: @unchecked Sendable {
    private var descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    /// Die Sperre fürs Bauen und Kopieren aufs Gerät.
    public static var installURL: URL { DataLocation.base.appendingPathComponent(".install.lock") }

    /// Nimmt die Sperre, wenn sie frei ist; sonst `nil`. Wartet nie.
    public static func acquire(_ url: URL) -> ProcessLock? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        // Lässt sich die Datei nicht anlegen (kein Schreibrecht), wird nicht gesperrt: lieber bauen als nie bauen.
        guard fd >= 0 else { return ProcessLock(descriptor: -1) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        return ProcessLock(descriptor: fd)
    }

    /// Ob gerade ein anderer Prozess die Sperre hält.
    public static func isHeld(_ url: URL) -> Bool {
        guard let lock = acquire(url) else { return true }
        lock.release()
        return false
    }

    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}

/// Was ein Lauf der Erneuerung für ein Spiel ergeben hat.
public struct RenewalOutcome: Codable, Sendable, Equatable {
    public enum Result: String, Codable, Sendable {
        /// Neu signiert; die Installation gilt länger als zuvor.
        case renewed
        /// Neu installiert, aber Apple hat kein neues Profil ausgestellt: das Ablaufdatum ist dasselbe.
        case unchanged
        /// Diesmal nicht versucht (Gerät nicht da, Spiel läuft, …).
        case skipped
        case failed
    }
    public var recipe: String
    public var title: String
    public var result: Result
    public var detail: String
    public var expires: Date?
}

/// Der letzte Lauf der Erneuerung, für die Anzeige in den Einstellungen.
public struct RenewalReport: Codable, Sendable, Equatable {
    public var ran: Date
    /// Wie viele Installationen überhaupt bekannt sind, und wie viele davon fällig waren.
    public var known: Int
    public var outcomes: [RenewalOutcome]

    public static var url: URL { DataLocation.base.appendingPathComponent("renewal.json") }

    public static func load(from url: URL = RenewalReport.url) -> RenewalReport? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.iso.decode(RenewalReport.self, from: data)
    }

    public func save(to url: URL = RenewalReport.url) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder.iso
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try? encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Erneuert Signaturen, die bald ablaufen: baut das Spiel neu und legt es über die bestehende Installation.
/// Spielstände und Daten bleiben dabei, wie bei jeder Installation über eine bestehende App.
///
/// visionOS öffnet eine App nur, solange ihr Bereitstellungsprofil gilt – sieben Tage bei einem kostenlosen
/// Apple-Konto. Ohne Erneuerung müsste jedes Spiel jede Woche von Hand neu installiert werden.
public enum Renewal {
    /// Nach einem Versuch, der nichts verlängert hat, wird so lange gewartet, bevor derselbe Bau noch einmal läuft.
    public static let retryAfter: TimeInterval = 6 * 3600

    /// Was ein neu signierter Bau vom bisherigen übernimmt: die Schalter und die Startauflösung, so wie der Stempel
    /// sie trägt. Fehlt dort eine Auflösung, bleibt sie weg (die des Targets) – das Erneuern verlängert nur die Frist.
    static func keepBuild(_ built: AppStamp.Built?, in request: inout InstallRequest) {
        guard let built else { return }
        if built.experimental { request.experimental = true }
        if built.metalFX {
            request.metalFX = true
            request.resolution = built.resolution
        }
    }

    /// Ist die Installation jetzt dran? Ab dem Zeitpunkt, ab dem auch die App an die Erneuerung erinnert (zwei Tage
    /// vor Ablauf bei sieben Tagen, dreißig bei einem Jahr) – und nicht kurz nach einem Versuch, der nichts brachte.
    public static func isDue(_ record: SigningRecord, now: Date) -> Bool {
        guard let from = record.remindFrom, now >= from else { return false }
        if let tried = record.renewalTried, now.timeIntervalSince(tried) < retryAfter { return false }
        return true
    }

    /// Die mitgelieferten Rezepte und die Entwürfe für nachgeschlagene Spiele; ein mitgeliefertes Rezept für
    /// dieselbe Store-App geht vor (wie in der Übersicht der App).
    public static func recipes(bundled: URL?, drafts: URL) -> [Recipe] {
        OtherSources.use(recipes: bundled)
        // Wo der Nutzer die neueste Fassung aus dem Store gewählt hat, wird auch die erneuert (StoreUpdate).
        let shipped = StoreUpdate.resolve(bundled.flatMap { try? RecipeStore(directory: $0).loadAll() } ?? [],
                                          variants: bundled.map { RecipeStore(directory: $0).loadVariants() } ?? [],
                                          sources: bundled.map { RecipeStore(directory: $0).loadSources() } ?? [], drafts: drafts)
        let known = Set(shipped.compactMap { $0.store.appId })
        let extra = ((try? RecipeStore(directory: drafts).loadAll()) ?? [])
            .filter { r in r.id.hasPrefix("store-") && !(r.store.appId.map(known.contains) ?? true) }
        return shipped + extra
    }

    /// Unter welcher Kennung die Installation auf dem Gerät liegt: die gemerkte, sonst die, unter der ein Team dieser
    /// Art üblicherweise installiert. Nie die Kennung der anderen Art: Liegt neben einer entfernten Installation mit
    /// einem kostenlosen Team noch eine mit einem bezahlten, gehört deren Kennung dem bezahlten Team – sie mit dem
    /// kostenlosen neu zu signieren, lehnte Apple ab.
    static func installedBundle(recipe: Recipe, record: SigningRecord, apps: [InstalledApp]) -> String? {
        let target = recipe.toolchain.target
        let usual = record.free ? Toolchain.bundleId(target: target, prefix: Toolchain.defaultBundlePrefix(freeTeam: record.team))
                                : Toolchain.defaultBundleId(target: target)
        let candidates = [record.bundleId, usual].compactMap { $0 }
        return candidates.first { bundle in apps.contains { $0.bundleIdentifier == bundle } }
    }

    /// Womit ein Spiel erneuert wird: mit dem für es gewählten Stand, sonst mit der neuesten Toolchain. `nil` (mit
    /// dem Grund an `skip`), wenn der gewählte Stand nicht mehr da ist, wenn die Toolchain für das Rezept zu alt
    /// ist – oder wenn auf dem Gerät ein Bau aus einer bearbeiteten Arbeitskopie liegt, die für das Spiel nicht
    /// gewählt ist: Den ersetzte das Erneuern sonst durch einen Bau ohne die Änderungen.
    static func chosenToolchain(for recipe: Recipe, app: InstalledApp, newest: Toolchain, choices: ToolchainChoices,
                                packager: ToolchainPackager, skip: (String) -> Void) -> Toolchain? {
        let chosen: Toolchain
        if let pin = choices.games[recipe.id] {
            guard let kept = packager.toolchain(for: pin) else {
                skip(L("toolchain \(pin.name), chosen for this game, is no longer on this Mac. Choose one on the game's page.",
                       "Toolchain \(pin.name), für dieses Spiel gewählt, liegt nicht mehr auf diesem Mac. Wähle auf der Seite des Spiels eine."))
                return nil
            }
            chosen = kept
        } else {
            if let built = app.bundleVersion.flatMap(AppStamp.parse), built.modified {
                skip(L("was built with toolchain \(Toolchain.name(version: built.toolchain, modified: true)), which is not chosen for this game. It is not renewed, so that this build is not replaced; choose the toolchain on the game's page.",
                       "wurde mit Toolchain \(Toolchain.name(version: built.toolchain, modified: true)) gebaut, die für dieses Spiel nicht gewählt ist. Es wird nicht erneuert, damit dieser Bau nicht ersetzt wird; wähle die Toolchain auf der Seite des Spiels."))
                return nil
            }
            chosen = newest
        }
        guard chosen.satisfies(minCommit: recipe.toolchain.minCommit) else {
            skip(choices.games[recipe.id] == nil
                 ? L("needs a newer toolchain than the one installed.", "braucht eine neuere Toolchain als die installierte.")
                 : L("needs a newer toolchain than the one chosen for it.", "braucht eine neuere Toolchain als die dafür gewählte."))
            return nil
        }
        return chosen
    }

    /// Ein Lauf: Wer fällig ist, wird neu signiert, sofern das Gerät erreichbar ist und nichts dagegen spricht.
    /// Ist nichts fällig, wird das Gerät gar nicht erst gefragt.
    /// - Parameters:
    ///   - toolchain: die installierte Toolchain; ohne sie wird nichts gebaut
    ///   - choices: wo für ein Spiel eine andere Toolchain gewählt ist, wird mit der erneuert – das Erneuern soll
    ///     einen Bau nicht gegen einen aus einem anderen Stand tauschen
    ///   - packager: wo die installierten Pakete liegen, unter denen ein gewähltes gesucht wird
    ///   - preferredDevice: das in der App gewählte Headset, wenn mehrere erreichbar sind
    ///   - dryRun: nur feststellen, was fällig wäre und ob es ginge
    ///   - force: diese Rezepte gelten als fällig, gleich wie lange ihre Signatur noch gilt (zum Ausprobieren)
    public static func run(recipes: [Recipe], store: ContentStore, toolchain: Toolchain?,
                           choices: ToolchainChoices = .load(), packager: ToolchainPackager = ToolchainPackager(root: ToolchainPackager.defaultRoot),
                           preferredDevice: String? = nil, now: Date = Date(), dryRun: Bool = false, force: Set<String> = [],
                           log: @escaping @Sendable (String) -> Void = { _ in }) async -> RenewalReport {
        let installations = recipes.compactMap { r in SigningRecord.load(store: store, recipe: r).map { (recipe: r, record: $0) } }
        let due = installations.filter { force.contains($0.recipe.id) || isDue($0.record, now: now) }
        var report = RenewalReport(ran: now, known: installations.count, outcomes: [])
        guard !due.isEmpty else { return report }

        func skipAll(_ why: String) -> RenewalReport {
            report.outcomes = due.map { RenewalOutcome(recipe: $0.recipe.id, title: $0.recipe.title, result: .skipped, detail: why, expires: $0.record.expires) }
            return report
        }
        guard StoreLocation.isAvailable(store.root) else {
            return skipAll(L("The folder for downloads is not connected.", "Der Ordner für Downloads ist nicht angeschlossen."))
        }
        guard DeveloperTools.present, let toolchain else {
            return skipAll(L("Xcode or the toolchain is missing (see “Setup”).", "Xcode oder die Toolchain fehlt (siehe „Einrichtung“)."))
        }
        let control = DeviceControl()
        let usable = ((try? control.devices()) ?? []).filter { $0.paired && $0.reachable }
        guard let device = usable.first(where: { $0.udid == preferredDevice }) ?? (usable.count == 1 ? usable[0] : nil),
              let apps = try? control.apps(device: device) else {
            return skipAll(L("The Vision Pro was not reachable.", "Die Vision Pro war nicht erreichbar."))
        }
        let running = (try? control.runningExecutables(device: device)) ?? []

        for (recipe, record) in due {
            func outcome(_ result: RenewalOutcome.Result, _ detail: String, expires: Date? = record.expires) {
                report.outcomes.append(RenewalOutcome(recipe: recipe.id, title: recipe.title, result: result, detail: detail, expires: expires))
                log("\(recipe.title): \(detail)")
            }
            /// Ein Versuch, der nichts verlängert hat, wird am Eintrag vermerkt – damit nicht jede Prüfung neu baut.
            func remember(_ note: String) {
                guard var current = SigningRecord.load(store: store, recipe: recipe) else { return }
                current.renewalTried = now
                current.renewalNote = note
                current.save(store: store, recipe: recipe, live: true)
            }
            guard let bundle = installedBundle(recipe: recipe, record: record, apps: apps),
                  let app = apps.first(where: { $0.bundleIdentifier == bundle }) else {
                outcome(.skipped, L("is not on this Vision Pro (any more).", "ist nicht (mehr) auf dieser Vision Pro."))
                continue
            }
            guard !DeviceControl.isRunning(app, executables: running) else {
                outcome(.skipped, L("is running right now; it is renewed at the next check.", "läuft gerade; erneuert wird bei der nächsten Prüfung."))
                continue
            }
            guard let toolchain = chosenToolchain(for: recipe, app: app, newest: toolchain, choices: choices, packager: packager,
                                                  skip: { outcome(.skipped, $0) }) else { continue }
            guard !ProcessLock.isHeld(ProcessLock.installURL) else {
                outcome(.skipped, L("another job is building right now; it is renewed at the next check.", "ein anderer Auftrag baut gerade; erneuert wird bei der nächsten Prüfung."))
                continue
            }
            if dryRun {
                outcome(.skipped, L("is due and would be renewed now.", "ist fällig und würde jetzt erneuert."))
                continue
            }
            var request = InstallRequest(toolchain: toolchain.root.path)
            request.team = record.team
            request.device = device.udid
            request.bundleId = bundle
            request.resign = true
            // Erneuert wird die eigentliche Installation, mit dem Namen, den sie bekommen hat.
            request.live = true
            request.displayName = record.displayName
            request.displaySuffix = record.displaySuffix
            request.storeArt = false
            request.addons = false
            // Ein neu signierter Bau bleibt, was er war: Hatte er die experimentellen Implementierungen an, dann
            // auch danach – das Erneuern soll an einem Spiel nichts ändern außer der Frist.
            Renewal.keepBuild(app.bundleVersion.flatMap(AppStamp.parse), in: &request)
            let installer = Installer(recipe: recipe, request: request, store: store, report: { log("  " + $0) })
            do {
                try await installer.perform(.build)
                let fresh = SigningRecord.load(store: store, recipe: recipe)
                if let after = fresh?.expires, let before = record.expires, after.timeIntervalSince(before) < 3600 {
                    let note = L("installed again, but the signature does not last longer than before. A later check tries again.",
                                 "neu installiert, aber die Signatur gilt nicht länger als zuvor. Eine spätere Prüfung versucht es erneut.")
                    remember(note)
                    outcome(.unchanged, note, expires: after)
                } else {
                    outcome(.renewed, L("signed again.", "neu signiert."), expires: fresh?.expires)
                }
            } catch {
                let note = Redaction.redact("\(error)")
                remember(note)
                outcome(.failed, note)
            }
        }
        return report
    }
}

/// Der Hintergrunddienst: ein Eintrag bei `launchd`, der in festen Abständen dieses Programm ohne Fenster startet,
/// damit es die Signaturen prüft (`--renew`). Er läuft auch, wenn AVP Play nicht geöffnet ist, und nur für den
/// angemeldeten Nutzer. Angelegt und entfernt wird er ausschließlich über den Schalter in den Einstellungen.
public struct BackgroundService: Sendable {
    public static let label = "io.github.mymartek.avpplay.renew"
    /// Die Abstände, die die Einstellungen anbieten, in Stunden.
    public static let intervals = [1, 3, 6, 12, 24]
    public static let defaultInterval = 6

    public let plist: URL
    public init(plist: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(BackgroundService.label).plist")) {
        self.plist = plist
    }

    public static var logURL: URL { DataLocation.base.appendingPathComponent("renewal.log") }

    /// Der Eintrag, wie `launchd` ihn liest.
    public static func definition(program: String, hours: Int, log: URL = BackgroundService.logURL) -> [String: Any] {
        ["Label": label,
         "ProgramArguments": [program, "--renew"],
         "StartInterval": max(1, hours) * 3600,
         // Nicht gleich beim Anmelden: dann ist das Headset selten schon da, und der erste Abstand genügt.
         "RunAtLoad": false,
         "ProcessType": "Background",
         "StandardOutPath": log.path,
         "StandardErrorPath": log.path]
    }

    /// Was gerade eingetragen ist: der Abstand in Stunden und das Programm; `nil`, wenn es keinen Eintrag gibt.
    public func installed() -> (hours: Int, program: String)? {
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let seconds = dict["StartInterval"] as? Int, let program = (dict["ProgramArguments"] as? [String])?.first else { return nil }
        return (max(1, seconds / 3600), program)
    }

    private var domain: String { "gui/\(getuid())" }

    /// Trägt den Dienst ein oder ändert seinen Abstand. Ein bestehender Eintrag wird ersetzt.
    public func enable(program: String, hours: Int) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: BackgroundService.definition(program: program, hours: hours),
                                                      format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = Toolchain.status(["/bin/launchctl", "bootout", "\(domain)/\(BackgroundService.label)"])
        try data.write(to: plist, options: .atomic)
        let status = Toolchain.status(["/bin/launchctl", "bootstrap", domain, plist.path])
        guard status == 0 else { throw BackgroundServiceError.launchd(status) }
    }

    public func disable() {
        _ = Toolchain.status(["/bin/launchctl", "bootout", "\(domain)/\(BackgroundService.label)"])
        try? FileManager.default.removeItem(at: plist)
    }

    /// Ob `launchd` den Dienst gerade kennt.
    public var isLoaded: Bool {
        Toolchain.status(["/bin/launchctl", "print", "\(domain)/\(BackgroundService.label)"]) == 0
    }
}

public enum BackgroundServiceError: Error, CustomStringConvertible, Equatable {
    case launchd(Int32)

    public var description: String {
        switch self {
        case .launchd(let status):
            return L("macOS did not accept the background service (launchctl \(status)). Check System Settings › General › Login Items & Extensions: AVP Play must be allowed to run in the background.",
                     "macOS hat den Hintergrunddienst nicht angenommen (launchctl \(status)). Prüfe Systemeinstellungen › Allgemein › Anmeldeobjekte & Erweiterungen: AVP Play muss im Hintergrund laufen dürfen.")
        }
    }
}
