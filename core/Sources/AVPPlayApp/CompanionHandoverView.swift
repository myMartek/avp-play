import AppKit
import AVPPlayCore
import SwiftUI

/// Die Übergabe an AVP Play Remote: was die Remote braucht, um Spiele allein auf der Brille zu installieren
/// (`CompanionHandover`). Sie ist aus, bis der Nutzer sie einschaltet; die Meta-Anmeldung geht nur mit einem
/// eigenen zweiten Schalter mit.
extension AppModel {
    static let handoverKey = "remoteHandover"
    static let handoverTokenKey = "remoteHandoverToken"

    var handoverEnabled: Bool { UserDefaults.standard.bool(forKey: AppModel.handoverKey) }

    /// Was übergeben wird, wie der Nutzer es eingestellt hat; `nil`, solange die Übergabe aus ist.
    func handoverPlan() -> CompanionHandover.Plan? {
        guard handoverEnabled else { return nil }
        return CompanionHandover.Plan(bundlePrefix: bundlePrefix,
                                      withToken: UserDefaults.standard.bool(forKey: AppModel.handoverTokenKey),
                                      recipes: paths.recipes, library: MetaLibraryCache(store: paths.store).url,
                                      toolchain: paths.packager.installed().first?.root)
    }

    /// Warum sich gerade nichts übergeben lässt.
    var handoverBlocker: String? {
        if !handoverEnabled { return L("The handover is switched off.", "Die Übergabe ist ausgeschaltet.") }
        if device == nil { return L("No Vision Pro is connected.", "Keine Vision Pro ist verbunden.") }
        if !companionInstalled { return L("AVP Play Remote is not installed on the Vision Pro.", "AVP Play Remote ist nicht auf der Vision Pro installiert.") }
        if isBusy(CompanionApp.recipeId) { return L("A job for AVP Play Remote is already running.", "Für AVP Play Remote läuft schon ein Auftrag.") }
        if let reason = companionRebuildReason { return reason }
        if companionRelease == nil { return companionProblem ?? L("Looking for the newest version on GitHub …", "Die neueste Fassung wird auf GitHub gesucht …") }
        return nil
    }

    /// Übergibt jetzt, ohne die Remote neu zu installieren: ein Auftrag mit dem einen Schritt.
    func handOverToCompanion() {
        guard handoverBlocker == nil, let release = companionRelease, let plan = handoverPlan() else { return }
        var request = InstallRequest(toolchain: "")
        request.team = teamId
        request.device = device?.udid
        request.bundleId = companionBundleId
        request.handover = plan
        do {
            let job = try paths.jobs.enqueue(Job(recipe: CompanionApp.recipe(release: release), request: request, steps: [.stage], toolchainCommit: ""))
            queued.append(job.id)
            reloadJobs()
            selectedJob = job.id
            section = .jobs
            pump()
        } catch {
            notice = "\(error)"
        }
    }
}

/// Auf der Seite von AVP Play Remote: die Übergabe einschalten und hinterlegen, was sie braucht.
struct CompanionHandoverBox: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(AppModel.handoverKey) private var enabled = false
    @AppStorage(AppModel.handoverTokenKey) private var withToken = false
    @State private var storedKeyId: String?
    @State private var loaded = false
    @State private var keyId = ""
    @State private var issuerId = ""
    @State private var problem: String?

    private var freeTeam: Bool { model.team?.free == true }

    var body: some View {
        GroupBox(L("Installing Games Without a Mac (Experimental)", "Spiele ohne Mac installieren (experimentell)")) {
            VStack(alignment: .leading, spacing: 10) {
                Label(L("Experimental: this is new. Not every game has been tried this way, and something may not work. Installing from this Mac stays the tested way.",
                        "Experimentell: Das ist neu. Nicht jedes Spiel wurde so ausprobiert, und es kann etwas nicht klappen. Die Installation von diesem Mac bleibt der erprobte Weg."),
                      systemImage: "flask")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Text(L("AVP Play Remote can install games on the Vision Pro by itself: it downloads from Meta, builds, signs and installs there, without this Mac being on. For that, this Mac hands over what only it can provide. This needs a paid Apple Developer Program membership.",
                       "AVP Play Remote kann Spiele allein auf der Vision Pro installieren: Sie lädt bei Meta, baut, signiert und installiert dort, ohne dass dieser Mac an ist. Dafür übergibt dieser Mac ihr, was nur er bereitstellen kann. Das braucht eine bezahlte Mitgliedschaft im Apple Developer Program."))
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(L("Hand over what AVP Play Remote needs for that", "AVP Play Remote mitgeben, was sie dafür braucht"), isOn: $enabled)
                    .disabled(freeTeam)
                if freeTeam {
                    Text(L("A free Apple team cannot do this.", "Mit einem kostenlosen Apple-Team geht das nicht.")).font(.callout).foregroundStyle(.orange)
                }
                if enabled, !freeTeam {
                    Text(L("Handed over when AVP Play Remote is installed, and with the button below: the app identifier prefix, your Meta library, the game recipes and the runtime of the toolchain – and what you set up here. The pairing with the headset is made in AVP Play Remote itself, under “Setup”.",
                           "Übergeben wird, wenn AVP Play Remote installiert wird, und mit dem Knopf unten: der Präfix für App-Kennungen, deine Meta-Bibliothek, die Rezepte der Spiele und die Laufzeit der Toolchain – und was du hier hinterlegst. Die Kopplung mit der Brille entsteht in AVP Play Remote selbst, unter „Einrichtung“."))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    appleKey
                    Divider()
                    token
                    Divider()
                    HStack {
                        Button(L("Hand Over Now", "Jetzt übergeben")) { model.handOverToCompanion() }
                            .disabled(model.handoverBlocker != nil)
                        if let blocker = model.handoverBlocker {
                            Text(blocker).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .task { await load() }
    }

    private var appleKey: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Apple team key", "Team-Schlüssel von Apple")).font(.headline)
            if let storedKeyId {
                Text(L("Key \(storedKeyId) is in this Mac's keychain.", "Schlüssel \(storedKeyId) liegt im Schlüsselbund dieses Macs."))
                Button(L("Remove the Key", "Schlüssel entfernen"), role: .destructive) { store { try $0.setAppleKey(nil) } }
            } else {
                Text(L("With a team key the headset gets what a signature needs from Apple itself: a certificate, an app identifier and a profile per game. Create one in App Store Connect under Users and Access › Integrations › App Store Connect API › Team Keys, with the access “App Manager”, and download the key file (AuthKey_….p8); Apple offers it only once.",
                       "Mit einem Team-Schlüssel holt die Brille bei Apple selbst, was eine Signatur braucht: ein Zertifikat, eine App-Kennung und ein Profil je Spiel. Lege ihn in App Store Connect unter Benutzer und Zugriff › Integrationen › App Store Connect API › Team-Schlüssel an, mit dem Zugriff „App Manager“, und lade die Schlüsseldatei (AuthKey_….p8); Apple bietet sie nur einmal an."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Link(L("Open App Store Connect", "App Store Connect öffnen"), destination: URL(string: "https://appstoreconnect.apple.com/access/integrations/api")!)
                TextField(L("Key ID (10 characters, in the key's row)", "Schlüssel-ID (10 Zeichen, in der Zeile des Schlüssels)"), text: $keyId)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 420)
                TextField(L("Issuer ID (above the list of keys)", "Issuer-ID (über der Liste der Schlüssel)"), text: $issuerId)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 420)
                Button(L("Choose the Key File (.p8) and Save …", "Schlüsseldatei (.p8) wählen und sichern …")) { chooseKey() }
                    .disabled(keyId.trimmingCharacters(in: .whitespaces).isEmpty || issuerId.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(L("The key goes into this Mac's keychain and, with the handover, to AVP Play Remote on your headset. From there it is sent to Apple only. To end its use for good, revoke it in App Store Connect.",
                   "Der Schlüssel kommt in den Schlüsselbund dieses Macs und mit der Übergabe zu AVP Play Remote auf deiner Brille. Von dort geht er nur an Apple. Um ihn ganz außer Dienst zu nehmen, widerrufe ihn in App Store Connect."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var token: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(L("Also hand over the Meta sign-in", "Auch die Meta-Anmeldung mitgeben"), isOn: $withToken)
            Text(L("Without it, AVP Play Remote can only rebuild games that are installed. With it, your Meta sign-in leaves this Mac's keychain: it is copied to AVP Play Remote on your headset, kept in that app's keychain and sent from there to Meta only – to check ownership and to download your games. Everywhere else AVP Play keeps the sign-in on this Mac.",
                   "Ohne sie kann AVP Play Remote nur installierte Spiele neu bauen. Mit ihr verlässt deine Meta-Anmeldung den Schlüsselbund dieses Macs: Sie wird zu AVP Play Remote auf deiner Brille kopiert, dort im Schlüsselbund der App gehalten und von dort nur an Meta geschickt – um den Besitz zu prüfen und deine Spiele zu laden. Überall sonst behält AVP Play die Anmeldung auf diesem Mac."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Schlüsselbund

    /// Der Schlüsselbund wird über `security` gefragt; das gehört nicht auf den Hauptfaden.
    private func load() async {
        storedKeyId = await Task.detached { HandoverSecrets().appleKey()?.keyId }.value
        loaded = true
    }

    private func store(_ change: @escaping @Sendable (HandoverSecrets) throws -> Void) {
        problem = nil
        Task {
            let failure = await Task.detached { () -> String? in
                do { try change(HandoverSecrets()); return nil } catch { return "\(error)" }
            }.value
            problem = failure
            await load()
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = L("Choose the key file from App Store Connect (AuthKey_….p8).", "Wähle die Schlüsseldatei aus App Store Connect (AuthKey_….p8).")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let size = ContentStore.fileSize(url), size < 16 * 1024, let pem = try? String(contentsOf: url, encoding: .utf8) else {
            problem = HandoverSecrets.SecretError.badAppleKey.description
            return
        }
        let key = HandoverSecrets.AppleKey(keyId: keyId.trimmingCharacters(in: .whitespaces).uppercased(),
                                           issuerId: issuerId.trimmingCharacters(in: .whitespaces).lowercased(), pem: pem)
        store { try $0.setAppleKey(key) }
    }
}
