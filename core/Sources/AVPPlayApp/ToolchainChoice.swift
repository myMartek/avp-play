import AVPPlayCore
import SwiftUI

extension AppModel {
    /// Was ein Aufräumen neben dem Stand offener Aufträge stehen lassen muss: die Pakete, die für ein Spiel gewählt
    /// sind – frisch gelesen, denn auch die Kommandozeile kann wählen – und die, die gerade für eines ankommen.
    var keptToolchainCommits: Set<String> {
        ToolchainChoices.load().packageCommits.union(toolchainChoices.packageCommits).union(toolchainArriving.values.map(\.commit))
    }

    /// Die Toolchain, mit der dieses Spiel gebaut wird: die dafür gewählte, sonst die neueste. `nil`, wenn keine
    /// installiert ist – oder die gewählte nicht mehr da ist; dann sagt `blocker(for:)`, was zu tun ist.
    func toolchain(for game: Game) -> Toolchain? {
        guard let pin = toolchainChoices.games[game.id] else { return toolchain }
        return paths.packager.toolchain(for: pin)
    }

    /// Fragt GitHub, welche Toolchain-Pakete mit früheren Veröffentlichungen von AVP Play kamen. Nur auf Wunsch.
    func loadReleasedToolchains() {
        guard !releasedToolchainsLoading else { return }
        releasedToolchainsLoading = true
        Task {
            do {
                releasedToolchains = try await ToolchainReleases.list()
            } catch {
                notice = "\(error)"
            }
            releasedToolchainsLoading = false
        }
    }

    /// Wählt, mit welcher Toolchain ein Spiel gebaut wird. Auf der Vision Pro ändert das nichts, bis installiert wird.
    func chooseToolchain(_ game: Game, _ option: ToolchainOption) {
        guard option.kind != .missing, toolchainArriving[game.id] == nil else { return }
        guard !isBusy(game.id) else {
            toolchainNote[game.id] = L("A job for this game is running. Choose the toolchain when it has finished.",
                                       "Für dieses Spiel läuft gerade ein Auftrag. Wähle die Toolchain, wenn er fertig ist.")
            return
        }
        toolchainNote[game.id] = nil
        let packager = paths.packager
        switch option.kind {
        case .newest:
            setToolchain(nil, for: game)
        case .installed:
            guard let chosen = packager.installed().first(where: { $0.commit() == option.commit && !$0.isModified }) else { return refresh() }
            setToolchain(packager.pin(for: chosen), for: game)
        case .copy:
            guard let path = option.path, let chosen = try? Toolchain(root: URL(fileURLWithPath: path, isDirectory: true)) else { return refresh() }
            setToolchain(packager.pin(for: chosen), for: game)
        case .released:
            guard let package = releasedToolchains?.first(where: { $0.commit == option.commit }) else { return }
            let need = game.recipe.toolchain.minCommit
            toolchainArriving[game.id] = package
            Task.detached(priority: .userInitiated) {
                var chosen: Toolchain?
                var problem: String?
                do {
                    let installed = try await ToolchainReleases.install(package, with: packager)
                    if need.isEmpty || installed.satisfies(minCommit: need) {
                        chosen = installed
                    } else {
                        problem = L("Toolchain \(package.version) cannot build this game: its recipe needs a newer one.",
                                    "Toolchain \(package.version) kann dieses Spiel nicht bauen: Sein Rezept braucht eine neuere.")
                    }
                } catch {
                    problem = L("Toolchain \(package.version) could not be downloaded and installed: \(error)",
                                "Toolchain \(package.version) ließ sich nicht laden und installieren: \(error)")
                }
                let result = chosen, why = problem
                await MainActor.run {
                    if let result { self.setToolchain(packager.pin(for: result), for: game) }
                    // Erst nach der Wahl freigeben: Dazwischen dürfte ein Aufräumen das Paket für überzählig halten.
                    self.toolchainArriving[game.id] = nil
                    self.toolchainNote[game.id] = why
                    self.scanStorageIfShown()
                }
            }
        case .missing:
            break
        }
    }

    private func scanStorageIfShown() { if section == .data { scanStorage() } }

    /// Schreibt die Wahl und bestimmt den Stand dieses einen Spiels neu, mit dem, was über das Gerät bekannt ist.
    private func setToolchain(_ pin: ToolchainChoices.Pin?, for game: Game) {
        var choices = ToolchainChoices.load()
        choices.choose(pin, for: game.id)
        do {
            try choices.save()
        } catch {
            toolchainNote[game.id] = "\(error.localizedDescription)"
            return
        }
        toolchainChoices = choices
        guard var fresh = allGames.first(where: { $0.id == game.id }) ?? games.first(where: { $0.id == game.id }) else { return }
        fresh.status = GameStatus.of(recipe: fresh.recipe, store: paths.store, apps: installedApps, toolchainVersion: toolchainRevision,
                                     pin: pin, bundlePrefix: bundlePrefix, otherSourceBuilds: Set(fresh.otherSourceBuilds),
                                     experimental: experimentalExpected, metalFX: metalFXExpected)
        replace(fresh)
    }
}

/// Die Toolchain eines Spiels: womit es gebaut wird, und die Wahl einer anderen als der neuesten – eines älteren
/// Pakets (von diesem Mac oder von GitHub) oder einer bearbeiteten Arbeitskopie.
struct ToolchainBox: View {
    @EnvironmentObject var model: AppModel
    let game: Game
    @State private var options = ToolchainOptions()
    @State private var expanded = false

    private var pin: ToolchainChoices.Pin? { model.toolchainChoices.games[game.id] }

    private func megabytes(_ bytes: Int64?) -> String {
        bytes.map { L(", \(max(1, $0 / 1_000_000)) MB to download", ", \(max(1, $0 / 1_000_000)) MB zu laden") } ?? ""
    }

    private func label(_ o: ToolchainOption) -> String {
        let name = Toolchain.name(version: o.version, modified: o.modified)
        switch o.kind {
        case .newest: return L("Always the newest (now \(o.version)) – recommended", "Immer die neueste (jetzt \(o.version)) – empfohlen")
        case .installed:
            return o.commit == options.newest?.commit ? L("Version \(name) – stay on this one", "Version \(name) – bei dieser bleiben")
                                                      : L("Version \(name)", "Version \(name)")
        case .copy: return L("Version \(name) – \(folder(o))", "Version \(name) – \(folder(o))")
        case .released:
            return L("Version \(name) – from AVP Play \(o.appVersion ?? "?")\(megabytes(o.size))",
                     "Version \(name) – aus AVP Play \(o.appVersion ?? "?")\(megabytes(o.size))")
        case .missing: return L("Version \(name) – no longer on this Mac", "Version \(name) – nicht mehr auf diesem Mac")
        }
    }

    /// Der Ordner einer Arbeitskopie, kurz: mit `~` für den eigenen Benutzerordner.
    private func folder(_ o: ToolchainOption) -> String {
        guard let path = o.path else { return "" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private var all: [ToolchainOption] {
        [options.newest, options.missing].compactMap { $0 } + options.installed + options.copies + options.released
    }

    private var selection: Binding<String> {
        Binding(get: {
            guard let pin else { return ToolchainOption.newestId }
            return options.missing != nil ? ToolchainOption.missingId : ToolchainOption.key(for: pin)
        }, set: { id in
            if let option = all.first(where: { $0.id == id }) { model.chooseToolchain(game, option) }
        })
    }

    var body: some View {
        GroupBox("Toolchain") {
            VStack(alignment: .leading, spacing: 8) {
                summary
                if let arriving = model.toolchainArriving[game.id] {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(L("Downloading toolchain \(arriving.version) from GitHub and checking it …",
                               "Toolchain \(arriving.version) wird von GitHub geladen und geprüft …")).font(.callout)
                    }
                }
                if let note = model.toolchainNote[game.id] {
                    Label(note, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup(L("Choose the toolchain for this game", "Toolchain für dieses Spiel wählen"), isExpanded: $expanded) {
                    chooser.padding(.top, 6)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
        // Neu bestimmt wird, wenn sich die Wahl, die installierten Pakete oder die Liste von GitHub ändern.
        .task(id: "\(game.id) \(pin.map(ToolchainOption.key(for:)) ?? "") \(model.toolchainText ?? "") \(model.releasedToolchains?.count ?? -1) \(model.toolchainArriving[game.id]?.commit ?? "")") {
            let recipe = game.recipe, pin = pin, paths = model.paths, released = model.releasedToolchains
            options = await Task.detached(priority: .userInitiated) {
                ToolchainOptions.make(recipe: recipe, pin: pin, packager: paths.packager, newest: paths.toolchain(), released: released)
            }.value
            if pin != nil || Snapshot.directory != nil { expanded = true }
        }
    }

    @ViewBuilder private var summary: some View {
        let newest = options.newest.map { String($0.version) } ?? "?"
        if let pin {
            Label(!pin.modified && pin.commit == options.newest?.commit
                  ? L("This game stays on toolchain \(pin.name) – the newest right now.",
                      "Dieses Spiel bleibt bei Toolchain \(pin.name) – im Moment die neueste.")
                  : L("This game is built with toolchain \(pin.name), not with the newest (\(newest)).",
                      "Dieses Spiel wird mit Toolchain \(pin.name) gebaut, nicht mit der neuesten (\(newest))."),
                  systemImage: "pin.fill").font(.headline)
            Text(pin.modified
                 ? L("“Modified” means: a working copy that somebody changed – for example an AI assistant fixing this game – and not a toolchain as the project released it. The game stays on it when AVP Play gets a newer toolchain, when the game is updated and when its signature is renewed. Keep its folder; without it the game cannot be built again.",
                     "„Modifiziert“ heißt: eine Arbeitskopie, an der jemand etwas geändert hat – etwa ein KI-Assistent beim Reparieren dieses Spiels – und keine Toolchain, wie das Projekt sie veröffentlicht hat. Das Spiel bleibt dabei, wenn AVP Play eine neuere Toolchain bekommt, wenn das Spiel aktualisiert und wenn seine Signatur erneuert wird. Behalte ihren Ordner; ohne ihn lässt sich das Spiel nicht mehr bauen.")
                 : L("The game stays on it when AVP Play gets a newer toolchain, when the game is updated and when its signature is renewed, and this toolchain is not removed when the app tidies up. Fixes and settings of newer toolchains do not reach this game until you go back to the newest.",
                     "Das Spiel bleibt dabei, wenn AVP Play eine neuere Toolchain bekommt, wenn das Spiel aktualisiert und wenn seine Signatur erneuert wird, und diese Toolchain wird beim Aufräumen nicht entfernt. Korrekturen und Einstellungen neuerer Toolchains erreichen dieses Spiel erst, wenn du zur neuesten zurückkehrst."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let path = options.copies.first(where: { $0.id == ToolchainOption.key(for: pin) })?.path {
                HStack {
                    Text(folder(ToolchainOption(id: "", kind: .copy, version: 0, commit: "", path: path))).foregroundStyle(.secondary).textSelection(.enabled)
                    Button(L("Show in Finder", "Im Finder zeigen")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                        .controlSize(.small)
                }
            }
            Button(L("Use the Newest Toolchain Again", "Wieder die neueste Toolchain verwenden")) {
                if let newest = options.newest { model.chooseToolchain(game, newest) }
            }
            .disabled(options.newest == nil || model.toolchainArriving[game.id] != nil)
        } else if let built = game.status.builtWith, built.modified {
            Label(L("The build on the Vision Pro was made with toolchain \(Toolchain.name(version: built.toolchain, modified: true)).",
                    "Der Bau auf der Vision Pro stammt von Toolchain \(Toolchain.name(version: built.toolchain, modified: true))."),
                  systemImage: "exclamationmark.triangle").font(.headline).foregroundStyle(.orange)
            Text(L("That is a working copy somebody changed, for example an AI assistant fixing this game. “Update” replaces the build with one from the newest toolchain (\(newest)), without those changes; “Update All” and the renewal of signatures leave it alone. To keep building from the working copy, choose it below.",
                   "Das ist eine Arbeitskopie, an der jemand etwas geändert hat, etwa ein KI-Assistent beim Reparieren dieses Spiels. „Aktualisieren“ ersetzt den Bau durch einen aus der neuesten Toolchain (\(newest)), ohne diese Änderungen; „Alle aktualisieren“ und das Erneuern der Signaturen lassen ihn in Ruhe. Um weiter aus der Arbeitskopie zu bauen, wähle sie unten."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            Text(L("This game is built with the newest toolchain (\(newest)).", "Dieses Spiel wird mit der neuesten Toolchain gebaut (\(newest))."))
        }
    }

    @ViewBuilder private var chooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L("Build with", "Bauen mit"), selection: selection) {
                if let newest = options.newest { Text(label(newest)).tag(newest.id) }
                if let missing = options.missing { Text(label(missing)).tag(missing.id) }
                if !options.installed.isEmpty {
                    Section(L("On this Mac", "Auf diesem Mac")) {
                        ForEach(options.installed) { Text(label($0)).tag($0.id) }
                    }
                }
                if !options.copies.isEmpty {
                    Section(L("Modified working copies on this Mac", "Bearbeitete Arbeitskopien auf diesem Mac")) {
                        ForEach(options.copies) { Text(label($0)).tag($0.id) }
                    }
                }
                if !options.released.isEmpty {
                    Section(L("Older ones from GitHub – downloaded when chosen", "Ältere von GitHub – geladen, wenn gewählt")) {
                        ForEach(options.released) { Text(label($0)).tag($0.id) }
                    }
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 520, alignment: .leading)
            .disabled(model.toolchainArriving[game.id] != nil)
            Text(L("Which toolchain builds this game – when it is installed or updated and when its signature is renewed. Only toolchains that can build this game's recipe are listed. A change does nothing on the Vision Pro until you install; saved games and data are kept. The project tests each game with the newest toolchain: an older one lacks later fixes and settings.",
                   "Welche Toolchain dieses Spiel baut – beim Installieren, beim Aktualisieren und wenn seine Signatur erneuert wird. Zur Wahl steht nur, womit sich das Rezept dieses Spiels bauen lässt. Ein Wechsel ändert nichts auf der Vision Pro, bis du installierst; Spielstände und Daten bleiben. Das Projekt prüft jedes Spiel mit der neuesten Toolchain: Einer älteren fehlen spätere Korrekturen und Einstellungen."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if model.releasedToolchainsLoading {
                    ProgressView().controlSize(.small)
                } else if model.releasedToolchains == nil {
                    Button(L("Show Older Toolchains from GitHub", "Ältere Toolchains von GitHub zeigen")) { model.loadReleasedToolchains() }
                } else if options.released.isEmpty {
                    Text(L("GitHub has no older toolchain that can build this game and is not on this Mac already.",
                           "GitHub hat keine ältere Toolchain, die dieses Spiel bauen kann und nicht schon auf diesem Mac liegt."))
                        .foregroundStyle(.secondary)
                }
            }
            Text(L("Older toolchains come from the releases of AVP Play on GitHub (github.com/myMartek/avp-play). The list is fetched when you ask for it, a package when you choose it; nothing else is sent. A package is checked against its checksum before it is installed.",
                   "Ältere Toolchains kommen aus den Veröffentlichungen von AVP Play auf GitHub (github.com/myMartek/avp-play). Die Liste wird geholt, wenn du danach fragst, ein Paket, wenn du es wählst; sonst wird nichts gesendet. Ein Paket wird vor dem Installieren gegen seine Prüfsumme geprüft."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
