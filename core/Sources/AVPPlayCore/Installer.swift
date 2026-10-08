import Foundation

public enum InstallError: Error, CustomStringConvertible, Equatable {
    case notOwned(String)
    case missingFiles(count: Int, examples: [String], recipe: String)
    case userFilesNeeded(names: [String], hint: String?)
    case missingTrees([String], recipe: String)
    case teamMissing
    case appNotInstalled(String)
    case badIcon(String)
    case appRunning(String)

    public var description: String {
        switch self {
        case .notOwned(let title):
            return L("\(title) isn't owned by this account. Nothing will be requested.",
                     "\(title) ist nicht im Besitz dieses Kontos. Es wird nichts angefragt.")
        case .missingFiles(let count, let examples, let recipe):
            let list = examples.joined(separator: ", ")
            return L("\(count) files are missing from the library (e.g. \(list)). Run 'avpplay fetch \(recipe)' or 'avpplay adopt' first.",
                     "Im Bestand fehlen \(count) Dateien (z. B. \(list)). Erst 'avpplay fetch \(recipe)' oder 'avpplay adopt'.")
        case .userFilesNeeded(let names, let hint):
            let list = "\(names.prefix(4).joined(separator: ", "))\(names.count > 4 ? ", …" : "")" + (hint.map { " – \($0)" } ?? "")
            return L("You need to provide these files yourself: \(list). Then add them with 'avpplay adopt' and resume the job.",
                     "Selbst bereitzustellen: \(list). Danach mit 'avpplay adopt' übernehmen und den Auftrag fortsetzen.")
        case .missingTrees(let names, let recipe):
            let list = names.joined(separator: ", ")
            return L("Folders are missing from the library: \(list). Run 'avpplay adopt \(recipe) --from <folder>' first.",
                     "Im Bestand fehlen Ordner: \(list). Erst 'avpplay adopt \(recipe) --from <Ordner>'.")
        case .teamMissing: return L("The Apple team ID needed for the build is missing (--team).", "Für den Build fehlt die Apple-Team-ID (--team).")
        case .appNotInstalled(let bundle):
            return L("The app \(bundle) isn't installed on the device. Run 'avpplay install' first.",
                     "Die App \(bundle) ist auf dem Gerät nicht installiert. Erst 'avpplay install'.")
        case .badIcon(let path): return L("\(path) isn't a readable image.", "\(path) ist kein lesbares Bild.")
        case .appRunning(let title):
            return L("\(title) is currently running on the Vision Pro. Installing would quit the game. Quit the game, then resume.",
                     "\(title) läuft gerade auf der Vision Pro. Eine Installation würde das Spiel beenden. Spiel beenden und dann fortsetzen.")
        }
    }
}

/// Was der Nutzer für eine Installation festgelegt hat. Wird mit dem Auftrag gespeichert.
public struct InstallRequest: Codable, Sendable, Equatable {
    public var account = "default"
    public var locales: [String] = []
    public var optionalNames: [String] = []
    /// Zusatzinhalte abfragen und freischalten.
    public var addons = true
    public var team: String?
    public var device: String?
    public var bundleId: String?
    public var toolchain: String
    public var customIcon: String?
    public var storeArt = true
    /// Mindestabstand zwischen Abrufen bei Meta, in Sekunden.
    public var interval: Double = 5
    /// Auch installieren, wenn die App gerade läuft (sie wird dabei beendet). Ohne Angabe: nein.
    public var replaceRunning: Bool?

    public init(toolchain: String) { self.toolchain = toolchain }
}

/// Die Schritte einer Installation. Jeder ist für sich wiederholbar: er stellt fest, was schon erledigt ist,
/// und tut nur den Rest. Zwischenstände (Käufe, geladene Dateien, Daten auf dem Gerät) liegen im Bestand bzw.
/// auf dem Gerät, nicht im Speicher – deshalb lässt sich nach jedem Schritt und mitten darin fortsetzen.
public enum InstallStep: String, Codable, Sendable, CaseIterable {
    /// Token prüfen, Besitz prüfen, Käufe abfragen.
    case account
    /// Fehlende Dateien laden und prüfen.
    case fetch
    /// Bauen und installieren.
    case build
    /// Daten ergänzend aufs Gerät kopieren.
    case stage
    /// Zusatzinhalte freischalten.
    case unlock

    public var title: String {
        switch self {
        case .account: return L("Check account and ownership", "Konto und Besitz prüfen")
        case .fetch: return L("Download files", "Dateien laden")
        case .build: return L("Build and install", "Bauen und installieren")
        case .stage: return L("Copy data to the device", "Daten aufs Gerät kopieren")
        case .unlock: return L("Unlock add-on content", "Zusatzinhalte freischalten")
        }
    }
}

public struct Installer: Sendable {
    public let recipe: Recipe
    public let request: InstallRequest
    public let store: ContentStore
    let control = DeviceControl()
    let report: @Sendable (String) -> Void

    public init(recipe: Recipe, request: InstallRequest, store: ContentStore, report: @escaping @Sendable (String) -> Void) {
        self.recipe = recipe
        self.request = request
        self.store = store
        self.report = report
    }

    var isStoreTitle: Bool { recipe.store.appId != nil || recipe.files.contains { $0.source == nil } || recipe.addons != nil }
    var wantsAddons: Bool { recipe.addons != nil && request.addons }

    public func perform(_ step: InstallStep) async throws {
        switch step {
        case .account: try await checkAccount()
        case .fetch: try await fetch()
        case .build: try await build()
        case .stage: try stage()
        case .unlock: try unlock()
        }
    }

    // MARK: Auswahl und Bestand

    /// Die Käufe, die gelten: der zuletzt von Meta bestätigte Stand.
    func confirmedPurchases() -> PurchaseRecord? {
        wantsAddons ? PurchaseRecord.load(store: store, recipe: recipe) : nil
    }

    func selection() -> FetchSelection {
        var sel = FetchSelection(locales: Set(request.locales), optionalNames: Set(request.optionalNames))
        if recipe.addons?.kind == .deliveredAssets, let p = confirmedPurchases() { sel.ownedSKUs = Set(p.skus) }
        return sel
    }

    /// Die gebrauchten Dateien, soweit sie vollständig im Bestand liegen. Fehlt eine Pflichtdatei, ist das ein
    /// Fehler; ein gekaufter, aber noch nicht geladener Zusatzinhalt wird schlicht nicht gemeldet.
    func localFiles() throws -> [(file: RecipeFile, url: URL, size: Int64)] {
        var local: [(file: RecipeFile, url: URL, size: Int64)] = []
        var missing: [String] = []
        for f in FetchPlan.wantedFiles(recipe: recipe, selection: selection()) {
            let url = store.url(for: f, in: recipe)
            if let size = ContentStore.fileSize(url), f.size == nil || f.size == size { local.append((f, url, size)) }
            else if f.role == "addon" { continue }
            else { missing.append(f.name) }
        }
        guard missing.isEmpty else {
            throw InstallError.missingFiles(count: missing.count, examples: Array(missing.prefix(3)), recipe: recipe.id)
        }
        let trees = TreeStore(store: store).missing(recipe: recipe)
        guard trees.isEmpty else { throw InstallError.missingTrees(trees.map(\.name), recipe: recipe.id) }
        return local
    }

    func target() throws -> (device: Device, bundle: String, toolchain: Toolchain) {
        let device = try control.pick(udid: request.device)
        let bundle = request.bundleId ?? Toolchain.defaultBundleId(target: recipe.toolchain.target)
        let toolchain = try Toolchain(root: URL(fileURLWithPath: request.toolchain))
        guard toolchain.satisfies(minCommit: recipe.toolchain.minCommit) else {
            throw ToolchainError.tooOld(have: toolchain.commit(), need: recipe.toolchain.minCommit)
        }
        return (device, bundle, toolchain)
    }

    // MARK: Schritte

    /// Konto: Token prüfen, Besitz prüfen, Käufe holen. Ohne gültigen Token wird nichts Neues freigeschaltet;
    /// ein früher bestätigter Stand der Käufe bleibt gültig.
    func checkAccount() async throws {
        guard isStoreTitle else {
            report(L("Special app: not a Meta Store title, so there is no ownership check with Meta.",
                     "Sonderapp: kein Titel aus dem Meta-Store, keine Besitzprüfung bei Meta."))
            return
        }
        var source: PurchaseRecord.Source?
        do {
            let client = MetaClient(token: try TokenStore().read(account: request.account))
            let user = try await client.me()
            if let app = recipe.store.appId {
                guard try await client.ownsApp(appId: app, userId: user) else { throw InstallError.notOwned(recipe.title) }
                report(L("Ownership confirmed.", "Besitz bestätigt."))
            }
            if wantsAddons {
                source = await PurchaseRecord.refresh(store: store, recipe: recipe) { try await client.purchases(appId: $0) }?.source
            }
        } catch let error as InstallError {
            throw error
        } catch {
            report(L("Note: \(Redaction.redact("\(error)"))", "Hinweis: \(Redaction.redact("\(error)"))"))
            if wantsAddons, PurchaseRecord.load(store: store, recipe: recipe) != nil { source = .cached(reason: L("no valid token", "kein gültiger Token")) }
        }
        if let record = confirmedPurchases(), let source {
            switch source {
            case .fresh: report(L("Purchases: \(record.skus.count) confirmed.", "Käufe: \(record.skus.count) bestätigt."))
            case .cached:
                let when = ISO8601DateFormatter().string(from: record.verified)
                report(L("Purchases: couldn't be checked – using the last confirmed state (\(record.skus.count) purchases, \(when)).",
                         "Käufe: Abfrage nicht möglich – es gilt der zuletzt bestätigte Stand (\(record.skus.count) Käufe, \(when))."))
            }
        }
    }

    /// Lädt, was im Bestand fehlt. Vor dem ersten Abruf bei Meta wird der Besitz geprüft; es wird nie eine
    /// Datei angefragt, nur um zu sehen, ob Meta sie herausgibt.
    func fetch() async throws {
        let plan = FetchPlan.plan(recipe: recipe, selection: selection()) { store.state(of: $0, in: recipe) }
        let fromUser = plan.filter { $0.action == .needsUser }
        guard fromUser.isEmpty else {
            throw InstallError.userFilesNeeded(names: fromUser.map(\.file.name), hint: fromUser.first?.file.source?.hint?.text)
        }
        let trees = TreeStore(store: store).missing(recipe: recipe)
        guard trees.isEmpty else { throw InstallError.missingTrees(trees.map(\.name), recipe: recipe.id) }
        let todo = plan.filter { $0.action != .keep }
        guard !todo.isEmpty else {
            report(L("Files: \(plan.count) needed, all in the library.", "Dateien: \(plan.count) gebraucht, alle im Bestand."))
            return
        }
        report(L("Files: \(plan.count) needed, \(plan.count - todo.count) in the library, \(todo.count) to download.",
                 "Dateien: \(plan.count) gebraucht, \(plan.count - todo.count) im Bestand, \(todo.count) zu laden."))

        var client = MetaClient(token: "unbenutzt")       // ohne Meta-Dateien wird er nie benutzt
        if todo.contains(where: { $0.file.source == nil }) {
            client = MetaClient(token: try TokenStore().read(account: request.account))
            let user = try await client.me()
            if let app = recipe.store.appId {
                guard try await client.ownsApp(appId: app, userId: user) else { throw InstallError.notOwned(recipe.title) }
            }
        }
        let report = self.report
        let fetcher = Fetcher(client: client, store: store, gate: RequestGate(minInterval: .seconds(request.interval)))
        let summary = try await fetcher.run(plan, recipe: recipe) { report("  " + $0) }
        report(L("Downloaded: \(summary.downloaded) files, \(summary.kept) were already there.",
                 "Geladen: \(summary.downloaded) Dateien, \(summary.kept) waren vorhanden."))
    }

    /// Bauen und installieren. Der Container muss existieren, bevor Daten kopiert werden; deshalb steht der
    /// Build vor dem Kopieren. Installieren über eine bestehende App erhält deren Daten.
    func build() async throws {
        guard let team = request.team else { throw InstallError.teamMissing }
        _ = try localFiles()
        let (device, bundle, toolchain) = try target()
        let commit = toolchain.commit()
        report(L("Device: \(device.name) (visionOS \(device.osVersion)); app: \(bundle); toolchain: \(commit)",
                 "Gerät: \(device.name) (visionOS \(device.osVersion)); App: \(bundle); Toolchain: \(commit)"))
        try await prepare(toolchain)
        // Eine Installation beendet die laufende App. Das soll niemandem mitten im Spiel passieren.
        if request.replaceRunning != true,
           let app = try? control.apps(device: device).first(where: { $0.bundleIdentifier == bundle }),
           let running = try? control.runningExecutables(device: device), DeviceControl.isRunning(app, executables: running) {
            throw InstallError.appRunning(recipe.title)
        }
        let log = store.directory(for: recipe).appendingPathComponent(".last-build.log")
        let started = Date()
        try toolchain.buildAndInstall(recipe: recipe, team: team, device: device, bundleId: request.bundleId, log: log,
                                      extraEnvironment: TreeStore(store: store).toolchainEnvironment(recipe: recipe))
        report(String(format: L("Built and installed (%.0f s).", "Gebaut und installiert (%.0f s)."), Date().timeIntervalSince(started)))
    }

    /// Icon bereitlegen und die Toolchain vorbereiten.
    func prepare(_ toolchain: Toolchain) async throws {
        if let path = request.customIcon {
            guard AppIcon.custom(at: URL(fileURLWithPath: path)) != nil else { throw InstallError.badIcon(path) }
            let target = Toolchain.customIconURL(store: store, recipe: recipe)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: target)
            report(L("Custom icon saved.", "Eigenes Icon hinterlegt."))
        }
        // Titelbild aus dem Store als Icon: einmal holen, danach liegt es im Bestand.
        let cover = Toolchain.storeCoverURL(store: store, recipe: recipe)
        if request.storeArt, !FileManager.default.fileExists(atPath: cover.path), let app = recipe.store.appId {
            if let image = await StoreArt().squareCover(appId: app) {
                try image.write(to: cover, options: .atomic)
                report(L("Icon: fetched the cover image from the store page.", "Icon: Titelbild von der Store-Seite geholt."))
            } else {
                report(L("Icon: no square cover image found on the store page – keeping the icon from the APK.",
                         "Icon: kein quadratisches Titelbild auf der Store-Seite gefunden – es bleibt beim Icon aus dem APK."))
            }
        }
        // Dasselbe im Querformat, für das Startfenster der App.
        let wide = StartHero.storeURL(store: store, recipe: recipe)
        if request.storeArt, !FileManager.default.fileExists(atPath: wide.path), let app = recipe.store.appId,
           let image = await StoreArt().landscapeCover(appId: app) {
            try image.write(to: wide, options: .atomic)
            report(L("Start image: fetched the landscape cover image from the store page.",
                     "Startbild: Titelbild im Querformat von der Store-Seite geholt."))
        }
        try toolchain.prepare(recipe: recipe, store: store)
    }

    /// Ergänzend kopieren: nur was auf dem Gerät fehlt oder eine andere Größe hat.
    func stage() throws {
        let local = try localFiles()
        let (device, bundle, toolchain) = try target()
        guard try control.apps(device: device).contains(where: { $0.bundleIdentifier == bundle }) else {
            throw InstallError.appNotInstalled(bundle)
        }
        var remote: [String: Int64] = [:]
        for dir in Set(local.compactMap { StagePlan.directory(for: $0.file) }) {
            for f in try control.files(device: device, bundle: bundle, subdirectory: dir) where !f.isDirectory {
                remote["\(dir)/\(f.relativePath)"] = f.size
            }
        }
        let items = StagePlan.plan(local: local, remote: remote)
        let staged = local.filter { StagePlan.destination(for: $0.file) != nil }.count
        let hasTrees = recipe.trees?.isEmpty == false
        if staged > 0 || !hasTrees {
            let total = Installer.gigabytes(items.map(\.size).reduce(0, +))
            report(L("Data: \(staged) files belong on the device, \(staged - items.count) are already there, "
                     + "\(items.count) to copy (\(total)).",
                     "Daten: \(staged) Dateien gehören aufs Gerät, \(staged - items.count) liegen dort schon, "
                     + "\(items.count) zu kopieren (\(total))."))
        }
        let copyStart = Date()
        for (n, item) in items.enumerated() {
            try copyWithRetry(item, to: device, bundle: bundle)
            if items.count <= 20 || (n + 1) % 10 == 0 || n + 1 == items.count {
                let name = item.destination.split(separator: "/").last ?? ""
                report(L("  copied \(n + 1)/\(items.count): \(name)", "  kopiert \(n + 1)/\(items.count): \(name)"))
            }
        }
        if !items.isEmpty { report(String(format: L("Copying: %.0f s.", "Kopieren: %.0f s."), Date().timeIntervalSince(copyStart))) }

        // Ordnerbestände: Die Toolchain baut ein Abbild dessen, was aufs Gerät gehört, und überträgt es ordnerweise;
        // devicectl lässt dabei aus, was unverändert schon dort liegt. Ein eigener Vorab-Vergleich über die
        // Dateiliste des Geräts wäre hier falsch: die rekursive Liste ist bei großen Bäumen unvollständig.
        if hasTrees {
            let env = TreeStore(store: store).toolchainEnvironment(recipe: recipe)
            let log = store.directory(for: recipe).appendingPathComponent(".last-sync.log")
            try? FileManager.default.removeItem(at: log)
            try toolchain.syncTrees(recipe: recipe, environment: env, device: device, bundleId: request.bundleId, copy: false, log: log)
            let want = TreeStore.listing(of: toolchain.mirrorDirectory(recipe: recipe))
            let total = Installer.gigabytes(want.values.reduce(0, +))
            report(L("Game data: \(want.count) files (\(total)) belong on the device; "
                     + "only what is missing or has changed there will be transferred …",
                     "Spieldaten: \(want.count) Dateien (\(total)) gehören aufs Gerät; "
                     + "übertragen wird nur, was dort fehlt oder sich geändert hat …"))
            let started = Date()
            try toolchain.syncTrees(recipe: recipe, environment: env, device: device, bundleId: request.bundleId, copy: true, log: log)
            report(String(format: L("Game data synced (%.0f s).", "Spieldaten abgeglichen (%.0f s)."), Date().timeIntervalSince(started)))
        }

        // Assets aus dem APK: als Ordner, wenn Anzahl oder Gesamtgröße abweichen. Der entpackte Baum entsteht
        // beim Build; fehlt er (Kopieren ohne vorherigen Build mit dieser Toolchain), wird er hier angelegt.
        try toolchain.prepare(recipe: recipe, store: store)
        let (localCount, localBytes) = toolchain.assetsSummary(recipe: recipe)
        guard localCount > 0 || !hasTrees else { return }
        let assetDest = "Documents/\(recipe.toolchain.target)/assets"
        let remoteAssets = try control.files(device: device, bundle: bundle, subdirectory: assetDest, recursive: true).filter { !$0.isDirectory }
        if localCount > 0, remoteAssets.count != localCount || remoteAssets.map(\.size).reduce(0, +) != localBytes {
            try control.copy(toolchain.assetsDirectory(recipe: recipe), to: device, bundle: bundle, destination: assetDest)
            report(L("Assets: \(localCount) files copied (\(Installer.gigabytes(localBytes))).",
                     "Assets: \(localCount) Dateien kopiert (\(Installer.gigabytes(localBytes)))."))
        } else {
            report(L("Assets: \(localCount) files are already on the device.", "Assets: \(localCount) Dateien liegen schon auf dem Gerät."))
        }
    }

    /// Die Verbindung zum Gerät reißt bei langen Kopierläufen gelegentlich ab (am Gerät beobachtet: nach einigen
    /// Minuten „socket was closed unexpectedly“). Eine einzelne Datei wird deshalb nach kurzer Pause erneut
    /// versucht; eine halb übertragene hat die falsche Größe und wird ohnehin ersetzt.
    func copyWithRetry(_ item: StageItem, to device: Device, bundle: String, attempts: Int = 4) throws {
        var last: Error?
        for attempt in 1...attempts {
            do {
                try control.copy(item.source, to: device, bundle: bundle, destination: item.destination)
                return
            } catch {
                last = error
                guard attempt < attempts else { break }
                let name = item.destination.split(separator: "/").last ?? ""
                report(L("  Connection lost at \(name) – retry \(attempt + 1)/\(attempts) in \(attempt * 10) s.",
                         "  Verbindung unterbrochen bei \(name) – neuer Versuch \(attempt + 1)/\(attempts) in \(attempt * 10) s."))
                Thread.sleep(forTimeInterval: Double(attempt) * 10)
            }
        }
        throw last!
    }

    /// Zusatzinhalte: Nur die kleine Liste geht aufs Gerät, nie ein Token.
    func unlock() throws {
        guard let addons = recipe.addons, let dest = addons.dest else { return }
        guard let record = confirmedPurchases() else {
            if request.addons {
                report(L("Add-on content: no confirmed purchases – nothing will be unlocked.",
                         "Zusatzinhalte: kein bestätigter Kaufstand – es wird nichts freigeschaltet."))
            }
            return
        }
        let local = try localFiles()
        let (device, bundle, _) = try target()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("qi-addon-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        switch addons.kind {
        case .purchaseList:
            try AddonFiles.entitlements(appId: record.appId, skus: record.skus, verified: record.verified)
                .write(to: tmp, atomically: true, encoding: .utf8)
            try control.copy(tmp, to: device, bundle: bundle, destination: "Documents/\(dest)/\(AddonFiles.entitlementsName)")
            report(L("Add-on content: purchase list with \(record.skus.count) purchases copied to the device.",
                     "Zusatzinhalte: Kaufliste mit \(record.skus.count) Käufen aufs Gerät gelegt."))
        case .deliveredAssets:
            let present = (addons.items ?? []).filter { item in
                record.skus.contains(item.sku) && local.contains { $0.file.name == item.name }
            }
            try AddonFiles.assetIndex(present).write(to: tmp, atomically: true, encoding: .utf8)
            try control.copy(tmp, to: device, bundle: bundle, destination: "Documents/\(dest)/\(AddonFiles.assetIndexName)")
            let bought = (addons.items ?? []).filter { record.skus.contains($0.sku) }.count
            report(L("Add-on content: \(present.count) of \(bought) purchased files reported"
                     + (present.count < bought ? " (the rest not downloaded yet)" : "") + ".",
                     "Zusatzinhalte: \(present.count) von \(bought) gekauften Dateien gemeldet"
                     + (present.count < bought ? " (Rest noch nicht geladen)" : "") + "."))
        }
    }

    public static func gigabytes(_ bytes: Int64) -> String { String(format: "%.2f GB", Double(bytes) / 1e9) }
}
