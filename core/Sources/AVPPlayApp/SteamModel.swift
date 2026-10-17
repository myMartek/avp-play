import AppKit
import AVPPlayCore
import SwiftUI

/// Merkt sich, welche Abrufe angehalten werden sollen – gefragt wird von einem anderen Faden als dem der Oberfläche.
final class StopFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []
    func request(_ id: String) { lock.lock(); ids.insert(id); lock.unlock() }
    func clear(_ id: String) { lock.lock(); ids.remove(id); lock.unlock() }
    func isRequested(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(id) }
}

/// Steam in der Oberfläche: Valves Werkzeug einrichten, anmelden, und die Dateien eines Spiels aus dem eigenen
/// Steam-Kauf holen. Was geladen werden darf, entscheidet Steam – geliefert wird nur, was dem Konto gehört.
extension AppModel {
    var steamSignedIn: Bool {
        steamToolPresent && !steamAccount.isEmpty && steamSignedInAs == steamAccount && SteamTool().hasSession
    }

    func refreshSteam() {
        steamToolPresent = SteamTool().isInstalled
        steamNeedsRosetta = SteamTool().needsRosetta()
    }

    /// Lässt macOS Rosetta installieren, damit Valves Intel-Programm starten kann.
    func installRosetta() {
        guard !rosettaInstalling else { return }
        rosettaInstalling = true
        steamNote = L("macOS is installing Rosetta …", "macOS installiert Rosetta …")
        Task {
            let result = await Task.detached { Rosetta.install() }.value
            rosettaInstalling = false
            refreshSteam()
            steamNote = result.ok
                ? L("Rosetta is installed. You can sign in to Steam now.", "Rosetta ist installiert. Du kannst dich jetzt bei Steam anmelden.")
                : L("Rosetta could not be installed (\(result.detail)). You can do it yourself in the Terminal app: softwareupdate --install-rosetta",
                    "Rosetta ließ sich nicht installieren (\(result.detail)). Von Hand geht es im Programm „Terminal“: softwareupdate --install-rosetta")
        }
    }

    /// Lädt SteamCMD direkt von Valve und richtet es ein – nur, wenn das Programm darin von Valve signiert ist.
    func setUpSteam() {
        guard !steamSettingUp else { return }
        steamSettingUp = true
        steamNote = L("Downloading SteamCMD from Valve …", "SteamCMD wird von Valve geladen …")
        Task {
            let problem: String? = await Task.detached {
                do {
                    let archive = try await SteamTool.downloadArchive()
                    defer { try? FileManager.default.removeItem(at: archive) }
                    try SteamTool.install(archive: archive)
                    return nil
                } catch { return "\(error)" }
            }.value
            steamSettingUp = false
            refreshSteam()
            steamNote = problem ?? (steamNeedsRosetta
                ? L("SteamCMD is set up and signed by Valve. One thing is still missing: Rosetta (see below).", "SteamCMD ist eingerichtet und von Valve signiert. Eines fehlt noch: Rosetta (siehe unten).")
                : L("SteamCMD is set up and signed by Valve. You can sign in now.", "SteamCMD ist eingerichtet und von Valve signiert. Du kannst dich jetzt anmelden."))
        }
    }

    func steamSignOut() {
        try? SteamTool().signOut()
        steamSignedInAs = ""
        SteamLibraryCache(store: paths.store).clear()
        steamLibrary = nil
        steamNote = L("Signed out of Steam. SteamCMD’s remembered sign-in has been deleted.", "Bei Steam abgemeldet. Die gemerkte Anmeldung von SteamCMD ist gelöscht.")
    }

    // MARK: Steam-Spiele mit Android-Fassung

    /// Liest, welche Spiele des Steam-Kontos eine Android-Fassung haben – höchstens einmal am Tag, `force` sofort.
    /// Valves Werkzeug fragt dafür die Lizenzen und die App-Daten ab; das dauert mit vielen Spielen über eine Minute.
    /// Gelingt es nicht, bleibt der letzte Stand stehen.
    func loadSteamLibrary(force: Bool = false) {
        guard steamSignedIn, storeBlocker == nil, !loadingSteamLibrary else { return }
        if !force, let steamLibrary, !steamLibrary.isStale() { return }
        loadingSteamLibrary = true
        let account = steamAccount
        let cache = SteamLibraryCache(store: paths.store)
        Task.detached {
            var problem: String?
            var fresh: SteamLibrary?
            var signedOut = false
            do {
                let library = SteamLibrary(checked: Date(), apps: try SteamLibraryScan(account: account).run())
                try? cache.save(library)
                fresh = library
            } catch {
                if case SteamError.notSignedIn = error { signedOut = true }
                problem = Redaction.redact("\(error)")
            }
            let loaded = fresh, note = problem, lost = signedOut
            await MainActor.run {
                self.loadingSteamLibrary = false
                self.steamLibraryProblem = note
                if lost { self.steamSignedInAs = "" }
                if let loaded { self.steamLibrary = loaded }
            }
        }
    }

    /// Die Steam-Spiele mit Android-Fassung, die es auf diesem Mac noch nicht gibt – weder als Rezept noch als Entwurf:
    /// die des Kontos und dahinter die übrigen aus der Steam-Liste des Katalogs (die gehören dem Konto nicht oder sind
    /// noch nicht gelesen). Ein Eintrag der Liste ohne Depot-Angaben lässt sich nicht laden, nur zeigen.
    func steamPlaceholders(known games: [Game]) -> [SteamAndroidApp] {
        var known = Set(games.flatMap { $0.ownershipKeys.isEmpty ? [OwnershipCache.key(for: $0.recipe)].compactMap { $0 } : $0.ownershipKeys })
        var out: [SteamAndroidApp] = []
        for app in steamLibrary?.apps ?? [] where known.insert("steam:\(app.appId)").inserted { out.append(app) }
        for entry in steamCatalog where known.insert("steam:\(entry.appId)").inserted {
            out.append(SteamAndroidApp(appId: entry.appId, name: entry.title, depots: [], apks: []))
        }
        return out
    }

    /// „Von Steam laden“ für ein ungetestetes Steam-Spiel: lädt seine Android-Fassung, schreibt daraus den Entwurf (mit
    /// Prüfsummen) und übernimmt die Dateien in den Bestand. Danach baut und installiert es der übliche Weg.
    /// Ein Steam-Spiel des Kontos, dessen Android-Fassung noch nicht geladen ist: seine Angaben aus den gelesenen
    /// Steam-Spielen. `nil` für jedes andere Spiel.
    func steamDraftApp(_ game: Game) -> SteamAndroidApp? {
        guard game.draft, !game.prepared, game.recipe.source == .steam, let id = game.recipe.store.steamAppId else { return nil }
        return steamLibrary?.apps.first { $0.appId == id }
    }

    /// Was dem Laden eines solchen Steam-Spiels im Weg steht: es lädt gerade, die Steam-Spiele sind noch nicht
    /// gelesen, oder es gehört dem Konto nicht.
    func steamDraftBlocker(for game: Game) -> String? {
        if preparing.contains(game.id) { return prepareNote[game.id] ?? L("Downloading from Steam …", "Wird von Steam geladen …") }
        if let why = steamBlocker(for: game) { return why }
        guard steamDraftApp(game) == nil else { return nil }
        if steamLibrary == nil {
            return L("Your Steam games have not been read yet (filter “Steam” or “Owned”).", "Deine Steam-Spiele sind noch nicht gelesen (Filter „Steam“ oder „Im Besitz“).")
        }
        return L("This game is not in your Steam account. Once you own it on Steam, it can be installed here.",
                 "Dieses Spiel gehört nicht zu deinem Steam-Konto. Sobald es dir bei Steam gehört, lässt es sich hier installieren.")
    }

    /// Nach dem Lesen der Spiele: was nach dem Laden von Steam installiert werden sollte und nun einen Entwurf hat.
    func installPreparedSteamGames() {
        for id in installAfterSteam {
            guard let game = games.first(where: { $0.id == id }), game.prepared else { continue }
            installAfterSteam.remove(id)
            install(game)
        }
    }

    func prepareFromSteam(_ game: Game, thenInstall: Bool = false) {
        guard game.draft, game.recipe.source == .steam, let appId = game.recipe.store.steamAppId,
              let app = steamLibrary?.apps.first(where: { $0.appId == appId }), !preparing.contains(game.id) else { return }
        if let why = steamBlocker(for: game) { prepareNote[game.id] = why; return }
        preparing.insert(game.id)
        if thenInstall { installAfterSteam.insert(game.id) } else { installAfterSteam.remove(game.id) }
        prepareNote[game.id] = L("Asking Steam whether this account owns the game …", "Steam wird gefragt, ob das Spiel zu diesem Konto gehört …")
        let store = paths.store, account = steamAccount, drafts = draftsDirectory, id = game.id
        let minCommit = toolchain?.commit() ?? ""
        let flags = steamStops
        flags.clear(id)
        Task.detached {
            var note: String?
            do {
                let recipe = try SteamDraftMaker(store: store, account: account).prepare(
                    app: app, target: DraftRecipe.genericTarget(appId:), minCommit: minCommit,
                    shouldStop: { flags.isRequested(id) },
                    progress: { p in
                        let text = L("Downloading from Steam: \(Installer.gigabytes(p.done)) of \(Installer.gigabytes(p.total)) …",
                                     "Von Steam wird geladen: \(Installer.gigabytes(p.done)) von \(Installer.gigabytes(p.total)) …")
                        Task { @MainActor in if self.preparing.contains(id) { self.prepareNote[id] = text } }
                    },
                    report: { line in Task { @MainActor in if self.preparing.contains(id) { self.prepareNote[id] = line } } })
                try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                try encoder.encode(recipe).write(to: drafts.appendingPathComponent("\(recipe.id).json"), options: .atomic)
            } catch {
                note = Redaction.redact("\(error)")
            }
            let final = note
            await MainActor.run {
                self.preparing.remove(id)
                self.prepareNote[id] = final
                // Ging es schief, wird danach auch nicht installiert.
                if final != nil { self.installAfterSteam.remove(id) }
                self.refresh()
            }
        }
    }

    /// Was einem Abruf bei Steam im Weg steht.
    func steamBlocker(for game: Game) -> String? {
        if let why = storeBlocker { return why }
        if !steamToolPresent || !steamSignedIn {
            return L("Sign in to Steam under “Setup” – then the app can fetch these files for you.", "Melde dich unter „Einrichtung“ bei Steam an – dann kann die App diese Dateien für dich holen.")
        }
        if isBusy(game.id) { return L("A job for this game is already running.", "Für dieses Spiel läuft schon ein Auftrag.") }
        return nil
    }

    /// Holt, was dem Spiel fehlt und aus dem eigenen Steam-Kauf kommt.
    func fetchFromSteam(_ game: Game) {
        guard steamBlocker(for: game) == nil, !steamBusy.contains(game.id) else { return }
        let id = game.id, recipe = game.recipe, account = steamAccount, paths = paths, stops = steamStops
        // Wählbares kommt nur mit, wenn es angehakt ist.
        let optional = Set(options(for: game).optionalNames)
        stops.clear(id)
        steamBusy.insert(id)
        steamProgress[id] = nil
        steamSaid[id] = L("Starting SteamCMD …", "SteamCMD wird gestartet …")
        let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                                                             reason: "Download from Steam")
        Task.detached {
            var outcome: String
            var signedOut = false
            do {
                let adopted = try SteamFetcher(store: paths.store, account: account).fetch(
                    recipe: recipe, optionalNames: optional, shouldStop: { stops.isRequested(id) },
                    progress: { p in Task { @MainActor in self.steamProgress[id] = p } },
                    report: { line in Task { @MainActor in self.steamSaid[id] = line } })
                outcome = adopted.isEmpty ? L("Nothing was missing that Steam could provide.", "Es fehlte nichts, was Steam liefern könnte.")
                                          : L("From Steam, added to the library: \(adopted.joined(separator: ", "))", "Von Steam in den Bestand übernommen: \(adopted.joined(separator: ", "))")
            } catch {
                if case SteamError.notSignedIn = error { signedOut = true }
                outcome = "\(error)"
            }
            let text = outcome, lost = signedOut
            // Kurz warten: die letzten Zwischenmeldungen sind noch unterwegs und sollen das Ergebnis nicht überschreiben.
            try? await Task.sleep(for: .milliseconds(300))
            await MainActor.run {
                ProcessInfo.processInfo.endActivity(activity)
                self.steamBusy.remove(id)
                self.steamProgress[id] = nil
                self.steamSaid[id] = text
                if lost { self.steamSignedInAs = "" }
                self.refresh()
            }
        }
    }

    func stopSteam(_ game: Game) { steamStops.request(game.id) }
}

/// Die Zeile „Steam“ der Einrichtung. Sie ist freiwillig: gebraucht wird sie nur für Spiele aus dem eigenen Steam-Kauf.
struct SteamCard: View {
    @EnvironmentObject var model: AppModel
    @State private var showLogin = false

    var body: some View {
        CheckCard(title: L("Steam Account (for games you bought on Steam)", "Steam-Konto (für Spiele, die du bei Steam gekauft hast)"), state: model.steamSignedIn ? .ok : .missing, detail: detail) {
            HStack {
                if !model.steamToolPresent {
                    Button(L("Get SteamCMD from Valve", "SteamCMD von Valve holen")) { model.setUpSteam() }.disabled(model.steamSettingUp)
                    if model.steamSettingUp { ProgressView().controlSize(.small) }
                } else if model.steamNeedsRosetta {
                    Button(L("Install Rosetta", "Rosetta installieren")) { model.installRosetta() }.disabled(model.rosettaInstalling)
                    if model.rosettaInstalling { ProgressView().controlSize(.small) }
                } else if model.steamSignedIn {
                    Button(L("Sign Out", "Abmelden")) { model.steamSignOut() }
                } else {
                    Button(L("Sign In …", "Anmelden …")) { showLogin = true }
                }
            }
            if !model.steamToolPresent {
                Text(L("SteamCMD is Valve’s own command-line tool. The app downloads it straight from Valve, checks that the program is signed by Valve, and keeps it in its own folder, apart from a Steam you may have installed.",
                       "SteamCMD ist Valves eigenes Kommandozeilenwerkzeug. Die App lädt es direkt von Valve, prüft, dass das Programm von Valve signiert ist, und hält es in einem eigenen Ordner – getrennt von einem Steam, das du vielleicht installiert hast."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.steamToolPresent, model.steamNeedsRosetta {
                Text(L("Valve ships SteamCMD as an Intel program. To run it, this Mac needs Rosetta, Apple's own translator for Intel programs – a small download from Apple that macOS installs itself, without a password. By clicking the button you accept Apple's licence for Rosetta.",
                       "Valve liefert SteamCMD als Intel-Programm aus. Damit es läuft, braucht dieser Mac Rosetta, Apples eigenen Übersetzer für Intel-Programme – ein kleiner Download von Apple, den macOS selbst installiert, ohne Kennwort. Mit dem Klick auf den Knopf stimmst du Apples Lizenz für Rosetta zu."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let note = model.steamNote {
                Label(note, systemImage: "info.circle").font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $showLogin) { SteamLoginSheet().environmentObject(model) }
    }

    private var detail: String {
        if model.steamSignedIn {
            return L("Signed in as \(model.steamAccount). SteamCMD remembers the sign-in in its own folder; the app stores only the account name.",
                     "Angemeldet als \(model.steamAccount). SteamCMD merkt sich die Anmeldung in seinem eigenen Ordner; die App speichert nur den Kontonamen.")
        }
        return L("Not signed in. Only needed for games from your own Steam purchases – Doom 3, Half-Life: Alyx, and games you can choose Steam for as the purchase source, such as Walkabout Mini Golf. With a sign-in the app checks your purchase and fetches the game files; Steam only hands out what your account owns. For Doom 3 and Half-Life: Alyx you can also point the app at a folder with the files instead.",
                 "Nicht angemeldet. Nur für Spiele aus deinem eigenen Steam-Kauf nötig – Doom 3, Half-Life: Alyx und Spiele, bei denen du Steam als Kaufquelle wählen kannst, etwa Walkabout Mini Golf. Mit einer Anmeldung prüft die App deinen Kauf und holt die Spieldateien; Steam gibt nur heraus, was deinem Konto gehört. Für Doom 3 und Half-Life: Alyx kannst du der App stattdessen auch einen Ordner mit den Dateien zeigen.")
    }
}

/// Die Anmeldung bei Steam: erst der Kontoname, dann Valves Werkzeug in diesem Fenster. Passwort und
/// Steam-Guard-Code gehen unverändert an das Werkzeug und werden hier weder gespeichert noch protokolliert.
struct SteamLoginSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = LoginSession()
    @State private var account = ""
    @State private var started = false
    @State private var answer = ""
    @FocusState private var focused: Bool

    private var name: String { account.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Sign In to Steam", "Bei Steam anmelden")).font(.title2.bold())
            Text(L("Sign-in runs through Valve’s own tool, SteamCMD. What you type here goes only to that tool. It remembers the sign-in in its own folder inside this app’s data; “Sign Out” deletes that folder. The app itself stores only your account name.",
                   "Die Anmeldung läuft über Valves eigenes Werkzeug SteamCMD. Was du hier eintippst, geht nur an dieses Werkzeug. Es merkt sich die Anmeldung in einem eigenen Ordner in den Daten dieser App; „Abmelden“ löscht diesen Ordner. Die App selbst speichert nur deinen Kontonamen."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !started {
                HStack {
                    TextField(L("Steam account name (the one you sign in with)", "Steam-Kontoname (mit dem du dich anmeldest)"), text: $account)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit(begin)
                    Button(L("Continue", "Weiter"), action: begin).keyboardShortcut(.defaultAction)
                        .disabled(!SteamTool.isAccountName(name))
                }
                Text(L("If Steam Guard is on, SteamCMD asks for the code next – or waits for you to confirm in the Steam app on your phone.",
                       "Ist Steam Guard an, fragt SteamCMD danach nach dem Code – oder wartet, bis du in der Steam-App auf dem Telefon bestätigst."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(session.transcript.isEmpty
                             ? L("Starting SteamCMD – the first start takes a moment, it updates itself …", "SteamCMD wird gestartet – der erste Start dauert einen Moment, es aktualisiert sich …")
                             : session.transcript)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(10)
                            .id("end")
                    }
                    .frame(minHeight: 170, maxHeight: 240)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .onChange(of: session.transcript) { proxy.scrollTo("end", anchor: .bottom) }
                }
                switch session.outcome {
                case .success:
                    Label(L("Signed in to Steam.", "Bei Steam angemeldet."), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failure(let why):
                    Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                case nil:
                    HStack {
                        Group {
                            if session.wantsSecret {
                                SecureField(L("Password (hidden as you type)", "Passwort (wird verdeckt)"), text: $answer)
                            } else {
                                TextField(L("Answer, e.g. the Steam Guard code", "Antwort, z. B. der Steam-Guard-Code"), text: $answer)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit(submit)
                        Button(L("Send", "Senden"), action: submit).keyboardShortcut(.defaultAction)
                    }
                    .disabled(!session.running)
                }
            }

            HStack {
                Spacer()
                if started, session.outcome != nil {
                    if session.outcome != .success { Button(L("Try Again", "Noch einmal")) { run() } }
                    Button(L("Close", "Schließen")) { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button(L("Cancel", "Abbrechen"), role: .cancel) {
                        if started { session.abort() }
                        dismiss()
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 580)
        .onAppear {
            account = model.steamAccount
            focused = true
        }
        .onChange(of: session.outcome) {
            if session.outcome == .success {
                model.steamAccount = name
                model.steamSignedInAs = name
                model.steamNote = nil
                model.refreshSteam()
            }
        }
    }

    private func begin() {
        guard SteamTool.isAccountName(name) else { return }
        started = true
        run()
    }

    private func run() {
        let name = name
        session.start { input, output in try SteamLogin.run(account: name, input: input, output: output) }
        focused = true
    }

    private func submit() {
        session.send(answer)
        answer = ""
        focused = true
    }
}

/// Auf der Seite eines Spiels: der Weg über Steam für das, was der Nutzer sonst selbst bereitstellt.
struct SteamFetchRow: View {
    @EnvironmentObject var model: AppModel
    let game: Game
    /// Die Zeile über der Erklärung; ohne Angabe die für die Dateien des Spiels selbst.
    var headline: String?

    var body: some View {
        let busy = model.steamBusy.contains(game.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline ?? L("Or let the app fetch them from your Steam account.", "Oder lass die App sie aus deinem Steam-Konto holen."))
                    Text(model.steamBlocker(for: game)
                         ?? L("Asks Steam whether your account owns the game, downloads exactly the version this recipe was made for, and checks it against the recipe.",
                              "Fragt Steam, ob das Spiel zu deinem Konto gehört, lädt genau die Fassung, für die dieses Rezept gemacht ist, und prüft sie gegen das Rezept."))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if busy {
                    Button(L("Stop", "Anhalten")) { model.stopSteam(game) }
                } else {
                    Button(L("Download from Steam", "Von Steam laden")) { model.fetchFromSteam(game) }
                        .disabled(model.steamBlocker(for: game) != nil)
                }
            }
            if busy, let p = model.steamProgress[game.id], p.total > 0 {
                ProgressView(value: Double(p.done), total: Double(p.total))
                Text("\(Installer.gigabytes(p.done)) / \(Installer.gigabytes(p.total))").font(.caption).foregroundStyle(.secondary)
            } else if busy {
                ProgressView().controlSize(.small)
            }
            if let said = model.steamSaid[game.id] {
                Text(said).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }
}
