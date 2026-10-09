import AppKit
import AVPPlayCore
import SwiftUI

/// Ein Ordner im Bestand: die heruntergeladenen Dateien eines Spiels in einer Fassung.
struct StoredGame: Identifiable {
    struct File: Identifiable {
        let name: String
        let bytes: Int64
        let isFolder: Bool
        var id: String { name }
    }
    /// Der Ordnername im Bestand.
    let id: String
    let url: URL
    let title: String
    let detail: String
    let bytes: Int64
    let fileCount: Int
    /// Was direkt im Ordner liegt, das Größte zuerst.
    let files: [File]
    /// Das Spiel der Übersicht, zu dem der Ordner gehört; `nil`, wenn ihn kein Rezept mehr braucht.
    let gameId: String?
}

struct StoredToolchain: Identifiable {
    let version: Int
    let commit: String
    let url: URL
    let bytes: Int64
    let inUse: Bool
    var id: Int { version }
}

/// Was auf diesem Mac an Daten liegt.
struct StorageOverview {
    var root: URL
    var isCustom: Bool
    var available: Bool
    var games: [StoredGame]
    var freeBytes: Int64?
    var toolchains: [StoredToolchain]
    /// Was von einem abgebrochenen Abruf bei SteamCMD liegen geblieben ist.
    var steamLeftover: Int64

    var gamesBytes: Int64 { games.map(\.bytes).reduce(0, +) }
    var olderToolchains: [StoredToolchain] { toolchains.filter { !$0.inUse } }
}

/// Die Datenverwaltung: sehen, was heruntergeladen ist, es entfernen, und den Ort dafür wechseln.
extension AppModel {
    /// Lässt sich der Ordner für Downloads gerade benutzen? Nicht, während er umzieht, und nicht, wenn seine Platte
    /// nicht angeschlossen ist – sonst sähe es aus, als fehlten alle Dateien, und sie würden neu geladen.
    var storeBlocker: String? {
        if storeMove != nil {
            return L("The downloads are being moved to another folder. Wait until that has finished.", "Die Downloads ziehen gerade in einen anderen Ordner um. Warte, bis das fertig ist.")
        }
        if !StoreLocation.isAvailable(paths.store.root) {
            return L("The downloads folder cannot be reached – is the disk connected? (\(paths.store.root.path))",
                     "Der Ordner für Downloads ist nicht erreichbar – ist die Platte angeschlossen? (\(paths.store.root.path))")
        }
        return nil
    }

    /// Sieht nach, was im Bestand liegt. Das Zählen läuft im Hintergrund: Es sind schnell über hundert Gigabyte
    /// in zehntausenden Dateien.
    func scanStorage() {
        guard !storageScanning else { return }
        storageScanning = true
        let paths = paths
        let known = games.map { (id: $0.id, folder: "\($0.recipe.id)-\($0.recipe.versionCode)", recipe: $0.recipe.id, title: $0.recipe.title, version: $0.recipe.versionName) }
        let unfinished = Set(jobs.filter { $0.state != .finished && $0.state != .cancelled }.map(\.toolchainCommit))
        Task.detached {
            let fm = FileManager.default
            let root = paths.store.root
            var stored: [StoredGame] = []
            for url in StoreMove.items(in: root) where !url.lastPathComponent.hasPrefix(".") {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let name = url.lastPathComponent
                let entries = ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                    .filter { !$0.lastPathComponent.hasPrefix(".") }
                let files = entries.map { entry -> StoredGame.File in
                    let folder = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    return StoredGame.File(name: entry.lastPathComponent, bytes: StoreMove.measure(entry).bytes, isFolder: folder)
                }.sorted { $0.bytes > $1.bytes }
                let size = StoreMove.measure(url)
                let title: String, detail: String, gameId: String?
                if let game = known.first(where: { $0.folder == name }) {
                    (title, detail, gameId) = (game.title, L("Version \(game.version)", "Version \(game.version)"), game.id)
                } else if let game = known.first(where: { name.hasPrefix($0.recipe + "-") }) {
                    (title, detail, gameId) = (game.title, L("An earlier version – no longer needed", "Eine frühere Fassung – wird nicht mehr gebraucht"), nil)
                } else {
                    (title, detail, gameId) = (name, L("Not used by any game in the list", "Von keinem Spiel der Liste gebraucht"), nil)
                }
                stored.append(StoredGame(id: name, url: url, title: title, detail: detail, bytes: size.bytes, fileCount: size.files, files: files, gameId: gameId))
            }
            stored.sort { $0.bytes > $1.bytes }

            let installed = paths.packager.installed()
            let toolchains = installed.enumerated().compactMap { index, toolchain -> StoredToolchain? in
                guard let manifest = toolchain.manifest else { return nil }
                let needed = index == 0 || unfinished.contains { !$0.isEmpty && (manifest.commit.hasPrefix($0) || $0.hasPrefix(manifest.commit)) }
                return StoredToolchain(version: manifest.version, commit: manifest.commit, url: toolchain.root,
                                       bytes: StoreMove.measure(toolchain.root).bytes, inUse: needed)
            }
            var steam = StoreMove.measure(SteamTool().directory.appendingPathComponent("steamapps/content")).bytes
            steam += StoreMove.measure(root.appendingPathComponent(".steamcmd/content")).bytes

            let overview = StorageOverview(
                root: root, isCustom: StoreLocation.custom() != nil, available: StoreLocation.isAvailable(root), games: stored,
                freeBytes: StoreLocation.freeBytes(at: root),
                toolchains: toolchains, steamLeftover: steam)
            await MainActor.run {
                self.storage = overview
                self.storageScanning = false
            }
        }
    }

    /// Entfernt die heruntergeladenen Dateien eines Eintrags von diesem Mac. Was auf der Vision Pro installiert
    /// ist, bleibt dort.
    func removeStored(_ item: StoredGame) {
        if let id = item.gameId, isBusy(id) || steamBusy.contains(id) {
            notice = L("A job for \(item.title) is running. Remove its files when it has finished.", "Für \(item.title) läuft gerade ein Auftrag. Entferne die Dateien, wenn er fertig ist.")
            return
        }
        guard storeMove == nil else { return }
        notice = L("Removing files …", "Dateien werden entfernt …")
        let url = item.url, title = item.title
        Task.detached {
            let problem: String?
            do { try FileManager.default.removeItem(at: url); problem = nil } catch { problem = error.localizedDescription }
            await MainActor.run {
                self.notice = problem ?? L("The downloaded files of \(title) have been removed from this Mac.", "Die heruntergeladenen Dateien von \(title) wurden von diesem Mac entfernt.")
                self.refresh()
                self.scanStorage()
            }
        }
    }

    /// Entfernt die Toolchains, die keiner mehr braucht: alle bis auf die neueste und die, mit denen ein noch
    /// nicht abgeschlossener Auftrag begonnen wurde.
    func removeOlderToolchains() {
        let paths = paths
        let unfinished = Set(jobs.filter { $0.state != .finished && $0.state != .cancelled }.map(\.toolchainCommit))
        Task.detached {
            let removed = (try? paths.packager.prune(keep: 1, protecting: unfinished)) ?? []
            await MainActor.run {
                self.notice = L("\(removed.count) older toolchain(s) removed.", "\(removed.count) ältere Toolchain(s) entfernt.")
                self.scanStorage()
            }
        }
    }

    func removeSteamLeftovers() {
        guard steamBusy.isEmpty else { return }
        let root = paths.store.root
        Task.detached {
            try? FileManager.default.removeItem(at: SteamTool().directory.appendingPathComponent("steamapps/content"))
            try? FileManager.default.removeItem(at: root.appendingPathComponent(".steamcmd/content"))
            await MainActor.run { self.scanStorage() }
        }
    }

    // MARK: Den Ort wechseln

    /// Fragt nach einem Ordner und zieht die Downloads dorthin um.
    func chooseStoreLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Use This Folder", "Diesen Ordner verwenden")
        panel.message = L("Choose where downloaded games are kept – for example on an external disk. The app creates a folder “\(StoreLocation.folderName)” in it.",
                          "Wähle, wo heruntergeladene Spiele liegen sollen – zum Beispiel auf einer externen Platte. Die App legt darin einen Ordner „\(StoreLocation.folderName)“ an.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        moveStore(to: StoreLocation.folder(in: url))
    }

    /// Zurück an den üblichen Ort neben den Daten des Programms.
    func useStandardStoreLocation() { moveStore(to: StoreLocation.standard()) }

    /// Zieht den Bestand um und stellt danach auf den neuen Ort um. Bestätigt wird vorher, mit der Größe.
    func moveStore(to target: URL, confirm: Bool = true) {
        let old = paths.store.root
        guard target.standardizedFileURL.path != old.standardizedFileURL.path else { return }
        guard storeMove == nil else { return }
        guard runningJob == nil, queued.isEmpty, steamBusy.isEmpty else {
            storeMoveNote = L("A job is running. Change the folder when it has finished.", "Es läuft gerade ein Auftrag. Wechsle den Ordner, wenn er fertig ist.")
            return
        }
        guard StoreLocation.isAvailable(target) else {
            storeMoveNote = "\(StoreMoveError.notAvailable(target.path))"
            return
        }
        storeMoveNote = L("Looking at what has to move …", "Es wird nachgesehen, was umziehen muss …")
        let stops = storeMoveStop
        stops.clear("store")
        Task {
            let total: Int64 = await Task.detached { StoreMove.items(in: old).map { StoreMove.measure($0).bytes }.reduce(0, +) }.value
            // Platz am Ziel, wenn es ein anderes Laufwerk ist.
            if !StoreLocation.sameVolume(old, target) {
                if let free = StoreLocation.freeBytes(at: target), total + 1_000_000_000 > free {
                    storeMoveNote = L("Not enough space there: \(Installer.gigabytes(total)) have to move, \(Installer.gigabytes(free)) are free.",
                                      "Dort ist zu wenig Platz: \(Installer.gigabytes(total)) müssen umziehen, \(Installer.gigabytes(free)) sind frei.")
                    return
                }
            }
            if confirm {
                let alert = NSAlert()
                alert.messageText = L("Move the downloads?", "Downloads umziehen?")
                alert.informativeText = L("\(Installer.gigabytes(total)) of downloaded games move to\n\(target.path)\n\nEach game is removed from the old place only once it has arrived completely. Installing is paused meanwhile.",
                                          "\(Installer.gigabytes(total)) heruntergeladene Spiele ziehen um nach\n\(target.path)\n\nJedes Spiel wird am alten Ort erst gelöscht, wenn es vollständig angekommen ist. Installieren ist währenddessen angehalten.")
                alert.addButton(withTitle: L("Move", "Umziehen"))
                alert.addButton(withTitle: L("Cancel", "Abbrechen"))
                guard alert.runModal() == .alertFirstButtonReturn else { storeMoveNote = nil; return }
            }
            storeMove = StoreMove.Progress(done: 0, total: total, item: "")
            storeMoveNote = nil
            let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .suddenTerminationDisabled], reason: "Moving downloads")
            let outcome: Result<StoreMove.Result, Error> = await Task.detached {
                Result {
                    try StoreMove.run(from: old, to: target, shouldStop: { stops.isRequested("store") }) { progress in
                        Task { @MainActor in if self.storeMove != nil { self.storeMove = progress } }
                    }
                }
            }.value
            ProcessInfo.processInfo.endActivity(activity)
            // Kurz warten, damit eine noch unterwegs befindliche Zwischenmeldung den Schluss nicht überschreibt.
            try? await Task.sleep(for: .milliseconds(200))
            storeMove = nil
            switch outcome {
            case .success(let result):
                do {
                    try StoreLocation.set(target)
                    paths = Paths()
                    storeMoveNote = result.skipped.isEmpty
                        ? L("Done. Downloads are now kept in \(target.path).", "Fertig. Downloads liegen jetzt in \(target.path).")
                        : L("Done. Downloads are now kept in \(target.path). Already present there and therefore left at the old place: \(result.skipped.joined(separator: ", ")).",
                            "Fertig. Downloads liegen jetzt in \(target.path). Dort schon vorhanden und deshalb am alten Ort geblieben: \(result.skipped.joined(separator: ", ")).")
                } catch {
                    storeMoveNote = error.localizedDescription
                }
            case .failure(let error):
                // Ein Teil kann schon drüben sein. Der alte Ort gilt weiter; derselbe Umzug noch einmal holt den Rest.
                storeMoveNote = L("\(error) The old folder is still the one in use. What has already moved is waiting at the new place – choose the same folder again to move the rest.",
                                  "\(error) Es gilt weiter der alte Ordner. Was schon umgezogen ist, wartet am neuen Ort – wähle denselben Ordner noch einmal, um den Rest zu holen.")
            }
            refresh()
            scanStorage()
        }
    }

    func stopStoreMove() { storeMoveStop.request("store") }
}

/// Der Ort der Downloads mit dem, was sich daran ändern lässt – auf der Seite „Datenverwaltung“ und in den Einstellungen.
struct StoreLocationBox: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let root = model.paths.store.root
        VStack(alignment: .leading, spacing: 8) {
            Text(root.path).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !StoreLocation.isAvailable(root) {
                Label(L("This folder cannot be reached – is the disk connected? Nothing is downloaded until it is.",
                        "Dieser Ordner ist nicht erreichbar – ist die Platte angeschlossen? Bis dahin wird nichts geladen."),
                      systemImage: "externaldrive.badge.exclamationmark").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let move = model.storeMove {
                ProgressView(value: Double(move.done), total: Double(max(move.total, 1)))
                HStack {
                    Text(move.item.isEmpty ? L("Moving …", "Umzug läuft …")
                         : L("Moving \(move.item) … \(Installer.gigabytes(move.done)) of \(Installer.gigabytes(move.total))",
                             "\(move.item) zieht um … \(Installer.gigabytes(move.done)) von \(Installer.gigabytes(move.total))"))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button(L("Stop", "Anhalten")) { model.stopStoreMove() }.controlSize(.small)
                }
            } else {
                HStack {
                    Button(L("Change …", "Ändern …")) { model.chooseStoreLocation() }
                    if StoreLocation.custom() != nil {
                        Button(L("Use Default Folder", "Üblichen Ordner verwenden")) { model.useStandardStoreLocation() }
                    }
                    Button(L("Show in Finder", "Im Finder zeigen")) { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                        .disabled(!FileManager.default.fileExists(atPath: root.path))
                }
            }
            if let note = model.storeMoveNote {
                Text(note).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }
}
