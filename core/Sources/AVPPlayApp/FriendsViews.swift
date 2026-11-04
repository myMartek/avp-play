import SwiftUI
import AVPPlayCore

/// Einstellungen › Freunde: ein- und ausschalten, der eigene Code, Anfragen, die Freunde mit ihrem Stand, und der
/// App-Store-Connect-Schlüssel für das Eintragen ihrer Headsets.
struct FriendsSettings: View {
    @EnvironmentObject var friends: FriendsModel
    @EnvironmentObject var model: AppModel
    @State private var codeDraft = ""
    @State private var nameDraft = ""
    @State private var issuerDraft = ""
    @State private var keyIdDraft = ""

    var body: some View {
        Section(L("Friends (experimental)", "Freunde (experimentell)")) {
            Toggle(L("Use Friends", "Freunde benutzen"), isOn: Binding(get: { friends.enabled }, set: { friends.setEnabled($0) }))
            Text(L("For a round of Walkabout Mini Golf with Spatial Personas, one friend with a paid Apple team builds the game for everybody and hands it over through this project’s server. With this on, this Mac gets a friend code and a pair of keys there; friends see your name, whether you own Walkabout and the identifier and name of your headset, sealed so the server cannot read it. Nothing is sent to anyone who is not your friend. Off: nothing of this exists.",
                   "Für eine Runde Walkabout Mini Golf mit räumlichen Personas baut ein Freund mit bezahltem Apple-Team das Spiel für alle und reicht es über den Server dieses Projekts weiter. Mit diesem Schalter bekommt dieser Mac dort einen Freundescode und ein Schlüsselpaar; Freunde sehen deinen Namen, ob du Walkabout besitzt und Kennung und Namen deines Headsets, versiegelt, sodass der Server es nicht lesen kann. An niemanden außer deinen Freunden geht etwas. Aus: Nichts davon existiert."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if friends.enabled {
                HStack {
                    Text(L("Your name for friends", "Dein Name für Freunde"))
                    TextField("", text: $nameDraft, prompt: Text(friends.name)).frame(maxWidth: 220)
                    Button(L("Save", "Sichern")) { friends.rename(nameDraft); nameDraft = "" }.disabled(nameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack {
                    Text(L("Your friend code", "Dein Freundescode"))
                    Text(friends.me?.code ?? "…").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Button(L("Copy", "Kopieren")) {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(friends.me?.code ?? "", forType: .string)
                    }.disabled(friends.me == nil)
                    Button(L("New code", "Neuer Code")) { friends.newCode() }.disabled(friends.me == nil)
                    Spacer()
                    Label(friends.connected ? L("connected", "verbunden") : L("not connected", "nicht verbunden"), systemImage: friends.connected ? "dot.radiowaves.left.and.right" : "wifi.slash")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    TextField(L("A friend’s code", "Code eines Freunds"), text: $codeDraft).frame(maxWidth: 220)
                    Button(L("Add friend", "Freund hinzufügen")) { friends.addFriend(code: codeDraft); codeDraft = "" }
                        .disabled(codeDraft.trimmingCharacters(in: .whitespaces).count < 8)
                }
                if let me = friends.me {
                    ForEach(me.incoming) { peer in
                        HStack {
                            Label(L("\(peer.name) wants to be your friend", "\(peer.name) möchte dein Freund sein"), systemImage: "person.crop.circle.badge.plus")
                            Spacer()
                            Button(L("Accept", "Annehmen")) { friends.accept(peer) }
                            Button(L("Decline", "Ablehnen")) { friends.remove(peer) }
                        }
                    }
                    ForEach(me.outgoing) { peer in
                        HStack {
                            Label(L("Waiting for \(peer.name)", "Wartet auf \(peer.name)"), systemImage: "hourglass").foregroundStyle(.secondary)
                            Spacer()
                            Button(L("Withdraw", "Zurückziehen")) { friends.remove(peer) }
                        }
                    }
                    if me.friends.isEmpty, me.incoming.isEmpty, me.outgoing.isEmpty {
                        Text(L("No friends yet. Swap codes with a friend; whoever enters the other’s code sends the request.",
                               "Noch keine Freunde. Tauscht eure Codes; wer den Code des anderen eingibt, schickt die Anfrage."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(me.friends) { peer in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(peer.name)
                                Text(FriendsSettings.describe(friends.statuses[peer.id])).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(L("Remove", "Entfernen")) { friends.remove(peer) }
                        }
                    }
                }
                Divider()
                Text(L("App Store Connect key (only for the friend who builds)", "App-Store-Connect-Schlüssel (nur für den Freund, der baut)")).font(.headline)
                Text(L("An ad-hoc build runs only on headsets that are registered in your Apple developer account. With a team key from App Store Connect (Users and Access › Integrations › Team Keys; role Admin or Developer) AVP Play registers your friends’ headsets itself. The key stays in this Mac’s keychain. Without it, register them by hand at developer.apple.com and tick the box below.",
                       "Ein Ad-hoc-Bau läuft nur auf Headsets, die in deinem Apple-Entwicklerkonto eingetragen sind. Mit einem Team-Schlüssel aus App Store Connect (Benutzer und Zugriff › Integrationen › Team-Schlüssel; Rolle Admin oder Entwickler) trägt AVP Play die Headsets deiner Freunde selbst ein. Der Schlüssel bleibt im Schlüsselbund dieses Macs. Ohne ihn trägst du sie unter developer.apple.com von Hand ein und hakst unten an."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if friends.ascKeyPresent {
                    HStack {
                        Label(L("A key is stored.", "Ein Schlüssel ist hinterlegt."), systemImage: "key.fill")
                        Button(L("Forget key", "Schlüssel vergessen")) { friends.forgetASCKey() }
                    }
                } else {
                    HStack {
                        TextField(L("Issuer ID", "Issuer-ID"), text: $issuerDraft).frame(maxWidth: 300)
                        TextField(L("Key ID", "Key-ID"), text: $keyIdDraft).frame(maxWidth: 120)
                        Button(L("Choose .p8 file …", ".p8-Datei wählen …")) {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.data]
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url {
                                friends.saveASCKey(issuerId: issuerDraft, keyId: keyIdDraft, p8: url)
                            }
                        }
                        .disabled(issuerDraft.trimmingCharacters(in: .whitespaces).count < 10 || keyIdDraft.trimmingCharacters(in: .whitespaces).count < 6)
                    }
                }
                Toggle(L("The friends’ headsets are registered by hand", "Die Headsets der Freunde sind von Hand eingetragen"), isOn: $friends.devicesRegisteredByHand)
                if let notice = friends.notice {
                    Text(notice).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
    }

    static func describe(_ status: FriendStatus?) -> String {
        guard let status else { return L("No status yet.", "Noch kein Stand.") }
        var parts: [String] = []
        if let w = status.games["walkabout"] { parts.append(w.owned ? L("owns Walkabout", "besitzt Walkabout") : L("does not own Walkabout", "besitzt Walkabout nicht")) }
        parts.append(status.device.map { L("headset \($0.name) (visionOS \($0.os))", "Headset \($0.name) (visionOS \($0.os))") } ?? L("no headset connected", "kein Headset verbunden"))
        if status.canShare { parts.append(L("can build and share", "kann bauen und teilen")) }
        parts.append(L("AVP Play \(status.app)", "AVP Play \(status.app)"))
        return parts.joined(separator: " · ")
    }
}

/// Auf der Seite des Spiels, bei dem, der baut: die Freunde wählen und den Bau teilen.
struct FriendShareBox: View {
    @EnvironmentObject var friends: FriendsModel
    @EnvironmentObject var model: AppModel
    let game: Game
    @State private var chosen: Set<String> = []
    @State private var note = ""

    var body: some View {
        let candidates = friends.candidates(for: game)
        GroupBox(L("Share with friends (experimental)", "Mit Freunden teilen (experimentell)")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Build Walkabout with SharePlay once for friends who own the game, signed by your team for their headsets. They get the app through the project’s server and copy the game’s files from their own purchase. Everyone then plays under one bundle identifier, which is what SharePlay needs.",
                       "Baue Walkabout mit SharePlay einmal für Freunde, die das Spiel besitzen, von deinem Team für ihre Headsets signiert. Sie bekommen die App über den Server des Projekts und kopieren die Spieldateien aus ihrem eigenen Kauf. Alle spielen dann unter einer Bundle-ID, was SharePlay braucht."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !friends.enabled {
                    Text(L("Turn on Friends under Settings first.", "Schalte erst unter Einstellungen die Freunde ein.")).font(.callout).foregroundStyle(.orange)
                } else if !friends.canShare {
                    Text(L("Sharing needs a paid Apple team and a toolchain that can export (853 or newer).", "Teilen braucht ein bezahltes Apple-Team und eine Toolchain, die exportieren kann (853 oder neuer).")).font(.callout).foregroundStyle(.orange)
                } else if candidates.isEmpty {
                    Text(L("No friend owns Walkabout with a headset connected yet (Settings › Friends shows what each friend reports).",
                           "Noch kein Freund besitzt Walkabout mit verbundenem Headset (Einstellungen › Freunde zeigt, was jeder meldet).")).font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(candidates, id: \.peer.id) { entry in
                        Toggle(isOn: Binding(get: { chosen.contains(entry.peer.id) }, set: { on in if on { chosen.insert(entry.peer.id) } else { chosen.remove(entry.peer.id) } })) {
                            HStack {
                                Text(entry.peer.name)
                                Text(entry.status.device.map { "\($0.name) · \($0.udid)" } ?? "").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                if let r = friends.results[game.id]?[entry.peer.id] {
                                    Text(FriendShareBox.describe(r)).font(.callout).foregroundStyle(r.state == .installed ? .green : .secondary)
                                }
                            }
                        }
                    }
                    TextField(L("A note for them (optional)", "Ein Hinweis für sie (optional)"), text: $note)
                    HStack {
                        Button(L("Build and share", "Bauen und teilen")) {
                            let peers = (friends.me?.friends ?? []).filter { chosen.contains($0.id) }
                            friends.share(game, with: peers, note: note)
                        }
                        .disabled(chosen.isEmpty || friends.working != nil || model.isBusy(game.id))
                        if let working = friends.working {
                            ProgressView().controlSize(.small)
                            Text(working).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if let notice = friends.notice {
                        Text(notice).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }

    static func describe(_ r: FriendResult) -> String {
        switch r.state {
        case .installed: return L("installed", "eingespielt")
        case .declined: return r.detail == "pending" ? L("offered", "angeboten") : L("declined", "abgelehnt")
        case .failed: return L("failed: \(r.detail)", "fehlgeschlagen: \(r.detail)")
        }
    }
}

/// Auf der Seite des Spiels, beim Freund: das Angebot und sein Zustand.
struct FriendOfferBox: View {
    @EnvironmentObject var friends: FriendsModel
    @EnvironmentObject var model: AppModel
    let game: Game

    var body: some View {
        let record = friends.offer(for: game)
        let shared = model.sharedInstall(game)
        GroupBox(L("Shared by a friend", "Von einem Freund geteilt")) {
            VStack(alignment: .leading, spacing: 8) {
                if let shared {
                    Label(L("Installed from \(shared.from)’s build (\(shared.bundleId), \(shared.stamp)). Its files come from your own purchase; “Sync add-on content” copies them again. A new build arrives as a new offer.",
                            "Aus \(shared.from)s Bau eingespielt (\(shared.bundleId), \(shared.stamp)). Die Dateien kommen aus deinem eigenen Kauf; „Zusatzinhalte abgleichen“ kopiert sie erneut. Ein neuer Bau kommt als neues Angebot."),
                          systemImage: "person.2.fill")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    if model.isBusy(game.id) {
                        Label(L("The game’s files are still being copied to the headset (see “Jobs”). Start the game only when that job has finished; before that it opens to a black picture.",
                                "Die Dateien des Spiels werden noch aufs Headset kopiert (siehe „Aufträge“). Starte das Spiel erst, wenn dieser Auftrag fertig ist; vorher bleibt das Bild schwarz."),
                              systemImage: "hourglass")
                            .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    Button(L("Forget the shared build", "Geteilten Bau zurücknehmen")) { model.setSharedInstall(game, bundleId: nil, stamp: nil, from: nil) }
                        .help(L("AVP Play then builds the game itself again; the app on the headset stays until you install over it.", "AVP Play baut das Spiel dann wieder selbst; die App auf dem Headset bleibt, bis du darüber installierst."))
                }
                if let record {
                    let o = record.offer
                    Text(L("\(record.fromName) shares a build of Walkabout with SharePlay for your headset: version \(o.appVersion), toolchain \(o.toolchain), \(ByteCountFormatter.string(fromByteCount: o.size, countStyle: .file)), until \(Date(timeIntervalSince1970: TimeInterval(o.expires)).formatted(date: .abbreviated, time: .omitted)).\(o.note.isEmpty ? "" : " “\(o.note)”")",
                           "\(record.fromName) teilt einen Bau von Walkabout mit SharePlay für dein Headset: Version \(o.appVersion), Toolchain \(o.toolchain), \(ByteCountFormatter.string(fromByteCount: o.size, countStyle: .file)), bis \(Date(timeIntervalSince1970: TimeInterval(o.expires)).formatted(date: .abbreviated, time: .omitted)).\(o.note.isEmpty ? "" : " „\(o.note)“")"))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("Install asks \(AppModel.name(game.recipe.source)) first whether you own the game, then installs the app on your Vision Pro and copies the game’s files from your own purchase. Both of you need a FaceTime call for the Personas; in the game: Settings › Spatial Personas.",
                           "Einspielen fragt zuerst \(AppModel.name(game.recipe.source)), ob dir das Spiel gehört, installiert dann die App auf deiner Vision Pro und kopiert die Spieldateien aus deinem eigenen Kauf. Für die Personas braucht ihr einen FaceTime-Anruf; im Spiel: Einstellungen › Räumliche Personas."))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(record.installed ? L("Install again", "Noch einmal einspielen") : L("Install", "Einspielen")) { friends.install(game) }
                            .disabled(friends.working != nil || model.isBusy(game.id) || model.device == nil)
                        Button(L("Decline", "Ablehnen")) { friends.decline(game) }.disabled(friends.working != nil)
                        if let working = friends.working {
                            ProgressView().controlSize(.small)
                            Text(working).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if model.device == nil {
                        Text(L("Connect the Vision Pro first.", "Verbinde zuerst die Vision Pro.")).font(.callout).foregroundStyle(.orange)
                    }
                    if let notice = friends.notice {
                        Text(notice).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }
}
