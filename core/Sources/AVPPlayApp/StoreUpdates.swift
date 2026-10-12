import AVPPlayCore
import Foundation

/// Eine Fassung, die auf der Seite eines Spiels zur Wahl steht.
struct GameVersion: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Mit einem eigenen Rezept des Projekts: auf einer Vision Pro geprüft.
        case verified
        /// Aus dem Store, wie Meta sie nennt: mit AVP Play nicht getestet.
        case store
    }
    let versionCode: Int
    let versionName: String
    let kind: Kind
    /// Die Fassung, die ohne Wahl gilt.
    let isDefault: Bool
    var id: Int { versionCode }
}

/// Die Fassungen eines Spiels: nachsehen, was der Store führt, anbieten, wählen lassen.
extension AppModel {
    private static let checkedKey = "storeBuildsChecked"
    private static let cacheKey = "storeBuildsCache"
    private static let listsKey = "storeBuildListsCache"
    /// Wann für ein Spiel zuletzt nachgesehen wurde (nur für diese Sitzung).
    private static var asked: [String: Double] = [:]

    /// Die geprüfte Fassung eines Spiels, auch wenn gerade die neueste gewählt ist.
    func testedRecipe(_ game: Game) -> Recipe? {
        guard !game.draft, let recipes = paths.recipes else { return nil }
        return try? RecipeStore(directory: recipes).load(id: game.id)
    }

    /// Der neuere Build aus dem Store, der für dieses Spiel angeboten werden kann – gemessen an der Fassung, die
    /// gerade gilt. `nil`, wenn es keinen gibt, das Spiel bei seiner Fassung bleibt oder noch nicht nachgesehen wurde.
    func storeUpdate(for game: Game) -> CatalogBuild? {
        // Eine Fassung, zu der das Projekt selbst ein Rezept führt, ist kein ungetestetes Angebot: Wer bewusst eine
        // ältere geprüfte gewählt hat, findet die neuere in der Liste der Fassungen.
        guard !game.draft, let build = storeBuilds[game.id], StoreUpdate.isOffered(build, for: game.recipe),
              !game.verifiedVersions.contains(where: { $0.versionCode == build.versionCode }) else { return nil }
        return build
    }

    /// Sieht nach, welchen Build der Store für die geprüften Spiele gerade führt.
    ///
    /// Für Spiele, die dem angemeldeten Meta-Konto gehören, wird Meta selbst gefragt (`MetaClient.latestBuild`,
    /// nach der Kontoprüfung; der erste unerwartete Ausgang beendet die Fragen an Meta für diese Runde). Für alle anderen, und wo Meta nichts nennt, gilt der Katalog des Projekts – der aus
    /// einer öffentlichen Versionsdatenbank schöpft und Tage bis Wochen zurückliegen kann.
    /// Von selbst höchstens alle zwanzig Stunden; für ein einzelnes Spiel, dessen Seite geöffnet wurde, höchstens
    /// alle dreißig Minuten.
    func checkStoreVersions(only game: Game? = nil) {
        guard onlineCatalog else { return }
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.cacheKey), storeBuilds.isEmpty,
           let cached = try? JSONDecoder().decode([String: CatalogBuild].self, from: data) {
            storeBuilds = cached
        }
        if let data = defaults.data(forKey: Self.listsKey), storeBuildLists.isEmpty,
           let cached = try? JSONDecoder().decode([String: [CatalogBuild]].self, from: data) {
            storeBuildLists = cached
        }
        let now = Date().timeIntervalSince1970
        let wanted: [Game]
        if let game {
            guard now - (Self.asked[game.id] ?? 0) > 30 * 60 else { return }
            wanted = [game]
        } else if now - defaults.double(forKey: Self.checkedKey) > 20 * 3600 {
            wanted = games
        } else {
            return
        }
        // Von selbst nur für Spiele mit geprüftem Rezept. Für ein ungetestetes wird gefragt, wenn jemand seine Seite
        // öffnet und es dem Konto gehört – dort steht dann die Liste der Fassungen zur Wahl.
        let list = wanted.filter { (!$0.draft || game != nil) && $0.recipe.store.appId != nil && $0.recipe.store.pinned != true }
            .compactMap { g in g.recipe.store.appId.map { (g.id, $0) } }
        let draftIds = Set(wanted.filter(\.draft).map(\.id))
        guard !list.isEmpty else { return }
        if game == nil { defaults.set(now, forKey: Self.checkedKey) }
        for (id, _) in list { Self.asked[id] = now }
        let client = catalogClient
        let signedIn = account == .signedIn
        let owned = Set(ownership.filter { $0.value.owned }.keys)
        Task.detached(priority: .utility) {
            var meta: MetaClient?
            if signedIn, list.contains(where: { owned.contains($0.1) }), let token = try? TokenStore().read() {
                let candidate = MetaClient(token: token)
                if (try? await candidate.me()) != nil { meta = candidate }
            }
            var found: [String: CatalogBuild] = [:]
            var lists: [String: [CatalogBuild]] = [:]
            for (id, appId) in list {
                var build: CatalogBuild?
                if let asked = meta, owned.contains(appId) {
                    // Dieselbe eine Abfrage wie bisher; ihre Antwort nennt alle Fassungen, nicht nur die neueste.
                    do {
                        let all = try await asked.builds(appId: appId)
                        build = all.first
                        if !all.isEmpty { lists[id] = all }
                    } catch { meta = nil }
                }
                // Ein ungetestetes Spiel kennt den Build des Katalogs schon; dort wird nur Metas Liste gebraucht.
                if build == nil, !draftIds.contains(id) {
                    build = try? await client.game(appId: appId).build
                    try? await Task.sleep(for: .milliseconds(300))
                }
                if let build { found[id] = build }
            }
            let result = found, resultLists = lists
            await MainActor.run {
                if !result.isEmpty {
                    self.storeBuilds.merge(result) { _, new in new }
                    if let data = try? JSONEncoder().encode(self.storeBuilds) { defaults.set(data, forKey: Self.cacheKey) }
                }
                if !resultLists.isEmpty {
                    self.storeBuildLists.merge(resultLists) { _, new in new }
                    if let data = try? JSONEncoder().encode(self.storeBuildLists) { defaults.set(data, forKey: Self.listsKey) }
                }
            }
        }
    }

    // MARK: Die Wahl der Fassung

    /// Was für ein Spiel zur Wahl steht: zuerst die Fassungen mit eigenem Rezept des Projekts (die ohne Wahl
    /// geltende voran), dann die übrigen, die der Store nennt, die neueste zuerst. Die gerade verwendete steht
    /// immer dabei, auch wenn der Store sie nicht mehr nennt.
    func versions(for game: Game) -> [GameVersion] {
        guard game.recipe.store.appId != nil, game.recipe.store.pinned != true else { return [] }
        var list = game.verifiedVersions
        var known = Set(list.map(\.versionCode))
        var store = storeBuildLists[game.id] ?? []
        if store.isEmpty, let one = storeBuilds[game.id] ?? game.catalog?.build { store = [one] }
        var others: [GameVersion] = []
        // Bei einem Spiel ohne Rezept gilt ohne Wahl der neueste Build, den der Katalog kennt.
        let draftDefault = game.draft ? game.catalog?.build?.versionCode : nil
        for build in store where known.insert(build.versionCode).inserted {
            others.append(GameVersion(versionCode: build.versionCode, versionName: build.version, kind: .store,
                                      isDefault: build.versionCode == draftDefault))
        }
        if game.prepared, known.insert(game.recipe.versionCode).inserted {
            others.append(GameVersion(versionCode: game.recipe.versionCode, versionName: game.recipe.versionName, kind: .store,
                                      isDefault: game.recipe.versionCode == draftDefault))
        }
        list += others.sorted { $0.versionCode > $1.versionCode }
        return list
    }

    /// Wählt die Fassung, mit der ein Spiel geladen und installiert wird. Eine Fassung mit eigenem Rezept gilt
    /// sofort; für eine andere aus dem Store wird – einmal je Fassung – Metas Werkzeug nach ihren Dateien gefragt.
    /// Geladen und installiert wird erst, wenn der Nutzer es danach verlangt.
    func chooseVersion(_ game: Game, versionCode: Int) {
        guard versionCode != game.recipe.versionCode, !preparing.contains(game.id),
              let wanted = versions(for: game).first(where: { $0.versionCode == versionCode }) else { return }
        guard !isBusy(game.id) else {
            prepareNote[game.id] = L("A job for this game is running. Switch versions when it has finished.",
                                     "Für dieses Spiel läuft gerade ein Auftrag. Wechsle die Fassung, wenn er fertig ist.")
            return
        }
        if game.draft {
            // Ein Spiel ohne Rezept: die Wahl merken und den Entwurf für diese Fassung neu nachschlagen (prepare).
            var choices = StoreUpdate.Choices.load()
            choices.choose(wanted.isDefault ? nil : versionCode, for: game.id)
            try? choices.save()
            latestChoices = choices
            prepare(game)
            return
        }
        if wanted.kind == .verified {
            setChoice(wanted.isDefault ? nil : versionCode, for: game)
            return
        }
        // Schon einmal nachgeschlagen: das Rezept liegt bei den Entwürfen, Meta wird nicht noch einmal gefragt.
        let drafts = draftsDirectory
        if let tested = testedRecipe(game),
           StoreUpdate.resolve([tested], drafts: drafts, choices: .init(versions: [game.id: versionCode])).first?.versionCode == versionCode {
            setChoice(versionCode, for: game)
            return
        }
        guard let build = (storeBuildLists[game.id] ?? storeBuilds[game.id].map { [$0] } ?? []).first(where: { $0.versionCode == versionCode }) else { return }
        useStoreVersion(game, build: build)
    }

    private func setChoice(_ versionCode: Int?, for game: Game) {
        var choices = StoreUpdate.Choices.load()
        choices.choose(versionCode, for: game.id)
        try? choices.save()
        latestChoices = choices
        prepareNote[game.id] = nil
        refresh()
    }

    /// Wählt für ein geprüftes Spiel die neueste Fassung aus dem Store.
    func useNewestVersion(_ game: Game) {
        guard let build = storeUpdate(for: game) else { return }
        chooseVersion(game, versionCode: build.versionCode)
    }

    /// Schlägt eine Fassung aus dem Store nach und wählt sie: fragt Metas Werkzeug nach ihren Dateien und legt
    /// daraus ein Rezept an, das wie das geprüfte angeordnet ist.
    private func useStoreVersion(_ game: Game, build: CatalogBuild) {
        guard let tested = testedRecipe(game), let appId = tested.store.appId, !preparing.contains(game.id) else { return }
        guard account == .signedIn else {
            prepareNote[game.id] = L("Sign in to Meta under “Setup” first – then the app can look up the files of this version.",
                                     "Melde dich zuerst unter „Einrichtung“ bei Meta an – dann kann die App die Dateien dieser Fassung nachschlagen.")
            return
        }
        preparing.insert(game.id)
        prepareNote[game.id] = L("Asking Meta whether you own this game …", "Meta wird gefragt, ob dir das Spiel gehört …")
        let drafts = draftsDirectory
        let tool = Probe.metaToolURL
        let id = game.id
        Task.detached {
            func say(_ text: String) async { await MainActor.run { self.prepareNote[id] = text } }
            var note: String?
            do {
                let token = try TokenStore().read()
                let meta = MetaClient(token: token)
                let user = try await meta.me()
                guard try await meta.ownsApp(appId: appId, userId: user) else {
                    throw Halt(L("This game is not in your Meta account. Nothing is looked up or downloaded.",
                                 "Dieses Spiel gehört nicht zu deinem Meta-Konto. Es wird nichts nachgeschlagen oder geladen."))
                }
                try MetaTool(url: tool).verify()
                await say(L("Asking Meta's tool for the files of version \(build.version) …",
                            "Metas Werkzeug wird nach den Dateien von Fassung \(build.version) gefragt …"))
                var files = try MetaListing.list(.build, buildId: build.buildId, tool: tool, token: token)
                try await Task.sleep(for: .seconds(5))
                if let assets = try? MetaListing.list(.assets, buildId: build.buildId, tool: tool, token: token) { files += assets }
                let recipe = try StoreUpdate.make(tested: tested, build: build, files: files)
                try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                try encoder.encode(recipe).write(to: StoreUpdate.url(drafts: drafts, recipeId: id, versionCode: build.versionCode), options: .atomic)
                var choices = StoreUpdate.Choices.load()
                choices.choose(build.versionCode, for: id)
                try choices.save()
            } catch let halt as Halt {
                note = halt.text
            } catch {
                note = Redaction.redact("\(error)")
            }
            let final = note
            await MainActor.run {
                self.preparing.remove(id)
                self.prepareNote[id] = final
                self.latestChoices = StoreUpdate.Choices.load()
                self.refresh()
            }
        }
    }

    /// Zurück zu der Fassung, die ohne Wahl gilt. Nachgeschlagene Rezepte bleiben liegen; sie gelten nur nicht mehr.
    func useTestedVersion(_ game: Game) {
        guard !isBusy(game.id) else {
            prepareNote[game.id] = L("A job for this game is running. Switch versions when it has finished.",
                                     "Für dieses Spiel läuft gerade ein Auftrag. Wechsle die Fassung, wenn er fertig ist.")
            return
        }
        setChoice(nil, for: game)
    }

    private struct Halt: Error { let text: String; init(_ text: String) { self.text = text } }
}
