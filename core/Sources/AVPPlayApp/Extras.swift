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
        return GameList.Entry(title: game.recipe.title, storeId: game.recipe.store.appId ?? "", version: game.recipe.versionName,
                              label: label, downloaded: game.downloaded, installed: installed)
    }

    /// Die eigenen Spiele als Text: was auf dem Mac liegt, was im Meta-Konto ist (soweit gefragt wurde) und die
    /// Favoriten. Ein Favorit, den der Katalog gerade nicht geladen hat, steht mit seiner Kennung da.
    func gameListText(now: Date = Date()) -> String {
        let downloaded = allGames.filter { $0.storeBytes > 0 || $0.downloaded }.map(listEntry)
        let owned = allGames.filter { owned($0) == .yes }.map(listEntry)
        let known = Dictionary(allGames.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let starred = favourites.sorted().map { id -> GameList.Entry in
            known[id].map(listEntry) ?? GameList.Entry(title: id, storeId: DraftRecipe.appId(of: id) ?? "", version: "",
                                                       label: L("not loaded", "nicht geladen"), downloaded: false, installed: nil)
        }
        return GameList.text(downloaded: downloaded, owned: owned, favourites: starred, appVersion: appVersion,
                             toolchain: toolchain.map { String($0.version()) } ?? "",
                             made: now.formatted(date: .abbreviated, time: .omitted))
    }

    /// Was die Übersicht gerade zeigt, in Worten: die gesetzten Filter und die Suche.
    var shownListTitle: String {
        var parts: [String] = []
        if filterVerified { parts.append(L("verified", "geprüft")) }
        if filterCommunity { parts.append(L("community verified", "von Nutzern bestätigt")) }
        if filterInstalled { parts.append(L("installed", "installiert")) }
        if filterDownloaded { parts.append(L("downloaded, not installed", "geladen, nicht installiert")) }
        if filterFavourites { parts.append(L("favourites", "Favoriten")) }
        let words = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { parts.append(L("search “\(words)”", "Suche „\(words)“")) }
        return parts.isEmpty ? L("All games the app has loaded", "Alle Spiele, die die App geladen hat")
                             : L("Games shown: ", "Gezeigte Spiele: ") + parts.joined(separator: ", ")
    }

    /// Die Spiele, die die Übersicht gerade zeigt – etwa nur die Favoriten oder nur das Installierte.
    func shownGamesText(now: Date = Date()) -> String {
        GameList.text(title: shownListTitle, entries: shownGames.map(listEntry), appVersion: appVersion,
                      toolchain: toolchain.map { String($0.version()) } ?? "", made: now.formatted(date: .abbreviated, time: .omitted))
    }

    /// Fragt, wohin, und schreibt die Liste dorthin: alle drei Listen der eigenen Spiele, oder – aus der Übersicht
    /// heraus – genau das, was dort gerade zu sehen ist.
    ///
    /// Vorher werden die Favoriten nachgeladen, die der Katalog noch nicht geliefert hat: Die Liste soll alle
    /// enthalten, nicht nur die, bis zu denen jemand geblättert hat.
    func exportGameList(shownOnly: Bool = false) {
        Task {
            let unloaded = await loadAllFavourites()
            writeGameList(shownOnly: shownOnly)
            if unloaded > 0, !shownOnly || filterFavourites {
                notice = unloaded == 1
                    ? L("One favourite could not be loaded from the catalogue and is missing from the list or stands there by its number only.",
                        "Ein Favorit ließ sich nicht aus dem Katalog laden und fehlt in der Liste oder steht dort nur mit seiner Kennung.")
                    : L("\(unloaded) favourites could not be loaded from the catalogue and are missing from the list or stand there by their number only.",
                        "\(unloaded) Favoriten ließen sich nicht aus dem Katalog laden und fehlen in der Liste oder stehen dort nur mit ihrer Kennung.")
            }
        }
    }

    /// Ob die Übersicht gerade etwas zeigt, das sich als vollständige Liste ausgeben lässt: Was installiert, geladen
    /// oder gemerkt ist, kennt dieser Mac ganz. Ohne einen dieser Filter zeigt die Übersicht nur den Teil des
    /// Katalogs, der schon geladen ist – das wäre keine Liste, sondern ein Ausschnitt.
    var canExportShown: Bool { filterInstalled || filterDownloaded || filterFavourites }

    private func writeGameList(shownOnly: Bool) {
        let panel = NSSavePanel()
        panel.title = L("Export Game List", "Spieleliste exportieren")
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "AVP Play – " + (shownOnly ? L("games", "Spiele") : L("my games", "meine Spiele")) + " "
            + ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate]) + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data((shownOnly ? shownGamesText() : gameListText()).utf8).write(to: url, options: .atomic)
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
