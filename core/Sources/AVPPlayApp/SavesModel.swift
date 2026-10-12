import AppKit
import AVPPlayCore
import SwiftUI

/// Spielstände: von der Vision Pro auf den Mac holen – von selbst, wenn ein Spiel beendet wurde, und regelmäßig –,
/// und bei Bedarf zurückspielen.
extension AppModel {
    /// Wie oft das Headset gefragt wird, was läuft, und nach welcher Zeit alle installierten Spiele wieder dran sind.
    static let saveWatchInterval: Duration = .seconds(180)
    static let saveRoundInterval: TimeInterval = 6 * 3600

    /// Spielstände gibt es für Spiele aus einem APK: Die schreiben alles unter einen Ordner, den die App kennt. Die
    /// wenigen Spiele, die als Linux-Programm laufen, legen ihre Stände zwischen ihre Spieldateien.
    func hasSaves(_ game: Game) -> Bool {
        game.draft || game.recipe.files.contains { $0.role == "apk" }
    }

    /// Das Präfix, unter dem die App installiert – als Angabe für die Suche nach der installierten App.
    private var savePrefix: String? { bundlePrefix == Toolchain.defaultBundlePrefix() ? nil : bundlePrefix }

    /// Holt die Spielstände eines Spiels jetzt.
    func fetchSaves(_ game: Game) {
        fetchSaves(of: [game], announce: true)
    }

    /// Holt die Spielstände aller installierten Spiele jetzt.
    func fetchAllSaves() {
        fetchSaves(of: games.filter { $0.installed && hasSaves($0) }, announce: true)
    }

    private func fetchSaves(of list: [Game], announce: Bool) {
        let wanted = list.filter { !savesBusy.contains($0.id) }
        guard !wanted.isEmpty else { return }
        savesBusy.formUnion(wanted.map(\.id))
        let paths = paths, prefix = savePrefix
        let preferred = chosenDevice.isEmpty ? nil : chosenDevice
        let recipes = wanted.map(\.recipe)
        Task.detached(priority: .utility) {
            let results = SaveRound.run(recipes: recipes, store: paths.store, preferredDevice: preferred, prefix: prefix)
            await MainActor.run { self.take(results, asked: recipes, announce: announce) }
        }
    }

    /// Übernimmt, was ein Durchgang ergab. `nil` heißt: das Headset war nicht erreichbar.
    private func take(_ results: [SaveRound.Result]?, asked: [Recipe], announce: Bool) {
        savesBusy.subtract(asked.map(\.id))
        guard let results else {
            if announce {
                let why = L("The Vision Pro is not reachable.", "Die Vision Pro ist nicht erreichbar.")
                for recipe in asked { savesNote[recipe.id] = why }
                if asked.count > 1 { notice = why }
            }
            return
        }
        var saved = 0
        for recipe in asked {
            guard let r = results.first(where: { $0.recipe == recipe.id }) else {
                if announce { savesNote[recipe.id] = L("Not on this Vision Pro.", "Nicht auf dieser Vision Pro.") }
                continue
            }
            if let snapshot = r.snapshot { saveSnapshots[recipe.id] = snapshot }
            if r.kind == .saved { saved += 1 }
            // Von selbst geholt, sagt nur ein neuer Stand oder ein Fehler etwas; „nichts Neues“ alle paar Minuten nicht.
            if announce || r.kind == .saved || r.kind == .failed {
                savesNote[recipe.id] = r.kind == .failed ? L("Fetching did not work: \(r.detail)", "Das Holen ging nicht: \(r.detail)")
                    : (r.detail.prefix(1).uppercased() + r.detail.dropFirst())
            }
        }
        if announce, asked.count > 1 {
            notice = saved == 0 ? L("Saved games: nothing new on the Vision Pro.", "Spielstände: nichts Neues auf der Vision Pro.")
                : saved == 1 ? L("Saved games of one game fetched.", "Spielstände eines Spiels geholt.")
                : L("Saved games of \(saved) games fetched.", "Spielstände von \(saved) Spielen geholt.")
        }
    }

    /// Was dem Zurückspielen im Weg steht.
    func restoreBlocker(for game: Game) -> String? {
        if saveSnapshots[game.id] == nil { return L("No saved games of this game are on this Mac yet.", "Von diesem Spiel liegen noch keine Spielstände auf diesem Mac.") }
        if device == nil { return deviceProblem ?? L("The Vision Pro is not reachable.", "Die Vision Pro ist nicht erreichbar.") }
        if !game.installed { return L("Install the game first.", "Erst das Spiel installieren.") }
        if isBusy(game.id) { return L("A job for this game is already running.", "Für dieses Spiel läuft schon ein Auftrag.") }
        return nil
    }

    /// Spielt den neuesten Stand aufs Gerät zurück und ersetzt, was dort liegt. Nur auf Knopfdruck, nach Rückfrage,
    /// und nicht, während das Spiel läuft: es würde die Dateien beim Beenden wieder überschreiben.
    func restoreSaves(_ game: Game) {
        guard restoreBlocker(for: game) == nil, let snapshot = saveSnapshots[game.id], !savesBusy.contains(game.id) else { return }
        savesBusy.insert(game.id)
        let paths = paths, prefix = savePrefix, recipe = game.recipe
        let preferred = chosenDevice.isEmpty ? nil : chosenDevice
        Task.detached(priority: .userInitiated) {
            let note: String
            do {
                let control = DeviceControl()
                let device = try control.pick(udid: preferred)
                let apps = try control.apps(device: device)
                guard let bundle = SaveSync.installedBundle(recipe: recipe, store: paths.store, prefix: prefix, apps: apps),
                      let app = apps.first(where: { $0.bundleIdentifier == bundle }) else { throw InstallError.appNotInstalled(recipe.title) }
                if DeviceControl.isRunning(app, executables: (try? control.runningExecutables(device: device)) ?? []) {
                    note = L("The game is running. Quit it on the Vision Pro first – otherwise it overwrites the saved games again when it quits.",
                             "Das Spiel läuft gerade. Beende es zuerst auf der Vision Pro – sonst überschreibt es die Spielstände beim Beenden wieder.")
                } else {
                    // Erst festhalten, was jetzt auf dem Gerät liegt: so kostet auch ein Irrtum keinen Spielstand.
                    let sync = SaveSync(store: paths.store)
                    _ = try sync.fetch(recipe: recipe, device: device, bundle: bundle)
                    let n = try sync.restore(snapshot, recipe: recipe, device: device, bundle: bundle, mode: .overwrite)
                    note = n == 1 ? L("One file put back on the Vision Pro.", "Eine Datei auf die Vision Pro zurückgespielt.")
                                  : L("\(n) files put back on the Vision Pro.", "\(n) Dateien auf die Vision Pro zurückgespielt.")
                }
            } catch {
                note = L("Putting back did not work: \(Redaction.redact("\(error)"))", "Das Zurückspielen ging nicht: \(Redaction.redact("\(error)"))")
            }
            await MainActor.run {
                self.savesBusy.remove(recipe.id)
                self.savesNote[recipe.id] = note
            }
        }
    }

    func showSaves(_ game: Game) {
        let store = paths.saves
        let folder = saveSnapshots[game.id].map { store.directory(of: $0, for: game.recipe) } ?? store.directory(for: game.recipe)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    // MARK: Von selbst

    /// Fragt das Headset in Abständen, was läuft. Ein Spiel, das beim letzten Mal lief und jetzt nicht mehr, wurde
    /// beendet: dann werden seine Spielstände geholt. Und alle paar Stunden sind alle installierten Spiele dran –
    /// das fängt auf, was lief, während der Mac aus oder das Headset nicht erreichbar war.
    func startSaveWatch() {
        guard saveWatch == nil, Snapshot.directory == nil else { return }
        saveWatch = Task { [weak self] in
            while !Task.isCancelled {
                await self?.saveTick()
                try? await Task.sleep(for: AppModel.saveWatchInterval)
            }
        }
    }

    private func saveTick() async {
        // Nicht, während gebaut oder kopiert wird: der Auftrag spricht selbst mit dem Gerät.
        // Und nicht, solange der Ort der Spielstände fehlt (die Platte mit dem gewählten Ordner ist nicht angeschlossen).
        guard syncSaves, runningJob == nil, queued.isEmpty, storeBlocker == nil, savesBusy.isEmpty, !games.isEmpty,
              !ProcessLock.isHeld(ProcessLock.installURL) else { return }
        let paths = paths, prefix = savePrefix
        let preferred = chosenDevice.isEmpty ? nil : chosenDevice
        let candidates = games.filter(hasSaves).map(\.recipe)
        let before = runningGames
        let roundDue = Date().timeIntervalSince1970 - lastSaveRound > AppModel.saveRoundInterval
        // Ein Headset ohne stehende Verbindung schläft vielleicht: dann nur bei jeder fünften Gelegenheit nachfragen.
        saveTicks += 1
        let patient = saveTicks % 5 != 1
        let outcome: (running: Set<String>, asked: [Recipe], results: [SaveRound.Result])? = await Task.detached(priority: .utility) {
            let control = DeviceControl()
            let usable = ((try? control.devices()) ?? []).filter { $0.paired && $0.reachable }
            guard let device = usable.first(where: { $0.udid == preferred }) ?? (usable.count == 1 ? usable[0] : nil),
                  device.connected || !patient, let apps = try? control.apps(device: device) else { return nil }
            let executables = (try? control.runningExecutables(device: device)) ?? []
            var installed: [Recipe] = [], running: Set<String> = []
            for recipe in candidates {
                guard let bundle = SaveSync.installedBundle(recipe: recipe, store: paths.store, prefix: prefix, apps: apps),
                      let app = apps.first(where: { $0.bundleIdentifier == bundle }) else { continue }
                installed.append(recipe)
                if DeviceControl.isRunning(app, executables: executables) { running.insert(recipe.id) }
            }
            let asked = installed.filter { !running.contains($0.id) && (roundDue || before.contains($0.id)) }
            let results = asked.isEmpty ? [] : SaveRound.run(recipes: asked, store: paths.store, device: device, apps: apps,
                                                             running: executables, prefix: prefix)
            return (running, asked, results)
        }.value
        guard let outcome else { return }
        runningGames = outcome.running
        if roundDue { lastSaveRound = Date().timeIntervalSince1970 }
        if !outcome.asked.isEmpty { take(outcome.results, asked: outcome.asked, announce: false) }
    }
}

/// Die Spielstände auf der Seite eines Spiels.
struct SavesBox: View {
    @EnvironmentObject var model: AppModel
    let game: Game
    @State private var confirmRestore = false

    var body: some View {
        let snapshot = model.saveSnapshots[game.id]
        let busy = model.savesBusy.contains(game.id)
        GroupBox(L("Saved Games", "Spielstände")) {
            VStack(alignment: .leading, spacing: 8) {
                if let snapshot {
                    let when = snapshot.taken.formatted(date: .abbreviated, time: .shortened)
                    Text(snapshot.files.count == 1
                         ? L("On this Mac: one file (\(StoredGameRow.size(snapshot.bytes))), fetched \(when).", "Auf diesem Mac: eine Datei (\(StoredGameRow.size(snapshot.bytes))), geholt am \(when).")
                         : L("On this Mac: \(snapshot.files.count) files (\(StoredGameRow.size(snapshot.bytes))), fetched \(when).", "Auf diesem Mac: \(snapshot.files.count) Dateien (\(StoredGameRow.size(snapshot.bytes))), geholt am \(when)."))
                } else {
                    Text(L("None on this Mac yet.", "Noch keine auf diesem Mac.")).foregroundStyle(.secondary)
                }
                Text(model.syncSaves
                     ? L("AVP Play fetches them from the Vision Pro by itself: after you quit the game, and every few hours, whenever the headset is reachable while the app is open. Each time something has changed, a new copy is kept, so an older one is never overwritten. The copies stay on this Mac when the game is removed from the Vision Pro.",
                         "AVP Play holt sie von selbst von der Vision Pro: nachdem du das Spiel beendet hast, und alle paar Stunden – immer wenn das Headset erreichbar ist, während die App offen ist. Jedes Mal, wenn sich etwas geändert hat, bleibt eine neue Kopie; eine ältere wird nie überschrieben. Die Kopien bleiben auf diesem Mac, auch wenn das Spiel von der Vision Pro entfernt wird.")
                     : L("Fetching by itself is turned off in the settings. “Fetch Now” still works.", "Das Holen von selbst ist in den Einstellungen abgestellt. „Jetzt holen“ geht weiterhin."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let note = model.savesNote[game.id] {
                    Label(note, systemImage: "info.circle").font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(L("Fetch Now", "Jetzt holen")) { model.fetchSaves(game) }
                        .disabled(busy || !game.installed)
                    if snapshot != nil {
                        Button(L("Show in Finder", "Im Finder zeigen")) { model.showSaves(game) }
                        Button(L("Put Back on the Vision Pro …", "Auf die Vision Pro zurückspielen …")) { confirmRestore = true }
                            .disabled(busy || model.restoreBlocker(for: game) != nil)
                            .help(model.restoreBlocker(for: game) ?? "")
                    }
                    if busy { ProgressView().controlSize(.small) }
                }
                if snapshot != nil {
                    Toggle(L("When this game is installed and has no saved games on the Vision Pro, put these back",
                             "Wenn dieses Spiel installiert wird und auf der Vision Pro keine Spielstände hat, diese zurückspielen"),
                           isOn: Binding(get: { model.options(for: game).restoreSaves ?? true },
                                         set: { var o = model.options(for: game); o.restoreSaves = $0; model.setOptions(o, for: game) }))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
        .confirmationDialog(L("Put the saved games of \(game.recipe.title) back on the Vision Pro?", "Die Spielstände von \(game.recipe.title) auf die Vision Pro zurückspielen?"),
                            isPresented: $confirmRestore) {
            Button(L("Replace the Saved Games on the Vision Pro", "Spielstände auf der Vision Pro ersetzen"), role: .destructive) { model.restoreSaves(game) }
        } message: {
            Text(L("The copy from \(model.saveSnapshots[game.id]?.taken.formatted(date: .abbreviated, time: .shortened) ?? "–") replaces what is on the Vision Pro now. What is there now is copied to this Mac first, so nothing is lost. Quit the game first.",
                   "Die Kopie vom \(model.saveSnapshots[game.id]?.taken.formatted(date: .abbreviated, time: .shortened) ?? "–") ersetzt, was jetzt auf der Vision Pro liegt. Was dort jetzt liegt, wird vorher auf diesen Mac kopiert – es geht also nichts verloren. Beende das Spiel vorher."))
        }
    }
}
