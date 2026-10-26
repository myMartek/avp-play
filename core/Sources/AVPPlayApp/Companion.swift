import AVPPlayCore
import SwiftUI

// AVP Play Remote als eigene Kachel vor den Spielen, mit einer Seite wie die eines Spiels – und als Abschnitt auf
// der Seite „Fernbedienung“. Installiert wird aus dem Quellcode auf GitHub (siehe `CompanionApp`).

extension AppModel {
    var companionBundleId: String { CompanionApp.bundleId(prefix: bundlePrefix) }

    var companionState: CompanionApp.State {
        CompanionApp.state(apps: installedApps, bundleId: companionBundleId, latest: companionRelease)
    }

    var companionInstalled: Bool {
        switch companionState {
        case .current, .updatable: return true
        case .unknown, .notInstalled: return false
        }
    }

    /// Steht die Kachel in der Übersicht? Ja, solange die Suche zu ihr passt und kein Filter sie ausschließt – sie ist
    /// geprüft, aber kein Spiel: Filter nach Besitz, Store, Favoriten oder Spielart blenden sie aus.
    var companionShown: Bool {
        let words = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = words.isEmpty || CompanionApp.title.lowercased().contains(words) || L("remote control", "fernbedienung").contains(words)
        let excluded = (filterCommunity && !filterVerified) || (filterInstalled && !companionInstalled) || filterDownloaded
            || filterFavourites || filterFavouritesMissing || filterMixedReality || filterHandTracking || filterOwned
            || horizonPlusWanted || filterMeta || filterSteam || !customFilterModes.isEmpty
        return matches && !excluded
    }

    /// Fragt GitHub nach der neuesten Fassung – höchstens einmal in der Stunde, außer `force`.
    func loadCompanionRelease(force: Bool = false) {
        if !force, let checked = companionChecked, Date().timeIntervalSince(checked) < 3600 { return }
        companionChecked = Date()
        Task {
            do {
                companionRelease = try await CompanionApp.latestRelease()
                companionProblem = nil
            } catch {
                companionProblem = (error as? CompanionError ?? .noRelease(error.localizedDescription)).description
            }
        }
    }

    var companionBlocker: String? {
        if xcodeProblem != nil { return L("Xcode is missing. “Setup” tells you what to do.", "Xcode fehlt. Unter „Einrichtung“ steht, was zu tun ist.") }
        if !teamValid { return L("The Apple team ID is still missing (see “Setup”).", "Die Apple-Team-ID fehlt noch (siehe „Einrichtung“).") }
        if device == nil { return deviceProblem ?? L("The Vision Pro is not reachable.", "Die Vision Pro ist nicht erreichbar.") }
        if isBusy(CompanionApp.recipeId) { return L("A job for AVP Play Remote is already running.", "Für AVP Play Remote läuft schon ein Auftrag.") }
        guard companionRelease != nil else {
            return companionProblem ?? L("Looking for the newest version on GitHub …", "Die neueste Fassung wird auf GitHub gesucht …")
        }
        // Ein kostenloses Konto: Die Fernbedienung zählt zu den Apps, die es gleichzeitig auf dem Gerät haben darf.
        if let mine = freeTeamApps, !mine.contains(where: { $0.bundleIdentifier == companionBundleId }),
           mine.count >= AppleMessages.freeAppsPerDevice {
            let names = mine.map(\.name).sorted().joined(separator: ", ")
            return L("A free Apple account may have only \(AppleMessages.freeAppsPerDevice) apps on the Vision Pro at a time. Already there: \(names). Remove one on the headset first.",
                     "Ein kostenloses Apple-Konto darf nur \(AppleMessages.freeAppsPerDevice) Apps gleichzeitig auf der Vision Pro haben. Schon dort: \(names). Entferne zuerst eine auf dem Headset.")
        }
        return nil
    }

    var companionActionTitle: String {
        switch companionState {
        case .updatable: return L("Update", "Aktualisieren")
        case .current: return L("Install Again", "Erneut installieren")
        case .notInstalled, .unknown: return L("Install", "Installieren")
        }
    }

    var companionStateText: String {
        switch companionState {
        case .unknown: return L("The Vision Pro is not reachable right now.", "Die Vision Pro ist gerade nicht erreichbar.")
        case .notInstalled: return L("Not installed yet.", "Noch nicht installiert.")
        case .current(let version): return L("Installed, version \(version) – up to date.", "Installiert, Fassung \(version) – auf dem neuesten Stand.")
        case .updatable(let installed, let latest):
            return L("Installed, version \(installed). Version \(latest) is out – “Update” builds and installs it; pairings are kept.",
                     "Installiert, Fassung \(installed). Fassung \(latest) ist erschienen – „Aktualisieren“ baut und installiert sie; Kopplungen bleiben.")
        }
    }

    /// Bis wann sich die installierte Fernbedienung öffnen lässt – bei einem kostenlosen Team immer, sonst kurz vor Ablauf.
    var companionSigningText: (text: String, urgent: Bool)? {
        guard companionInstalled, let record = CompanionApp.signing(), record.bundleId == companionBundleId,
              let expires = record.expires else { return nil }
        let now = Date()
        let urgent = record.remindFrom.map { now >= $0 } ?? false
        guard record.free || urgent else { return nil }
        let day = DateFormatter.localizedString(from: expires, dateStyle: .medium, timeStyle: .short)
        if now >= expires {
            return (L("The signature ran out on \(day): the app no longer opens. “Install Again” signs it again.",
                      "Die Signatur ist am \(day) abgelaufen: Die App lässt sich nicht mehr öffnen. „Erneut installieren“ signiert sie neu."), true)
        }
        return (L("Opens until \(day). Install it again before then to renew it.",
                  "Lässt sich bis \(day) öffnen. Installiere sie vorher erneut, um sie zu erneuern."), urgent)
    }

    func installCompanion() {
        guard companionBlocker == nil, let release = companionRelease else { return }
        var request = InstallRequest(toolchain: "")
        request.team = teamId
        request.device = device?.udid
        request.bundleId = companionBundleId
        request.live = true
        do {
            let job = try paths.jobs.enqueue(Job(recipe: CompanionApp.recipe(release: release), request: request,
                                                 steps: [.fetch, .build], toolchainCommit: ""))
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

/// Das Bild der Kachel: keine Datei, eine Fläche mit dem Zeichen der Vision Pro.
struct CompanionCover: View {
    var body: some View {
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                LinearGradient(colors: [Color(red: 0.16, green: 0.36, blue: 0.95), Color(red: 0.42, green: 0.18, blue: 0.78)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "visionpro").font(.system(size: 54, weight: .light))
                            Text(CompanionApp.title).font(.title3.bold())
                        }
                        .foregroundStyle(.white)
                    }
            }
            .clipped()
    }
}

struct CompanionBadges: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let busy = model.isBusy(CompanionApp.recipeId)
        let (text, color, symbol): (String, Color, String) = {
            if busy { return (L("Installing", "Wird installiert"), .blue, "arrow.triangle.2.circlepath") }
            switch model.companionState {
            case .current: return (L("On the Vision Pro", "Auf der Vision Pro"), .green, "checkmark.circle.fill")
            case .updatable: return (L("Update available", "Aktualisierung möglich"), .orange, "arrow.up.circle.fill")
            case .notInstalled: return (L("Not installed", "Nicht installiert"), .secondary, "circle.dashed")
            case .unknown: return (L("Device not reachable", "Gerät nicht erreichbar"), .secondary, "wifi.slash")
            }
        }()
        Label(text, systemImage: symbol).font(.caption.weight(.medium)).foregroundStyle(color)
    }
}

struct CompanionTrust: View {
    var body: some View {
        TrustCapsule(text: L("Verified", "Geprüft"), symbol: "checkmark.seal.fill", color: .blue,
                     help: L("Made by the project for AVP Play and tested on an Apple Vision Pro.",
                             "Vom Projekt für AVP Play gemacht und auf einer Apple Vision Pro geprüft."))
    }
}

struct CompanionCard: View {
    @EnvironmentObject var model: AppModel
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CompanionCover()
                .overlay(alignment: .topTrailing) { CompanionTrust().padding(8) }
            VStack(alignment: .leading, spacing: 5) {
                Text(CompanionApp.title).font(.headline).lineLimit(1)
                CompanionBadges()
                Label(L("Remote control for this Mac", "Fernbedienung für diesen Mac"), systemImage: "appletvremote.gen4")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(hovering ? 0.22 : 0.1), radius: hovering ? 10 : 4, y: 2)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .task { model.loadCompanionRelease() }
    }
}

/// Der Knopf und was ihm im Weg steht – auf der Seite der App und auf der Seite „Fernbedienung“.
struct CompanionInstallButton: View {
    @EnvironmentObject var model: AppModel
    var trailing = true

    var body: some View {
        let blocked = model.companionBlocker
        VStack(alignment: trailing ? .trailing : .leading, spacing: 6) {
            Button(action: { model.installCompanion() }) {
                Text(model.companionActionTitle).frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(blocked != nil)
            if let why = blocked {
                Text(why).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(trailing ? .trailing : .leading)
                    .frame(maxWidth: 280, alignment: trailing ? .trailing : .leading)
            } else if model.usesFreeTeam {
                Label(model.freeAccountLine, systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.callout).foregroundStyle(.orange)
                    .multilineTextAlignment(trailing ? .trailing : .leading)
                    .frame(maxWidth: 280, alignment: trailing ? .trailing : .leading)
            }
        }
    }
}

struct CompanionDetail: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                CompanionCover()
                    .frame(maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(CompanionApp.title).font(.largeTitle.bold())
                        if let release = model.companionRelease {
                            Text(L("Version \(release.version) on GitHub", "Fassung \(release.version) auf GitHub")).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            CompanionBadges()
                            CompanionTrust()
                        }
                    }
                    Spacer()
                    CompanionInstallButton()
                }

                Text(L("The remote control for AVP Play: on the Vision Pro you see your games and jobs and install, update or download games while you wear the headset – this Mac does the work as usual. It is not in the App Store: AVP Play downloads its source code from GitHub, builds it with your Apple team and installs it like a game.",
                       "Die Fernbedienung für AVP Play: Auf der Vision Pro siehst du deine Spiele und Aufträge und kannst Spiele installieren, aktualisieren oder laden, während du das Headset trägst – die Arbeit macht wie immer dieser Mac. Sie steht nicht im App Store: AVP Play lädt ihren Quellcode von GitHub, baut ihn mit deinem Apple-Team und installiert sie wie ein Spiel."))
                    .fixedSize(horizontal: false, vertical: true)

                GroupBox(L("On the Vision Pro", "Auf der Vision Pro")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.companionStateText)
                        if let signing = model.companionSigningText {
                            Text(signing.text).foregroundStyle(signing.urgent ? .orange : .secondary)
                        }
                        Text(L("App identifier: \(model.companionBundleId)", "App-Kennung: \(model.companionBundleId)"))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox(L("Getting Started", "So geht es los")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("1. Install the app here.", "1. Installiere die App hier."))
                        Text(L("2. Switch on the remote control under “Remote Control” in the sidebar.",
                               "2. Schalte die Fernbedienung unter „Fernbedienung“ in der Seitenleiste ein."))
                        Text(L("3. Open AVP Play Remote on the headset, allow it to find devices in the local network and enter the code shown under “Remote Control”.",
                               "3. Öffne AVP Play Remote auf dem Headset, erlaube ihr, Geräte im lokalen Netz zu finden, und gib den Code ein, der unter „Fernbedienung“ steht."))
                        HStack {
                            Button(L("Open “Remote Control”", "„Fernbedienung“ öffnen")) { model.section = .remote }
                            Link(L("Source Code on GitHub", "Quellcode auf GitHub"), destination: CompanionApp.page)
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
                if let problem = model.companionProblem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(CompanionApp.title)
        .task { model.loadCompanionRelease() }
    }
}

/// Auf der Seite „Fernbedienung“: die App für die Vision Pro, gleich hier zu installieren.
struct CompanionSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section(L("The app for the Vision Pro", "Die App für die Vision Pro")) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(CompanionApp.title).font(.headline)
                        CompanionBadges()
                    }
                    Text(model.companionStateText).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let signing = model.companionSigningText {
                        Text(signing.text).font(.callout).foregroundStyle(signing.urgent ? .orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(L("AVP Play downloads its source code from GitHub, builds it with your Apple team and installs it on the Vision Pro.",
                           "AVP Play lädt ihren Quellcode von GitHub, baut ihn mit deinem Apple-Team und installiert sie auf der Vision Pro."))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                CompanionInstallButton()
            }
        }
        .task { model.loadCompanionRelease() }
    }
}
