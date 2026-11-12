import AppKit
import AVPPlayCore
import SwiftUI
import UniformTypeIdentifiers

/// Welche Aufträge aus der Liste genommen werden.
enum JobClearing: CaseIterable {
    case finished, stopped, all

    var title: String {
        switch self {
        case .finished: return L("Finished Jobs", "Abgeschlossene Aufträge")
        case .stopped: return L("Stopped, Interrupted and Cancelled Jobs", "Angehaltene, unterbrochene und abgebrochene Aufträge")
        case .all: return L("All Jobs That Are Not Running or Waiting", "Alle Aufträge, die nicht laufen oder warten")
        }
    }
}

// MARK: Aufträge leeren

extension AppModel {
    /// Die Aufträge, die eine Auswahl träfe. Was läuft oder wartet, bleibt immer stehen.
    func jobs(matching clearing: JobClearing) -> [Job] {
        jobs.filter { job in
            switch (phase(of: job), clearing) {
            case (.running, _), (.queued, _): return false
            case (.finished, .finished), (_, .all): return true
            case (.stopped, .stopped), (.interrupted, .stopped), (.cancelled, .stopped): return true
            default: return false
            }
        }
    }

    /// Nimmt Aufträge aus der Liste. Es verschwinden nur ihr Eintrag und ihr Verlauf: geladene Dateien, Gebautes und
    /// alles auf der Vision Pro bleiben. Einen angehaltenen Auftrag kann danach niemand mehr fortsetzen – die Seite
    /// des Spiels legt einen neuen an, der mit dem weitermacht, was schon da ist.
    func clearJobs(_ clearing: JobClearing) {
        remove(jobs(matching: clearing))
    }

    func remove(_ list: [Job]) {
        for job in list where job.id != runningJob && !queued.contains(job.id) {
            closeLog(job.id)
            paths.jobs.remove(job.id)
            logs[job.id] = nil
            copyProgress[job.id] = nil
        }
        reloadJobs()
    }
}

/// Das Menü „Leeren“ über der Liste der Aufträge.
struct ClearJobsMenu: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            ForEach(JobClearing.allCases, id: \.self) { clearing in
                let n = model.jobs(matching: clearing).count
                Button("\(clearing.title) (\(n))") { model.clearJobs(clearing) }.disabled(n == 0)
            }
        } label: {
            Label(L("Clear", "Leeren"), systemImage: "trash")
        }
        .help(L("Take jobs off this list. Downloaded files and everything on the Vision Pro stay.",
                "Aufträge aus dieser Liste nehmen. Geladene Dateien und alles auf der Vision Pro bleiben."))
    }
}

// MARK: Liste der eigenen Spiele

extension AppModel {
    private func listEntry(_ game: Game) -> GameList.Entry {
        let label: String
        switch game.trust {
        case .verified: label = L("verified", "geprüft")
        case .community: label = L("community verified", "von Nutzern bestätigt")
        case .untested: label = L("untested", "ungetestet")
        case .incompatible: label = L("incompatible", "inkompatibel")
        }
        let installed: Bool? = { if case .unknown = game.status.onDevice { return nil }; return game.installed }()
        return GameList.Entry(title: game.recipe.title, storeId: game.recipe.catalogAppId ?? "", version: game.recipe.versionName,
                              label: label, downloaded: game.downloaded, installed: installed)
    }

    /// Die eigenen Spiele als Text: was auf dem Mac liegt, was im Meta-Konto ist (soweit gefragt wurde) und die
    /// Favoriten. Ein Favorit, den der Katalog gerade nicht geladen hat, steht mit seiner Kennung da.
    func gameListText(now: Date = Date()) -> String {
        let downloaded = allGames.filter { $0.storeBytes > 0 || $0.downloaded }.map(listEntry)
        let owned = allGames.filter { owned($0) == .yes }.map(listEntry)
        let starred = listEntries(favourites)
        return GameList.text(downloaded: downloaded, owned: owned, favourites: starred, appVersion: appVersion,
                             toolchain: toolchain.map { String($0.version()) } ?? "",
                             made: now.formatted(date: .abbreviated, time: .omitted))
    }

    /// Die Einträge zu einer Menge von Spielen; eines, das der Katalog gerade nicht geladen hat, steht mit seiner Kennung da.
    func listEntries(_ ids: Set<String>) -> [GameList.Entry] {
        let known = Dictionary(allGames.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.sorted().map { id -> GameList.Entry in
            known[id].map(listEntry) ?? GameList.Entry(title: id, storeId: DraftRecipe.appId(of: id) ?? "", version: "",
                                                       label: L("not loaded", "nicht geladen"), downloaded: false, installed: nil)
        }
    }

    /// Was die Übersicht gerade zeigt, in Worten: die gesetzten Filter und die Suche.
    var shownListTitle: String {
        var parts: [String] = []
        if filterVerified { parts.append(L("verified", "geprüft")) }
        if filterCommunity { parts.append(L("community verified", "von Nutzern bestätigt")) }
        if filterInstalled { parts.append(L("installed", "installiert")) }
        if filterDownloaded { parts.append(L("downloaded, not installed", "geladen, nicht installiert")) }
        if filterFavourites { parts.append(L("favourites", "Favoriten")) }
        if filterFavouritesMissing { parts.append(L("favourites not downloaded", "nicht geladene Favoriten")) }
        if filterMixedReality { parts.append(L("mixed reality", "Mixed Reality")) }
        if filterHandTracking { parts.append(L("hand tracking", "Hand-Tracking")) }
        if filterOwned { parts.append(L("owned", "im Besitz")) }
        if filterHorizonGames { parts.append(L("Horizon+ games", "Horizon+ Spiele")) }
        if filterHorizonIndie { parts.append("Horizon+ Indie") }
        if filterMeta { parts.append("Meta") }
        if filterSteam { parts.append("Steam") }
        for filter in customFilters {
            switch customFilterModes[filter.id] ?? .off {
            case .off: break
            case .only: parts.append(L("in “\(filter.name)”", "in „\(filter.name)“"))
            case .hide: parts.append(L("without “\(filter.name)”", "ohne „\(filter.name)“"))
            }
        }
        let words = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { parts.append(L("search “\(words)”", "Suche „\(words)“")) }
        return parts.isEmpty ? L("All games the app has loaded", "Alle Spiele, die die App geladen hat")
                             : L("Games shown: ", "Gezeigte Spiele: ") + parts.joined(separator: ", ")
    }

    /// Die Spiele, die die Übersicht gerade zeigt – etwa nur die Favoriten oder nur das Installierte.
    func shownGamesText(note: String? = nil, now: Date = Date()) -> String {
        GameList.text(title: shownListTitle, entries: shownGames.map(listEntry), note: note, appVersion: appVersion,
                      toolchain: toolchain.map { String($0.version()) } ?? "", made: now.formatted(date: .abbreviated, time: .omitted))
    }

    /// Fragt, wohin, und schreibt die Liste dorthin: alle drei Listen der eigenen Spiele, oder – aus der Übersicht
    /// heraus – genau das, was dort gerade zu sehen ist.
    ///
    /// Vorher werden die Favoriten nachgeladen, die der Katalog noch nicht geliefert hat: Die Liste soll alle
    /// enthalten, nicht nur die, bis zu denen jemand geblättert hat. Aus der Übersicht heraus geht das mit jedem
    /// Filter: Was der Katalog in wenigen Seiten liefern kann, wird vorher geholt (`completeShownList`).
    func exportGameList(shownOnly: Bool = false) {
        Task {
            if shownOnly {
                guard !exportingList else { return }
                exportingList = true
                defer { exportingList = false }
                // Was die gesetzten Filter vollständig machen will: die Favoriten und die Spiele der eigenen Filter,
                // und unter „Im Besitz“ die Bibliothek des Kontos.
                var unloaded = await loadMissing(listedIds)
                if filterOwned { unloaded += await loadMissingApps(libraryIds) }
                let note = await completeShownList()
                writeList(shownGamesText(note: note), name: L("games", "Spiele"))
                if let note { notice = note } else if unloaded > 0 { notice = AppModel.unloadedNote(unloaded) }
                return
            }
            let unloaded = await loadAllFavourites()
            writeList(gameListText(), name: L("my games", "meine Spiele"))
            if unloaded > 0 {
                notice = unloaded == 1
                    ? L("One favourite could not be loaded from the catalogue and is missing from the list or stands there by its number only.",
                        "Ein Favorit ließ sich nicht aus dem Katalog laden und fehlt in der Liste oder steht dort nur mit seiner Kennung.")
                    : L("\(unloaded) favourites could not be loaded from the catalogue and are missing from the list or stand there by their number only.",
                        "\(unloaded) Favoriten ließen sich nicht aus dem Katalog laden und fehlen in der Liste oder stehen dort nur mit ihrer Kennung.")
            }
        }
    }

    /// Die Spiele eines eigenen Filters als Liste – alle, auch die, die die Übersicht gerade nicht geladen hat.
    func exportFilter(_ filter: CustomFilter) {
        Task {
            let unloaded = await loadMissing(filter.games)
            let title = L("Filter “\(filter.name)”", "Filter „\(filter.name)“")
            let text = GameList.text(title: title, entries: listEntries(filter.games), appVersion: appVersion,
                                     toolchain: toolchain.map { String($0.version()) } ?? "",
                                     made: Date().formatted(date: .abbreviated, time: .omitted))
            writeList(text, name: StoreIndex.fileSafe(filter.name))
            if unloaded > 0 { notice = AppModel.unloadedNote(unloaded) }
        }
    }

    static func unloadedNote(_ count: Int) -> String {
        count == 1
            ? L("One game could not be loaded from the catalogue and is missing from the list or stands there by its number only.",
                "Ein Spiel ließ sich nicht aus dem Katalog laden und fehlt in der Liste oder steht dort nur mit seiner Kennung.")
            : L("\(count) games could not be loaded from the catalogue and are missing from the list or stand there by their number only.",
                "\(count) Spiele ließen sich nicht aus dem Katalog laden und fehlen in der Liste oder stehen dort nur mit ihrer Kennung.")
    }

    /// Die Spiele, die die gesetzten Filter vollständig sehen wollen, auch wenn der Katalog sie noch nicht geladen
    /// hat: die Favoriten unter einem Favoriten-Filter und die Spiele jedes eigenen Filters auf „nur diese“.
    var listedIds: [String] {
        var ids = favouritesWanted ? favourites : []
        for filter in customFilters where customFilterModes[filter.id] == .only { ids.formUnion(filter.games) }
        return ids.sorted()
    }

    /// Ob die Übersicht gerade etwas zeigt, das dieser Mac ganz kennt: was installiert, geladen, gemerkt, einem
    /// eigenen Filter zugeordnet oder im eigenen Konto ist, und die Steam-Liste. Ein eigener Filter zum Ausblenden
    /// allein macht die Liste nicht vollständig, wohl aber zusammen mit einem der anderen.
    var shownListKnown: Bool {
        filterInstalled || filterDownloaded || favouritesWanted || customOnlyWanted || (horizonPlusWanted && horizonPlus != nil)
            || filterOwned || (filterSteam && !filterMeta)
    }

    /// Was eine Liste der Übersicht vor dem Schreiben noch braucht (siehe `GameList.Completion`).
    var shownListCompletion: GameList.Completion {
        GameList.completion(local: shownListKnown, online: onlineCatalog,
                            labelled: filterVerified || filterCommunity || filterMixedReality || filterHandTracking,
                            searching: searchText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3)
    }

    /// Holt vom Katalog, was zu den gesetzten Filtern noch fehlt, soweit das in wenigen Seiten geht: die
    /// gekennzeichneten Spiele oder die Treffer der Suche. Antwortet mit dem Satz, der in der Liste stehen muss,
    /// wenn sie danach trotzdem nur einen Teil enthält – ohne Filter und Suche wäre das Ganze der Katalog selbst.
    func completeShownList() async -> String? {
        switch shownListCompletion {
        case .known:
            return nil
        case .loadedPart:
            return GameList.partNote(loaded: catalog.count, total: catalogTotal ?? catalog.count)
        case .pages:
            // Mit einem Filter nach Kennzeichen: alle gekennzeichneten Spiele holen, sie stehen im Katalog vorn. Die
            // Suche engt dann hier ein. Sonst: alle Treffer der Suche – eine eben getippte hat ihre erste Seite
            // vielleicht noch nicht.
            let labelled = filterVerified || filterCommunity || filterMixedReality || filterHandTracking
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !labelled, query != searchedQuery { searchCatalog() }
            var pages = 0, waits = 0
            while pages < GameList.pageLimit, waits < 200 {
                if loadingMore || (!labelled && searching) {
                    waits += 1
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    continue
                }
                guard labelled ? moreLabelled : canLoadMore, await loadNextCatalogPage(labelled: labelled) else { break }
                pages += 1
            }
            // Noch Seiten übrig (Obergrenze), oder der Katalog hat nicht geantwortet.
            let left = labelled ? moreLabelled : canLoadMore
            return left || catalogProblem != nil ? GameList.partNote(loaded: catalog.count, total: nil) : nil
        }
    }

    #if DEBUG
    /// Nur im Test-Bau: `AVPPLAY_TEST_EXPORT=<Datei>` schreibt die Liste der Übersicht mit den gesetzten Filtern
    /// (etwa `-filterVerified YES`) ohne Dialog dorthin und beendet die App – der Weg, den „Liste exportieren“ geht.
    func debugExportShownList() {
        guard let path = ProcessInfo.processInfo.environment["AVPPLAY_TEST_EXPORT"], path.hasPrefix("/") else { return }
        Task {
            for _ in 0..<100 where catalogNextPage == 0 && catalogProblem == nil { try? await Task.sleep(nanoseconds: 200_000_000) }
            let before = catalog.count
            let completion = shownListCompletion
            let note = await completeShownList()
            let text = shownGamesText(note: note)
                + "\n[test] completion \(completion), catalogue \(before) -> \(catalog.count) of \(catalogTotal ?? -1), pages \(catalogNextPage), problem \(catalogProblem ?? "none")\n"
            try? Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            exit(0)
        }
    }
    #endif

    private func writeList(_ text: String, name: String) {
        let panel = NSSavePanel()
        panel.title = L("Export Game List", "Spieleliste exportieren")
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "AVP Play – " + name + " "
            + ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate]) + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Zeigt den Ordner eines Spiels im Ordner für Downloads.
    func showFiles(_ game: Game) {
        NSWorkspace.shared.activateFileViewerSelecting([paths.store.directory(for: game.recipe)])
    }
}
