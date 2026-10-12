import AppKit
import AVPPlayCore
import SwiftUI
import UserNotifications

// MARK: Kostenloses Apple-Konto

extension AppModel {
    /// Wird mit einem kostenlosen Apple-Konto signiert?
    var usesFreeTeam: Bool { team?.free == true }

    /// Unter welcher Kennung ein Spiel installiert wird.
    func bundleId(for game: Game) -> String { "\(bundlePrefix).\(game.recipe.toolchain.target)" }

    /// Die Apps dieses Kontos, die dieses Programm auf dem Gerät installiert hat; `nil`, wenn das Gerät nicht
    /// erreichbar ist.
    var freeTeamApps: [InstalledApp]? {
        guard usesFreeTeam, let apps = installedApps else { return nil }
        return Installer.appsSharingPrefix(with: "\(bundlePrefix).x", in: apps)
    }

    /// Installationen neuer Spiele, die schon laufen oder warten – sie belegen bald einen der Plätze.
    private var pendingNewInstalls: Set<String> {
        let installed = Set((installedApps ?? []).map(\.bundleIdentifier))
        var bundles: Set<String> = []
        for job in jobs where (job.id == runningJob || queued.contains(job.id)) && job.steps.contains(.build) {
            let bundle = job.request.bundleId ?? Toolchain.defaultBundleId(target: job.recipe.toolchain.target)
            if !installed.contains(bundle) { bundles.insert(bundle) }
        }
        return bundles
    }

    /// Was einer Installation mit einem kostenlosen Konto im Weg steht: eine Toolchain, die dafür nicht bauen kann,
    /// oder Apples Grenze von drei Apps je Gerät.
    func freeAccountBlocker(for game: Game) -> String? {
        guard usesFreeTeam else { return nil }
        if let t = toolchain, !t.supportsFreeTeams {
            return L("The installed toolchain cannot build for a free Apple account yet. Update AVP Play, or choose a paid team under “Setup”.",
                     "Die installierte Toolchain kann für ein kostenloses Apple-Konto noch nicht bauen. Aktualisiere AVP Play oder wähle unter „Einrichtung“ ein bezahltes Team.")
        }
        guard let mine = freeTeamApps else { return nil }
        let bundle = bundleId(for: game)
        guard !mine.contains(where: { $0.bundleIdentifier == bundle }) else { return nil }
        let waiting = pendingNewInstalls.subtracting([bundle]).count
        guard mine.count + waiting >= AppleMessages.freeAppsPerDevice else { return nil }
        let names = mine.map(\.name).sorted().joined(separator: ", ")
        if mine.count >= AppleMessages.freeAppsPerDevice {
            return L("A free Apple account may have only \(AppleMessages.freeAppsPerDevice) apps on the Vision Pro at a time. Already there: \(names). Remove one on the headset first (press and hold its icon, then “Remove App”).",
                     "Ein kostenloses Apple-Konto darf nur \(AppleMessages.freeAppsPerDevice) Apps gleichzeitig auf der Vision Pro haben. Schon dort: \(names). Entferne zuerst eine auf dem Headset (Icon gedrückt halten, dann „App entfernen“).")
        }
        return L("A free Apple account may have only \(AppleMessages.freeAppsPerDevice) apps on the Vision Pro at a time: \(mine.count) \(mine.count == 1 ? "is" : "are") there and \(waiting) more \(waiting == 1 ? "is" : "are") already being installed.",
                 "Ein kostenloses Apple-Konto darf nur \(AppleMessages.freeAppsPerDevice) Apps gleichzeitig auf der Vision Pro haben: \(mine.count) \(mine.count == 1 ? "ist" : "sind") dort, und \(waiting) weitere \(waiting == 1 ? "wird" : "werden") schon installiert.")
    }

    /// Eine Zeile zum Konto, für die Seitenleiste und die Seite eines Spiels.
    var freeAccountLine: String {
        guard let mine = freeTeamApps else {
            return L("Free Apple account: \(AppleMessages.freeSigningDays) days per install, \(AppleMessages.freeAppsPerDevice) apps at a time",
                     "Kostenloses Apple-Konto: \(AppleMessages.freeSigningDays) Tage je Installation, \(AppleMessages.freeAppsPerDevice) Apps gleichzeitig")
        }
        return L("Free Apple account: \(mine.count) of \(AppleMessages.freeAppsPerDevice) apps on the Vision Pro, \(AppleMessages.freeSigningDays) days per install",
                 "Kostenloses Apple-Konto: \(mine.count) von \(AppleMessages.freeAppsPerDevice) Apps auf der Vision Pro, \(AppleMessages.freeSigningDays) Tage je Installation")
    }
}

/// In der Seitenleiste: dass mit einem kostenlosen Konto signiert wird, und wie viele der Plätze belegt sind.
struct FreeAccountChip: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button { model.section = .setup } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Free Apple account", "Kostenloses Konto")).font(.callout.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(L("You are signing with a free Apple account. Click to see what that means.", "Du signierst mit einem kostenlosen Apple-Konto. Klicke, um zu sehen, was das bedeutet."))
    }

    private var detail: String {
        if let mine = model.freeTeamApps {
            return L("\(mine.count) of \(AppleMessages.freeAppsPerDevice) apps · \(AppleMessages.freeSigningDays) days each",
                     "\(mine.count) von \(AppleMessages.freeAppsPerDevice) Apps · je \(AppleMessages.freeSigningDays) Tage")
        }
        return L("\(AppleMessages.freeAppsPerDevice) apps · \(AppleMessages.freeSigningDays) days each", "\(AppleMessages.freeAppsPerDevice) Apps · je \(AppleMessages.freeSigningDays) Tage")
    }
}

/// Was ein kostenloses Konto bedeutet, als Liste – in der Einrichtung beim Entwicklerteam.
struct FreeAccountLimits: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("Free Apple account – what is different", "Kostenloses Apple-Konto – was anders ist"), systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold)).foregroundStyle(.orange)
            ForEach(AppleMessages.freeAccountLimits(), id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                    Text(line).fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
            if let mine = model.freeTeamApps {
                Text(mine.isEmpty
                     ? L("On this Vision Pro right now: none of the \(AppleMessages.freeAppsPerDevice) places is taken by a game from AVP Play.",
                         "Auf dieser Vision Pro gerade: Keiner der \(AppleMessages.freeAppsPerDevice) Plätze ist von einem Spiel aus AVP Play belegt.")
                     : L("On this Vision Pro right now: \(mine.count) of \(AppleMessages.freeAppsPerDevice) places taken (\(mine.map(\.name).sorted().joined(separator: ", "))).",
                         "Auf dieser Vision Pro gerade: \(mine.count) von \(AppleMessages.freeAppsPerDevice) Plätzen belegt (\(mine.map(\.name).sorted().joined(separator: ", "))).") )
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(model.renewInBackground
                     ? L("Signatures are renewed in the background (every \(model.renewIntervalHours) h).", "Signaturen werden im Hintergrund erneuert (alle \(model.renewIntervalHours) Std.).")
                     : L("AVP Play can renew the signatures by itself while the headset is reachable.", "AVP Play kann die Signaturen selbst erneuern, solange das Headset erreichbar ist."))
                    .font(.callout).foregroundStyle(.secondary)
                Button(L("Settings …", "Einstellungen …")) { model.section = .settings }.controlSize(.small)
            }
            Link(L("Apple Developer Program (paid, without these limits)", "Apple Developer Program (bezahlt, ohne diese Grenzen)"),
                 destination: URL(string: "https://developer.apple.com/programs/")!)
                .font(.callout)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: Mehrere Spiele auf einmal

enum BulkAction { case install, download }

extension AppModel {
    /// Die angehakten Spiele, in der Reihenfolge der Übersicht.
    var selectedGames: [Game] {
        let ids = selection
        // Erst die wenigen angehakten heraussuchen, dann ordnen – nicht die ganze Übersicht sortieren.
        return visible(allGames.filter { ids.contains($0.id) })
    }

    func toggleSelection(_ game: Game) {
        if selection.contains(game.id) { selection.remove(game.id) } else { selection.insert(game.id) }
    }

    /// Legt für jedes angehakte Spiel einen Auftrag an – installieren oder nur laden. Die Aufträge laufen
    /// nacheinander. Ein Spiel, dessen Dateien noch nicht nachgeschlagen sind, wird zuerst nachgeschlagen (das fragt
    /// Meta, mit Abstand); was nicht geht, wird am Ende mit Grund genannt, der Rest läuft trotzdem.
    func runBulk(_ action: BulkAction) {
        let ids = selectedGames.map(\.id)
        guard !ids.isEmpty, !bulkBusy else { return }
        bulkBusy = true
        Task { @MainActor in
            var started = 0
            var refused: [String] = []
            var firstJob: String?
            for (n, id) in ids.enumerated() {
                guard var game = allGames.first(where: { $0.id == id }) else { continue }
                if game.draft, !game.prepared {
                    notice = L("Looking up \(game.recipe.title) (\(n + 1) of \(ids.count)) …", "\(game.recipe.title) wird nachgeschlagen (\(n + 1) von \(ids.count)) …")
                    game = await lookedUp(game)
                }
                let known = Set(jobs.map(\.id))
                let why: String?
                switch action {
                case .install:
                    why = blocker(for: game)
                    if why == nil { enqueue(game, steps: InstallStep.allCases, show: false) }
                case .download:
                    why = hasDownloads(game) ? downloadBlocker(for: game)
                                             : L("nothing left to download", "nichts mehr zu laden")
                    if why == nil { enqueue(game, steps: InstallStep.download, show: false) }
                }
                if let why {
                    refused.append("\(game.recipe.title) – \(why)")
                } else {
                    started += 1
                    selection.remove(id)
                    if firstJob == nil { firstJob = jobs.first { !known.contains($0.id) }?.id }
                }
            }
            bulkBusy = false
            let done = action == .install
                ? L("\(started) install job\(started == 1 ? "" : "s") started; they run one after another.", "\(started) \(started == 1 ? "Installation" : "Installationen") gestartet; sie laufen nacheinander.")
                : L("\(started) download\(started == 1 ? "" : "s") started; they run one after another.", "\(started) \(started == 1 ? "Download" : "Downloads") gestartet; sie laufen nacheinander.")
            notice = refused.isEmpty ? done
                : (started > 0 ? done + " " : "") + L("Not started: ", "Nicht gestartet: ") + refused.joined(separator: "; ")
            if let firstJob {
                selectedJob = firstJob
                section = .jobs
            }
        }
    }

    /// Schlägt die Dateien eines ungetesteten Spiels nach und wartet, bis das Ergebnis in der Übersicht steht.
    private func lookedUp(_ game: Game) async -> Game {
        prepare(game)
        // Nachschlagen heißt: Katalog, Besitz, Metas Werkzeug (mit fünf Sekunden Abstand) – selten über eine Minute.
        var waited = 0.0
        while preparing.contains(game.id), waited < 180 {
            try? await Task.sleep(for: .milliseconds(400))
            waited += 0.4
        }
        // Danach liest die App den Bestand neu; erst dann kennt die Übersicht die Dateien.
        waited = 0
        while refreshing, waited < 60 {
            try? await Task.sleep(for: .milliseconds(300))
            waited += 0.3
        }
        return allGames.first { $0.id == game.id } ?? game
    }
}

/// Der Haken auf einer Karte der Übersicht. Er hört nur auf die Auswahl, nicht auf den Zustand der ganzen App.
struct SelectionMark: View {
    @EnvironmentObject var model: AppModel
    let game: Game

    var body: some View { Mark(picked: model.picked, game: game) }

    private struct Mark: View {
        @ObservedObject var picked: GameSelection
        let game: Game

        var body: some View {
            let on = picked.ids.contains(game.id)
            Button {
                if on { picked.ids.remove(game.id) } else { picked.ids.insert(game.id) }
            } label: {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(on ? L("Remove from the selection", "Aus der Auswahl nehmen") : L("Select, to install or download several games at once", "Auswählen, um mehrere Spiele auf einmal zu installieren oder zu laden"))
            .accessibilityLabel(L("Select \(game.recipe.title)", "\(game.recipe.title) auswählen"))
        }
    }
}

/// Der Rahmen einer Karte: farbig, wenn sie angehakt ist.
struct SelectionBorder: View {
    @ObservedObject var picked: GameSelection
    let id: String
    let hovering: Bool

    var body: some View {
        let on = picked.ids.contains(id)
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator.opacity(hovering ? 1 : 0.5)), lineWidth: on ? 2 : 1)
    }
}

/// Zeigt die Leiste, sobald etwas angehakt ist.
struct SelectionBarHost: View {
    @ObservedObject var picked: GameSelection

    var body: some View {
        if !picked.ids.isEmpty { SelectionBar(picked: picked) }
    }
}

/// Die Leiste unter der Übersicht, sobald Spiele angehakt sind: installieren oder nur laden, für alle zugleich.
struct SelectionBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var picked: GameSelection

    var body: some View {
        let games = model.selectedGames
        HStack(spacing: 12) {
            if model.bulkBusy { ProgressView().controlSize(.small) }
            Text(games.count == 1 ? L("1 game selected", "1 Spiel ausgewählt") : L("\(games.count) games selected", "\(games.count) Spiele ausgewählt"))
                .font(.callout.weight(.medium))
            if model.selection.count > games.count {
                Text(L("(\(model.selection.count - games.count) hidden by a filter)", "(\(model.selection.count - games.count) durch einen Filter ausgeblendet)"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("Clear Selection", "Auswahl aufheben")) { model.selection = [] }
            Button(L("Download Only", "Nur herunterladen")) { model.runBulk(.download) }
                .help(L("Fetches the files of the selected games to this Mac. Needs only the account the games were bought with – no Xcode, no Apple team, no Vision Pro.",
                        "Holt die Dateien der gewählten Spiele auf diesen Mac. Braucht nur das Konto, mit dem die Spiele gekauft sind – kein Xcode, kein Apple-Team, keine Vision Pro."))
            Button(L("Install", "Installieren")) { model.runBulk(.install) }
                .buttonStyle(.borderedProminent)
                .help(L("Downloads what is missing, builds each game and puts it on the Vision Pro, one after another.",
                        "Lädt, was fehlt, baut jedes Spiel und bringt es auf die Vision Pro, eines nach dem anderen."))
        }
        .disabled(model.bulkBusy || games.isEmpty)
        .padding(.horizontal, 22).padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: Signaturen erneuern

extension AppModel {
    /// Das Programm, das der Hintergrunddienst startet: dieses hier.
    private var ownExecutable: String? { Bundle.main.executablePath }

    /// Trägt den Hintergrunddienst ein, ändert seinen Abstand oder entfernt ihn – je nach Schalter.
    func applyBackgroundService() {
        let service = BackgroundService()
        guard renewInBackground else {
            service.disable()
            renewalNote = nil
            return
        }
        guard let program = ownExecutable else { return }
        do {
            try service.enable(program: program, hours: renewIntervalHours)
            renewalNote = nil
        } catch {
            renewInBackground = false
            renewalNote = "\(error)"
        }
    }

    /// Beim Start: Der Eintrag soll zu dem passen, was eingestellt ist – auch nachdem das Programm verschoben oder
    /// aktualisiert wurde. Ist nichts eingestellt, wird nichts angefasst.
    func reconcileBackgroundService() {
        guard renewInBackground, Snapshot.directory == nil, let program = ownExecutable else { return }
        let service = BackgroundService()
        if let installed = service.installed(), installed.program == program, installed.hours == renewIntervalHours, service.isLoaded { return }
        applyBackgroundService()
    }

    /// Prüft jetzt, was fällig ist, und erneuert es – dasselbe, was der Hintergrunddienst tut.
    func renewNow() {
        guard !renewing else { return }
        renewing = true
        let paths = paths
        let drafts = draftsDirectory
        let wanted = chosenDevice.isEmpty ? nil : chosenDevice
        Task.detached {
            let report = await Renewal.run(recipes: Renewal.recipes(bundled: paths.recipes, drafts: drafts), store: paths.store,
                                           toolchain: paths.toolchain(), preferredDevice: wanted)
            report.save()
            await MainActor.run {
                self.renewalReport = report
                self.renewing = false
                self.refresh()
            }
        }
    }

    /// Installationen mit bekanntem Ablauf, die früheste zuerst.
    var signedGames: [(game: Game, record: SigningRecord)] {
        games.compactMap { game in
            guard game.installed, let record = SigningRecord.load(store: paths.store, recipe: game.recipe), record.expires != nil else { return nil }
            return (game, record)
        }.sorted { ($0.record.expires ?? .distantFuture) < ($1.record.expires ?? .distantFuture) }
    }
}

/// Der Abschnitt der Einstellungen zum Erneuern der Signaturen.
struct RenewalSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section(L("Renew signatures", "Signaturen erneuern")) {
            Toggle(L("Check in the background and renew games before their signature runs out",
                     "Im Hintergrund prüfen und Spiele erneuern, bevor ihre Signatur abläuft"),
                   isOn: Binding(get: { model.renewInBackground }, set: { model.renewInBackground = $0; model.applyBackgroundService() }))
            Picker(L("Check every", "Prüfen alle"), selection: Binding(get: { model.renewIntervalHours },
                                                                      set: { model.renewIntervalHours = $0; if model.renewInBackground { model.applyBackgroundService() } })) {
                ForEach(BackgroundService.intervals, id: \.self) { hours in
                    Text(hours == 1 ? L("hour", "Stunde") : hours == 24 ? L("24 hours", "24 Stunden") : L("\(hours) hours", "\(hours) Stunden")).tag(hours)
                }
            }
            .disabled(!model.renewInBackground)
            Text(L("The Vision Pro opens a game only while its signature is valid: \(AppleMessages.freeSigningDays) days with a free Apple account, a year with a paid one. With this switch on, a small background service of AVP Play looks at the dates at the chosen interval – also while the app is closed. When a game is due (two days before the end with a free account, thirty with a paid one) and the Vision Pro is on, unlocked and on the same Wi-Fi, it builds the game again and installs it over the old one; saved games and data stay, and a game that is running is left alone. The files the game was built from must still be on this Mac. macOS lists the service under System Settings › General › Login Items.",
                   "Die Vision Pro öffnet ein Spiel nur, solange seine Signatur gilt: \(AppleMessages.freeSigningDays) Tage mit einem kostenlosen Apple-Konto, ein Jahr mit einem bezahlten. Mit diesem Schalter sieht ein kleiner Hintergrunddienst von AVP Play im gewählten Abstand nach den Daten – auch wenn das Programm geschlossen ist. Ist ein Spiel fällig (zwei Tage vor dem Ende bei einem kostenlosen Konto, dreißig bei einem bezahlten) und die Vision Pro an, entsperrt und im selben WLAN, baut er das Spiel neu und installiert es über das alte; Spielstände und Daten bleiben, und ein laufendes Spiel wird nicht angefasst. Die Dateien, aus denen das Spiel gebaut wurde, müssen dafür noch auf diesem Mac liegen. macOS führt den Dienst unter Systemeinstellungen › Allgemein › Anmeldeobjekte."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let note = model.renewalNote {
                Label(note, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let signed = model.signedGames
            if !signed.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(signed, id: \.game.id) { entry in
                        HStack {
                            Text(entry.game.recipe.title)
                            Spacer()
                            Text(RenewalSettings.remaining(entry.record))
                                .foregroundStyle(Renewal.isDue(entry.record, now: Date()) || (entry.record.remindFrom.map { Date() >= $0 } ?? false) ? .orange : .secondary)
                        }
                        .font(.callout)
                    }
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(lastRun).font(.callout)
                    ForEach(model.renewalReport?.outcomes ?? [], id: \.recipe) { outcome in
                        Text("\(outcome.title): \(outcome.detail)").font(.callout).foregroundStyle(outcome.result == .failed ? .orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
                Spacer()
                if model.renewing { ProgressView().controlSize(.small) }
                Button(L("Check Now", "Jetzt prüfen")) { model.renewNow() }.disabled(model.renewing || model.runningJob != nil)
            }
        }
    }

    private var lastRun: String {
        guard let report = model.renewalReport else { return L("Not checked yet.", "Noch nicht geprüft.") }
        let when = DateFormatter.localizedString(from: report.ran, dateStyle: .medium, timeStyle: .short)
        if report.outcomes.isEmpty {
            return report.known == 0
                ? L("Last check \(when): no installation with a known date yet.", "Letzte Prüfung \(when): noch keine Installation mit bekanntem Datum.")
                : L("Last check \(when): nothing due (\(report.known) known).", "Letzte Prüfung \(when): nichts fällig (\(report.known) bekannt).")
        }
        return L("Last check \(when):", "Letzte Prüfung \(when):")
    }

    /// „noch 3 Tage (bis 14.10., 18:20)“ oder „abgelaufen seit …“.
    static func remaining(_ record: SigningRecord, now: Date = Date()) -> String {
        guard let expires = record.expires else { return "" }
        let day = DateFormatter.localizedString(from: expires, dateStyle: .short, timeStyle: .short)
        let seconds = expires.timeIntervalSince(now)
        if seconds <= 0 { return L("ran out on \(day)", "abgelaufen am \(day)") }
        let days = Int(seconds / 86_400)
        if days >= 1 { return L("\(days) day\(days == 1 ? "" : "s") left (until \(day))", "noch \(days) \(days == 1 ? "Tag" : "Tage") (bis \(day))") }
        let hours = max(1, Int(seconds / 3600))
        return L("\(hours) hour\(hours == 1 ? "" : "s") left (until \(day))", "noch \(hours) Std. (bis \(day))")
    }
}

/// Der Lauf des Hintergrunddienstes: dieses Programm, gestartet mit `--renew`, ohne Fenster. Es prüft, erneuert,
/// schreibt auf, was dabei herauskam, sagt gegebenenfalls Bescheid und endet.
enum RenewalAgent {
    static func run() -> Never {
        let defaults = UserDefaults.standard
        let choice = defaults.string(forKey: "language") ?? "system"
        L10n.language = Language(rawValue: choice) ?? L10n.systemLanguage(preferred: Locale.preferredLanguages)
        DataLocation.adoptLegacyData()
        let paths = Paths()
        let drafts = DataLocation.base.appendingPathComponent("drafts", isDirectory: true)
        let wanted = defaults.string(forKey: "deviceUDID").flatMap { $0.isEmpty ? nil : $0 }
        @Sendable func stamp() -> String { ISO8601DateFormatter().string(from: Date()) }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let report = await Renewal.run(recipes: Renewal.recipes(bundled: paths.recipes, drafts: drafts), store: paths.store,
                                           toolchain: paths.toolchain(), preferredDevice: wanted,
                                           log: { print("\(stamp()) \(Redaction.redact($0))") })
            report.save()
            print("\(stamp()) checked: \(report.known) known, \(report.outcomes.count) due, "
                  + "\(report.outcomes.filter { $0.result == .renewed }.count) renewed")
            await notify(report)
            // Bei der Gelegenheit die Spielstände, sofern nicht abgestellt und gerade niemand baut oder kopiert.
            if defaults.object(forKey: "syncSaves") as? Bool ?? true, !ProcessLock.isHeld(ProcessLock.installURL),
               StoreLocation.isAvailable(paths.store.root) {
                let custom = defaults.string(forKey: "bundlePrefix").flatMap { $0.isEmpty ? nil : $0 }
                let all = Renewal.recipes(bundled: paths.recipes, drafts: drafts).filter { $0.id.hasPrefix("store-") || $0.files.contains { $0.role == "apk" } }
                if let results = SaveRound.run(recipes: all, store: paths.store, preferredDevice: wanted, prefix: custom) {
                    for r in results where r.kind == .saved || r.kind == .failed { print("\(stamp()) saved games – \(r.title): \(Redaction.redact(r.detail))") }
                    print("\(stamp()) saved games: \(results.count) installed, \(results.filter { $0.kind == .saved }.count) with something new")
                    defaults.set(Date().timeIntervalSince1970, forKey: "lastSaveRound")
                }
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }

    /// Sagt Bescheid, wenn etwas erneuert wurde oder nicht ging. Nur aus dem Programmpaket heraus; dass ein Spiel
    /// gerade nicht erreichbar war, ist keine Mitteilung wert – außer es läuft binnen eines Tages ab (einmal am Tag).
    static func notify(_ report: RenewalReport) async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        for outcome in report.outcomes {
            let content = UNMutableNotificationContent()
            content.title = outcome.title
            switch outcome.result {
            case .renewed:
                let until = outcome.expires.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) }
                content.body = until.map { L("Signed again – opens until \($0).", "Neu signiert – lässt sich bis \($0) öffnen.") } ?? L("Signed again.", "Neu signiert.")
            case .failed:
                content.body = L("The signature could not be renewed. AVP Play › Settings shows why.", "Die Signatur ließ sich nicht erneuern. AVP Play › Einstellungen zeigt, warum.")
            case .unchanged, .skipped:
                guard let expires = outcome.expires, expires.timeIntervalSinceNow < 86_400 else { continue }
                let key = "renewWarned-\(outcome.recipe)"
                guard UserDefaults.standard.string(forKey: key) != today else { continue }
                UserDefaults.standard.set(today, forKey: key)
                content.body = expires.timeIntervalSinceNow <= 0
                    ? L("The signature has run out. Turn on the Vision Pro so that it can be renewed.", "Die Signatur ist abgelaufen. Schalte die Vision Pro ein, damit sie erneuert werden kann.")
                    : L("The signature runs out within a day. Turn on the Vision Pro so that it can be renewed.", "Die Signatur läuft binnen eines Tages ab. Schalte die Vision Pro ein, damit sie erneuert werden kann.")
            }
            try? await center.add(UNNotificationRequest(identifier: "renew-\(outcome.recipe)", content: content, trigger: nil))
        }
        // Dem System einen Moment geben, die Mitteilungen anzunehmen, bevor der Prozess endet.
        try? await Task.sleep(for: .milliseconds(600))
    }
}
