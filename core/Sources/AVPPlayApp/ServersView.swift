import AVPPlayCore
import SwiftUI

/// Die eigenen Server zu einem Spiel, das so eine Liste versteht: Adressen, Namen und – wer mag – das
/// Admin-Passwort. Die Passwörter liegen im Schlüsselbund dieses Macs; aufs Gerät kommen sie nur als Teil der
/// kleinen Liste im Datenbereich des Spiels, weil das Spiel sie dem Server schicken muss.
struct ServerListBox: View {
    @EnvironmentObject var model: AppModel
    let game: Game
    @State private var servers: [GameServer] = []
    @State private var withAdmin: Set<String> = []
    /// Die fest eingebauten Server des Spiels: nicht zu entfernen, aber mit eigenem Admin-Passwort zu versehen.
    @State private var fixed: Set<String> = []
    /// Der Server, dessen Admin-Passwort gerade eingegeben wird, und die Eingabe dazu.
    @State private var editing: String?
    @State private var editPassword = ""
    @State private var name = ""
    @State private var address = ""
    @State private var password = ""
    @State private var note: String?
    @State private var problem = false
    @State private var busy = false

    private let store = GameServerStore()

    var body: some View {
        GroupBox(L("Your Own Servers", "Eigene Server")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("These servers appear in the game’s server list (Multiplayer › Internet games); you can add your own. With an admin password, the quick menu in the game (press the left stick) controls that server the way it controls a game you host: bots, maps, restart and the on/off settings. The password is kept in this Mac's keychain and copied to the game's data on the Vision Pro, nowhere else.",
                       "Diese Server stehen im Spiel in der Serverliste (Multiplayer › Internet games); du kannst eigene ergänzen. Mit einem Admin-Passwort steuert das Schnellmenü im Spiel (linken Stick drücken) diesen Server so wie ein Spiel, das du selbst eröffnest: Bots, Karten, Neustart und die Ein/Aus-Einstellungen. Das Passwort liegt im Schlüsselbund dieses Macs und wird zu den Daten des Spiels auf der Vision Pro kopiert, sonst nirgendwohin."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if servers.isEmpty {
                    Text(L("No servers yet.", "Noch keine Server.")).font(.callout)
                }
                ForEach(servers) { server in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(server.name)
                                if fixed.contains(server.address) {
                                    Text(L("built in", "eingebaut")).font(.caption).foregroundStyle(.secondary)
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(.quaternary, in: Capsule())
                                        .help(L("Every player has this server in the list. You can add your admin password for it.",
                                                "Diesen Server hat jeder Spieler in der Liste. Du kannst dein Admin-Passwort dazu hinterlegen."))
                                }
                            }
                            Text(server.address).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        if editing == server.address {
                            SecureField(L("Admin password", "Admin-Passwort"), text: $editPassword)
                                .textFieldStyle(.roundedBorder).frame(width: 170)
                                .onSubmit { setPassword(server) }
                            Button(L("Save", "Sichern")) { setPassword(server) }.controlSize(.small).disabled(busy || editPassword.isEmpty)
                            Button(L("Cancel", "Abbrechen")) { editing = nil; editPassword = "" }.controlSize(.small)
                        } else {
                            let has = withAdmin.contains(server.address)
                            Label(has ? L("Admin access", "Admin-Zugang") : L("No admin access", "Kein Admin-Zugang"),
                                  systemImage: has ? "key.fill" : "key.slash")
                                .font(.callout).foregroundStyle(has ? .primary : .secondary)
                            Button(has ? L("Change Password …", "Passwort ändern …") : L("Add Admin Password …", "Admin-Passwort ergänzen …")) {
                                editing = server.address
                                editPassword = ""
                            }
                            .controlSize(.small).disabled(busy)
                            if has { Button(L("Forget Password", "Passwort vergessen")) { forgetPassword(server) }.controlSize(.small).disabled(busy) }
                            if !fixed.contains(server.address) {
                                Button(L("Remove", "Entfernen")) { remove(server) }.controlSize(.small).disabled(busy)
                            }
                        }
                    }
                }
                Divider()
                HStack {
                    TextField(L("Name", "Name"), text: $name).textFieldStyle(.roundedBorder).frame(minWidth: 110)
                    TextField(L("Address, e.g. 203.0.113.7:27015", "Adresse, z. B. 203.0.113.7:27015"), text: $address)
                        .textFieldStyle(.roundedBorder).frame(minWidth: 190)
                    SecureField(L("Admin password (optional)", "Admin-Passwort (optional)"), text: $password)
                        .textFieldStyle(.roundedBorder).frame(minWidth: 150)
                    Button(L("Add", "Hinzufügen")) { add() }
                        .disabled(busy || address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack(alignment: .firstTextBaseline) {
                    if busy { ProgressView().controlSize(.small) }
                    Text(note ?? pushHint).font(.callout).foregroundStyle(problem ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L("Copy to Vision Pro", "Auf die Vision Pro übertragen")) { push() }
                        .disabled(busy || !game.installed || model.device == nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
        .task(id: game.id) { reload() }
    }

    private var pushHint: String {
        if !game.installed { return L("The list goes along when the game is installed.", "Die Liste kommt mit, wenn das Spiel installiert wird.") }
        if model.device == nil { return L("The Vision Pro is not reachable right now.", "Die Vision Pro ist gerade nicht erreichbar.") }
        return L("Changes reach the game with “Copy to Vision Pro” or the next install, and apply from the next start of the game.",
                 "Änderungen kommen mit „Auf die Vision Pro übertragen“ oder der nächsten Installation zum Spiel und gelten ab dessen nächstem Start.")
    }

    private func reload() {
        let recipe = game.recipe, store = store
        Task.detached {
            let list = store.all(recipe: recipe)
            let admin = Set(list.map(\.address).filter { store.hasAdminPassword(address: $0, recipe: recipe) })
            let builtin = Set(GameServerStore.builtin(recipe: recipe).map(\.address))
            await MainActor.run {
                servers = list
                withAdmin = admin
                fixed = builtin
            }
        }
    }

    private func add() {
        let recipe = game.recipe, store = store
        let (n, a, p) = (name, address, password)
        busy = true
        Task.detached {
            var text: String?
            do {
                let server = try store.add(address: a, name: n, recipe: recipe)
                if !p.isEmpty { try store.setAdminPassword(p, address: server.address, recipe: recipe) }
            } catch { text = "\(error)" }
            let failed = text
            await MainActor.run {
                busy = false
                problem = failed != nil
                note = failed
                if failed == nil { name = ""; address = ""; password = "" }
                reload()
            }
        }
    }

    private func remove(_ server: GameServer) {
        do {
            try store.remove(address: server.address, recipe: game.recipe)
            note = nil
            problem = false
        } catch {
            note = "\(error)"
            problem = true
        }
        reload()
    }

    /// Hinterlegt oder ersetzt das Admin-Passwort eines Servers (im Schlüsselbund).
    private func setPassword(_ server: GameServer) {
        let recipe = game.recipe, store = store, secret = editPassword
        guard !secret.isEmpty else { return }
        busy = true
        Task.detached {
            var text: String?
            do { try store.setAdminPassword(secret, address: server.address, recipe: recipe) } catch { text = "\(error)" }
            let failed = text
            await MainActor.run {
                busy = false
                problem = failed != nil
                note = failed
                if failed == nil { editing = nil; editPassword = "" }
                reload()
            }
        }
    }

    private func forgetPassword(_ server: GameServer) {
        try? store.setAdminPassword(nil, address: server.address, recipe: game.recipe)
        note = nil
        problem = false
        reload()
    }

    private func push() {
        guard let device = model.device else { return }
        let recipe = game.recipe, store = store, bundle = model.bundleId(for: game)
        busy = true
        Task.detached {
            let text: String
            var failed = false
            do {
                text = try store.push(recipe: recipe, device: device, bundle: bundle)
                    ? L("Copied. The list applies from the next start of the game.", "Übertragen. Die Liste gilt ab dem nächsten Start des Spiels.")
                    : L("Nothing to copy: the list is empty and there is none on the Vision Pro.", "Nichts zu übertragen: Die Liste ist leer, und auf der Vision Pro liegt keine.")
            } catch {
                text = Redaction.redact("\(error)")
                failed = true
            }
            let wrong = failed
            await MainActor.run {
                busy = false
                note = text
                problem = wrong
            }
        }
    }
}
