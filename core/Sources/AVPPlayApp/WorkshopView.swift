import SwiftUI
import WebKit
import AVPPlayCore

// MARK: - Laden und Wegnehmen

extension AppModel {
    /// Die Items aus dem Workshop, die der Nutzer gewählt hat, je mit ihrer wählbaren Datei im Rezept.
    func workshopEntries(_ game: Game) -> [(item: WorkshopItem, file: RecipeFile)] {
        guard let support = game.recipe.workshop else { return [] }
        let files = game.recipe.files.filter { $0.role == Workshop.role }
        return WorkshopList.load().shown(app: support.app).compactMap { item in
            files.first(where: { $0.name == item.fileName }).map { (item, $0) }
        }
    }

    /// Was dem Laden aus dem Workshop im Weg steht.
    func workshopBlocker(for game: Game) -> String? {
        if let why = steamBlocker(for: game) { return why }
        if steamBusy.contains(game.id) {
            return L("Steam is already busy for this game; wait until it has finished.", "Steam ist für dieses Spiel schon beschäftigt; warte, bis es fertig ist.")
        }
        return nil
    }

    /// Lädt Items (Links oder Kennungen) aus dem Workshop des Spiels, nimmt sie in die Liste und hakt sie an.
    func addWorkshop(_ game: Game, from texts: [String]) {
        guard let support = game.recipe.workshop, workshopBlocker(for: game) == nil else { return }
        let ids = texts.compactMap(Workshop.itemId(from:))
        guard !ids.isEmpty else {
            steamSaid[game.id] = L("That is neither a Workshop link nor an item ID.", "Das ist weder ein Workshop-Link noch eine Item-Kennung.")
            return
        }
        let id = game.id, recipe = game.recipe, account = steamAccount, paths = paths, stops = steamStops
        stops.clear(id)
        steamBusy.insert(id)
        steamProgress[id] = nil
        steamSaid[id] = L("Asking Steam about the Workshop item …", "Steam wird nach dem Workshop-Item gefragt …")
        let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                                                             reason: "Download from the Steam Workshop")
        Task.detached {
            var outcome: String
            var loaded: [WorkshopItem] = []
            var signedOut = false
            do {
                let (details, requiredBy) = try await WorkshopDetails.resolve(ids, app: support.app)
                loaded = try WorkshopFetcher(store: paths.store, account: account).download(
                    details, requiredBy: requiredBy, recipe: recipe, known: WorkshopList.load().items(app: support.app),
                    shouldStop: { stops.isRequested(id) },
                    report: { line in Task { @MainActor in self.steamSaid[id] = line } })
                outcome = L("Loaded: \(loaded.map(\.title).joined(separator: ", ")).", "Geladen: \(loaded.map(\.title).joined(separator: ", ")).")
            } catch {
                if case SteamError.notSignedIn = error { signedOut = true }
                outcome = Redaction.redact("\(error)")
            }
            let text = outcome, items = loaded, lost = signedOut
            try? await Task.sleep(for: .milliseconds(300))
            await MainActor.run {
                ProcessInfo.processInfo.endActivity(activity)
                self.steamBusy.remove(id)
                self.steamSaid[id] = text
                if lost { self.steamSignedInAs = "" }
                guard !items.isEmpty else { self.refresh(); return }
                var list = WorkshopList.load()
                for item in items { list.put(item, app: support.app) }
                do { try list.save() } catch { self.notice = "\(error)" }
                var chosen = self.options(for: game)
                chosen.optionalNames = Array(Set(chosen.optionalNames + items.map(\.fileName))).sorted()
                self.setOptions(chosen, for: game)
                self.copyWorkshopWhenRefreshed(id, loaded: text)
            }
        }
    }

    /// Ist alles geladen, kommt es gleich zum installierten Spiel auf die Vision Pro – mit dem Spiel, wie es nach dem
    /// Neuladen dasteht (erst dann stehen die neuen Items in seinem Rezept).
    private func copyWorkshopWhenRefreshed(_ id: String, loaded text: String) {
        Task { @MainActor in
            while self.refreshing { try? await Task.sleep(for: .milliseconds(200)) }
            self.refresh()
            try? await Task.sleep(for: .milliseconds(100))
            while self.refreshing { try? await Task.sleep(for: .milliseconds(200)) }
            guard let game = self.allGames.first(where: { $0.id == id }) else { return }
            if let why = self.copyWorkshop(game) {
                self.steamSaid[id] = text + " " + why
            } else {
                self.steamSaid[id] = text + " " + L("Copying to the Vision Pro …", "Wird auf die Vision Pro kopiert …")
            }
        }
    }

    /// Legt die gewählten Items zum installierten Spiel auf die Vision Pro, ohne es neu zu bauen. Das Spiel liest sie
    /// selbst, das geht mit jeder installierten Fassung. Gibt zurück, warum es (noch) nicht geht.
    @discardableResult
    func copyWorkshop(_ game: Game) -> String? {
        guard game.installed else {
            return L("It goes onto the Vision Pro when the game is installed.", "Auf die Vision Pro kommt es, wenn das Spiel installiert wird.")
        }
        if let why = extrasBlocker(for: game) { return L("Not copied to the Vision Pro: \(why)", "Nicht auf die Vision Pro kopiert: \(why)") }
        guard missingExtras(for: game).isEmpty else {
            return L("Not copied to the Vision Pro: some chosen content is not on this Mac yet.",
                     "Nicht auf die Vision Pro kopiert: Gewähltes liegt noch nicht ganz auf diesem Mac.")
        }
        UserDefaults.standard.removeObject(forKey: AppModel.workshopWithdrawKey(game.id))
        enqueue(game, steps: InstallStep.contentSync, show: false)
        return nil
    }

    /// Nimmt ein Item aus der Liste und vom Mac. Auf der Vision Pro geht es beim nächsten Abgleich.
    func removeWorkshop(_ game: Game, _ item: WorkshopItem, file: RecipeFile) {
        guard let support = game.recipe.workshop, !isBusy(game.id), !steamBusy.contains(game.id) else { return }
        var list = WorkshopList.load()
        list.remove(id: item.id, app: support.app)
        do { try list.save() } catch { notice = "\(error)"; return }
        try? FileManager.default.removeItem(at: paths.store.url(for: file, in: game.recipe))
        var chosen = options(for: game)
        chosen.optionalNames = chosen.optionalNames.filter { $0 != file.name }
        setOptions(chosen, for: game)
        if game.installed { UserDefaults.standard.set(true, forKey: AppModel.workshopWithdrawKey(game.id)) }
        steamSaid[game.id] = L("“\(item.title)” is no longer in the list.", "„\(item.title)“ steht nicht mehr in der Liste.")
        refresh()
    }

    static func workshopWithdrawKey(_ id: String) -> String { "workshopWithdraw.\(id)" }

    /// Steht noch aus, Weggenommenes auch von der Vision Pro zu nehmen?
    func workshopWithdrawPending(_ game: Game) -> Bool {
        game.installed && UserDefaults.standard.bool(forKey: AppModel.workshopWithdrawKey(game.id))
    }

    /// Gleicht mit der Vision Pro ab: Gewähltes hin, Weggenommenes dort leeren.
    func syncWorkshop(_ game: Game) {
        if let why = copyWorkshop(game) { steamSaid[game.id] = why }
    }
}

// MARK: - Der Abschnitt auf der Seite des Spiels

struct WorkshopBox: View {
    @EnvironmentObject var model: AppModel
    let game: Game
    @State private var showBrowser = false
    @State private var entry = ""

    var body: some View {
        let entries = model.workshopEntries(game)
        let busy = model.steamBusy.contains(game.id)
        GroupBox(L("Steam Workshop", "Steam Workshop")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Maps, weapons and other add-ons made by players. Browse the Workshop and load an item with “Load into AVP Play”: the app fetches it with your Steam sign-in and then copies it to the installed game on the Vision Pro by itself. In the game, switch it on under Manage Addons in the main menu.",
                       "Karten, Waffen und andere Add-ons von Spielern. Stöbere im Workshop und lade ein Item mit „In AVP Play laden“: Die App holt es mit deiner Steam-Anmeldung und legt es danach von selbst zum installierten Spiel auf die Vision Pro. Im Spiel schaltest du es im Hauptmenü unter „Addons verwalten“ ein."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L("Browse Workshop …", "Workshop durchsuchen …")) { showBrowser = true }
                    TextField(L("Workshop link or item ID", "Workshop-Link oder Item-Kennung"), text: $entry)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(load)
                    Button(L("Load", "Laden"), action: load)
                        .disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty || model.workshopBlocker(for: game) != nil)
                }
                if busy {
                    HStack(alignment: .firstTextBaseline) {
                        ProgressView().controlSize(.small)
                        Text(model.steamSaid[game.id] ?? "").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Stop", "Anhalten")) { model.stopSteam(game) }.controlSize(.small)
                    }
                } else if let why = model.workshopBlocker(for: game) {
                    Text(why).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else if let said = model.steamSaid[game.id] {
                    Text(said).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(entries, id: \.item.id) { entry in
                    Divider()
                    ExtraContentRow(game: game, file: entry.file)
                    HStack(alignment: .firstTextBaseline) {
                        if let needed = entry.item.requiredBy, !needed.isEmpty {
                            let names = needed.map { id in entries.first(where: { $0.item.id == id })?.item.title ?? id }
                            Text(L("Needed by \(names.joined(separator: ", ")).", "Gebraucht von \(names.joined(separator: ", "))."))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Link(L("Workshop Page", "Workshop-Seite"),
                             destination: URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(entry.item.id)")!)
                            .font(.callout)
                        Button(L("Remove from List", "Aus der Liste nehmen")) { model.removeWorkshop(game, entry.item, file: entry.file) }
                            .controlSize(.small)
                            .disabled(model.isBusy(game.id) || busy)
                    }
                    .padding(.leading, 20)
                }
                if model.workshopWithdrawPending(game) {
                    Divider()
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.extrasBlocker(for: game)
                             ?? L("You removed items from the list. If they are on the Vision Pro, this frees their space there; the game clears away the rest the next time it starts.",
                                  "Du hast Items aus der Liste genommen. Liegen sie auf der Vision Pro, gibt das ihren Platz dort frei; den Rest räumt das Spiel beim nächsten Start weg."))
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(L("Sync with Vision Pro", "Mit der Vision Pro abgleichen")) { model.syncWorkshop(game) }
                            .disabled(model.extrasBlocker(for: game) != nil)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
        .sheet(isPresented: $showBrowser) {
            WorkshopBrowser(game: game).environmentObject(model)
        }
    }

    private func load() {
        let text = entry
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.addWorkshop(game, from: [text])
        if Workshop.itemId(from: text) != nil { entry = "" }
    }
}

// MARK: - Das Workshop-Fenster

/// Die Seite des Workshops bei Steam, eingebettet. Angemeldet wird hier nicht – angesehen wird ohne Konto, geladen
/// wird mit Valves Werkzeug und der Anmeldung, die die App schon hat. Seiten außerhalb der Steam Community öffnen
/// sich im Browser des Systems.
struct WorkshopBrowser: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let game: Game
    @StateObject private var page: WorkshopPage

    init(game: Game) {
        self.game = game
        _page = StateObject(wrappedValue: WorkshopPage(start: game.recipe.workshop?.browseURL ?? URL(string: "https://steamcommunity.com/workshop/")!))
    }

    var body: some View {
        let itemId = page.url.flatMap { Workshop.itemId(from: $0.absoluteString) }
        let known = Set(model.workshopEntries(game).map(\.item.id))
        let busy = model.steamBusy.contains(game.id)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { page.view.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!page.canGoBack)
                    .help(L("Back", "Zurück"))
                Button { page.view.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!page.canGoForward)
                    .help(L("Forward", "Vor"))
                Button { page.goHome() } label: { Image(systemName: "house") }
                    .help(L("Workshop home", "Startseite des Workshops"))
                Button { page.view.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("Reload", "Neu laden"))
                Text(page.title.isEmpty ? (page.url?.host ?? "") : page.title)
                    .lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
                Spacer()
                if page.loading { ProgressView().controlSize(.small) }
                Button(L("Done", "Fertig")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(8)
            Divider()
            WorkshopWebView(page: page)
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if busy {
                    ProgressView().controlSize(.small)
                    Text(model.steamSaid[game.id] ?? "").lineLimit(2).foregroundStyle(.secondary)
                } else if let why = model.workshopBlocker(for: game) {
                    Text(why).foregroundStyle(.orange).lineLimit(2)
                } else if let itemId, known.contains(itemId) {
                    Text(L("This item is in your list.", "Dieses Item steht in deiner Liste.")).foregroundStyle(.secondary)
                } else if itemId != nil {
                    Text(L("Loads this item – or, for a collection, everything in it – with the items it needs.",
                           "Lädt dieses Item – oder bei einer Sammlung alles darin – mit den Items, die es braucht."))
                        .foregroundStyle(.secondary).lineLimit(2)
                } else if let said = model.steamSaid[game.id] {
                    Text(said).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text(L("Open an item; then load it into AVP Play here. Steam's own “Subscribe” button is not needed.",
                           "Öffne ein Item und lade es dann hier in AVP Play. Steams eigener Knopf „Abonnieren“ wird nicht gebraucht."))
                        .foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button(L("Load into AVP Play", "In AVP Play laden")) {
                    if let itemId { model.addWorkshop(game, from: [itemId]) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(itemId == nil || busy || model.workshopBlocker(for: game) != nil || itemId.map(known.contains) == true)
            }
            .padding(10)
        }
        .frame(minWidth: 980, idealWidth: 1180, minHeight: 680, idealHeight: 820)
    }
}

/// Der Zustand der eingebetteten Seite.
@MainActor
final class WorkshopPage: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let view: WKWebView
    let start: URL
    @Published var url: URL?
    @Published var title = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var loading = false
    private var observations: [NSKeyValueObservation] = []

    init(start: URL) {
        self.start = start
        let configuration = WKWebViewConfiguration()
        // Nichts bleibt: keine Cookies, kein Cache über das Fenster hinaus.
        configuration.websiteDataStore = .nonPersistent()
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        view.navigationDelegate = self
        view.uiDelegate = self
        observations = [
            view.observe(\.url, options: [.initial, .new]) { [weak self] v, _ in Task { @MainActor in self?.url = v.url } },
            view.observe(\.title, options: [.initial, .new]) { [weak self] v, _ in Task { @MainActor in self?.title = v.title ?? "" } },
            view.observe(\.canGoBack, options: [.initial, .new]) { [weak self] v, _ in Task { @MainActor in self?.canGoBack = v.canGoBack } },
            view.observe(\.canGoForward, options: [.initial, .new]) { [weak self] v, _ in Task { @MainActor in self?.canGoForward = v.canGoForward } },
            view.observe(\.isLoading, options: [.initial, .new]) { [weak self] v, _ in Task { @MainActor in self?.loading = v.isLoading } },
        ]
        view.load(URLRequest(url: start))
    }

    func goHome() { view.load(URLRequest(url: start)) }

    /// Seiten der Steam Community bleiben im Fenster; alles andere geht an den Browser des Systems.
    nonisolated static func staysInside(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "steamcommunity.com" || host.hasSuffix(".steamcommunity.com")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        // Eingebettetes (Videos, Bilder anderer Seiten) darf laden; gewechselt wird das Hauptfenster nur innerhalb.
        if navigationAction.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
        if url.scheme == "about" || WorkshopPage.staysInside(url) { decisionHandler(.allow); return }
        if navigationAction.navigationType == .linkActivated, url.scheme == "https" || url.scheme == "http" {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        // Heruntergeladen wird hier nichts.
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    /// Ein Link, der ein neues Fenster öffnen will: im selben Fenster, wenn er drinnen bleibt.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if WorkshopPage.staysInside(url) { webView.load(URLRequest(url: url)) }
            else if url.scheme == "https" || url.scheme == "http" { NSWorkspace.shared.open(url) }
        }
        return nil
    }
}

struct WorkshopWebView: NSViewRepresentable {
    let page: WorkshopPage
    func makeNSView(context: Context) -> WKWebView { page.view }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
