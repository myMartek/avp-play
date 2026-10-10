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
                        if model.onlineCatalog { Toggle(L("Community Verified", "Von Nutzern bestätigt"), isOn: $model.filterCommunity) }
                        Toggle(L("Installed", "Installiert"), isOn: $model.filterInstalled)
                        Toggle(L("Favourites", "Favoriten"), isOn: $model.filterFavourites)
                        Spacer()
                        if model.searching {
                            ProgressView().controlSize(.small)
                            Text(L("Searching the catalogue …", "Katalog wird durchsucht …")).font(.callout).foregroundStyle(.secondary)
                        }
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
                    ContentUnavailableView(model.searchText.isEmpty ? L("No Game Matches These Filters", "Kein Spiel passt zu diesen Filtern")
                                                                    : L("Nothing Found for “\(model.searchText)”", "Nichts gefunden zu „\(model.searchText)“"),
                                           systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text(!model.searchText.isEmpty
                                               ? (model.catalogProblem ?? L("The catalogue knows no game by that name, or a filter above hides it.",
                                                                            "Der Katalog kennt kein Spiel mit diesem Namen, oder ein Filter oben blendet es aus."))
                                               : L("Turn off a filter above to see more.", "Schalte oben einen Filter aus, um mehr zu sehen.")))
                        .padding(.top, 80)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 18)], spacing: 18) {
                        Section {
                            ForEach(shown) { game in
                                Button { model.gamePath = [game.id] } label: { GameCard(game: game) }
                                    .buttonStyle(.plain)
                            }
                        } footer: {
                            if model.canLoadMore { MoreGames(shown: shown.count) }
                        }
                    }
                    .padding(22)
                }
            }
            .navigationTitle(L("Games", "Spiele"))
            .searchable(text: $model.searchText, prompt: L("Search games", "Spiele suchen"))
            .onSubmit(of: .search) { model.searchCatalog() }
            // Beim Tippen sucht die Liste sofort in dem, was schon da ist; der Katalog wird erst gefragt, wenn
            // die Eingabe kurz stillsteht.
            .task(id: model.searchText) {
                try? await Task.sleep(for: .milliseconds(800))
                if !Task.isCancelled { model.searchCatalog() }
            }
            .navigationDestination(for: String.self) { id in
                if let game = model.allGames.first(where: { $0.id == id }) { GameDetail(game: game) }
            }
        }
    }
}

/// Das Ende der Liste, solange der Katalog noch mehr kennt: lädt die nächste Seite, sobald es in Sicht kommt.
/// Es steht im Raster, das seine Zeilen erst beim Heranscrollen anlegt – so wird nachgeladen, wenn jemand
/// tatsächlich bis hierher blättert, und nicht der ganze Katalog auf einmal.
struct MoreGames: View {
    @EnvironmentObject var model: AppModel
    let shown: Int

    var body: some View {
        HStack(spacing: 10) {
            if model.loadingMore {
                ProgressView().controlSize(.small)
                Text(L("Loading more games …", "Weitere Spiele werden geladen …")).foregroundStyle(.secondary)
            } else {
                Button(L("Show More Games", "Weitere Spiele zeigen")) { model.loadMoreCatalog() }
            }
            if model.searchText.isEmpty, let total = model.catalogTotal, total > model.catalog.count {
                Text(L("\(model.catalog.count) of \(total) games in the catalogue loaded", "\(model.catalog.count) von \(total) Spielen des Katalogs geladen"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 16)
        // Bleibt das Ende nach dem Nachladen sichtbar (großes Fenster, enger Filter), geht es von selbst weiter.
        .task(id: shown) { model.loadMoreCatalog() }
    }
}

/// Die Frage nach einer Installation: Wie läuft es? Ein Klick, auf Wunsch ein Satz dazu.
struct FeedbackBox: View {
    @EnvironmentObject var model: AppModel
    let game: Game
    @State private var comment = ""
    @State private var showFix = false

    var body: some View {
        GroupBox(L("How does it run?", "Wie läuft es?")) {
            VStack(alignment: .leading, spacing: 8) {
                if !(game.needsMetaAccount && model.onlineCatalog) {
                    // Sonderapps kennt der Katalog nicht, und ohne Katalog gibt es keinen Empfänger.
                    EmptyView()
                } else if let sent = model.feedbackSent(game) {
                    Label(L("You reported: \(label(sent)). Thank you.", "Du hast gemeldet: \(label(sent)). Danke."), systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Text(L("Tell everyone how this build runs on your Vision Pro – the label of a game follows these reports. Sent are the game, its build, the versions of app and toolchain, and your answer – nothing about you or your device.",
                           "Sag allen, wie dieser Build auf deiner Vision Pro läuft – das Kennzeichen eines Spiels richtet sich nach diesen Meldungen. Gesendet werden das Spiel, sein Build, die Versionen von App und Toolchain und deine Antwort – nichts über dich oder dein Gerät."))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField(L("A sentence about it, if you like", "Ein Satz dazu, wenn du magst"), text: $comment, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...3)
                    HStack {
                        Button(L("It works", "Es läuft")) { model.sendFeedback(game, result: .works, comment: comment) }
                        Button(L("It starts, with problems", "Es startet, mit Problemen")) { model.sendFeedback(game, result: .problems, comment: comment) }
                        Button(L("It does not start", "Es startet nicht")) { model.sendFeedback(game, result: .fails, comment: comment) }
                    }
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Not working? Let an AI assistant try to fix it.", "Läuft nicht? Lass einen KI-Assistenten versuchen, es zu reparieren."))
                        Text(L("The app writes the task for it; a working fix can go to the project for review.",
                               "Die App schreibt den Auftrag dafür; ein funktionierender Fix kann zur Prüfung an das Projekt gehen."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("Fix with AI …", "Mit KI reparieren …")) { showFix = true }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
        .sheet(isPresented: $showFix) { FixSheet(game: game).environmentObject(model) }
    }

    private func label(_ result: String) -> String {
        switch result {
        case "works": return L("it works", "es läuft")
        case "problems": return L("it starts, with problems", "es startet, mit Problemen")
        default: return L("it does not start", "es startet nicht")
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

/// Wie weit einem Spiel zu trauen ist: vom Projekt geprüft, von Nutzern bestätigt, noch offen, oder nicht lauffähig.
struct TrustBadge: View {
    let game: Game

    var body: some View {
        let (text, symbol, color, help): (String, String, Color, String) = {
            switch game.trust {
            case .verified:
                return (L("Verified", "Geprüft"), "checkmark.seal.fill", .blue,
                        L("Tested by the project on an Apple Vision Pro.", "Vom Projekt auf einer Apple Vision Pro geprüft."))
            case .community:
                return (L("Community Verified", "Von Nutzern bestätigt"), "person.2.fill", .green,
                        L("More users report that it runs than that it does not. The project has not tested it.",
                          "Mehr Nutzer melden, dass es läuft, als dass es nicht läuft. Das Projekt hat es nicht getestet."))
            case .incompatible:
                return (L("Incompatible", "Inkompatibel"), "xmark.octagon.fill", .red,
                        L("More users report that it does not run than that it does.", "Mehr Nutzer melden, dass es nicht läuft, als dass es läuft."))
            case .untested:
                return (L("Untested", "Ungetestet"), "questionmark.circle.fill", .gray,
                        L("Nobody has confirmed yet that this game runs.", "Noch hat niemand bestätigt, dass dieses Spiel läuft."))
            }
        }()
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(.white)
            .background(color.opacity(0.92), in: Capsule())
            .help(help)
    }
}

/// Der Stern: ein Spiel merken, um es über den Filter „Favoriten“ wiederzufinden.
struct FavouriteButton: View {
    @EnvironmentObject var model: AppModel
    let game: Game

    var body: some View {
        let on = model.isFavourite(game)
        Button { model.toggleFavourite(game) } label: {
            Image(systemName: on ? "star.fill" : "star")
                .font(.body.weight(.semibold))
                .foregroundStyle(on ? Color.yellow : Color.white)
                .padding(6)
                .background(.black.opacity(0.45), in: Circle())
        }
        .buttonStyle(.plain)
        .help(on ? L("Remove from favourites", "Aus den Favoriten entfernen") : L("Mark as favourite", "Als Favorit merken"))
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
    @EnvironmentObject var model: AppModel
    let game: Game
    /// Das nachgeladene Bild eines Spiels, dessen Dateien (und damit sein eigenes Bild) noch nicht auf dem Mac liegen.
    @State private var fetched: NSImage?

    var body: some View {
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                if let cover = game.cover ?? fetched {
                    Image(nsImage: cover).resizable().scaledToFill().transition(.opacity)
                } else {
                    // Ohne Bild: eine ruhige Fläche mit dem Namen, damit die Karte nicht leer wirkt.
                    LinearGradient(colors: [Color(nsColor: .controlAccentColor).opacity(0.55), Color.black.opacity(0.75)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(Text(game.recipe.title).font(.title3.bold()).foregroundStyle(.white).padding(12)
                            .multilineTextAlignment(.center))
                }
            }
            .clipped()
            .animation(.easeIn(duration: 0.25), value: fetched != nil)
            // Erst die Farbfläche, dann das Bild von der Store-Seite – nur für Karten, die gerade zu sehen sind:
            // scrollt eine aus dem Bild, endet ihre Aufgabe, und ein noch nicht begonnener Abruf entfällt.
            .task(id: game.id) {
                fetched = nil
                guard game.cover == nil, model.storePictures, let appId = game.recipe.store.appId,
                      let data = await model.covers.image(appId: appId), !Task.isCancelled else { return }
                fetched = NSImage(data: data)
            }
    }
}

struct GameCard: View {
    @EnvironmentObject var model: AppModel
    let game: Game
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CoverImage(game: game)
                .overlay(alignment: .topTrailing) { TrustBadge(game: game).padding(8) }
                .overlay(alignment: .topLeading) { FavouriteButton(game: game).padding(8) }
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
                            TrustBadge(game: game)
                            FavouriteButton(game: game)
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
                        let blocked = model.blocker(for: game)
                        if let why = blocked {
                            Text(why).font(.callout).foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing).frame(maxWidth: 280, alignment: .trailing)
                        }
                        // Nur laden: bei Spielen aus dem Meta Store immer angeboten, solange etwas fehlt – wer den
                        // Bestand erst füllen und später (oder an einem anderen Tag) bauen will, braucht dafür weder
                        // Toolchain noch Vision Pro. Bei allen anderen wie bisher nur, wenn allein dem Bauen etwas
                        // im Weg steht. Steht dem Laden dasselbe im Weg wie dem Installieren, sagt es der Text oben.
                        let downloadBlocked = model.downloadBlocker(for: game)
                        if model.hasDownloads(game), !model.isBusy(game.id),
                           blocked == nil ? game.needsMetaAccount : downloadBlocked != blocked {
                            Button(action: { model.download(game) }) {
                                Text(L("Download Only", "Nur herunterladen")).frame(minWidth: 150)
                            }
                            .controlSize(.large)
                            .disabled(downloadBlocked != nil)
                            Text(downloadBlocked
                                 ?? (blocked == nil
                                     ? L("\(Installer.gigabytes(game.status.bytesToDownload)) – fetches the files to this Mac; nothing is built or installed.",
                                         "\(Installer.gigabytes(game.status.bytesToDownload)) – holt die Dateien auf diesen Mac; gebaut und installiert wird nichts.")
                                     : L("\(Installer.gigabytes(game.status.bytesToDownload)) – this already works; building and installing follow later.",
                                         "\(Installer.gigabytes(game.status.bytesToDownload)) – das geht schon jetzt; gebaut und installiert wird später.")))
                                .font(.callout).foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing).frame(maxWidth: 280, alignment: .trailing)
                        }
                    }
                }

                if game.draft { untestedBox }
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
                        } else if !game.prepared {
                            row(L("Files", "Dateien"), L("not looked up yet", "noch nicht nachgeschlagen"))
                        } else if game.status.filesPresent < game.status.filesRequired {
                            row(L("Still to download", "Noch zu laden"),
                                game.status.filesRequired - game.status.filesPresent == 1
                                    ? L("one file, size not known in advance", "eine Datei, Größe vorab nicht bekannt")
                                    : L("\(game.status.filesRequired - game.status.filesPresent) files, size not known in advance",
                                        "\(game.status.filesRequired - game.status.filesPresent) Dateien, Größe vorab nicht bekannt"))
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

                if !languageFiles.isEmpty || game.recipe.addons != nil || !extras.isEmpty { optionalContent }

                if game.installed { FeedbackBox(game: game) }

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
        // Erst wenn jemand die Seite eines ungetesteten Spiels öffnet, wird nachgeschlagen, woraus es besteht.
        // Sagt der Katalog erst danach, unter welchem Namen die Toolchain das Spiel kennt, wird noch einmal geprüft.
        .task(id: "\(game.id) \(game.catalog?.target ?? "")") { model.prepare(game) }
        .confirmationDialog(L("Remove the files of \(game.recipe.title) from this Mac?", "Die Dateien von \(game.recipe.title) von diesem Mac entfernen?"),
                            isPresented: $confirmRemove) {
            Button(L("Remove \(Installer.gigabytes(game.storeBytes))", "\(Installer.gigabytes(game.storeBytes)) entfernen"), role: .destructive) { model.removeFiles(game) }
        } message: {
            Text(removeWarning)
        }
    }

    /// Was über ein ungetestetes Spiel zu sagen ist: dass es ein Versuch ist, was gerade nachgeschlagen wird, was
    /// andere melden und was das Projekt dazu notiert hat.
    private var untestedBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label(game.incompatible ? L("This game is reported not to work at the moment", "Dieses Spiel läuft nach den Meldungen derzeit nicht")
                      : game.trust == .community ? L("Users report that this game works", "Nutzer melden, dass dieses Spiel läuft")
                      : L("Nobody has tested this game yet", "Dieses Spiel hat noch niemand getestet"),
                      systemImage: game.incompatible ? "xmark.octagon" : game.trust == .community ? "person.2" : "flask")
                    .font(.headline)
                Text(L("You can try it. Each of the verified games needed its own adjustments before it ran, so a game the project has not tested may well not start. Afterwards, say how it went: when more people report that a game works than that it does not, it becomes “Community Verified”, the other way round “Incompatible”.",
                       "Du kannst es versuchen. Jedes der geprüften Spiele brauchte eigene Anpassungen, bevor es lief – ein vom Projekt nicht getestetes startet also womöglich nicht. Sag danach, wie es lief: Melden mehr Leute, dass ein Spiel läuft, als dass es nicht läuft, wird es „Von Nutzern bestätigt“, umgekehrt „Inkompatibel“."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let c = game.catalog, c.works + c.problems + c.fails > 0 {
                    Text(L("Reports from users: \(c.works) say it works, \(c.problems) report problems, \(c.fails) say it does not start.",
                           "Meldungen von Nutzern: \(c.works) sagen, es läuft, \(c.problems) melden Probleme, \(c.fails) sagen, es startet nicht."))
                        .font(.callout)
                }
                if let note = game.catalog?.note { Label(note, systemImage: "text.bubble").font(.callout) }
                if game.prepared, DraftRecipe.isGeneric(game.recipe.toolchain.target) {
                    Label(L("The toolchain has no entry of its own for this game. It is built with general settings for its engine – the least certain kind of attempt.",
                            "Die Toolchain hat für dieses Spiel keinen eigenen Eintrag. Es wird mit allgemeinen Einstellungen für seine Engine gebaut – die unsicherste Art von Versuch."),
                          systemImage: "wand.and.stars").font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                if model.preparing.contains(game.id) {
                    HStack { ProgressView().controlSize(.small); Text(model.prepareNote[game.id] ?? "").font(.callout) }
                } else if let note = model.prepareNote[game.id] {
                    Label(note, systemImage: "info.circle").font(.callout).fixedSize(horizontal: false, vertical: true)
                } else if game.prepared {
                    Label(game.recipe.files.count == 1
                            ? L("Build \(game.recipe.versionName): one file (the APK), as Meta's tool lists it.",
                                "Build \(game.recipe.versionName): eine Datei (das APK), wie Metas Werkzeug sie nennt.")
                            : L("Build \(game.recipe.versionName): \(game.recipe.files.count) files, as Meta's tool lists them.",
                                "Build \(game.recipe.versionName): \(game.recipe.files.count) Dateien, wie Metas Werkzeug sie nennt."),
                          systemImage: "checkmark.circle").font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
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
        switch game.trust {
        case .verified: return L("Verified: the project has tested this game on an Apple Vision Pro.", "Geprüft: Das Projekt hat dieses Spiel auf einer Apple Vision Pro getestet.")
        case .community: return L("Community Verified: more users report that it runs than that it does not. The project has not tested it.", "Von Nutzern bestätigt: Mehr Nutzer melden, dass es läuft, als dass es nicht läuft. Das Projekt hat es nicht getestet.")
        case .incompatible: return L("Incompatible: more users report that it does not run than that it does.", "Inkompatibel: Mehr Nutzer melden, dass es nicht läuft, als dass es läuft.")
        case .untested: return L("Untested: nobody has confirmed yet that this game runs. You can try it.", "Ungetestet: Noch hat niemand bestätigt, dass dieses Spiel läuft. Du kannst es versuchen.")
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

    private var extras: [RecipeFile] { AppModel.extras(of: game.recipe) }

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
                ForEach(extras, id: \.name) { file in
                    if file.name != extras.first?.name || !languageFiles.isEmpty { Divider() }
                    ExtraContentRow(game: game, file: file)
                }
                if game.recipe.addons != nil {
                    if !extras.isEmpty { Divider() }
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
                    if game.installed {
                        Divider()
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("Bought something new?", "Etwas Neues gekauft?"))
                                Text(model.syncBlocker(for: game)
                                     ?? L("Asks Meta again what you have purchased, downloads what is missing and adds it to the installed game – without building it again.",
                                          "Fragt Meta neu, was du gekauft hast, lädt das Fehlende und legt es zum installierten Spiel – ohne es neu zu bauen."))
                                    .font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Button(L("Sync DLCs", "DLCs abgleichen")) { model.syncAddons(game) }
                                .disabled(model.syncBlocker(for: game) != nil)
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
                if SteamFetcher.usesSteam(game.recipe) {
                    Divider()
                    SteamFetchRow(game: game)
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

/// Eine wählbare Datei mit eigenem Namen – etwa eine Sprachausgabe von Fans: der Haken, und darunter, was noch zu
/// tun bleibt, bis sie auf der Vision Pro liegt.
struct ExtraContentRow: View {
    @EnvironmentObject var model: AppModel
    let game: Game
    let file: RecipeFile

    var body: some View {
        let chosen = model.options(for: game)
        let on = chosen.optionalNames.contains(file.name)
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { on }, set: { want in
                var next = chosen
                next.optionalNames = want ? Set(chosen.optionalNames + [file.name]).sorted() : chosen.optionalNames.filter { $0 != file.name }
                model.setOptions(next, for: game)
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text((file.title?.text ?? file.name) + (file.size.map { " · \(Installer.gigabytes($0))" } ?? ""))
                    if let hint = file.source?.hint?.text {
                        Text(hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Group { if on { next } else { leftovers } }.padding(.leading, 20)
        }
    }

    /// Ohne Haken: was von der Datei noch herumliegt, und wie man es loswird.
    @ViewBuilder private var leftovers: some View {
        if model.inLibrary(file, of: game) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("Still on this Mac\(file.size.map { " (\(Installer.gigabytes($0)))" } ?? "").",
                       "Liegt noch auf diesem Mac\(file.size.map { " (\(Installer.gigabytes($0)))" } ?? "")."))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(L("Remove from This Mac", "Von diesem Mac entfernen")) { model.removeFromLibrary(file, of: game) }
                    .controlSize(.small)
                    .disabled(model.isBusy(game.id) || model.steamBusy.contains(game.id))
            }
        }
        if file.clearable == true, game.installed {
            if case .current = game.status.onDevice {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.extrasBlocker(for: game)
                         ?? L("If it is on the Vision Pro, “Remove from Vision Pro” frees its space there; the game clears away the rest the next time it starts.",
                              "Liegt sie auf der Vision Pro, gibt „Von der Vision Pro entfernen“ ihren Platz dort frei; den Rest räumt das Spiel beim nächsten Start weg."))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L("Remove from Vision Pro", "Von der Vision Pro entfernen")) { model.syncExtras(game) }
                        .controlSize(.small)
                        .disabled(model.extrasBlocker(for: game) != nil)
                }
            } else {
                Text(L("If it is on the Vision Pro, “Update” above takes it off there as well.",
                       "Liegt sie auf der Vision Pro, nimmt „Aktualisieren“ oben sie auch dort wieder weg."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Was nach dem Haken kommt: holen, dann aufs Gerät.
    @ViewBuilder private var next: some View {
        if model.inLibrary(file, of: game) {
            if case .current = game.status.onDevice {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.extrasBlocker(for: game)
                         ?? L("On this Mac. “Copy to Vision Pro” adds it to the installed game without building it again.",
                              "Liegt auf diesem Mac. „Auf die Vision Pro kopieren“ legt sie zum installierten Spiel, ohne es neu zu bauen."))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L("Copy to Vision Pro", "Auf die Vision Pro kopieren")) { model.syncExtras(game) }
                        .disabled(model.extrasBlocker(for: game) != nil)
                }
            } else {
                Text(game.installed
                     ? L("On this Mac. “Update” above builds the game again and brings it along.",
                         "Liegt auf diesem Mac. „Aktualisieren“ oben baut das Spiel neu und bringt sie mit.")
                     : L("On this Mac. It is copied to the Vision Pro when the game is installed.",
                         "Liegt auf diesem Mac. Beim Installieren des Spiels kommt sie mit auf die Vision Pro."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else if file.source?.kind == .user {
            if file.source?.steam != nil, !game.status.userProvidedMissing.isEmpty {
                // Die Dateien des Spiels fehlen auch noch: ein Abruf holt beides, und der Knopf dafür steht oben.
                Text(L("Not on this Mac yet. “Download from Steam” above fetches it together with the game.",
                       "Liegt noch nicht auf diesem Mac. „Von Steam laden“ oben holt sie zusammen mit dem Spiel."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if file.source?.steam != nil {
                SteamFetchRow(game: game, headline: L("Not on this Mac yet.", "Liegt noch nicht auf diesem Mac."))
            }
            Button(L("Choose Folder …", "Ordner auswählen …")) {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.message = L("Choose the folder that contains “\(file.name)”. It is copied into this app’s library.",
                                  "Ordner wählen, in dem „\(file.name)“ liegt. Die Datei wird in den Bestand dieses Programms kopiert.")
                if panel.runModal() == .OK, let url = panel.url { model.adopt(game, from: url) }
            }
            .controlSize(.small)
        }
    }
}
