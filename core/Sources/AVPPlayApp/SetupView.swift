import AppKit
import AVPPlayCore
import SwiftUI
import UniformTypeIdentifiers

/// Die Einrichtung: fünf Dinge, jedes mit einer echten Prüfung und – wenn etwas fehlt – dem nächsten Handgriff.
struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @State private var showLogin = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("To put a game on the Vision Pro, this Mac needs five things. Green means: checked and fine.", "Damit ein Spiel auf die Vision Pro kommt, braucht dieser Mac fünf Dinge. Grün heißt: geprüft und in Ordnung."))
                    .foregroundStyle(.secondary)

                CheckCard(title: "Xcode", state: model.xcodeProblem == nil ? (model.xcodeText == nil ? .checking : .ok) : .missing,
                          detail: model.xcodeProblem ?? model.xcodeText ?? L("Checking …", "Wird geprüft …")) {
                    if model.xcodeProblem != nil {
                        Link(L("Open Xcode in the App Store", "Xcode im App Store öffnen"), destination: URL(string: "macappstore://apps.apple.com/app/xcode/id497799835")!)
                    }
                }

                CheckCard(title: "Vision Pro", state: model.device == nil ? .missing : (model.deviceProblem == nil ? .ok : .warning),
                          detail: model.device.map { d in model.deviceProblem ?? L("\(d.name) with visionOS \(d.osVersion) is reachable.", "\(d.name) mit visionOS \(d.osVersion) ist erreichbar.") }
                              ?? model.deviceProblem ?? L("Searching …", "Wird gesucht …")) {
                    if model.device == nil {
                        Text(L("The first time: put Vision Pro and Mac on the same Wi-Fi, then pair them in Xcode under Window › Devices and Simulators.", "Beim ersten Mal: Vision Pro und Mac ins selbe WLAN, dann in Xcode unter Window › Devices and Simulators koppeln."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }

                CheckCard(title: L("Apple Developer Team", "Apple-Entwicklerteam"), state: teamState, detail: teamDetail) {
                    HStack {
                        TextField(L("Team ID", "Team-ID"), text: $model.teamId)
                            .textFieldStyle(.roundedBorder).frame(width: 150)
                            .onChange(of: model.teamId) { model.teamId = model.teamId.uppercased().filter { $0.isLetter || $0.isNumber } }
                        if !model.teamCandidates.isEmpty {
                            Menu(L("Signed In to Xcode", "In Xcode angemeldet")) {
                                ForEach(model.teamCandidates) { team in
                                    Button("\(team.name) – \(team.id)\(team.free ? L(" (free)", " (kostenlos)") : "")") { model.teamId = team.id }
                                }
                            }
                            .fixedSize()
                        }
                    }
                    if model.teamCandidates.isEmpty {
                        Text(L("Xcode does not know a team yet. Sign in with your Apple ID in Xcode under Settings › Accounts, then choose “Check Again” here.", "Xcode kennt noch kein Team. In Xcode unter Einstellungen › Accounts mit der Apple-ID anmelden und hier „Neu prüfen“ wählen."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }

                CheckCard(title: L("Meta Account", "Meta-Konto"), state: accountState, detail: accountDetail) {
                    HStack {
                        switch model.account {
                        case .signedIn:
                            Button(L("Sign Out", "Abmelden")) { model.signOut() }
                        case .checking, .unknown:
                            EmptyView()
                        case .signedOut, .problem:
                            Button(L("Sign In …", "Anmelden …")) { showLogin = true }.disabled(!model.toolPresent)
                            if case .problem = model.account { Button(L("Check Again", "Erneut prüfen")) { model.checkAccount() } }
                        }
                    }
                    if !model.toolPresent, model.account != .signedIn {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("Signing in needs Meta’s tool “ovr-platform-util”. Download it from Meta and put it in your “Downloads” folder – or choose the file.", "Für die Anmeldung wird Metas Werkzeug „ovr-platform-util“ gebraucht. Lade es bei Meta und lege es in den Ordner „Downloads“ – oder wähle die Datei aus."))
                                .font(.callout).foregroundStyle(.secondary)
                            HStack {
                                Link(L("Download Page at Meta", "Download-Seite bei Meta"), destination: URL(string: "https://developers.meta.com/horizon/resources/publish-reference-platform-command-line-utility/")!)
                                Button(L("Choose File …", "Datei auswählen …")) { chooseTool() }
                            }
                        }
                    }
                    Text(L("Special apps such as Doom 3 and Half-Life: Alyx do not need a Meta account.", "Sonderapps wie Doom 3 und Half-Life: Alyx brauchen kein Meta-Konto."))
                        .font(.callout).foregroundStyle(.secondary)
                }

                CheckCard(title: "Toolchain", state: model.toolchainText == nil ? .missing : .ok,
                          detail: model.toolchainText ?? L("Not installed yet. The toolchain translates the games for the Vision Pro.", "Noch nicht installiert. Die Toolchain übersetzt die Spiele für die Vision Pro.")) {
                    Text(L("The toolchain comes with the app and installs itself. You only need the button below to use a different package.",
                           "Die Toolchain kommt mit dem Programm und installiert sich selbst. Den Knopf brauchst du nur für ein anderes Paket."))
                        .font(.callout).foregroundStyle(.secondary)
                    Button(L("Use Another Package …", "Anderes Paket verwenden …")) { chooseToolchain() }
                        .controlSize(.small)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(L("Setup", "Einrichtung"))
        .sheet(isPresented: $showLogin) { LoginSheet().environmentObject(model) }
    }

    private var teamState: CheckState {
        guard model.teamValid else { return .missing }
        return model.team?.free == true ? .warning : .ok
    }

    private var teamDetail: String {
        guard model.teamValid else {
            return L("No team chosen yet. The apps are signed with your Apple developer account; the team ID has ten characters.", "Noch kein Team gewählt. Die Apps werden mit deinem Apple-Entwicklerkonto signiert; die Team-ID hat zehn Zeichen.")
        }
        if let team = model.team {
            return team.free
                ? L("\(team.name) is a free team. The games do not run with it in this version: required entitlements are missing. You need the paid Apple Developer Program membership.", "\(team.name) ist ein kostenloses Team. Damit laufen die Spiele in dieser Fassung nicht: nötige Berechtigungen fehlen. Gebraucht wird die bezahlte Mitgliedschaft im Apple Developer Program.")
                : L("\(team.name) (\(team.id)) signs the apps.", "\(team.name) (\(team.id)) signiert die Apps.")
        }
        return L("Team \(model.teamId) signs the apps.", "Team \(model.teamId) signiert die Apps.")
    }

    private var accountState: CheckState {
        switch model.account {
        case .signedIn: return .ok
        case .checking, .unknown: return .checking
        case .signedOut: return .missing
        case .problem: return .warning
        }
    }

    private var accountDetail: String {
        switch model.account {
        case .signedIn: return L("Signed in. The access key is in this Mac’s keychain and nowhere else.", "Angemeldet. Der Zugangsschlüssel liegt im Schlüsselbund dieses Macs und nirgends sonst.")
        case .checking, .unknown: return L("Checking …", "Wird geprüft …")
        case .signedOut: return L("Not signed in. Once you sign in, the app checks which games you own and downloads only those.", "Nicht angemeldet. Mit der Anmeldung prüft das Programm, welche Spiele du gekauft hast, und lädt nur diese.")
        case .problem(let why): return L("The stored access was not confirmed: \(why)", "Der hinterlegte Zugang wurde nicht bestätigt: \(why)")
        }
    }

    private func chooseTool() {
        let panel = NSOpenPanel()
        panel.message = L("Choose the file “ovr-platform-util”.", "Die Datei „ovr-platform-util“ auswählen.")
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try MetaTool(url: url).verify()
            UserDefaults.standard.set(url.path, forKey: "metaToolPath")
            model.refresh()
        } catch {
            model.notice = "\(error)"
        }
    }

    private func chooseToolchain() {
        let panel = NSOpenPanel()
        panel.message = L("Choose the toolchain package (ending in .tar.gz). The description file next to it is read as well.", "Das Toolchain-Paket auswählen (Endung .tar.gz). Die Beschreibungsdatei daneben wird mitgelesen.")
        panel.allowedContentTypes = [UTType.gzip]
        if panel.runModal() == .OK, let url = panel.url { model.installToolchain(archive: url) }
    }
}

enum CheckState { case ok, warning, missing, checking }

/// Eine Zeile der Einrichtung: Zustand, ein Satz dazu, darunter was sich tun lässt.
struct CheckCard<Actions: View>: View {
    let title: String
    let state: CheckState
    let detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    switch state {
                    case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    case .missing: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                    case .checking: ProgressView().controlSize(.small)
                    }
                }
                .font(.title2).frame(width: 28)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.headline)
                    Text(detail).fixedSize(horizontal: false, vertical: true)
                    actions
                }
                Spacer(minLength: 0)
            }
            .padding(8)
        }
    }
}
