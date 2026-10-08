import AppKit
import AVPPlayCore
import SwiftUI

enum UpdateState: Equatable {
    case idle, checking, upToDate, downloading, installing
    case failed(String)
}

/// Neue Fassungen: einmal am Tag nachsehen, auf Wunsch einspielen. Geprüft und eingespielt wird in der
/// Bibliothek (`Updater`); hier steht nur, wann gefragt wird und was die Oberfläche zeigt.
extension AppModel {
    var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// Woher die Liste kommt. `AVPPLAY_UPDATE_FEED` (Pfad oder Adresse) ersetzt sie zum Testen; an der Prüfung
    /// der Signatur ändert das nichts.
    private var updateFeed: URL {
        guard let custom = ProcessInfo.processInfo.environment["AVPPLAY_UPDATE_FEED"] else { return Updater.defaultFeed }
        return custom.contains("://") ? (URL(string: custom) ?? Updater.defaultFeed) : URL(fileURLWithPath: custom)
    }

    /// Kann sich dieses Programm selbst ersetzen? Nur ein mit Entwickler-Identität signiertes Programmpaket an
    /// einem beschreibbaren Ort. Sonst bleibt der Verweis auf die Seite der Veröffentlichung.
    var canSelfUpdate: Bool {
        Bundle.main.bundleIdentifier != nil && ownTeam != nil && Updater.canReplace(app: Bundle.main.bundleURL)
    }

    /// Sieht nach, ob es eine neuere Fassung gibt. Von selbst höchstens alle zwanzig Stunden und nur, wenn es
    /// in den Einstellungen nicht abgestellt ist; `manual` fragt sofort und sagt auch „alles aktuell“.
    func checkForUpdate(manual: Bool) async {
        if !manual {
            guard autoUpdateCheck, Bundle.main.bundleIdentifier != nil, Snapshot.directory == nil,
                  Date().timeIntervalSince1970 - lastUpdateCheck > 20 * 3600 else { return }
        }
        guard updateState != .checking, updateState != .downloading, updateState != .installing else { return }
        updateState = .checking
        do {
            let release = try await Updater.latest(feed: updateFeed)
            lastUpdateCheck = Date().timeIntervalSince1970
            if Updater.isNewer(release.version, than: appVersion) {
                update = release
                updateState = .idle
            } else {
                update = nil
                updateState = manual ? .upToDate : .idle
            }
        } catch {
            // Von selbst gefragt und nichts erreicht: kein Grund, jemanden damit zu behelligen.
            updateState = manual ? .failed("\(error)") : .idle
        }
    }

    /// Lädt die neue Fassung, prüft sie, ersetzt das Programm und startet es neu.
    func installUpdate(relaunch: Bool = true) async {
        guard let release = update else { return }
        guard runningJob == nil, queued.isEmpty else {
            notice = L("A job is still running. Install the update when it has finished.",
                       "Es läuft noch ein Auftrag. Spiele die neue Fassung ein, wenn er fertig ist.")
            return
        }
        guard canSelfUpdate, let team = ownTeam, let bundleId = Bundle.main.bundleIdentifier else {
            NSWorkspace.shared.open(release.page)
            return
        }
        let app = Bundle.main.bundleURL
        let running = appVersion
        updateState = .downloading
        do {
            let image = try await Updater.download(release, to: DataLocation.base.appendingPathComponent("updates", isDirectory: true))
            updateState = .installing
            try await Task.detached {
                defer { try? FileManager.default.removeItem(at: image) }
                try Updater.install(image: image, replacing: app, team: team, bundleId: bundleId, running: running)
            }.value
        } catch {
            updateState = .failed("\(error)")
            return
        }
        update = nil
        updateState = .idle
        guard relaunch else { return }
        // Neu starten: ein kleiner Wächter wartet, bis dieses Programm beendet ist, und öffnet dann das neue.
        let watcher = Process()
        watcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        watcher.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                             app.path, String(ProcessInfo.processInfo.processIdentifier)]
        try? watcher.run()
        NSApp.terminate(nil)
    }
}

/// Der Hinweis auf eine neue Fassung, unten in der Seitenleiste.
struct UpdateCard: View {
    @EnvironmentObject var model: AppModel
    let release: AppRelease

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Version \(release.version) is available", "Version \(release.version) ist da"))
                .font(.callout.weight(.semibold)).lineLimit(2)
            switch model.updateState {
            case .downloading:
                Label(L("Downloading …", "Wird geladen …"), systemImage: "arrow.down.circle").font(.caption).foregroundStyle(.secondary)
            case .installing:
                Label(L("Checking and installing …", "Wird geprüft und eingespielt …"), systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary)
            default:
                if case .failed(let why) = model.updateState {
                    Text(why).font(.caption).foregroundStyle(.orange).lineLimit(5).help(why)
                }
                Button(model.canSelfUpdate ? L("Install and Relaunch", "Einspielen und neu starten") : L("Open Download Page", "Download-Seite öffnen")) {
                    Task { await model.installUpdate() }
                }
                .controlSize(.small)
                Link(L("What’s new", "Was ist neu"), destination: release.page).font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
    }
}
