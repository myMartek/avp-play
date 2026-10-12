import AppKit
import AVPPlayCore
import SwiftUI
import UserNotifications

/// Ein Spiel in der Übersicht: sein Rezept, sein Stand und sein Titelbild.
struct Game: Identifiable {
    let recipe: Recipe
    var status: GameStatus
    var cover: NSImage?
    /// Was das Spiel auf diesem Mac belegt.
    var storeBytes: Int64 = 0
    /// Was der Online-Katalog über das Spiel sagt, soweit er es kennt.
    var catalog: CatalogGame?
    /// Kein mitgeliefertes Rezept, sondern ein Entwurf aus Katalog und Metas Werkzeug – oder erst ein Platzhalter.
    var draft = false
    /// Gesetzt, wenn statt einer geprüften Fassung eine ungetestete aus dem Store gewählt ist: der Name der Fassung,
    /// die ohne Wahl gilt.
    var testedVersion: String?
    /// Die Fassungen, zu denen das Projekt ein eigenes Rezept führt: zuerst die, die ohne Wahl gilt, dann weitere.
    /// Leer bei einem Spiel ohne mitgeliefertes Rezept.
    var verifiedVersions: [GameVersion] = []
    var id: String { recipe.id }
    /// Sind die Dateien des Spiels bekannt? Bei einem Platzhalter noch nicht.
    var prepared: Bool { !draft || !recipe.files.isEmpty }
    /// Wie weit dem Spiel zu trauen ist. Was der Katalog sagt, gilt – dort legt das Projekt fest oder zählen die
    /// Meldungen. Ohne Katalog (kein Netz, abgeschaltet, Sonderapp) gilt das mitgelieferte Rezept.
    var trust: Trust {
        // Geprüft ist eine Fassung, nicht ein Name: die neuere aus dem Store hat das Projekt nicht gesehen.
        if testedVersion != nil { return .untested }
        switch catalog?.status {
        case "verified": return .verified
        case "community": return .community
        case "incompatible": return .incompatible
        case "untested": return .untested
        default: return !draft && recipe.status.playability == "verified" ? .verified : .untested
        }
    }
    var incompatible: Bool { trust == .incompatible }
    /// Sonderapps kommen nicht aus dem Meta-Store; für sie wird kein Meta-Konto gebraucht.
    var needsMetaAccount: Bool { recipe.store.appId != nil }
    /// Vom Projekt selbst auf einer Vision Pro geprüft.
    var verified: Bool { trust == .verified }
    var installed: Bool {
        switch status.onDevice {
        case .current, .olderToolchain, .olderGame, .unstamped: return true
        case .notInstalled, .unknown: return false
        }
    }
    /// Liegt alles, woraus das Spiel gebaut wird, vollständig auf diesem Mac?
    var downloaded: Bool { prepared && status.filesRequired + status.treesRequired > 0 && status.stockComplete }
}

/// Vom Projekt geprüft, von Nutzern bestätigt, noch offen, oder von Nutzern als nicht lauffähig gemeldet.
enum Trust: Int { case verified, community, untested, incompatible }

/// Gehört das Spiel dem angemeldeten Konto? Sonderapps haben keinen Store-Titel; bei ihnen stellt sich die Frage nicht.
enum Owned { case notApplicable, unknown, yes, no }

/// Was der Nutzer für ein Spiel zusätzlich gewählt hat.
struct GameOptions: Codable, Equatable {
    /// Sprachen, deren wählbare Dateien mitkommen (Kürzel wie im Rezept).
    var locales: [String] = []
    /// Weitere wählbare Dateien, mit Namen.
    var optionalNames: [String] = []
    /// Gekaufte Zusatzinhalte laden und freischalten.
    var addons = true
    /// Beim Installieren die Spielstände vom Mac zurückspielen, wenn das Spiel auf dem Gerät noch keine hat.
    /// Wählbar und nicht fest, weil ältere gespeicherte Angaben den Eintrag nicht kennen; ohne Angabe: ja.
    var restoreSaves: Bool?
}

/// Die in der Übersicht angehakten Spiele – ein eigener, kleiner Zustand (siehe `AppModel.picked`).
@MainActor
final class GameSelection: ObservableObject {
    @Published var ids: Set<String> = []
}

enum AccountState: Equatable {
    case unknown, checking, signedOut, signedIn
    /// Ein Token liegt im Schlüsselbund, Meta nimmt ihn aber nicht (mehr) an – oder ist nicht erreichbar.
    case problem(String)
}

enum AppSection: String, CaseIterable, Identifiable {
    /// Die Einstellungen stehen als letzter Punkt in der Seitenleiste, nicht in einem eigenen Fenster.
    case games, jobs, data, setup, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .games: return L("Games", "Spiele")
        case .jobs: return L("Jobs", "Aufträge")
        case .data: return L("Data", "Datenverwaltung")
        case .setup: return L("Setup", "Einrichtung")
        case .settings: return L("Settings", "Einstellungen")
        }
    }
    var symbol: String {
        switch self {
        case .games: return "square.grid.2x2"
        case .jobs: return "list.bullet.clipboard"
        case .data: return "externaldrive"
        case .setup: return "checklist"
        case .settings: return "gearshape"
        }
    }
}

/// Der Zustand der Oberfläche. Alles, was länger dauert (Gerät fragen, laden, bauen), läuft außerhalb des
/// Hauptfadens; hier landen nur die Ergebnisse.
@MainActor
final class AppModel: ObservableObject {
    @Published var section: AppSection = .games
    /// Das geöffnete Spiel in der Übersicht (leer: das Raster).
    @Published var gamePath: [String] = []
    @Published var games: [Game] = [] { didSet { rebuildAllGames() } }
    @Published var loadProblem: String?
    @Published var device: Device?
    @Published var devices: [Device] = []
    /// Das gewählte Headset, wenn mehrere erreichbar sind; leer heißt: das einzige.
    @AppStorage("deviceUDID") var chosenDevice = ""
    @Published var deviceProblem: String?
    @Published var refreshing = false
    @Published var toolchainText: String?
    @Published var account: AccountState = .unknown
    @Published var toolPresent = false
    @Published var xcodeText: String?
    @Published var xcodeProblem: String?
    @Published var jobs: [Job] = []
    @Published var selectedJob: String?
    @Published var runningJob: String?
    @Published var queued: [String] = []
    @Published var logs: [String: [String]] = [:]
    @Published var notice: String?
    @Published var teamCandidates: [Probe.Team] = []
    /// Metas letzte Antworten auf die Besitzfrage, je Store-App.
    @Published var ownership: [String: OwnershipRecord] = [:]
    @Published var checkingOwnership = false
    /// Spiele, für die gerade einzeln bei Meta nachgefragt wird („Kauf prüfen“), und was dabei zuletzt zu sagen war.
    @Published var checkingPurchase: Set<String> = []
    @Published var purchaseNote: [String: String] = [:]
    /// Was zuletzt beim Einrichten von Metas Werkzeug herauskam – steht in der Karte „Meta-Konto“.
    @Published var toolNote: String?
    /// Der Dialog „Ein Problem melden“ ist offen; `reportJob` nennt den Auftrag, um den es geht.
    @Published var showReport = false
    @Published var reportJob: Job?
    @Published var lookingForTool = false
    private var toolWatch: Task<Void, Never>?
    @Published var freeBytes: Int64?
    /// Der Online-Katalog: was der Dienst des Projekts über weitere Spiele sagt.
    @Published var catalog: [CatalogGame] = [] { didSet { rebuildAllGames() } }
    /// Alle Spiele der Übersicht: die mit dem Programm gelieferten und schon nachgeschlagenen, ergänzt um das,
    /// was vom Katalog bisher geladen ist. Wird neu gebaut, wenn sich eine der beiden Seiten ändert.
    @Published var allGames: [Game] = []
    @Published var catalogProblem: String?
    /// Wie viele Spiele der Katalog insgesamt kennt, und ob nach den geladenen Seiten noch welche kommen.
    @Published var catalogTotal: Int?
    @Published var catalogMore = false
    @Published var loadingMore = false
    var catalogNextPage = 0
    /// Nach welchen eigenen Spielen der Katalog schon gezielt gefragt wurde.
    var askedOwn: Set<String> = []
    /// Dasselbe für die laufende Suche.
    @Published var searchedQuery = ""
    @Published var searchMore = false
    var searchNextPage = 0
    @AppStorage("filterCommunity") var filterCommunity = false
    /// Steam: der Kontoname (kein Geheimnis; Passwort und Code sieht dieses Programm nie), ob Valves Werkzeug da
    /// ist und für welches Konto die Anmeldung zuletzt gelang.
    @AppStorage("steamAccount") var steamAccount = ""
    @AppStorage("steamSignedInAs") var steamSignedInAs = ""
    @Published var steamToolPresent = SteamTool().isInstalled
    @Published var steamSettingUp = false
    /// Valves Werkzeug liegt als Intel-Programm da, und dem Mac fehlt Rosetta.
    @Published var steamNeedsRosetta = SteamTool().needsRosetta()
    @Published var rosettaInstalling = false
    @Published var steamNote: String?
    /// Je Spiel: läuft gerade ein Abruf bei Steam, wie weit ist er, und was hat er zuletzt gesagt.
    @Published var steamBusy: Set<String> = []
    @Published var steamProgress: [String: SteamProgress] = [:]
    @Published var steamSaid: [String: String] = [:]
    let steamStops = StopFlags()
    @Published var searchText = ""
    @Published var searching = false
    @Published var preparing: Set<String> = []
    @Published var prepareNote: [String: String] = [:]
    @Published var favourites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "favourites") ?? [])
    @Published var sentFeedback: [String: String] = UserDefaults.standard.dictionary(forKey: "sentFeedback") as? [String: String] ?? [:]
    @AppStorage("onlineCatalog") var onlineCatalog = true
    /// Dem Katalog sagen, dass die App in Gebrauch ist und welche Spiele installiert wurden – ohne Kennung.
    @AppStorage("usageCounts") var usageCounts = true
    /// Titelbilder für Spiele, die noch nicht geladen sind, von deren öffentlicher Store-Seite holen.
    @AppStorage("storePictures") var storePictures = true
    /// Der aktuelle Build geprüfter Store-Spiele, wie der Katalog ihn kennt (Kennung des Rezepts → Build).
    @Published var storeBuilds: [String: CatalogBuild] = [:]
    /// Alle Fassungen, die der Store zu einem Spiel des Kontos nennt, die neueste zuerst (Kennung des Rezepts →
    /// Builds). Nur wo Meta selbst gefragt wurde; sonst kennt die App nur den einen Build des Katalogs.
    @Published var storeBuildLists: [String: [CatalogBuild]] = [:]
    /// Für welche Spiele die neueste Fassung aus dem Store statt der geprüften gewählt ist.
    @Published var latestChoices = StoreUpdate.Choices.load()
    /// Ältere Toolchains von selbst entfernen, sobald eine neuere installiert ist und nichts mehr mit ihnen baut.
    @AppStorage("autoRemoveOldToolchains") var autoRemoveOldToolchains = true
    /// Besorgt diese Bilder: zwei Abrufe zugleich, mit Zwischenspeicher.
    let covers = CoverLoader()
    @AppStorage("filterFavourites") var filterFavourites = false
    /// Was das Gerät zuletzt als installiert gemeldet hat, und ab welcher Toolchain-Nummer ein Bau aktuell ist.
    var installedApps: [InstalledApp]?
    var toolchainRevision: Int?
    /// Wie weit das Kopieren aufs Gerät im laufenden Auftrag ist.
    @Published var copyProgress: [String: InstallProgress] = [:]
    /// Eine neuere veröffentlichte Fassung, falls es eine gibt.
    @Published var update: AppRelease?
    @Published var updateState: UpdateState = .idle
    @AppStorage("autoUpdateCheck") var autoUpdateCheck = true
    @AppStorage("lastUpdateCheck") var lastUpdateCheck: Double = 0
    /// Das Entwicklerteam, das dieses Programm signiert hat; `nil` bei einem Bau ohne Identität.
    let ownTeam: String? = Bundle.main.bundleIdentifier == nil ? nil : Updater.team(of: Bundle.main.bundleURL)
    private var awake: NSObjectProtocol?
    @Published private var options: [String: GameOptions] = [:]
    /// Die Filter der Übersicht; mehrere zugleich engen weiter ein.
    @AppStorage("filterVerified") var filterVerified = false
    @AppStorage("filterInstalled") var filterInstalled = false
    /// Nur Spiele, deren Dateien vollständig auf dem Mac liegen, die aber nicht auf der Vision Pro sind.
    @AppStorage("filterDownloaded") var filterDownloaded = false
    private var routed = false
    @AppStorage("teamId") var teamId = ""
    /// Die Sprache, in der das Programm gerade spricht. Ansichten hängen daran und bauen sich beim Wechsel neu.
    @Published private(set) var language: Language = .en
    @AppStorage("language") private var languageRaw = LanguageChoice.system.rawValue
    /// Vom Nutzer gesetztes Präfix der App-Kennungen; leer heißt Standard.
    @AppStorage("bundlePrefix") var customBundlePrefix = ""

    /// Vor allem anderen: Daten aus der Zeit vor dem Namen „AVP Play“ übernehmen (der Ordner wird umbenannt).
    /// Neu gesetzt wird das nur, wenn der Ordner für Downloads gewechselt hat (siehe `moveStore`).
    @Published var paths: Paths = {
        DataLocation.adoptLegacyData()
        return Paths()
    }()
    /// Die Datenverwaltung: was auf dem Mac liegt, und ein laufender Umzug des Ordners für Downloads.
    @Published var storage: StorageOverview?
    @Published var storageScanning = false
    @Published var storeMove: StoreMove.Progress?
    @Published var storeMoveNote: String?
    let storeMoveStop = StopFlags()
    private var runningTask: Task<Void, Never>?
    private var stopRequested: Set<String> = []
    /// Die in der Übersicht angehakten Spiele, und ob gerade ein Sammelauftrag für sie vorbereitet wird.
    /// Nicht `@Published`: Hinge die Auswahl am Zustand der ganzen Oberfläche, würde jeder Haken die Übersicht neu
    /// filtern, sortieren und jede schon gezeichnete Karte samt Bild neu aufbauen – bei vielen geladenen Spielen
    /// spürbar träge. So hören nur die Haken, die Rahmen und die Leiste auf sie.
    let picked = GameSelection()
    var selection: Set<String> {
        get { picked.ids }
        set { picked.ids = newValue }
    }
    @Published var bulkBusy = false
    /// Der Hintergrunddienst, der ablaufende Signaturen erneuert: ob er eingetragen sein soll, in welchem Abstand
    /// er prüft, und was der letzte Lauf ergab.
    @AppStorage("renewInBackground") var renewInBackground = false
    @AppStorage("renewIntervalHours") var renewIntervalHours = BackgroundService.defaultInterval
    @Published var renewalReport: RenewalReport? = RenewalReport.load()
    @Published var renewalNote: String?
    @Published var renewing = false
    /// Spielstände: ob sie von selbst von der Vision Pro geholt werden, wann zuletzt alle Spiele dran waren, der
    /// neueste Stand je Spiel (nach Kennung des Rezepts), für welche Spiele gerade geholt oder zurückgespielt wird
    /// und was dabei zuletzt herauskam.
    @AppStorage("syncSaves") var syncSaves = true
    @AppStorage("lastSaveRound") var lastSaveRound: Double = 0
    @Published var saveSnapshots: [String: SaveSnapshot] = [:]
    @Published var savesBusy: Set<String> = []
    @Published var savesNote: [String: String] = [:]
    /// Welche Spiele bei der letzten Nachfrage auf dem Headset liefen – endet eines, werden seine Spielstände geholt.
    var runningGames: Set<String> = []
    var saveWatch: Task<Void, Never>?
    var saveTicks = 0

    init() {
        applyLanguage()
        if let data = UserDefaults.standard.data(forKey: "gameOptions"),
           let saved = try? JSONDecoder().decode([String: GameOptions].self, from: data) { options = saved }
    }

    // MARK: Besitz

    func owned(_ game: Game) -> Owned {
        guard let app = game.recipe.store.appId else { return .notApplicable }
        guard let record = ownership[app] else { return .unknown }
        return record.owned ? .yes : .no
    }

    /// Die Spiele, die zu den gesetzten Filtern passen.
    var shownGames: [Game] { visible(allGames) }

    /// Aus einer Menge von Spielen die, die zu den gesetzten Filtern passen, in der Reihenfolge der Übersicht.
    func visible(_ games: [Game]) -> [Game] {
        let words = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return games.filter { game in
            // „Geprüft“ und „Von Nutzern bestätigt“ ergänzen einander; alle anderen Filter engen weiter ein.
            ((!filterVerified && !filterCommunity) || (filterVerified && game.trust == .verified) || (filterCommunity && game.trust == .community))
                && (!filterInstalled || game.installed)
                && (!filterDownloaded || (game.downloaded && !game.installed))
                && (!filterFavourites || isFavourite(game))
                && (words.isEmpty || game.recipe.title.lowercased().contains(words) || game.recipe.package.lowercased().contains(words))
        }.sorted { a, b in
            // Geprüftes zuerst, dann schon Nachgeschlagenes, dann was Nutzer bestätigen, das Ungetestete, zuletzt
            // was nicht läuft – jeweils nach der Zahl derer, die sagen, es läuft, dann nach Namen. So reiht auch
            // der Katalog, damit eine nachgeladene Seite unten anschließt.
            let rank: (Game) -> Int = { $0.trust == .verified ? 0 : ($0.prepared && $0.trust != .incompatible ? 1 : $0.trust.rawValue + 1) }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            let works: (Game) -> Int = { $0.catalog?.works ?? 0 }
            if works(a) != works(b) { return works(a) > works(b) }
            return a.recipe.title.localizedCaseInsensitiveCompare(b.recipe.title) == .orderedAscending
        }
    }

    /// Fragt Meta für jedes Store-Spiel, ob das Konto es besitzt – eine dokumentierte Abfrage je Spiel, mit
    /// Abstand dazwischen, höchstens einmal am Tag. Beim ersten unerwarteten Ergebnis ist Schluss; was bis
    /// dahin beantwortet ist, bleibt stehen.
    func checkOwnership(force: Bool = false) {
        // Der Besitzstand liegt beim Bestand. Fehlt dessen Platte, wird Meta nicht für jedes Spiel neu gefragt, nur
        // weil der gemerkte Stand gerade nicht lesbar ist – und nichts an den verwaisten Pfad geschrieben.
        guard account == .signedIn, !checkingOwnership, !games.isEmpty, storeBlocker == nil else { return }
        let cache = OwnershipCache(store: paths.store)
        let known = cache.load()
        ownership = known
        let due = games.compactMap { $0.recipe.store.appId }.filter { force || OwnershipCache.needsCheck(known[$0]) }
        guard !due.isEmpty else { return }
        checkingOwnership = true
        Task.detached {
            let gate = RequestGate()
            do {
                let client = MetaClient(token: try TokenStore().read())
                let user = try await client.me()
                for app in due {
                    try await gate.waitForTurn()
                    let owned = try await client.ownsApp(appId: app, userId: user)
                    await gate.requestFinished()
                    let now = cache.record(appId: app, owned: owned)
                    await MainActor.run { self.ownership = now }
                }
            } catch {}
            await MainActor.run { self.checkingOwnership = false }
        }
    }

    /// „Kauf prüfen“: fragt Meta jetzt für dieses eine Spiel, ob das Konto es besitzt – dieselbe dokumentierte
    /// Abfrage wie im täglichen Durchgang, nach `/me`, und trägt die Antwort ein. Für jemanden, der ein Spiel
    /// gerade gekauft hat und es hier noch als „nicht in deinem Meta-Konto“ sieht.
    func checkPurchase(_ game: Game, quiet: Bool = false) {
        guard let app = game.recipe.store.appId, !checkingPurchase.contains(game.id) else { return }
        if let why = storeBlocker { purchaseNote[game.id] = why; return }
        guard account == .signedIn else {
            purchaseNote[game.id] = L("Sign in to Meta under “Setup” first.", "Melde dich zuerst unter „Einrichtung“ bei Meta an.")
            return
        }
        checkingPurchase.insert(game.id)
        purchaseNote[game.id] = nil
        let cache = OwnershipCache(store: paths.store)
        let id = game.id
        Task.detached {
            var note: String?
            var owned: Bool?
            do {
                let client = MetaClient(token: try TokenStore().read())
                let user = try await client.me()
                let answer = try await client.ownsApp(appId: app, userId: user)
                owned = answer
                let now = cache.record(appId: app, owned: answer)
                await MainActor.run { self.ownership = now }
                // Ungefragt (beim Öffnen der Seite) wird ein weiteres „Nein“ nicht eigens erläutert.
                if !answer, !quiet {
                    note = L("Meta says this game is not in the account you are signed in with. A new purchase can take a few minutes to show up; a game bought with another Meta account needs that account under “Setup”.",
                             "Meta sagt, dass dieses Spiel nicht zu dem Konto gehört, mit dem du angemeldet bist. Ein neuer Kauf kann ein paar Minuten brauchen, bis er sichtbar ist; ein Spiel, das mit einem anderen Meta-Konto gekauft wurde, braucht dieses Konto unter „Einrichtung“.")
                }
            } catch {
                if !quiet { note = L("Meta could not be asked: \(Redaction.redact("\(error)"))", "Meta ließ sich nicht fragen: \(Redaction.redact("\(error)"))") }
            }
            let final = note
            let bought = owned == true
            await MainActor.run {
                self.checkingPurchase.remove(id)
                self.purchaseNote[id] = final
                // Ein ungetestetes Spiel, das nun doch zum Konto gehört: gleich nachschlagen, woraus es besteht.
                if bought, let game = self.allGames.first(where: { $0.id == id }), game.draft, !game.prepared { self.prepare(game) }
            }
        }
    }

    /// Beim Öffnen der Seite eines Spiels: Ein „Nein“, das älter als zehn Minuten ist, wird noch einmal erfragt.
    /// Nicht bei einem ungetesteten Spiel, das noch nachgeschlagen wird – dort stellt `prepare` dieselbe Frage.
    func recheckPurchaseIfStale(_ game: Game) {
        guard let app = game.recipe.store.appId, let record = ownership[app], !record.owned,
              Date().timeIntervalSince(record.checked) > 600, account == .signedIn, !(game.draft && !game.prepared) else { return }
        checkPurchase(game, quiet: true)
    }

    // MARK: Auswahl je Spiel

    func options(for game: Game) -> GameOptions {
        options[game.id] ?? AppModel.defaultOptions(recipe: game.recipe, store: paths.store)
    }

    func setOptions(_ value: GameOptions, for game: Game) {
        options[game.id] = value
        if let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: "gameOptions") }
    }

    /// Wählbare Dateien, die das Rezept unter eigenem Namen anbietet – etwa eine Sprachausgabe von Fans.
    nonisolated static func extras(of recipe: Recipe) -> [RecipeFile] {
        recipe.files.filter { !$0.required && $0.locale == nil && $0.title != nil }
    }

    func inLibrary(_ file: RecipeFile, of game: Game) -> Bool {
        if case .present(let size) = paths.store.state(of: file, in: game.recipe) { return file.size == nil || file.size == size }
        return false
    }

    /// Angehakt, vom Nutzer bereitzustellen (oder aus seinem Steam-Konto zu holen), und noch nicht im Bestand.
    func missingExtras(for game: Game) -> [RecipeFile] {
        let extras = AppModel.extras(of: game.recipe)
        guard !extras.isEmpty else { return [] }
        let chosen = Set(options(for: game).optionalNames)
        return extras.filter { chosen.contains($0.name) && $0.source?.kind == .user && !inLibrary($0, of: game) }
    }

    /// Ohne eigene Wahl: was schon im Bestand liegt, bleibt gewählt; sonst die Sprache des Systems, wenn es
    /// dafür Dateien gibt. Englisch braucht bei Sprachpaketen nichts – es ist die Fassung des Spiels selbst.
    nonisolated static func defaultOptions(recipe: Recipe, store: ContentStore,
                                           preferred: [String] = Locale.preferredLanguages) -> GameOptions {
        let optional = recipe.files.filter { !$0.required }
        func present(_ f: RecipeFile) -> Bool { if case .present = store.state(of: f, in: recipe) { return true }; return false }
        var result = GameOptions()
        var locales = Set(optional.filter(present).compactMap(\.locale))
        let available = Set(optional.compactMap(\.locale))
        if locales.isEmpty {
            for language in preferred {
                let code = language.split(separator: "-").first.map(String.init) ?? language
                if let match = available.first(where: { $0 == language }) ?? available.sorted().first(where: { $0 == code || $0.hasPrefix(code + "-") }) {
                    locales.insert(match)
                    break
                }
                if code == "en" { break }
            }
        }
        result.locales = locales.sorted()
        result.optionalNames = optional.filter { $0.locale == nil && present($0) }.map(\.name).sorted()
        return result
    }

    /// Wie weit der Download eines Auftrags ist: vorhandene und angefangene Bytes gegen die bekannte Summe.
    func downloadProgress(_ job: Job) -> (done: Int64, total: Int64)? {
        var selection = FetchSelection(locales: Set(job.request.locales), optionalNames: Set(job.request.optionalNames),
                                       withheld: paths.store.withheld(for: job.recipe))
        if job.recipe.addons?.kind == .deliveredAssets, job.request.addons,
           let purchases = PurchaseRecord.load(store: paths.store, recipe: job.recipe) { selection.ownedSKUs = Set(purchases.skus) }
        var done: Int64 = 0, total: Int64 = 0
        for file in FetchPlan.wantedFiles(recipe: job.recipe, selection: selection) where file.source?.kind != .user {
            guard let size = file.size else { continue }
            total += size
            switch paths.store.state(of: file, in: job.recipe) {
            case .present(let have), .partial(let have): done += min(have, size)
            case .missing: break
            }
        }
        return total > 0 ? (done, total) : nil
    }

    var languageChoice: LanguageChoice {
        get { LanguageChoice(rawValue: languageRaw) ?? .system }
        set {
            languageRaw = newValue.rawValue
            applyLanguage()
            // Was schon als Satz im Zustand liegt (Gerät, Xcode, Toolchain), entsteht beim Prüfen neu.
            refresh()
        }
    }

    /// Stellt die Sprache ein: die gewählte, sonst die erste bevorzugte des Systems. Eine feste Wahl wird
    /// auch als `AppleLanguages` dieses Programms hinterlegt, damit die Menüs von macOS beim nächsten Start
    /// dieselbe Sprache haben.
    private func applyLanguage() {
        let choice = LanguageChoice(rawValue: languageRaw) ?? .system
        let chosen: Language
        if choice == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            let system = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                                kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
            chosen = L10n.systemLanguage(preferred: system ?? Locale.preferredLanguages)
        } else {
            chosen = Language(rawValue: choice.rawValue) ?? .en
            UserDefaults.standard.set([chosen.rawValue], forKey: "AppleLanguages")
        }
        L10n.language = chosen
        language = chosen
    }

    /// Das Präfix, unter dem die Spiele installiert werden: das gewählte, sonst der Standard.
    var bundlePrefix: String {
        customBundlePrefix.isEmpty ? Toolchain.defaultBundlePrefix(freeTeam: team?.free == true ? teamId : nil) : customBundlePrefix
    }

    var teamValid: Bool { teamId.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil }
    /// Das gewählte Team, soweit Xcode es kennt.
    var team: Probe.Team? { teamCandidates.first { $0.id == teamId } }
    var toolchain: Toolchain? { paths.toolchain() }

    /// Was einer Installation im Weg steht, als Satz mit der nächsten Handlung – oder `nil`.
    func blocker(for game: Game) -> String? {
        if let why = storeBlocker { return why }
        if xcodeProblem != nil { return L("Xcode is missing. “Setup” tells you what to do.", "Xcode fehlt. Unter „Einrichtung“ steht, was zu tun ist.") }
        if toolchain == nil { return L("The toolchain is not installed yet (see “Setup”).", "Die Toolchain ist noch nicht installiert (siehe „Einrichtung“).") }
        if !teamValid { return L("The Apple team ID is still missing (see “Setup”).", "Die Apple-Team-ID fehlt noch (siehe „Einrichtung“).") }
        if device == nil { return deviceProblem ?? L("The Vision Pro is not reachable.", "Die Vision Pro ist nicht erreichbar.") }
        if game.draft, !game.prepared {
            return prepareNote[game.id] ?? L("The files of this game have not been looked up yet.", "Die Dateien dieses Spiels sind noch nicht nachgeschlagen.")
        }
        if game.needsMetaAccount, account != .signedIn { return L("Sign in to Meta first (see “Setup”).", "Erst bei Meta anmelden (siehe „Einrichtung“).") }
        if owned(game) == .no {
            return L("This game is not in your Meta account, so nothing is downloaded.",
                     "Dieses Spiel gehört nicht zu deinem Meta-Konto. Es wird nichts geladen.")
        }
        if let why = freeAccountBlocker(for: game) { return why }
        if !game.status.userProvidedMissing.isEmpty { return L("Files that you provide yourself are missing (see below).", "Es fehlen Dateien, die du selbst bereitstellst (siehe unten).") }
        if let extra = missingExtras(for: game).first {
            let name = extra.title?.text ?? extra.name
            return L("“\(name)” is ticked but not on this Mac yet (see “Optional Content”).",
                     "„\(name)“ ist angehakt, liegt aber noch nicht auf diesem Mac (siehe „Wählbare Inhalte“).")
        }
        // Ein Entwurf, der ohne Toolchain nachgeschlagen wurde, nennt noch keinen Mindeststand; der wird beim Anlegen
        // des Auftrags eingesetzt.
        if let t = toolchain, !game.recipe.toolchain.minCommit.isEmpty, !t.satisfies(minCommit: game.recipe.toolchain.minCommit) {
            return L("This game needs a newer toolchain than the one installed.", "Dieses Spiel braucht eine neuere Toolchain als die installierte.")
        }
        if isBusy(game.id) { return L("A job for this game is already running.", "Für dieses Spiel läuft schon ein Auftrag.") }
        // Platz für den Download, mit zwei Gigabyte Luft für Bau und Zwischenstände.
        if let free = freeBytes, game.status.bytesToDownload > 0, game.status.bytesToDownload + 2_000_000_000 > free {
            return L("Not enough free space on this Mac: \(Installer.gigabytes(game.status.bytesToDownload)) to download, \(Installer.gigabytes(free)) free.",
                     "Auf diesem Mac ist zu wenig Platz: \(Installer.gigabytes(game.status.bytesToDownload)) zu laden, \(Installer.gigabytes(free)) frei.")
        }
        return nil
    }

    func isBusy(_ recipeId: String) -> Bool {
        jobs.contains { $0.recipe.id == recipeId && ($0.id == runningJob || queued.contains($0.id)) }
    }

    // MARK: Lage feststellen

    func refresh() {
        guard !refreshing else { return }
        // Auf der Seite der Datenverwaltung heißt „neu laden“ auch: neu zählen.
        if section == .data { scanStorage() }
        refreshing = true
        let paths = paths
        let prefix = bundlePrefix
        let wanted = chosenDevice.isEmpty ? nil : chosenDevice
        Task.detached(priority: .userInitiated) {
            let snapshot = Probe.run(paths: paths, bundlePrefix: prefix, preferredDevice: wanted)
            await MainActor.run {
                self.apply(snapshot)
                self.refreshing = false
            }
        }
    }

    private func apply(_ s: Probe.Snapshot) {
        // Vor den Spielen: daraus wird die Liste aller Spiele gebaut, und die braucht den neuen Stand des Geräts.
        installedApps = s.apps
        toolchainRevision = s.toolchainRevision
        games = s.games
        loadOwnCatalogEntries()
        checkStoreVersions()
        loadProblem = s.loadProblem
        device = s.device
        devices = s.devices
        deviceProblem = s.deviceProblem
        toolchainText = s.toolchainText
        toolPresent = s.toolPresent
        xcodeText = s.xcodeText
        xcodeProblem = s.xcodeProblem
        teamCandidates = s.teamCandidates
        freeBytes = s.freeBytes
        // Genau ein bezahltes Team: das ist es. Sonst entscheidet der Nutzer.
        let paid = s.teamCandidates.filter { !$0.free }
        if teamId.isEmpty, paid.count == 1 { teamId = paid[0].id }
        saveSnapshots = s.saves
        reloadJobs()
        ownership = OwnershipCache(store: paths.store).load()
        checkOwnership()
        // Beim ersten Start dorthin, wo etwas zu tun ist. Ein ausgeschaltetes Headset zählt nicht dazu.
        if !routed {
            routed = true
            if xcodeProblem != nil || !teamValid || toolchainText == nil { section = .setup }
        }
    }

    func reloadJobs() {
        jobs = paths.jobs.all().sorted { $0.created > $1.created }
        if selectedJob == nil || !jobs.contains(where: { $0.id == selectedJob }) { selectedJob = jobs.first?.id }
    }

    /// Fragt Meta, ob der hinterlegte Token gilt. Eine einzige Abfrage; gezeigt wird nie mehr als ja oder nein.
    func checkAccount() {
        guard account != .checking else { return }
        account = .checking
        Task.detached {
            let state: AccountState
            do {
                let token = try TokenStore().read()
                do {
                    _ = try await MetaClient(token: token).me()
                    state = .signedIn
                } catch {
                    state = .problem(Redaction.redact("\(error)"))
                }
            } catch {
                state = .signedOut
            }
            await MainActor.run {
                self.account = state
                self.checkOwnership()
            }
        }
    }

    func signOut() {
        _ = try? TokenStore().delete()
        account = .signedOut
        OwnershipCache(store: paths.store).clear()
        ownership = [:]
    }

    // MARK: Metas Werkzeug

    static let toolPage = URL(string: "https://developers.meta.com/horizon/resources/publish-reference-platform-command-line-utility/")!

    /// Öffnet Metas Seite im Browser und hält danach eine Weile im Ordner „Downloads“ Ausschau: Sobald die
    /// Datei dort liegt, richtet die App sie ein. Geladen wird beim Nutzer, im Browser, zu Metas Bedingungen –
    /// die App lädt das Werkzeug nie selbst und bringt es nicht mit.
    func openToolPage() {
        NSWorkspace.shared.open(AppModel.toolPage)
        toolNote = L("Download the macOS version on Meta’s page. AVP Play picks it up from your Downloads folder as soon as it is there.",
                     "Lade auf Metas Seite die Fassung für macOS. AVP Play übernimmt sie aus deinem Ordner „Downloads“, sobald sie dort liegt.")
        toolWatch?.cancel()
        lookingForTool = true
        toolWatch = Task { [weak self] in
            for _ in 0..<450 {                      // 15 Minuten
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, !self.toolPresent else { break }
                if await self.adoptToolFromDownloads(quiet: true) { break }
            }
            self?.lookingForTool = false
        }
    }

    /// Sucht jetzt im Ordner „Downloads“ und sagt, was dabei herauskam.
    func findTool() {
        Task { await adoptToolFromDownloads(quiet: false) }
    }

    @discardableResult
    private func adoptToolFromDownloads(quiet: Bool) async -> Bool {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let outcome: (ok: Bool, note: String?) = await Task.detached {
            // macOS fragt beim ersten Zugriff auf „Downloads“ um Erlaubnis. Wurde sie verweigert, lässt sich
            // der Ordner nicht lesen – dann bleibt die Dateiauswahl, die diese Erlaubnis nicht braucht.
            guard (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil else {
                return (false, quiet ? nil : L("AVP Play is not allowed to look into your Downloads folder. Use “Choose File …” instead, or allow it under System Settings › Privacy & Security › Files and Folders.",
                                               "AVP Play darf nicht in deinen Ordner „Downloads“ sehen. Nimm stattdessen „Datei auswählen …“, oder erlaube es unter Systemeinstellungen › Datenschutz & Sicherheit › Dateien und Ordner."))
            }
            let candidates = MetaTool.downloads(in: folder)
            guard !candidates.isEmpty else {
                return (false, quiet ? nil : L("There is no file named “ovr-platform-util” in your Downloads folder yet.",
                                               "In deinem Ordner „Downloads“ liegt noch keine Datei namens „ovr-platform-util“."))
            }
            var problem = ""
            for file in candidates {
                do {
                    try MetaTool.adopt(from: file)
                    return (true, nil)
                } catch { problem = "\(error)" }
            }
            return (false, problem)
        }.value
        finishToolSetup(ok: outcome.ok, note: outcome.note)
        return outcome.ok
    }

    /// Richtet eine vom Nutzer gewählte Datei ein.
    func adoptTool(from file: URL) {
        Task {
            let problem: String? = await Task.detached {
                do { try MetaTool.adopt(from: file); return nil } catch { return "\(error)" }
            }.value
            finishToolSetup(ok: problem == nil, note: problem)
        }
    }

    private func finishToolSetup(ok: Bool, note: String?) {
        if ok {
            toolWatch?.cancel()
            lookingForTool = false
            toolPresent = true
            toolNote = L("Meta’s tool is set up. You can sign in now.", "Metas Werkzeug ist eingerichtet. Du kannst dich jetzt anmelden.")
        } else if let note {
            toolNote = note
        }
    }

    // MARK: Dateien des Nutzers übernehmen

    /// Sucht in einem vom Nutzer gewählten Ordner nach den Dateien und Ordnern, die das Rezept verlangt.
    func adopt(_ game: Game, from folder: URL) {
        let paths = paths
        notice = L("Searching the folder …", "Ordner wird durchsucht …")
        Task.detached {
            var found: [String] = []
            var problem: String?
            do {
                let r = try Adopter(store: paths.store).adopt(recipe: game.recipe, from: [folder])
                found += r.adopted
                if !r.mismatched.isEmpty { problem = L("Not the expected version: \(r.mismatched.joined(separator: ", "))", "Nicht die erwartete Fassung: \(r.mismatched.joined(separator: ", "))") }
                if !(game.recipe.trees ?? []).isEmpty {
                    found += try TreeStore(store: paths.store).adopt(recipe: game.recipe, from: [folder]).adopted
                }
            } catch {
                problem = "\(error)"
            }
            let text = problem ?? (found.isEmpty ? L("Nothing matching was found in this folder.", "In diesem Ordner wurde nichts Passendes gefunden.")
                                                 : L("Added: \(found.joined(separator: ", "))", "Übernommen: \(found.joined(separator: ", "))"))
            await MainActor.run {
                self.notice = text
                self.refresh()
            }
        }
    }

    // MARK: Toolchain

    /// Das Programmpaket bringt eine Toolchain mit. Ist keine installiert oder nur eine ältere, wird die
    /// mitgelieferte installiert – geprüft wie jedes andere Paket (Größe, Prüfsumme, Inhalt).
    func installBundledToolchainIfNewer() {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("toolchain", isDirectory: true),
              let archive = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
                  .first(where: { $0.lastPathComponent.hasSuffix(".tar.gz") }) else { return }
        let paths = paths
        Task.detached {
            guard let bundled = Paths.manifest(beside: archive) else { return }
            if let installed = paths.packager.installed().first?.manifest, installed.version >= bundled.version {
                await MainActor.run { self.removeOlderToolchainsAutomatically() }
                return
            }
            let text: String
            do {
                let t = try paths.packager.install(archive: archive)
                text = L("Toolchain version \(t.version()) has been installed.", "Toolchain Version \(t.version()) wurde installiert.")
            } catch {
                text = L("The toolchain that comes with this app could not be installed: \(error)",
                         "Die mitgelieferte Toolchain konnte nicht installiert werden: \(error)")
            }
            await MainActor.run {
                self.notice = text
                self.refresh()
                self.removeOlderToolchainsAutomatically()
            }
        }
    }

    /// Räumt ältere Toolchains weg, ohne dass jemand darum bitten muss: nach dem Start, nach dem Installieren einer
    /// neueren und nach jedem Auftrag. In der neuesten fällt dabei weg, was Spiele beim Bauen hinterlassen haben,
    /// deren letzter Bau über eine Woche her ist. Eine Toolchain wächst mit jedem gebauten Spiel um Gigabytes, und gebaut wird
    /// immer mit der neuesten – die älteren braucht nur noch ein Auftrag, der gerade wartet oder läuft. Baut oder
    /// kopiert gerade irgendein AVP-Play-Prozess (auch der Hintergrunddienst), passiert nichts; der nächste Anlass
    /// holt es nach.
    nonisolated static let buildLeftoverAge: TimeInterval = 7 * 24 * 3600

    func removeOlderToolchainsAutomatically() {
        guard autoRemoveOldToolchains, runningJob == nil else { return }
        let paths = paths
        let active = jobs.filter { $0.state == .waiting || $0.state == .running }
        let open = Set(active.map(\.toolchainCommit)), busy = Set(active.map(\.recipe.toolchain.target))
        // Die Kopie des APK heißt nicht bei jedem Spiel wie sein Target; den Namen kennt das Rezept.
        var apkNames: [String: String] = [:]
        for recipe in games.map(\.recipe) + jobs.map(\.recipe) {
            if let name = recipe.files.first(where: { $0.role == "apk" })?.localName { apkNames[recipe.toolchain.target] = name }
        }
        Task.detached(priority: .utility) {
            guard let cleared = paths.packager.pruneWhenIdle(protecting: open, leftoversOlderThan: AppModel.buildLeftoverAge,
                                                             apkNames: apkNames, busyTargets: busy),
                  !cleared.isEmpty else { return }
            var parts: [String] = []
            if !cleared.toolchains.isEmpty {
                let names = cleared.toolchains.map { String($0.version) }.joined(separator: ", ")
                parts.append(cleared.toolchains.count == 1
                    ? L("an older toolchain (version \(names))", "eine ältere Toolchain (Version \(names))")
                    : L("\(cleared.toolchains.count) older toolchains (versions \(names))", "\(cleared.toolchains.count) ältere Toolchains (Versionen \(names))"))
            }
            if !cleared.games.isEmpty {
                parts.append(cleared.games.count == 1
                    ? L("the build leftovers of one game built more than a week ago", "die Bau-Reste eines Spiels, das vor über einer Woche gebaut wurde")
                    : L("the build leftovers of \(cleared.games.count) games built more than a week ago", "die Bau-Reste von \(cleared.games.count) Spielen, die vor über einer Woche gebaut wurden"))
            }
            let what = parts.joined(separator: L(" and ", " und "))
            await MainActor.run {
                self.notice = L("Tidied up: \(what) removed from this Mac. Nothing on the Vision Pro or among the downloads was touched.",
                                "Aufgeräumt: \(what) von diesem Mac entfernt. Vision Pro und Downloads sind unberührt.")
                self.scanStorage()
            }
        }
    }

    func installToolchain(archive: URL) {
        let paths = paths
        notice = L("Checking and unpacking the toolchain package …", "Toolchain-Paket wird geprüft und entpackt …")
        Task.detached {
            let text: String
            do {
                let t = try paths.packager.install(archive: archive)
                text = L("Toolchain version \(t.version()) is installed.", "Toolchain Version \(t.version()) ist installiert.")
            } catch {
                text = "\(error)"
            }
            await MainActor.run {
                self.notice = text
                self.refresh()
            }
        }
    }

    // MARK: Aufträge

    func install(_ game: Game) {
        guard blocker(for: game) == nil else { return }
        enqueue(game, steps: InstallStep.allCases)
    }

    /// Was dem bloßen Laden im Weg steht. Es braucht nur, was mit den Dateien zu tun hat: den Ordner für Downloads,
    /// das Konto, bei dem das Spiel gekauft ist, und Platz. Xcode, Toolchain, Apple-Team und Vision Pro spielen
    /// keine Rolle – wer die noch nicht hat, kann schon laden und später bauen.
    func downloadBlocker(for game: Game) -> String? {
        if let why = storeBlocker { return why }
        if game.draft, !game.prepared {
            return prepareNote[game.id] ?? L("The files of this game have not been looked up yet.", "Die Dateien dieses Spiels sind noch nicht nachgeschlagen.")
        }
        if game.needsMetaAccount, account != .signedIn { return L("Sign in to Meta first (see “Setup”).", "Erst bei Meta anmelden (siehe „Einrichtung“).") }
        if owned(game) == .no {
            return L("This game is not in your Meta account, so nothing is downloaded.",
                     "Dieses Spiel gehört nicht zu deinem Meta-Konto. Es wird nichts geladen.")
        }
        if isBusy(game.id) { return L("A job for this game is already running.", "Für dieses Spiel läuft schon ein Auftrag.") }
        if let free = freeBytes, game.status.bytesToDownload + 2_000_000_000 > free {
            return L("Not enough free space on this Mac: \(Installer.gigabytes(game.status.bytesToDownload)) to download, \(Installer.gigabytes(free)) free.",
                     "Auf diesem Mac ist zu wenig Platz: \(Installer.gigabytes(game.status.bytesToDownload)) zu laden, \(Installer.gigabytes(free)) frei.")
        }
        return nil
    }

    /// Ob es für das Spiel etwas gibt, das das Programm selbst laden kann und das noch fehlt. Gezählt werden die
    /// Dateien, nicht ihre Größe: bei einem nachgeschlagenen Spiel aus dem Meta-Store kennt die vorab niemand.
    func hasDownloads(_ game: Game) -> Bool { game.status.filesToDownload > 0 || game.status.bytesToDownload > 0 }

    /// Lädt die Dateien des Spiels, ohne es zu bauen oder zu installieren.
    func download(_ game: Game) {
        guard hasDownloads(game), downloadBlocker(for: game) == nil else { return }
        enqueue(game, steps: InstallStep.download)
    }

    /// Was dem Abgleich der Zusatzinhalte im Weg steht. Anders als eine Installation braucht er kein Xcode und
    /// kein Apple-Team – aber das Spiel muss schon auf dem Gerät sein.
    func syncBlocker(for game: Game) -> String? {
        if let why = storeBlocker { return why }
        if toolchain == nil { return L("The toolchain is not installed yet (see “Setup”).", "Die Toolchain ist noch nicht installiert (siehe „Einrichtung“).") }
        if device == nil { return deviceProblem ?? L("The Vision Pro is not reachable.", "Die Vision Pro ist nicht erreichbar.") }
        if !game.installed { return L("Install the game first – this only adds to a game that is on the Vision Pro.", "Erst das Spiel installieren – das hier ergänzt nur ein Spiel, das schon auf der Vision Pro ist.") }
        if account != .signedIn { return L("Sign in to Meta first (see “Setup”).", "Erst bei Meta anmelden (siehe „Einrichtung“).") }
        if owned(game) == .no { return L("This game is not in your Meta account, so nothing is downloaded.", "Dieses Spiel gehört nicht zu deinem Meta-Konto. Es wird nichts geladen.") }
        if isBusy(game.id) { return L("A job for this game is already running.", "Für dieses Spiel läuft schon ein Auftrag.") }
        return nil
    }

    /// Fragt Meta neu, welche Zusatzinhalte gekauft sind, lädt die fehlenden und legt sie zum installierten Spiel –
    /// ohne es neu zu bauen.
    func syncAddons(_ game: Game) {
        guard game.recipe.addons != nil, syncBlocker(for: game) == nil else { return }
        enqueue(game, steps: InstallStep.addonSync, addons: true)
    }

    /// Was dem Nachreichen gewählter Inhalte im Weg steht. Wie beim Abgleich der Zusatzinhalte braucht es weder Xcode
    /// noch ein Apple-Team – aber das Spiel muss schon auf dem Gerät sein.
    func extrasBlocker(for game: Game) -> String? {
        if let why = storeBlocker { return why }
        if toolchain == nil { return L("The toolchain is not installed yet (see “Setup”).", "Die Toolchain ist noch nicht installiert (siehe „Einrichtung“).") }
        if device == nil { return deviceProblem ?? L("The Vision Pro is not reachable.", "Die Vision Pro ist nicht erreichbar.") }
        if !game.installed { return L("Install the game first – this only adds to a game that is on the Vision Pro.", "Erst das Spiel installieren – das hier ergänzt nur ein Spiel, das schon auf der Vision Pro ist.") }
        if isBusy(game.id) { return L("A job for this game is already running.", "Für dieses Spiel läuft schon ein Auftrag.") }
        return nil
    }

    /// Löscht eine wählbare Datei aus dem Bestand auf diesem Mac. Auf dem Gerät ändert das nichts.
    func removeFromLibrary(_ file: RecipeFile, of game: Game) {
        guard !isBusy(game.id), !steamBusy.contains(game.id) else { return }
        do {
            try FileManager.default.removeItem(at: paths.store.url(for: file, in: game.recipe))
            notice = L("“\(file.title?.text ?? file.name)” has been removed from this Mac.", "„\(file.title?.text ?? file.name)“ wurde von diesem Mac entfernt.")
        } catch {
            notice = "\(error.localizedDescription)"
        }
        refresh()
    }

    /// Gleicht die wählbaren Inhalte mit dem installierten Spiel ab, ohne es neu zu bauen: Gewähltes, das im Bestand
    /// liegt, wird kopiert; Abgewähltes, das sich vom Gerät nehmen lässt, wird dort geleert.
    func syncExtras(_ game: Game) {
        guard extrasBlocker(for: game) == nil, missingExtras(for: game).isEmpty else { return }
        enqueue(game, steps: InstallStep.contentSync)
    }

    /// - Parameter show: zur Seite „Aufträge“ wechseln und den neuen Auftrag zeigen. Ein Sammelauftrag tut das
    ///   einmal am Ende, nicht für jedes Spiel.
    func enqueue(_ game: Game, steps: [InstallStep], addons: Bool? = nil, show: Bool = true) {
        // Nur wer baut oder aufs Gerät kopiert, braucht die Toolchain.
        let downloadOnly = steps == InstallStep.download
        let toolchain = toolchain
        guard toolchain != nil || downloadOnly else { return }
        // Ein Entwurf, der ohne Toolchain nachgeschlagen wurde: Jetzt, wo gebaut wird, steht fest, mit welchem Stand.
        var recipe = game.recipe
        if game.draft, recipe.toolchain.minCommit.isEmpty, !downloadOnly, let toolchain {
            recipe = DraftRecipe.retargeted(recipe, target: recipe.toolchain.target, minCommit: toolchain.commit())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try? encoder.encode(recipe).write(to: draftsDirectory.appendingPathComponent("\(recipe.id).json"), options: .atomic)
        }
        var request = InstallRequest(toolchain: toolchain?.root.path ?? "")
        if downloadOnly { request.downloadOnly = true }
        request.team = teamId
        request.device = device?.udid
        let chosen = options(for: game)
        request.locales = chosen.locales
        request.optionalNames = chosen.optionalNames
        request.addons = addons ?? chosen.addons
        // Nur eine Installation spielt Spielstände zurück; ein Abgleich von Inhalten rührt sie nicht an.
        if steps.contains(.build) { request.restoreSaves = chosen.restoreSaves ?? true }
        // Ein eigenes Präfix oder das eines kostenlosen Teams: dann steht die Kennung im Auftrag.
        let prefix = bundlePrefix
        if prefix != Toolchain.defaultBundlePrefix() { request.bundleId = "\(prefix).\(game.recipe.toolchain.target)" }
        do {
            // Eingefroren wird der Stand, mit dem der Auftrag beginnt.
            let job = Job(recipe: recipe, request: request, steps: steps, toolchainCommit: toolchain?.commit() ?? "")
            try paths.jobs.save(job)
            queued.append(job.id)
            reloadJobs()
            if show {
                selectedJob = job.id
                section = .jobs
            }
            pump()
        } catch {
            notice = "\(error)"
        }
    }

    /// Spiele, für die es eine neuere Fassung gibt und denen nichts im Weg steht.
    var updatable: [Game] {
        games.filter { game in
            switch game.status.onDevice {
            case .olderToolchain, .olderGame, .unstamped: return blocker(for: game) == nil
            case .current, .notInstalled, .unknown: return false
            }
        }
    }

    /// Legt für jedes aktualisierbare Spiel einen Auftrag an; sie laufen nacheinander.
    func updateAll() {
        let list = updatable
        for game in list { install(game) }
        if let first = list.first, let job = jobs.first(where: { $0.recipe.id == first.id }) { selectedJob = job.id }
    }

    /// Löscht, was dieses Programm für ein Spiel auf dem Mac abgelegt hat. Auf dem Gerät ändert sich nichts.
    func removeFiles(_ game: Game) {
        guard !isBusy(game.id) else { return }
        let directory = paths.store.directory(for: game.recipe)
        notice = L("Removing files …", "Dateien werden entfernt …")
        Task.detached {
            let problem: String?
            do {
                if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
                problem = nil
            } catch {
                problem = "\(error.localizedDescription)"
            }
            await MainActor.run {
                self.notice = problem ?? L("The files of \(game.recipe.title) have been removed from this Mac.",
                                           "Die Dateien von \(game.recipe.title) wurden von diesem Mac entfernt.")
                self.refresh()
            }
        }
    }

    func resume(_ job: Job) {
        guard job.id != runningJob, !queued.contains(job.id) else { return }
        queued.append(job.id)
        pump()
    }

    /// Hält einen Auftrag an. Läuft gerade ein Schritt, endet der Auftrag danach; Downloads brechen sofort ab.
    /// Geladene Dateien und Daten auf dem Gerät bleiben in jedem Fall erhalten.
    func cancel(_ job: Job) {
        if job.id == runningJob {
            stopRequested.insert(job.id)
            runningTask?.cancel()
            append(job.id, L("Cancel requested – the current step will finish first.", "Abbruch angefordert – der laufende Schritt wird noch beendet."))
        } else {
            queued.removeAll { $0 == job.id }
            _ = try? JobRunner(store: paths.jobs).cancel(job.id)
            reloadJobs()
        }
    }

    func log(for id: String) -> [String] {
        if let lines = logs[id] { return lines }
        let text = (try? String(contentsOf: paths.logURL(job: id), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    private func append(_ id: String, _ line: String) {
        let clean = Redaction.redact(line)
        logs[id, default: log(for: id)].append(clean)
        if let handle = try? FileHandle(forWritingTo: paths.logURL(job: id)) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((clean + "\n").utf8))
        } else {
            try? Data((clean + "\n").utf8).write(to: paths.logURL(job: id))
        }
    }

    /// Es läuft immer nur ein Auftrag: alle bauen im selben Toolchain-Ordner und sprechen dasselbe Gerät an.
    private func pump() {
        guard runningTask == nil, let id = queued.first else { return }
        queued.removeFirst()
        guard let job = try? paths.jobs.load(id) else { return pump() }
        runningJob = id
        // Der Mac soll nicht einschlafen, während geladen, gebaut oder kopiert wird.
        if awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                                                          reason: "Installing a game on Apple Vision Pro")
        }
        askForNotifications()
        let paths = paths
        let (lines, feed) = AsyncStream<String>.makeStream()
        let reader = Task { @MainActor in
            for await line in lines {
                self.append(id, line)
                if line.hasPrefix("[") { self.reloadJobs() }
            }
        }
        runningTask = Task.detached {
            let installer = Installer(recipe: job.recipe, request: job.request, store: paths.store,
                                      progress: { p in Task { @MainActor in
                                          // Die Verbindungsart kommt einmal am Anfang; die Meldungen danach tragen sie nicht.
                                          var p = p
                                          if p.via == nil { p.via = self.copyProgress[id]?.via }
                                          self.copyProgress[id] = p
                                      } },
                                      report: { feed.yield("    " + $0) })
            let now = (try? Toolchain(root: URL(fileURLWithPath: job.request.toolchain)).commit()) ?? "unbekannt"
            do {
                _ = try await JobRunner(store: paths.jobs).run(job, currentToolchain: now, log: { feed.yield($0) }) { step, _ in
                    try Task.checkCancellation()
                    try await installer.perform(step)
                }
                feed.yield(job.isDownloadOnly
                    ? L("Done: the files of \(job.recipe.title) are on this Mac. Once everything under “Setup” is in place, “Install” builds the game and puts it on the Vision Pro – without downloading again.",
                        "Fertig: Die Dateien von \(job.recipe.title) liegen auf diesem Mac. Sobald unter „Einrichtung“ alles beisammen ist, baut „Installieren“ das Spiel und bringt es auf die Vision Pro – ohne noch einmal zu laden.")
                    : job.isAddonSync
                    ? L("Done: the add-on content of \(job.recipe.title) is up to date. If the game is running, quit it and start it again so that it sees the new content.",
                        "Fertig: Die Zusatzinhalte von \(job.recipe.title) sind auf dem Stand. Läuft das Spiel gerade, beende es und starte es neu, damit es die neuen Inhalte sieht.")
                    : L("Done: \(job.recipe.title) is ready on the device.", "Fertig: \(job.recipe.title) ist auf dem Gerät bereit."))
            } catch is CancellationError {
                feed.yield(L("Stopped.", "Angehalten."))
            } catch {
                feed.yield(L("Stopped: \(error)", "Angehalten: \(error)"))
            }
            feed.finish()
            await reader.value
            await MainActor.run { self.finished(id) }
        }
    }

    private func finished(_ id: String) {
        let cancelled = stopRequested.remove(id) != nil
        if cancelled { _ = try? JobRunner(store: paths.jobs).cancel(id) }
        runningTask = nil
        runningJob = nil
        copyProgress[id] = nil
        if !cancelled, let job = try? paths.jobs.load(id) {
            notify(job)
            if job.state == .finished, !job.isDownloadOnly, !job.isAddonSync { reportInstall(job.recipe) }
        }
        reportUsage()
        refresh()
        pump()
        removeOlderToolchainsAutomatically()
        if runningJob == nil, let token = awake {
            ProcessInfo.processInfo.endActivity(token)
            awake = nil
        }
    }

    // MARK: Mitteilungen

    /// Mitteilungen gibt es nur für das Programmpaket; ohne Paket (beim Entwickeln) kennt macOS den Absender nicht.
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil && Snapshot.directory == nil }

    private func askForNotifications() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Sagt Bescheid, wenn ein Auftrag fertig ist oder hängt – aber nur, wenn das Programm nicht vorn ist.
    private func notify(_ job: Job) {
        guard canNotify, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = job.recipe.title
        switch job.state {
        case .finished: content.body = job.isDownloadOnly ? L("The files are downloaded.", "Die Dateien sind geladen.")
                                     : job.isAddonSync ? L("Add-on content is up to date.", "Zusatzinhalte sind auf dem Stand.")
                                                       : L("Ready on your Vision Pro.", "Auf deiner Vision Pro bereit.")
        case .failed: content.body = job.isDownloadOnly ? L("The download has stopped and needs your attention.", "Der Download ist angehalten und braucht dich.")
                                                        : L("The installation has stopped and needs your attention.", "Die Installation ist angehalten und braucht dich.")
        default: return
        }
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: job.id, content: content, trigger: nil))
    }
}

/// Wo Rezepte, Bestand, Aufträge und Toolchains liegen.
struct Paths: Sendable {
    let recipes: URL?
    let store: ContentStore
    let jobs: JobStore
    let packager: ToolchainPackager
    /// Die Spielstände: neben dem Ordner für Downloads, wenn einer gewählt ist, sonst bei den Daten des Programms.
    var saves: SaveStore { SaveStore(root: SaveStore.root(forStore: store.root)) }

    init() {
        let env = ProcessInfo.processInfo.environment
        func dir(_ key: String) -> URL? { env[key].map { URL(fileURLWithPath: $0) } }
        store = ContentStore(root: dir("AVPPLAY_STORE") ?? ContentStore.defaultRoot)
        jobs = JobStore(directory: dir("AVPPLAY_JOBS") ?? JobStore.defaultDirectory)
        packager = ToolchainPackager(root: dir("AVPPLAY_TOOLCHAINS") ?? ToolchainPackager.defaultRoot)
        recipes = dir("AVPPLAY_RECIPES") ?? Paths.findRecipes()
    }

    /// Im Programmpaket liegen die Rezepte unter `Resources/recipes`; beim Entwickeln neben dem Quelltext.
    private static func findRecipes() -> URL? {
        let fm = FileManager.default
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("recipes", isDirectory: true),
           fm.fileExists(atPath: bundled.path) { return bundled }
        var starts = [Bundle.main.bundleURL, URL(fileURLWithPath: fm.currentDirectoryPath)]
        // Von Xcode gestartet liegt das Programm in DerivedData und das Arbeitsverzeichnis irgendwo – beides führt
        // nicht zum Quelltext. Der Pfad dieser Datei tut es. Nur in Entwickler-Builds: `#filePath` schreibt den Pfad
        // des bauenden Rechners samt Benutzernamen ins Programm, und in einem Release hat der nichts zu suchen
        // (dort liegen die Rezepte ohnehin im Programmpaket).
        #if DEBUG
        starts.append(URL(fileURLWithPath: #filePath))
        #endif
        for start in starts {
            var dir = start
            for _ in 0..<6 {
                let candidate = dir.appendingPathComponent("recipes", isDirectory: true)
                if fm.fileExists(atPath: candidate.path) { return candidate }
                dir.deleteLastPathComponent()
            }
        }
        return nil
    }

    /// Das neueste installierte Paket; beim Entwickeln ersatzweise das Arbeitsverzeichnis neben den Rezepten.
    func toolchain() -> Toolchain? {
        if let env = ProcessInfo.processInfo.environment["AVPPLAY_TOOLCHAIN"] { return try? Toolchain(root: URL(fileURLWithPath: env)) }
        if let installed = packager.installed().first { return installed }
        guard let recipes else { return nil }
        return try? Toolchain(root: recipes.deletingLastPathComponent().appendingPathComponent("klepton-fork-test"))
    }

    /// Die Beschreibung, die neben einem Toolchain-Archiv liegt.
    static func manifest(beside archive: URL) -> ToolchainManifest? {
        guard let data = try? Data(contentsOf: ToolchainPackager.sidecar(for: archive)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ToolchainManifest.self, from: data)
    }

    func logURL(job id: String) -> URL {
        try? FileManager.default.createDirectory(at: jobs.directory, withIntermediateDirectories: true)
        return jobs.directory.appendingPathComponent("\(id).log")
    }
}
