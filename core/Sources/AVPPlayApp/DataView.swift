import AppKit
import AVPPlayCore
import SwiftUI

/// Die Datenverwaltung: was heruntergeladen ist, wie viel Platz es belegt, und wie man es wieder loswird.
struct DataView: View {
    @EnvironmentObject var model: AppModel
    @State private var removing: StoredGame?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox(L("Downloads Folder", "Ordner für Downloads")) {
                    VStack(alignment: .leading, spacing: 8) {
                        StoreLocationBox()
                        if let storage = model.storage, storage.available, model.storeMove == nil {
                            Text(summary(storage)).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }

                GroupBox(L("Downloaded Games", "Heruntergeladene Spiele")) {
                    VStack(alignment: .leading, spacing: 0) {
                        if let storage = model.storage {
                            if storage.games.isEmpty {
                                Text(storage.available ? L("Nothing has been downloaded yet.", "Noch ist nichts heruntergeladen.")
                                                       : L("The folder cannot be read at the moment.", "Der Ordner lässt sich gerade nicht lesen."))
                                    .foregroundStyle(.secondary).padding(6)
                            }
                            ForEach(storage.games) { item in
                                StoredGameRow(item: item) { removing = item }
                                if item.id != storage.games.last?.id { Divider() }
                            }
                        } else {
                            HStack { ProgressView().controlSize(.small); Text(L("Counting …", "Wird gezählt …")).foregroundStyle(.secondary) }.padding(6)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let storage = model.storage, !storage.toolchains.isEmpty || storage.steamLeftover > 0 {
                    GroupBox(L("Other Data on This Mac", "Weitere Daten auf diesem Mac")) {
                        VStack(alignment: .leading, spacing: 10) {
                            if !storage.toolchains.isEmpty {
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(L("Toolchains", "Toolchains"))
                                        Text(toolchainText(storage)).font(.callout).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer()
                                    if !storage.olderToolchains.isEmpty {
                                        Button(L("Remove Older Ones", "Ältere entfernen")) { model.removeOlderToolchains() }
                                    }
                                }
                            }
                            if storage.steamLeftover > 0 {
                                Divider()
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(L("Left over from a Steam download", "Reste eines Steam-Abrufs"))
                                        Text(L("\(Installer.gigabytes(storage.steamLeftover)) that SteamCMD downloaded but that did not make it into the library. A new download from Steam continues with them.",
                                               "\(Installer.gigabytes(storage.steamLeftover)), die SteamCMD geladen hat, die aber nicht im Bestand angekommen sind. Ein neuer Abruf bei Steam setzt damit fort."))
                                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer()
                                    Button(L("Remove", "Entfernen")) { model.removeSteamLeftovers() }.disabled(!model.steamBusy.isEmpty)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }

                Text(L("Removing downloaded files frees space on this Mac only. A game that is installed on the Vision Pro stays there and keeps running; to install or update it again, the app downloads the files once more.",
                       "Heruntergeladene Dateien zu entfernen macht nur auf diesem Mac Platz. Ein Spiel, das auf der Vision Pro installiert ist, bleibt dort und läuft weiter; um es neu zu installieren oder zu aktualisieren, lädt die App die Dateien noch einmal."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(L("Data", "Datenverwaltung"))
        .task { model.scanStorage() }
        .confirmationDialog(removing.map { L("Remove the downloaded files of \($0.title) from this Mac?", "Die heruntergeladenen Dateien von \($0.title) von diesem Mac entfernen?") } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { item in
            Button(L("Remove \(Installer.gigabytes(item.bytes))", "\(Installer.gigabytes(item.bytes)) entfernen"), role: .destructive) { model.removeStored(item) }
            Button(L("Cancel", "Abbrechen"), role: .cancel) {}
        } message: { _ in
            Text(L("What is installed on the Vision Pro stays there.", "Was auf der Vision Pro installiert ist, bleibt dort."))
        }
    }

    private func summary(_ storage: StorageOverview) -> String {
        let n = storage.games.count
        let used = L("\(n) \(n == 1 ? "download" : "downloads"), \(Installer.gigabytes(storage.gamesBytes)) in all", "\(n) \(n == 1 ? "Download" : "Downloads"), zusammen \(Installer.gigabytes(storage.gamesBytes))")
        guard let free = storage.freeBytes else { return used }
        return used + L(" · \(Installer.gigabytes(free)) free on this disk", " · \(Installer.gigabytes(free)) frei auf dieser Platte")
    }

    private func toolchainText(_ storage: StorageOverview) -> String {
        let all = storage.toolchains.map(\.bytes).reduce(0, +)
        let older = storage.olderToolchains
        // Die Zahl ist die Summe der Dateigrößen. Beim Bauen entstehen Kopien, die sich auf dem Startlaufwerk den Platz
        // mit den Downloads teilen können; frei wird dann weniger, als hier steht.
        let base = L("\(storage.toolchains.count) installed, \(Installer.gigabytes(all)) by file size (they grow with every game that is built; part of it can share disk space with the downloads).",
                     "\(storage.toolchains.count) installiert, nach Dateigröße \(Installer.gigabytes(all)) (sie wachsen mit jedem Spiel, das gebaut wird; ein Teil kann sich den Platz mit den Downloads teilen).")
        guard !older.isEmpty else { return base }
        return base + L(" \(older.count) of them are older versions that nothing needs any more: \(Installer.gigabytes(older.map(\.bytes).reduce(0, +))).",
                        " \(older.count) davon sind ältere Fassungen, die nichts mehr braucht: \(Installer.gigabytes(older.map(\.bytes).reduce(0, +))).")
    }
}

/// Eine Zeile der Datenverwaltung: ein Spiel mit dem, was von ihm auf dem Mac liegt, aufklappbar bis zur Datei.
struct StoredGameRow: View {
    @EnvironmentObject var model: AppModel
    let item: StoredGame
    let remove: () -> Void
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(item.files.prefix(200)) { file in
                    HStack {
                        Image(systemName: file.isFolder ? "folder" : "doc").foregroundStyle(.secondary).frame(width: 18)
                        Text(file.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(Self.size(file.bytes)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.callout)
                }
                if item.files.count > 200 {
                    Text(L("… and \(item.files.count - 200) more", "… und \(item.files.count - 200) weitere")).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 4).padding(.vertical, 6)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.headline).lineLimit(1)
                    Text(L("\(item.detail) · \(item.fileCount) \(item.fileCount == 1 ? "file" : "files")", "\(item.detail) · \(item.fileCount) \(item.fileCount == 1 ? "Datei" : "Dateien")"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Installer.gigabytes(item.bytes)).monospacedDigit()
                Button(L("Show", "Zeigen")) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }.controlSize(.small)
                Button(L("Remove …", "Entfernen …"), role: .destructive, action: remove).controlSize(.small)
                    .disabled(model.storeMove != nil || (item.gameId.map { model.isBusy($0) || model.steamBusy.contains($0) } ?? false))
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
    }

    static func size(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? Installer.gigabytes(bytes) : String(format: "%.1f MB", Double(bytes) / 1e6)
    }
}
