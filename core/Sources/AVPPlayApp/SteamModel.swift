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
        steamNote = L("Signed out of Steam. SteamCMD’s remembered sign-in has been deleted.", "Bei Steam abgemeldet. Die gemerkte Anmeldung von SteamCMD ist gelöscht.")
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
        CheckCard(title: L("Steam Account (for Doom 3 and Half-Life: Alyx)", "Steam-Konto (für Doom 3 und Half-Life: Alyx)"), state: model.steamSignedIn ? .ok : .missing, detail: detail) {
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
        return L("Not signed in. Only needed for Doom 3 and Half-Life: Alyx: with a sign-in the app fetches their game files from your own Steam purchase – Steam only hands out what your account owns. You can also point the app at a folder with the files instead.",
                 "Nicht angemeldet. Nur für Doom 3 und Half-Life: Alyx nötig: Mit einer Anmeldung holt die App deren Spieldateien aus deinem eigenen Steam-Kauf – Steam gibt nur heraus, was deinem Konto gehört. Stattdessen kannst du der App auch einen Ordner mit den Dateien zeigen.")
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
