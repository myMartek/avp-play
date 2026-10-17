import AppKit
import AVPPlayCore
import SwiftUI

/// Der Online-Katalog in der Oberfläche: Spiele aus dem Meta-Store, die noch niemand geprüft hat, die Suche
/// danach, Favoriten, und die Rückmeldung an das Projekt.
extension AppModel {
    var catalogClient: CatalogClient {
        CatalogClient.configured
    }

    var draftsDirectory: URL { DataLocation.base.appendingPathComponent("drafts", isDirectory: true) }

    // MARK: Liste und Suche

    /// Holt die erste Seite des Katalogs und dazu, was der Katalog über die Spiele sagt, die schon auf dem Mac
    /// liegen oder gemerkt sind. Ohne Netz oder mit abgeschaltetem Katalog bleibt es bei den Spielen, die mit dem
    /// Programm kommen.
    func loadCatalog() {
        guard onlineCatalog else {
            catalog = []
            catalogTotal = nil
            catalogMore = false
            return
        }
        Task {
            do {
                let first = try await catalogClient.catalog()
                merge(first.games)
                catalogTotal = first.total
                catalogMore = first.more
                catalogNextPage = 1
                catalogProblem = nil
                askedOwn = []
                loadOwnCatalogEntries()
                loadOwnedCatalogEntries()
            } catch {
                catalogProblem = "\(error)"
            }
        }
        loadSteamCatalog()
        reportUsage()
    }

    /// Eigene und gemerkte Spiele stehen im Katalog irgendwo zwischen tausenden; nach ihnen wird gezielt gefragt,
    /// damit ihr Kennzeichen stimmt, auch wenn ihre Seite des Katalogs nie geladen wird. Jede Kennung nur einmal.
    func loadOwnCatalogEntries() {
        guard onlineCatalog, catalogNextPage > 0 else { return }
        let mine = Set(games.compactMap { $0.recipe.catalogAppId } + favourites.compactMap(DraftRecipe.appId(of:))
                       + customFilters.flatMap(\.games).compactMap(DraftRecipe.appId(of:)))
        let missing = mine.subtracting(catalog.map(\.appId)).subtracting(askedOwn).sorted()
        guard !missing.isEmpty else { return }
        askedOwn.formUnion(missing)
        Task {
            // Kommt keine Antwort, gelten die Kennungen nicht als gefragt: der nächste Anlass fragt neu.
            do { merge(try await catalogClient.games(appIds: missing)) } catch { askedOwn.subtract(missing) }
        }
    }

    /// Holt, was der Katalog über die Favoriten sagt, die noch nicht geladen sind, und wartet darauf – damit eine
    /// Liste der Favoriten vollständig ist, auch wenn die Übersicht erst einen Teil des Katalogs geladen hat.
    /// Sagt, wie viele danach noch fehlen (kein Netz, Katalog abgeschaltet, vom Katalog nicht mehr geführt).
    @discardableResult
    func loadAllFavourites() async -> Int { await loadMissing(favourites) }

    /// Dasselbe für beliebige Spiele – etwa die eines eigenen Filters.
    @discardableResult
    func loadMissing<S: Sequence>(_ ids: S) async -> Int where S.Element == String {
        let ids = Array(ids)
        func missing() -> [String] {
            let loaded = Set(catalog.map(\.appId)).union(games.compactMap { $0.recipe.catalogAppId })
            return Set(ids.compactMap(DraftRecipe.appId(of:))).filter { !loaded.contains($0) }.sorted()
        }
        let wanted = missing()
        guard !wanted.isEmpty else { return 0 }
        guard onlineCatalog else { return wanted.count }
        if let found = try? await catalogClient.games(appIds: wanted) {
            merge(found)
            askedOwn.formUnion(wanted)
        }
        return missing().count
    }

    // MARK: Steam-Liste

    /// Holt die ganze Steam-Liste des Katalogs – ein paar Dutzend Spiele, Seite für Seite. Ein Dienst ohne Steam-Liste
    /// (vor dem Ausrollen) antwortet nicht: dann bleibt sie leer, und es stehen nur die eigenen Steam-Spiele da.
    func loadSteamCatalog() {
        guard onlineCatalog else { steamCatalog = []; return }
        let client = catalogClient
        Task {
            var all: [SteamCatalogGame] = []
            var page = 0
            do {
                while page < 20 {
                    let next = try await client.steamCatalog(page: page)
                    all += next.games
                    page += 1
                    if !next.more || next.games.isEmpty { break }
                }
            } catch {
                return
            }
            var seen = Set<String>()
            steamCatalog = all.filter { seen.insert($0.appId).inserted }
        }
    }

    // MARK: Im Besitz

    /// Lädt die Bibliothek des Meta-Kontos – höchstens einmal in der Stunde, `force` sofort – und holt dann beim
    /// Katalog, was er über die Spiele darin sagt, die er noch nicht geliefert hat: Unter „Im Besitz“ sollen alle
    /// stehen, nicht nur die, bis zu denen jemand geblättert hat. Steam fragt der Durchgang in `checkOwnership`.
    ///
    /// Wie überall bei Meta: erst `/me`, der Token nur im Kopf der Anfrage, und beim ersten unerwarteten Ergebnis ist
    /// Schluss – die zuletzt geladene Bibliothek bleibt dann stehen.
    func loadLibrary(force: Bool = false) {
        guard account == .signedIn, storeBlocker == nil, !loadingLibrary else { return }
        if !force, let library, !library.isStale() {
            loadOwnedCatalogEntries()
            return
        }
        loadingLibrary = true
        let cache = MetaLibraryCache(store: paths.store)
        Task.detached {
            var problem: String?
            var fresh: MetaLibrary?
            do {
                let client = MetaClient(token: try TokenStore().read())
                let user = try await client.me()
                let library = MetaLibrary(checked: Date(), apps: try await client.library(userId: user))
                try? cache.save(library)
                fresh = library
            } catch {
                problem = Redaction.redact("\(error)")
            }
            let loaded = fresh
            let note = problem
            await MainActor.run {
                self.loadingLibrary = false
                self.libraryProblem = note
                if let loaded { self.library = loaded }
                self.loadOwnedCatalogEntries()
            }
        }
    }

    /// Fragt den Katalog nach den Spielen der Bibliothek, die er noch nicht geliefert hat – jede Kennung einmal, wie
    /// bei den eigenen und gemerkten Spielen. Was er nicht kennt (Apps, Videos, Systemprogramme), fehlt einfach.
    func loadOwnedCatalogEntries() {
        guard onlineCatalog, !libraryIds.isEmpty else { return }
        let known = Set(catalog.map(\.appId)).union(games.compactMap { $0.recipe.catalogAppId })
        let missing = libraryIds.subtracting(known).subtracting(askedOwn).sorted()
        guard !missing.isEmpty else { return }
        askedOwn.formUnion(missing)
        Task {
            do { merge(try await catalogClient.games(appIds: missing)) } catch { askedOwn.subtract(missing) }
        }
    }

    /// Nach einer neuen Anmeldung: Die Bibliothek gehört zum vorigen Konto.
    func forgetLibrary() {
        MetaLibraryCache(store: paths.store).clear()
        library = nil
        libraryProblem = nil
    }

    /// Sucht im Katalog. Der Dienst lernt dabei neue Spiele kennen; hier kommen sie als „ungetestet“ an.
    func searchCatalog() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard onlineCatalog, query.count >= 3, !searching, query != searchedQuery else { return }
        searching = true
        Task {
            do {
                let first = try await catalogClient.catalog(query: query)
                merge(first.games)
                searchedQuery = query
                searchMore = first.more
                searchNextPage = 1
                catalogProblem = nil
            } catch {
                catalogProblem = "\(error)"
            }
            searching = false
        }
    }

    /// Gibt es zu dem, was gerade gezeigt wird, noch eine Seite? Bei einer Suche die nächsten Treffer, sonst die
    /// nächste Seite des ganzen Katalogs. Mit einem Filter, der nur auf diesem Mac entschieden wird, nicht: was
    /// installiert oder gemerkt ist, steht schon vollständig da – und was dem Nutzer gehört, holt `loadLibrary` gezielt.
    var canLoadMore: Bool {
        // Nur Steam: der Katalog führt Meta-Spiele, Nachladen bringt nichts.
        guard onlineCatalog, !filterInstalled, !favouritesWanted, !filterDownloaded, !customOnlyWanted, !filterOwned, !(filterSteam && !filterMeta) else { return false }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty else { return query == searchedQuery && searchMore }
        // Geprüftes und von Nutzern Bestätigtes steht im Katalog vorn. Ist einer dieser Filter gesetzt, lohnt
        // Nachladen nur, solange die geladenen Seiten noch ganz aus solchen Spielen bestehen. Dasselbe gilt für
        // Mixed Reality: Die Angabe trägt nur, was das Projekt oder ein eingesandter Fix zum Laufen gebracht hat.
        if filterVerified || filterCommunity || filterMixedReality {
            let labelled = catalog.filter { $0.status == "verified" || $0.status == "community" }.count
            if labelled < catalogNextPage * 60 { return false }
        }
        return catalogMore
    }

    /// Lädt die nächste Seite nach – ausgelöst, wenn das Ende der Liste in Sicht kommt.
    func loadMoreCatalog() {
        guard canLoadMore, !loadingMore else { return }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        loadingMore = true
        Task {
            do {
                if query.isEmpty {
                    let next = try await catalogClient.catalog(page: catalogNextPage)
                    merge(next.games)
                    catalogMore = next.more && !next.games.isEmpty
                    catalogTotal = next.total ?? catalogTotal
                    catalogNextPage += 1
                } else {
                    let next = try await catalogClient.catalog(query: query, page: searchNextPage)
                    merge(next.games)
                    if query == searchedQuery {
                        searchMore = next.more && !next.games.isEmpty
                        searchNextPage += 1
                    }
                }
                catalogProblem = nil
            } catch {
                // Kein Dauerversuch: Nachladen gibt es erst wieder nach einem neuen Laden der ersten Seite.
                catalogProblem = "\(error)"
                if query.isEmpty { catalogMore = false } else { searchMore = false }
            }
            loadingMore = false
        }
    }

    private func merge(_ found: [CatalogGame]) {
        guard !found.isEmpty else { return }
        var byId = Dictionary(catalog.map { ($0.appId, $0) }, uniquingKeysWith: { a, _ in a })
        for game in found { byId[game.appId] = game }
        catalog = byId.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Baut die Liste aller Spiele neu: die eigenen, ergänzt um das, was der Katalog sagt, und dahinter ein
    /// Platzhalter für jeden Titel aus dem Katalog, den es auf diesem Mac noch nicht gibt.
    func rebuildAllGames() {
        let info = Dictionary(catalog.map { ($0.appId, $0) }, uniquingKeysWith: { a, _ in a })
        var out = games.map { game -> Game in
            var g = game
            if let app = game.recipe.catalogAppId { g.catalog = info[app] }
            return g
        }
        let known = Set(games.compactMap { $0.recipe.catalogAppId })
        let prefix = customBundlePrefix.isEmpty ? nil : customBundlePrefix
        for entry in catalog where !known.contains(entry.appId) {
            let recipe = DraftRecipe.placeholder(game: entry)
            out.append(Game(recipe: recipe,
                            status: GameStatus.of(recipe: recipe, store: paths.store, apps: installedApps, toolchainVersion: toolchainRevision,
                                                  pin: toolchainChoices.games[recipe.id], bundlePrefix: prefix,
                                                  metalFX: metalFXExpected,
                                                  xrPrediction: xrPredictionExpected(for: recipe.id)),
                            cover: nil, catalog: entry, draft: true))
        }
        // Dahinter die Steam-Spiele mit Android-Fassung – die des Kontos und die aus der Steam-Liste des Katalogs –, die
        // noch kein Rezept und keinen Entwurf haben.
        let steamInfo = Dictionary(steamCatalog.map { ($0.appId, $0) }, uniquingKeysWith: { a, _ in a })
        for index in out.indices where out[index].recipe.source == .steam {
            if let app = out[index].recipe.store.steamAppId { out[index].steamCatalog = steamInfo[app] }
        }
        for app in steamPlaceholders(known: games) {
            let recipe = SteamDraft.placeholder(app: app)
            var game = Game(recipe: recipe,
                            status: GameStatus.of(recipe: recipe, store: paths.store, apps: installedApps, toolchainVersion: toolchainRevision,
                                                  pin: toolchainChoices.games[recipe.id], bundlePrefix: prefix, metalFX: metalFXExpected,
                                                  xrPrediction: xrPredictionExpected(for: recipe.id)),
                            cover: nil, catalog: nil, draft: true)
            game.ownershipKeys = ["steam:\(app.appId)"]
            game.steamCatalog = steamInfo[app.appId]
            out.append(game)
        }
        allGames = out
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
        // Hat der Nutzer eine bestimmte Fassung gewählt, wird die nachgeschlagen und nicht der neueste Build; sie
        // bleibt, auch wenn der Store inzwischen einen neueren führt. Kennt die App den gewählten Build (noch) nicht,
        // bleibt der Entwurf, wie er ist.
        let chosenCode = latestChoices.versions[game.id]
        let chosen = chosenCode.flatMap { code in (storeBuildLists[game.id] ?? []).first { $0.versionCode == code } }
        if chosenCode != nil, chosen == nil, game.prepared { return }
        if game.prepared, game.recipe.versionCode == (chosen?.versionCode ?? entry.build?.versionCode ?? game.recipe.versionCode) {
            // Fertig nachgeschlagen – es sei denn, der Entwurf baut noch mit dem allgemeinen Versuchs-Target und die
            // Toolchain kennt das Spiel inzwischen unter eigenem Namen: dann wird der Entwurf neu geschrieben.
            let named = entry.target.flatMap { $0.isEmpty || toolchain?.targetKind($0) == nil ? nil : $0 }
            if named == nil || named == game.recipe.toolchain.target { return }
        }
        if let why = storeBlocker {
            prepareNote[game.id] = why
            return
        }
        guard account == .signedIn else {
            prepareNote[game.id] = L("Sign in to Meta under “Setup” first – then the app can check whether you own this game and look up its files.",
                                     "Melde dich zuerst unter „Einrichtung“ bei Meta an – dann kann die App prüfen, ob dir das Spiel gehört, und seine Dateien nachschlagen.")
            return
        }
        // Die Toolchain braucht es zum Nachschlagen nicht: Wer nur laden will, hat sie vielleicht noch gar nicht (oder
        // kein Xcode, ohne das sie nicht sagen kann, welche Spiele sie kennt). Der Entwurf nennt dann das allgemeine
        // Versuchs-Target und noch keinen Mindeststand; beides wird nachgetragen, sobald gebaut wird.
        let toolchain = toolchain
        preparing.insert(game.id)
        prepareNote[game.id] = chosen.map { L("Looking up version \($0.version) …", "Fassung \($0.version) wird nachgeschlagen …") }
            ?? L("Looking up the newest build …", "Der neueste Build wird nachgeschlagen …")
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
                guard let build = chosen ?? detail.build else {
                    throw Stop(L("No public build of this game is known yet.", "Zu diesem Spiel ist noch kein öffentlicher Build bekannt."))
                }
                await say(L("Asking Meta whether you own this game …", "Meta wird gefragt, ob dir das Spiel gehört …"))
                let token = try TokenStore().read()
                let meta = MetaClient(token: token)
                let user = try await meta.me()
                let owned = try await meta.ownsApp(appId: entry.appId, userId: user)
                let records = OwnershipCache(store: paths.store).record(appId: entry.appId, owned: owned)
                await MainActor.run { self.ownership = records }
                guard owned else {
                    throw Stop(L("This game is not in your Meta account. Nothing is looked up or downloaded.",
                                 "Dieses Spiel gehört nicht zu deinem Meta-Konto. Es wird nichts nachgeschlagen oder geladen."))
                }
                // Kennt die Toolchain das Spiel, gilt ihr Eintrag; sonst wird es mit dem allgemeinen Versuchs-Target
                // gebaut, das sich nur nach der Engine richtet.
                let named = detail.target.flatMap { $0.isEmpty || toolchain?.targetKind($0) == nil ? nil : $0 }
                let target = named ?? DraftRecipe.genericTarget(appId: entry.appId)
                try MetaTool(url: tool).verify()
                await say(L("Asking Meta's tool for the files of build \(build.version) …", "Metas Werkzeug wird nach den Dateien von Build \(build.version) gefragt …"))
                let files = try await MetaListing.files(buildId: build.buildId, tool: tool, token: token, client: meta, say: say)
                let recipe = try DraftRecipe.make(game: detail, build: build, files: files, target: target, minCommit: toolchain?.commit() ?? "")
                try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                try encoder.encode(recipe).write(to: drafts.appendingPathComponent("\(recipe.id).json"), options: .atomic)
                // Das Titelbild von der Store-Seite, wie bei den geprüften Spielen: einmal holen, danach liegt es im Bestand.
                let cover = StartHero.storeURL(store: paths.store, recipe: recipe)
                // Zeigt die Store-Seite keins und nennt der Katalog eins, kommt es von dort.
                if !FileManager.default.fileExists(atPath: cover.path) {
                    var image = await StoreArt().landscapeCover(appId: entry.appId)
                    if image == nil, detail.cover == true { image = await client.cover(appId: entry.appId) }
                    if let image {
                        try? FileManager.default.createDirectory(at: cover.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? image.write(to: cover, options: .atomic)
                    }
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

    func feedbackKey(_ game: Game) -> String { "\(game.recipe.catalogAppId ?? game.id)-\(game.recipe.versionCode)" }
    func feedbackSent(_ game: Game) -> String? { sentFeedback[feedbackKey(game)] }

    /// Schickt eine Rückmeldung: Spiel, Build, Ergebnis, Kommentar und die Versionen von App und Toolchain.
    ///
    /// Der Katalog führt ein Spiel unter seiner Meta-Store-Seite, auch wenn es hier aus Steam installiert ist; die
    /// Meldung zählt dann für dasselbe Spiel. Dass sie die Steam-Fassung meint, sagen ihr Build und ein Vermerk am
    /// Anfang des Kommentars – der Dienst kennt kein eigenes Feld für die Kaufquelle.
    /// Kann zu diesem Spiel eine Rückmeldung gehen? Ein Spiel aus dem Meta-Store unter seiner Store-Kennung, eines aus
    /// Steam unter seiner Steam-App-ID.
    func canSendFeedback(_ game: Game) -> Bool {
        guard onlineCatalog, game.fromStore else { return false }
        if game.recipe.source == .steam { return game.recipe.store.steamAppId.flatMap(SteamCatalogGame.serviceKey(steamAppId:)) != nil }
        return game.recipe.catalogAppId != nil
    }

    func sendFeedback(_ game: Game, result: CatalogFeedback.Result, comment: String) {
        guard canSendFeedback(game) else { return }
        let steamApp = game.recipe.source == .steam ? game.recipe.store.steamAppId : nil
        guard let appId = steamApp.flatMap(SteamCatalogGame.serviceKey(steamAppId:)) ?? game.recipe.catalogAppId else { return }
        let feedback = CatalogFeedback(appId: appId, versionCode: game.recipe.versionCode, result: result, comment: comment,
                                       appVersion: appVersion, toolchain: toolchain(for: game).map { String($0.version()) } ?? "", lang: language.rawValue)
        let key = feedbackKey(game)
        let metaApp = game.recipe.catalogAppId
        Task {
            do {
                // Die Steam-Fassung zählt für ihren Eintrag in der Steam-Liste. Ein Dienst ohne Steam-Liste bekommt sie wie
                // früher beim Meta-Spiel, mit Vermerk (das erledigt `sendSteam`).
                if let steamApp { try await catalogClient.sendSteam(feedback, steamAppId: steamApp, metaAppId: metaApp) }
                else { try await catalogClient.send(feedback) }
                sentFeedback[key] = result.rawValue
                UserDefaults.standard.set(sentFeedback, forKey: "sentFeedback")
                notice = L("Thank you – your report has been sent.", "Danke – deine Rückmeldung ist gesendet.")
            } catch {
                notice = "\(error)"
            }
        }
    }

    // MARK: Zählung

    /// Gezählt wird nur für ein Programmpaket (nicht beim Entwickeln), nur mit eingeschaltetem Katalog und nur,
    /// solange es in den Einstellungen nicht abgestellt ist.
    private var counting: Bool { onlineCatalog && usageCounts && Bundle.main.bundleIdentifier != nil && Snapshot.directory == nil }

    /// Sagt dem Dienst höchstens einmal am Tag, dass diese Kopie in Gebrauch ist – ohne Kennung, siehe `UsagePing`.
    /// Der Tag wird vor dem Senden gemerkt, damit zwei Anläufe kurz hintereinander nicht doppelt zählen, und
    /// zurückgenommen, wenn die Meldung nicht ankommt.
    func reportUsage() {
        let key = "lastUsagePing"
        let last = UserDefaults.standard.string(forKey: key)
        let now = Date()
        guard counting, let ping = UsagePing.due(last: last, now: now, appVersion: appVersion) else { return }
        UserDefaults.standard.set(UsagePing.day(now), forKey: key)
        let client = catalogClient
        Task {
            if (try? await client.send(ping)) == nil { UserDefaults.standard.set(last, forKey: key) }
        }
    }

    /// Sagt dem Dienst, dass ein Spiel installiert wurde – für jedes Spiel ein einziges Mal, nur sein Name.
    func reportInstall(_ recipe: Recipe) {
        let key = "countedInstalls"
        guard counting, let game = UsagePing.gameKey(appId: recipe.catalogAppId, recipe: recipe.id),
              !(UserDefaults.standard.stringArray(forKey: key) ?? []).contains(game) else { return }
        let client = catalogClient
        Task {
            guard (try? await client.countInstall(of: game)) != nil else { return }
            UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: key) ?? []) + [game], forKey: key)
        }
    }
}
