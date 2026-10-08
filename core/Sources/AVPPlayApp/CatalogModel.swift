import AppKit
import AVPPlayCore
import SwiftUI

/// Der Online-Katalog in der Oberfläche: Spiele aus dem Meta-Store, die noch niemand geprüft hat, die Suche
/// danach, Favoriten, und die Rückmeldung an das Projekt.
extension AppModel {
    var catalogClient: CatalogClient {
        if let custom = ProcessInfo.processInfo.environment["AVPPLAY_CATALOG"], let url = URL(string: custom) { return CatalogClient(base: url) }
        return CatalogClient()
    }

    var draftsDirectory: URL { DataLocation.base.appendingPathComponent("drafts", isDirectory: true) }

    // MARK: Liste und Suche

    /// Holt die erste Seite des Katalogs. Ohne Netz oder mit abgeschaltetem Katalog bleibt es bei den Spielen,
    /// die mit dem Programm kommen.
    func loadCatalog() {
        guard onlineCatalog else {
            catalog = []
            return
        }
        Task {
            do {
                merge(try await catalogClient.catalog().games)
                catalogProblem = nil
            } catch {
                catalogProblem = "\(error)"
            }
        }
    }

    /// Sucht im Katalog. Der Dienst lernt dabei neue Spiele kennen; hier kommen sie als „ungetestet“ an.
    func searchCatalog() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard onlineCatalog, query.count >= 3, !searching else { return }
        searching = true
        Task {
            do {
                merge(try await catalogClient.catalog(query: query).games)
                catalogProblem = nil
            } catch {
                catalogProblem = "\(error)"
            }
            searching = false
        }
    }

    private func merge(_ found: [CatalogGame]) {
        var byId = Dictionary(catalog.map { ($0.appId, $0) }, uniquingKeysWith: { a, _ in a })
        for game in found { byId[game.appId] = game }
        catalog = byId.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Alle Spiele der Übersicht: die mit dem Programm gelieferten und schon nachgeschlagenen, ergänzt um das,
    /// was der Katalog sonst kennt.
    var allGames: [Game] {
        let info = Dictionary(catalog.map { ($0.appId, $0) }, uniquingKeysWith: { a, _ in a })
        var out = games.map { game -> Game in
            var g = game
            if let app = game.recipe.store.appId { g.catalog = info[app] }
            return g
        }
        let known = Set(games.compactMap { $0.recipe.store.appId })
        for entry in catalog where !known.contains(entry.appId) {
            let recipe = DraftRecipe.placeholder(game: entry)
            out.append(Game(recipe: recipe,
                            status: GameStatus.of(recipe: recipe, store: paths.store, apps: installedApps, toolchainVersion: toolchainRevision,
                                                  bundlePrefix: customBundlePrefix.isEmpty ? nil : customBundlePrefix),
                            cover: nil, catalog: entry, draft: true))
        }
        return out
    }

    // MARK: Favoriten

    func isFavourite(_ game: Game) -> Bool { favourites.contains(game.id) }

    func toggleFavourite(_ game: Game) {
        if favourites.contains(game.id) { favourites.remove(game.id) } else { favourites.insert(game.id) }
        UserDefaults.standard.set(favourites.sorted(), forKey: "favourites")
    }

    // MARK: Ein ungetestetes Spiel nachschlagen

    /// Schlägt nach, woraus der neueste Build eines Spiels besteht, sobald jemand seine Seite öffnet: Build beim
    /// Katalog, Besitz bei Meta, Dateien über Metas Werkzeug. Jede Frage wird je Build nur einmal gestellt; das
    /// Ergebnis liegt danach als Rezeptentwurf auf dem Mac. Beim ersten unerwarteten Ergebnis ist Schluss.
    func prepare(_ game: Game) {
        guard game.draft, let entry = game.catalog, !preparing.contains(game.id) else { return }
        if game.prepared, game.recipe.versionCode == (entry.build?.versionCode ?? game.recipe.versionCode) { return }
        guard account == .signedIn else {
            prepareNote[game.id] = L("Sign in to Meta under “Setup” first – then the app can check whether you own this game and look up its files.",
                                     "Melde dich zuerst unter „Einrichtung“ bei Meta an – dann kann die App prüfen, ob dir das Spiel gehört, und seine Dateien nachschlagen.")
            return
        }
        guard let toolchain else {
            prepareNote[game.id] = L("The toolchain is not installed yet (see “Setup”).", "Die Toolchain ist noch nicht installiert (siehe „Einrichtung“).")
            return
        }
        preparing.insert(game.id)
        prepareNote[game.id] = L("Looking up the newest build …", "Der neueste Build wird nachgeschlagen …")
        let client = catalogClient
        let paths = paths
        let drafts = draftsDirectory
        let tool = Probe.metaToolURL
        let id = game.id
        Task.detached {
            func say(_ text: String) async { await MainActor.run { self.prepareNote[id] = text } }
            var note: String?
            do {
                let detail = try await client.game(appId: entry.appId)
                guard let build = detail.build else {
                    throw Stop(L("No public build of this game is known yet.", "Zu diesem Spiel ist noch kein öffentlicher Build bekannt."))
                }
                await say(L("Asking Meta whether you own this game …", "Meta wird gefragt, ob dir das Spiel gehört …"))
                let token = try TokenStore().read()
                let meta = MetaClient(token: token)
                let user = try await meta.me()
                let owned = try await meta.ownsApp(appId: entry.appId, userId: user)
                let cache = OwnershipCache(store: paths.store)
                var records = cache.load()
                records[entry.appId] = OwnershipRecord(owned: owned, checked: Date())
                try? cache.save(records)
                await MainActor.run { self.ownership = records }
                guard owned else {
                    throw Stop(L("This game is not in your Meta account. Nothing is looked up or downloaded.",
                                 "Dieses Spiel gehört nicht zu deinem Meta-Konto. Es wird nichts nachgeschlagen oder geladen."))
                }
                // Kennt die Toolchain das Spiel, gilt ihr Eintrag; sonst wird es mit dem allgemeinen Versuchs-Target
                // gebaut, das sich nur nach der Engine richtet.
                let named = detail.target.flatMap { $0.isEmpty || toolchain.targetKind($0) == nil ? nil : $0 }
                let target = named ?? DraftRecipe.genericTarget(appId: entry.appId)
                try MetaTool(url: tool).verify()
                await say(L("Asking Meta's tool for the files of build \(build.version) …", "Metas Werkzeug wird nach den Dateien von Build \(build.version) gefragt …"))
                var files = try MetaListing.list(.build, buildId: build.buildId, tool: tool, token: token)
                try await Task.sleep(for: .seconds(5))
                // Weitere Dateien hat nicht jedes Spiel; sagt das Werkzeug dazu nichts oder lehnt ab, bleibt es bei APK und OBB.
                if let assets = try? MetaListing.list(.assets, buildId: build.buildId, tool: tool, token: token) { files += assets }
                let recipe = try DraftRecipe.make(game: detail, build: build, files: files, target: target, minCommit: toolchain.commit())
                try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                try encoder.encode(recipe).write(to: drafts.appendingPathComponent("\(recipe.id).json"), options: .atomic)
                // Das Titelbild von der Store-Seite, wie bei den geprüften Spielen: einmal holen, danach liegt es im Bestand.
                let cover = StartHero.storeURL(store: paths.store, recipe: recipe)
                if !FileManager.default.fileExists(atPath: cover.path), let image = await StoreArt().landscapeCover(appId: entry.appId) {
                    try? FileManager.default.createDirectory(at: cover.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? image.write(to: cover, options: .atomic)
                }
            } catch let stop as Stop {
                note = stop.text
            } catch {
                note = Redaction.redact("\(error)")
            }
            let final = note
            await MainActor.run {
                self.preparing.remove(id)
                self.prepareNote[id] = final
                self.refresh()
            }
        }
    }

    private struct Stop: Error { let text: String; init(_ text: String) { self.text = text } }

    // MARK: Rückmeldung

    func feedbackKey(_ game: Game) -> String { "\(game.recipe.store.appId ?? game.id)-\(game.recipe.versionCode)" }
    func feedbackSent(_ game: Game) -> String? { sentFeedback[feedbackKey(game)] }

    /// Schickt eine Rückmeldung: Spiel, Build, Ergebnis, Kommentar und die Versionen von App und Toolchain.
    func sendFeedback(_ game: Game, result: CatalogFeedback.Result, comment: String) {
        guard onlineCatalog, let appId = game.recipe.store.appId else { return }
        let feedback = CatalogFeedback(appId: appId, versionCode: game.recipe.versionCode, result: result, comment: comment,
                                       appVersion: appVersion, toolchain: toolchain.map { String($0.version()) } ?? "", lang: language.rawValue)
        let key = feedbackKey(game)
        Task {
            do {
                try await catalogClient.send(feedback)
                sentFeedback[key] = result.rawValue
                UserDefaults.standard.set(sentFeedback, forKey: "sentFeedback")
                notice = L("Thank you – your report has been sent.", "Danke – deine Rückmeldung ist gesendet.")
            } catch {
                notice = "\(error)"
            }
        }
    }
}
