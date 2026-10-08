import AppKit
import AVPPlayCore
import SwiftUI

/// Die Übersicht: jedes Spiel mit Titelbild, Stand und dem einen Knopf, der als Nächstes sinnvoll ist.
struct GamesView: View {
    @EnvironmentObject var model: AppModel

    private var shown: [Game] { model.shownGames }

    var body: some View {
        NavigationStack(path: $model.gamePath) {
            ScrollView {
                if model.loadProblem == nil, !model.games.isEmpty {
                    HStack {
                        Text(L("Show only:", "Nur zeigen:")).foregroundStyle(.secondary)
                        Toggle(L("Verified", "Geprüft"), isOn: $model.filterVerified)
                        Toggle(L("Purchased", "Gekauft"), isOn: $model.filterPurchased)
                        Toggle(L("Installed", "Installiert"), isOn: $model.filterInstalled)
                        Spacer()
                        if model.updatable.count > 1 {
                            Button(L("Update All (\(model.updatable.count))", "Alle aktualisieren (\(model.updatable.count))")) { model.updateAll() }
                        }
                        if model.checkingOwnership {
                            ProgressView().controlSize(.small)
                            Text(L("Checking ownership …", "Besitz wird geprüft …")).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 22).padding(.top, 18)
                }
                if let problem = model.loadProblem {
                    ContentUnavailableView(L("No Games", "Keine Spiele"), systemImage: "questionmark.folder", description: Text(problem))
                        .padding(.top, 80)
                } else if model.games.isEmpty {
                    ProgressView(L("Reading games …", "Spiele werden gelesen …")).padding(.top, 120)
                } else if shown.isEmpty {
                    ContentUnavailableView(L("No Game Matches These Filters", "Kein Spiel passt zu diesen Filtern"), systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text(model.filterPurchased && model.account != .signedIn
                                               ? L("Sign in to Meta under “Setup” to see which games you have purchased.",
                                                   "Melde dich unter „Einrichtung“ bei Meta an, um zu sehen, welche Spiele du gekauft hast.")
                                               : L("Turn off a filter above to see more.", "Schalte oben einen Filter aus, um mehr zu sehen.")))
                        .padding(.top, 80)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 18)], spacing: 18) {
                        ForEach(shown) { game in
                            Button { model.gamePath = [game.id] } label: { GameCard(game: game) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(22)
                }
            }
            .navigationTitle(L("Games", "Spiele"))
            .navigationDestination(for: String.self) { id in
                if let game = model.games.first(where: { $0.id == id }) { GameDetail(game: game) }
            }
        }
    }
}

/// Der Stand eines Spiels als ein Wort mit Farbe.
struct StatusBadge: View {
    let status: GameStatus
    let busy: Bool

    var body: some View {
        let (text, color, symbol) = content
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
    }

    private var content: (String, Color, String) {
        if busy { return (L("Installing", "Wird installiert"), .blue, "arrow.triangle.2.circlepath") }
        switch status.onDevice {
        case .current: return (L("On the Vision Pro", "Auf der Vision Pro"), .green, "checkmark.circle.fill")
        case .olderToolchain: return (L("Update available", "Aktualisierung möglich"), .orange, "arrow.up.circle.fill")
        case .unstamped: return (L("Installed, older build", "Installiert, älterer Stand"), .orange, "arrow.up.circle.fill")
        case .notInstalled: return (L("Not installed", "Nicht installiert"), .secondary, "circle.dashed")
        case .unknown: return (L("Device not reachable", "Gerät nicht erreichbar"), .secondary, "wifi.slash")
        }
    }
}

/// Wie weit einem Spiel zu trauen ist: vom Projekt geprüft, oder noch von niemandem bestätigt.
struct TrustBadge: View {
    let verified: Bool

    var body: some View {
        Label(verified ? L("Verified", "Geprüft") : L("Untested", "Ungetestet"),
              systemImage: verified ? "checkmark.seal.fill" : "questionmark.circle.fill")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(.white)
            .background((verified ? Color.blue : Color.gray).opacity(0.92), in: Capsule())
            .help(verified ? L("Tested by the project on an Apple Vision Pro.", "Vom Projekt auf einer Apple Vision Pro geprüft.")
                           : L("Nobody has confirmed yet that this game runs.", "Noch hat niemand bestätigt, dass dieses Spiel läuft."))
    }
}

/// Wem das Spiel gehört, in einer Zeile.
struct OwnershipLabel: View {
    let owned: Owned
    let checking: Bool
    var compact = true

    var body: some View {
        let (text, symbol): (String, String) = {
            switch owned {
            case .yes: return (L("In your Meta account", "In deinem Meta-Konto"), "checkmark.seal")
            case .no: return (L("Not in your Meta account", "Nicht in deinem Meta-Konto"), "xmark.seal")
            case .unknown: return (checking ? L("Checking ownership …", "Besitz wird geprüft …") : L("Ownership not checked", "Besitz nicht geprüft"), "seal")
            case .notApplicable: return (L("Uses your own game files", "Mit deinen eigenen Spieldateien"), "folder")
            }
        }()
        Label(text, systemImage: symbol).font(compact ? .caption : .callout).foregroundStyle(.secondary)
    }
}

struct CoverImage: View {
    let game: Game

    var body: some View {
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                if let cover = game.cover {
                    Image(nsImage: cover).resizable().scaledToFill()
                } else {
                    // Ohne Bild: eine ruhige Fläche mit dem Namen, damit die Karte nicht leer wirkt.
                    LinearGradient(colors: [Color(nsColor: .controlAccentColor).opacity(0.55), Color.black.opacity(0.75)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(Text(game.recipe.title).font(.title3.bold()).foregroundStyle(.white).padding(12)
                            .multilineTextAlignment(.center))
                }
            }
            .clipped()
    }
}

struct GameCard: View {
    @EnvironmentObject var model: AppModel
    let game: Game
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CoverImage(game: game)
                .overlay(alignment: .topTrailing) { TrustBadge(verified: game.verified).padding(8) }
            VStack(alignment: .leading, spacing: 5) {
                Text(game.recipe.title).font(.headline).lineLimit(1)
                StatusBadge(status: game.status, busy: model.isBusy(game.id))
                OwnershipLabel(owned: model.owned(game), checking: model.checkingOwnership)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(hovering ? 1 : 0.5)))
        .shadow(color: .black.opacity(hovering ? 0.22 : 0.1), radius: hovering ? 10 : 4, y: 2)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

struct GameDetail: View {
    @EnvironmentObject var model: AppModel
    let game: Game
    @State private var confirmRemove = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                CoverImage(game: game)
                    .frame(maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(game.recipe.title).font(.largeTitle.bold())
                        Text(L("Version \(game.recipe.versionName)", "Version \(game.recipe.versionName)")).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            StatusBadge(status: game.status, busy: model.isBusy(game.id))
                            TrustBadge(verified: game.verified)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Button(action: { model.install(game) }) {
                            Text(actionTitle).frame(minWidth: 150)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(model.blocker(for: game) != nil)
                        if let why = model.blocker(for: game) {
                            Text(why).font(.callout).foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing).frame(maxWidth: 280, alignment: .trailing)
                        }
                    }
                }

                if !game.status.userProvidedMissing.isEmpty { ownFiles }

                GroupBox(L("On This Mac", "Auf diesem Mac")) {
                    VStack(alignment: .leading, spacing: 6) {
                        if game.status.filesRequired > 0 {
                            row(L("Files", "Dateien"), L("\(game.status.filesPresent) of \(game.status.filesRequired) present", "\(game.status.filesPresent) von \(game.status.filesRequired) vorhanden"))
                        }
                        if game.status.treesRequired > 0 {
                            row(L("Folders", "Ordner"), L("\(game.status.treesPresent) of \(game.status.treesRequired) present", "\(game.status.treesPresent) von \(game.status.treesRequired) vorhanden"))
                        }
                        if game.status.bytesToDownload > 0 {
                            row(L("Still to download", "Noch zu laden"), Installer.gigabytes(game.status.bytesToDownload))
                        } else if game.status.stockComplete {
                            row("Download", L("nothing left to download", "nichts mehr zu laden"))
                        }
                        if game.storeBytes > 0 {
                            HStack {
                                Text(L("Space used", "Belegter Platz")).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                                Text(Installer.gigabytes(game.storeBytes))
                                Spacer()
                                Button(L("Remove from This Mac …", "Von diesem Mac entfernen …")) { confirmRemove = true }
                                    .controlSize(.small)
                                    .disabled(model.isBusy(game.id))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }

                GroupBox(L("On the Vision Pro", "Auf der Vision Pro")) {
                    Text(deviceText).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }

                if !languageFiles.isEmpty || game.recipe.addons != nil { optionalContent }

                GroupBox(L("Good to Know", "Gut zu wissen")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(game.needsMetaAccount
                             ? L("Before anything is downloaded, Meta is asked whether you own this game. Without a purchase, nothing is downloaded.", "Vor dem Laden wird bei Meta geprüft, dass du dieses Spiel gekauft hast. Ohne Kauf wird nichts geladen.")
                             : L("This game does not come from the Meta Store. The game files come from your own purchase and are never downloaded.", "Dieses Spiel kommt nicht aus dem Meta-Store. Die Spieldateien stammen aus deinem eigenen Kauf und werden nie geladen."))
                        OwnershipLabel(owned: model.owned(game), checking: model.checkingOwnership, compact: false)
                        if let app = game.recipe.store.appId, let page = URL(string: "https://www.meta.com/experiences/\(app)/") {
                            Link(L("View in the Meta Store", "Im Meta-Store ansehen"), destination: page)
                        }
                        Text(playability)
                        if let notes = game.recipe.status.notes, !notes.isEmpty {
                            DisclosureGroup(L("Notes on This Recipe", "Anmerkungen zu diesem Rezept")) {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(notes, id: \.self) { Text("• \($0.text)").foregroundStyle(.secondary) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                            }
                        }
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
            .padding(24)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(game.recipe.title)
        .confirmationDialog(L("Remove the files of \(game.recipe.title) from this Mac?", "Die Dateien von \(game.recipe.title) von diesem Mac entfernen?"),
                            isPresented: $confirmRemove) {
            Button(L("Remove \(Installer.gigabytes(game.storeBytes))", "\(Installer.gigabytes(game.storeBytes)) entfernen"), role: .destructive) { model.removeFiles(game) }
        } message: {
            Text(removeWarning)
        }
    }

    /// Was beim Entfernen verloren geht – bei Sonderapps auch Dateien, die sich nicht neu laden lassen.
    private var removeWarning: String {
        let device = L("The game on your Vision Pro is not touched.", "Das Spiel auf deiner Vision Pro bleibt unberührt.")
        if game.needsMetaAccount {
            return L("Everything this app downloaded for the game is deleted. For the next update it has to be downloaded again. ",
                     "Alles, was dieses Programm für das Spiel geladen hat, wird gelöscht. Für die nächste Aktualisierung muss es neu geladen werden. ") + device
        }
        return L("This also deletes the copies of your own game files that this app keeps. For the next update you have to choose the folder with them again. ",
                 "Dabei werden auch die Kopien deiner eigenen Spieldateien gelöscht, die dieses Programm aufbewahrt. Für die nächste Aktualisierung musst du den Ordner damit neu auswählen. ") + device
    }

    private var actionTitle: String {
        switch game.status.onDevice {
        case .current: return L("Reinstall", "Neu installieren")
        case .olderToolchain, .unstamped: return L("Update", "Aktualisieren")
        case .notInstalled, .unknown: return L("Install", "Installieren")
        }
    }

    private var deviceText: String {
        switch game.status.onDevice {
        case .unknown: return L("The Vision Pro is not reachable right now.", "Die Vision Pro ist gerade nicht erreichbar.")
        case .notInstalled: return L("Not installed yet.", "Noch nicht installiert.")
        case .current: return L("Installed and up to date.", "Installiert und auf dem neuesten Stand.")
        case .olderToolchain: return L("Installed. The current toolchain produces a newer build – “Update” builds it; saved games and data are kept.", "Installiert. Mit der jetzigen Toolchain gibt es eine neuere Fassung – „Aktualisieren“ baut sie; Spielstände und Daten bleiben.")
        case .unstamped: return L("Installed, but as an older build that was not made by this app. “Update” replaces it; saved games and data are kept.", "Installiert, aber in einer älteren Fassung, die nicht von diesem Programm stammt. „Aktualisieren“ ersetzt sie; Spielstände und Daten bleiben.")
        }
    }

    private var playability: String {
        switch game.recipe.status.playability {
        case "reported": return L("Reported as working by users, not yet checked by the project.", "Von Nutzern als lauffähig gemeldet, vom Projekt noch nicht geprüft.")
        case "verified": return L("Verified: the project has tested this game on an Apple Vision Pro.", "Geprüft: Das Projekt hat dieses Spiel auf einer Apple Vision Pro getestet.")
        default: return L("Untested: nobody has confirmed yet that this game runs. You can try it.", "Ungetestet: Noch hat niemand bestätigt, dass dieses Spiel läuft. Du kannst es versuchen.")
        }
    }

    /// Wählbare Dateien, die zu einer Sprache gehören (Sprachausgabe, Sprachpakete), nach Sprache geordnet.
    private var languageFiles: [(locale: String, bytes: Int64?)] {
        let files = game.recipe.files.filter { !$0.required && $0.locale != nil }
        return Set(files.compactMap(\.locale)).sorted().map { locale in
            let sizes = files.filter { $0.locale == locale }.map(\.size)
            return (locale, sizes.contains(where: { $0 == nil }) ? nil : sizes.compactMap { $0 }.reduce(0, +))
        }
    }

    private func languageName(_ locale: String) -> String {
        L10n.locale.localizedString(forIdentifier: locale) ?? locale
    }

    private var optionalContent: some View {
        let chosen = model.options(for: game)
        return GroupBox(L("Optional Content", "Wählbare Inhalte")) {
            VStack(alignment: .leading, spacing: 8) {
                if !languageFiles.isEmpty {
                    Text(L("Languages – each one is an extra download.", "Sprachen – jede ist ein zusätzlicher Download."))
                        .font(.callout).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(languageFiles, id: \.locale) { entry in
                            Toggle(isOn: Binding(
                                get: { chosen.locales.contains(entry.locale) },
                                set: { on in
                                    var next = chosen
                                    next.locales = on ? (chosen.locales + [entry.locale]).sorted() : chosen.locales.filter { $0 != entry.locale }
                                    model.setOptions(next, for: game)
                                })) {
                                Text(languageName(entry.locale) + (entry.bytes.map { " · \(Installer.gigabytes($0))" } ?? ""))
                            }
                        }
                    }
                }
                if game.recipe.addons != nil {
                    Toggle(isOn: Binding(get: { chosen.addons }, set: { on in
                        var next = chosen
                        next.addons = on
                        model.setOptions(next, for: game)
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Add-on content you have purchased", "Zusatzinhalte, die du gekauft hast"))
                            Text(L("Only what Meta confirms as purchased is downloaded and unlocked.",
                                   "Geladen und freigeschaltet wird nur, was Meta als gekauft bestätigt."))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }

    private var ownFiles: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label(L("You Provide These Files Yourself", "Diese Dateien stellst du selbst bereit"), systemImage: "folder.badge.questionmark").font(.headline)
                ForEach(game.status.userProvidedMissing, id: \.self) { Text("• \($0)").font(.callout) }
                Button(L("Choose Folder …", "Ordner auswählen …")) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.message = L("Choose the folder that contains the files. They are copied into this app’s library.", "Ordner wählen, in dem die Dateien liegen. Sie werden in den Bestand dieses Programms kopiert.")
                    if panel.runModal() == .OK, let url = panel.url { model.adopt(game, from: url) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value)
        }
    }
}
