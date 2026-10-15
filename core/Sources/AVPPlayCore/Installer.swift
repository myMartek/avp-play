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
    /// Ein kostenloses Apple-Konto hat schon so viele Apps auf dem Gerät, wie Apple ihm erlaubt.
    case freeTeamFull(String, installed: [String])
    /// Die App ist kein Programm, das die Toolchain starten könnte (für Androids Java-Laufzeit geschrieben).
    case notANativeApp(String)
    /// Das APK bringt nur Programmcode für einen anderen Prozessor mit (ein reines 32-Bit-Spiel).
    case wrongArchitecture(String, [String])
    /// Die App ist eine 2D-App (ein Panel unter Horizon OS), kein VR-Spiel (`FlatApp`).
    case notAVRGame
    /// Für ein Spiel aus Steam fehlt der Name des Steam-Kontos, mit dem Valves Werkzeug angemeldet ist.
    case steamAccountMissing
    /// Auf dem Gerät liegt dasselbe Spiel aus einer anderen Kaufquelle (Meta statt Steam oder umgekehrt).
    case otherSourceInstalled(String, wanted: Recipe.Source)

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
        case .notANativeApp(let title):
            return L("\(title) cannot run on the Vision Pro with this tool. It is an ordinary Android app, written for Android's Java runtime, not a game built on a native engine such as Unity or Unreal – and that runtime does not exist here. Nothing was installed. This is not something a fix can change.",
                     "\(title) kann mit diesem Werkzeug nicht auf der Vision Pro laufen. Es ist eine gewöhnliche Android-App, geschrieben für Androids Java-Laufzeit, kein Spiel auf einer nativen Engine wie Unity oder Unreal – und diese Laufzeit gibt es hier nicht. Installiert wurde nichts. Ein Fix kann daran nichts ändern.")
        case .wrongArchitecture(let title, let found):
            let list = found.joined(separator: ", ")
            return L("\(title) cannot run on the Vision Pro. This build is a 32-bit game (it only contains code for \(list)); the Vision Pro's processor runs 64-bit code only, and this tool translates 64-bit Quest games. Nothing can be changed about that from here – only a 64-bit build from the developer would work. The files already downloaded can be removed on the game's page.",
                     "\(title) kann auf der Vision Pro nicht laufen. Dieser Build ist ein 32-Bit-Spiel (er enthält nur Code für \(list)); der Prozessor der Vision Pro führt ausschließlich 64-Bit-Code aus, und dieses Werkzeug übersetzt 64-Bit-Spiele der Quest. Daran lässt sich von hier aus nichts ändern – nur ein 64-Bit-Build des Entwicklers würde gehen. Die schon geladenen Dateien lassen sich auf der Seite des Spiels entfernen.")
        case .notAVRGame:
            return L("This is a 2D app, not a VR game. AVP Play only supports immersive games.",
                     "Das ist eine 2D-App, kein VR-Spiel. AVP Play unterstützt nur immersive Spiele.")
        case .freeTeamFull(let title, let installed):
            let list = installed.joined(separator: ", ")
            return L("\(title) was not installed: a free Apple account may have only \(AppleMessages.freeAppsPerDevice) apps on the Vision Pro at a time, and these are already there: \(list). Remove one on the headset (press and hold its icon, then “Remove App”), then choose “Resume”. A paid developer membership has no such limit. Before you remove a game, let AVP Play fetch its saved games (the game's page, “Saved Games”): they stay on this Mac and are put back when you install the game again.",
                     "\(title) wurde nicht installiert: Ein kostenloses Apple-Konto darf nur \(AppleMessages.freeAppsPerDevice) Apps gleichzeitig auf der Vision Pro haben, und diese sind schon dort: \(list). Entferne eine auf dem Headset (Icon gedrückt halten, dann „App entfernen“) und wähle dann „Fortsetzen“. Eine bezahlte Entwickler-Mitgliedschaft hat diese Grenze nicht. Bevor du ein Spiel entfernst, lass AVP Play seine Spielstände holen (Seite des Spiels, „Spielstände“): Sie bleiben auf diesem Mac und werden zurückgespielt, wenn du das Spiel wieder installierst.")
        case .steamAccountMissing:
            return L("This game comes from Steam, and no Steam account is signed in. Sign in to Steam under “Setup” (on the command line: --steam-account <name>).",
                     "Dieses Spiel kommt aus Steam, und es ist kein Steam-Konto angemeldet. Melde dich unter „Einrichtung“ bei Steam an (auf der Kommandozeile: --steam-account <Name>).")
        case .otherSourceInstalled(let title, let wanted):
            let (new, old) = wanted == .steam ? ("Steam", "Meta") : ("Meta", "Steam")
            return L("\(title) is on the Vision Pro in its \(old) version. The \(new) version is a different build of the game with its own files and its own saved games, and it cannot be installed over the other one. Remove the game from the Vision Pro first (press and hold its icon, “Remove App”), then install again. Removing the app also deletes the saved games of the \(old) version on the headset.",
                     "\(title) liegt in der \(old)-Fassung auf der Vision Pro. Die \(new)-Fassung ist ein anderer Stand des Spiels mit eigenen Dateien und eigenen Spielständen und lässt sich nicht über die andere installieren. Entferne das Spiel zuerst von der Vision Pro (Symbol gedrückt halten, „App entfernen“) und installiere dann neu. Beim Entfernen löscht das Headset auch die Spielstände der \(old)-Fassung.")
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
    public var interval: Double = 0
    /// Auch installieren, wenn die App gerade läuft (sie wird dabei beendet). Ohne Angabe: nein.
    public var replaceRunning: Bool?
    /// Der Auftrag lädt nur. Was der Nutzer selbst bereitstellen muss, darf dann noch fehlen: es wird genannt,
    /// hält das Laden der übrigen Dateien aber nicht auf. Ohne Angabe: nein.
    public var downloadOnly: Bool?
    /// Nur neu signieren: bauen und über die bestehende Installation legen. Gebraucht wird dann allein, woraus
    /// gebaut wird (das APK, bei einem Linux-Spiel seine Ordner) – die großen Datendateien liegen schon auf dem
    /// Gerät und dürfen auf dem Mac inzwischen fehlen. Ohne Angabe: nein.
    public var resign: Bool?
    /// Nach dem Kopieren die Spielstände vom Mac zurückspielen, wenn auf dem Gerät noch keine liegen (ein frisch
    /// installiertes Spiel). Ohne Angabe: nein.
    public var restoreSaves: Bool?
    /// Der Name des Steam-Kontos, mit dem Valves Werkzeug angemeldet ist – für ein Spiel aus Steam.
    public var steamAccount: String?
    /// Die Versionscodes, unter denen dasselbe Spiel aus einer anderen Kaufquelle installiert wäre. Liegt eine davon
    /// auf dem Gerät, wird nicht darüber installiert.
    public var otherSourceBuilds: [Int]?
    /// Die experimentellen Implementierungen (`Toolchain.experimentalSwitches`) in diesem Bau von Anfang an
    /// einschalten. Ohne Angabe: nein.
    public var experimental: Bool?
    /// Der Name der App auf dem Gerät statt des üblichen (`KLEPTON_DISPLAY_OVERRIDE`). Ohne Angabe: der übliche.
    public var displayName: String?
    /// Ein Zusatz zum Namen der App, etwa „ (Test)“ (`KLEPTON_DISPLAY_SUFFIX`). Ohne Angabe: keiner.
    public var displaySuffix: String?
    /// Ob die Signatur dieser Installation als die der eigentlichen gilt (`SigningRecord.save(live:)`). Ohne Angabe:
    /// ja, außer eine ausdrücklich genannte Kennung weicht von der der bisherigen eigentlichen Installation ab – oder,
    /// gibt es noch keine, von der üblichen Kennung des Teams. Das ist eine Testkopie neben dem Spiel.
    public var live: Bool?
    /// Das MetalFX-Hochskalieren (`Toolchain.metalFXSwitch`) in diesem Bau von Anfang an einschalten. Ohne Angabe:
    /// nein.
    public var metalFX: Bool?
    /// Die Auflösung in Prozent, mit der das Spiel beginnt, wenn `metalFX` eingeschaltet ist
    /// (`MetalFXResolution`). Ohne Angabe: die des Targets.
    public var resolution: Int?
    /// Die XR-Vorhersage (`Toolchain.xrPredictionSwitch`) in diesem Bau von Anfang an einschalten – die Option
    /// „XR prediction“ auf der Seite des Spiels. Ohne Angabe: nein, das Spiel bekommt die Kopfpose ohne Vorhersage.
    public var xrPrediction: Bool?

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

    /// Nur die Zusatzinhalte eines schon installierten Spiels abgleichen: Käufe neu bei Meta abfragen, Fehlendes
    /// laden, aufs Gerät legen und freischalten. Gebaut und installiert wird dabei nichts – das Programm auf dem
    /// Gerät bleibt, wie es ist.
    public static let addonSync: [InstallStep] = [.account, .fetch, .stage, .unlock]

    /// Gewählte Inhalte zu einem schon installierten Spiel nachreichen – etwa eine Sprachausgabe, die erst später
    /// angehakt wurde: prüfen, dass alles im Bestand liegt, und aufs Gerät kopieren, was dort fehlt. Gebaut wird nichts.
    public static let contentSync: [InstallStep] = [.fetch, .stage]

    /// Nur die Dateien laden, die das Programm selbst besorgen kann. Dafür braucht es das Konto, bei dem das Spiel
    /// gekauft ist, und sonst nichts – kein Xcode, kein Apple-Team, keine Vision Pro. Gebaut wird später.
    public static let download: [InstallStep] = [.account, .fetch]

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

/// Wie weit ein Schritt ist, in Bytes. Für Schritte, die Datei für Datei arbeiten.
public struct InstallProgress: Sendable, Equatable {
    public var step: InstallStep
    public var done: Int64
    public var total: Int64
    /// Worüber kopiert wird (Kabel oder WLAN), soweit bekannt.
    public var via: Device.Transport?
    public init(step: InstallStep, done: Int64, total: Int64, via: Device.Transport? = nil) {
        self.step = step
        self.done = done
        self.total = total
        self.via = via
    }
}

public struct Installer: Sendable {
    public let recipe: Recipe
    public let request: InstallRequest
    public let store: ContentStore
    let control = DeviceControl()
    let report: @Sendable (String) -> Void
    let progress: @Sendable (InstallProgress) -> Void
    /// Metas Werkzeug, falls eingerichtet: der Ausweg für Dateien, die die direkte Adresse mit HTTP 404 verweigert.
    public var metaTool: URL?

    public init(recipe: Recipe, request: InstallRequest, store: ContentStore,
                progress: @escaping @Sendable (InstallProgress) -> Void = { _ in },
                report: @escaping @Sendable (String) -> Void) {
        self.recipe = recipe
        self.request = request
        self.store = store
        self.report = report
        self.progress = progress
    }

    /// Ein Titel aus dem Meta-Store. Ein Spiel aus Steam ist keiner: Bei ihm bestätigt Steam Besitz und Zusatzinhalte.
    var isStoreTitle: Bool {
        recipe.source != .steam && (recipe.store.appId != nil || recipe.files.contains { $0.source == nil } || recipe.addons != nil)
    }
    var wantsAddons: Bool { recipe.addons != nil && request.addons }

    public func perform(_ step: InstallStep) async throws {
        switch step {
        case .account: try await checkAccount()
        case .fetch: try await fetch()
        case .build: try await exclusive { try await build() }
        case .stage: try await exclusive { try stage() }
        case .unlock: try unlock()
        }
    }

    /// Bauen und aufs Gerät kopieren darf zur selben Zeit nur ein Programm: Alle bauen im selben Ordner der Toolchain
    /// und sprechen dasselbe Gerät an – die App, die Kommandozeile und der Hintergrunddienst, der Signaturen erneuert.
    func exclusive(_ body: () async throws -> Void) async throws {
        var lock = ProcessLock.acquire(ProcessLock.installURL)
        if lock == nil {
            report(L("Another AVP Play process is building or copying right now – waiting for it to finish …",
                     "Ein anderer AVP-Play-Prozess baut oder kopiert gerade – es wird gewartet, bis er fertig ist …"))
            while lock == nil {
                try await Task.sleep(for: .seconds(2))
                lock = ProcessLock.acquire(ProcessLock.installURL)
            }
        }
        defer { lock?.release() }
        try await body()
    }

    /// Die Apps auf dem Gerät, die unter demselben Präfix installiert sind wie `bundle` – also mit demselben
    /// Konto von diesem Programm. Daran wird die Grenze eines kostenlosen Kontos vorab geprüft.
    public static func appsSharingPrefix(with bundle: String, in apps: [InstalledApp]) -> [InstalledApp] {
        guard let dot = bundle.lastIndex(of: ".") else { return [] }
        let prefix = String(bundle[...dot])
        return apps.filter { $0.bundleIdentifier.hasPrefix(prefix) }
    }

    /// Stünde eine Installation mit einem kostenlosen Konto an Apples Grenze an? Dann die Namen der Apps, die
    /// schon dort sind. Eine App, die selbst schon installiert ist, wird nur ersetzt und zählt nicht neu.
    public static func freeTeamBlock(bundle: String, apps: [InstalledApp]) -> [String]? {
        let mine = appsSharingPrefix(with: bundle, in: apps)
        guard !mine.contains(where: { $0.bundleIdentifier == bundle }), mine.count >= AppleMessages.freeAppsPerDevice else { return nil }
        return mine.map(\.name).sorted()
    }

    // MARK: Auswahl und Bestand

    /// Die Käufe, die gelten: der zuletzt von Meta bestätigte Stand.
    func confirmedPurchases() -> PurchaseRecord? {
        wantsAddons ? PurchaseRecord.load(store: store, recipe: recipe) : nil
    }

    func selection() -> FetchSelection {
        var sel = FetchSelection(locales: Set(request.locales), optionalNames: Set(request.optionalNames),
                                 withheld: store.withheld(for: recipe))
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

    /// Woraus gebaut wird, muss da sein: das APK und die Ordner, die die Toolchain selbst liest.
    func buildInputs() throws {
        if let apk = recipe.files.first(where: { $0.role == "apk" }), ContentStore.fileSize(store.url(for: apk, in: recipe)) == nil {
            throw InstallError.missingFiles(count: 1, examples: [apk.name], recipe: recipe.id)
        }
        let trees = TreeStore(store: store).missing(recipe: recipe).filter { $0.role != .data }
        guard trees.isEmpty else { throw InstallError.missingTrees(trees.map(\.name), recipe: recipe.id) }
    }

    /// Unter welcher Kennung das Spiel installiert wird: die ausdrücklich genannte; sonst bei einem kostenlosen Team
    /// die mit dessen eigenem Präfix (die übliche Kennung gehört womöglich schon einem bezahlten Team, und Apple
    /// gäbe sie keinem zweiten); ohne Team – beim bloßen Kopieren – die der bestehenden Installation; sonst die übliche.
    var resolvedBundleId: String {
        let target = recipe.toolchain.target
        if let given = request.bundleId { return given }
        if let team = request.team {
            return AppleTeams.isFree(team) ? Toolchain.bundleId(target: target, prefix: Toolchain.defaultBundlePrefix(freeTeam: team))
                                           : Toolchain.defaultBundleId(target: target)
        }
        return SigningRecord.load(store: store, recipe: recipe)?.bundleId ?? Toolchain.defaultBundleId(target: target)
    }

    func target() throws -> (device: Device, bundle: String, toolchain: Toolchain) {
        let device = try control.pick(udid: request.device)
        let bundle = resolvedBundleId
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
        if let app = recipe.store.steamAppId, recipe.source == .steam {
            try checkSteamAccount(app: app)
            return
        }
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

    /// Ein Spiel aus Steam: Steam wird gefragt, ob das Konto das Spiel besitzt und welche seiner Zusatzinhalte.
    /// Gefragt wird Valves eigenes Werkzeug mit der Anmeldung des Nutzers; ohne ein klares Ja geht es nicht weiter.
    /// Die bestätigten Zusatzinhalte bilden die Kaufliste – wie bei Meta ersetzt eine neue Antwort die alte.
    func checkSteamAccount(app: String) throws {
        guard let account = request.steamAccount, SteamTool.isAccountName(account) else { throw InstallError.steamAccountMissing }
        let addons = wantsAddons ? (recipe.addons?.steamApps ?? []) : []
        report(L("Asking Steam whether this account owns the game …", "Steam wird gefragt, ob das Spiel zu diesem Konto gehört …"))
        let answers = try SteamLicences(account: account).owned(apps: [app] + addons)
        switch answers[app] {
        case true?: report(L("Ownership confirmed by Steam.", "Besitz von Steam bestätigt."))
        case false?: throw InstallError.notOwned(recipe.title)
        case nil: throw SteamError.unclearOwnership
        }
        guard wantsAddons else { return }
        let record = PurchaseRecord(appId: app, skus: addons.filter { answers[$0] == true }.sorted(), verified: Date())
        try? record.save(store: store, recipe: recipe)
        report(L("Purchases: \(record.skus.count) of \(addons.count) add-ons confirmed by Steam.",
                 "Käufe: \(record.skus.count) von \(addons.count) Zusatzinhalten von Steam bestätigt."))
    }

    /// Was aus dem eigenen Steam-Kauf kommt und im Bestand fehlt, holt Valves Werkzeug – bei einem Spiel aus Steam
    /// als Teil des Auftrags, damit „Installieren“ dort dasselbe tut wie bei einem Spiel aus dem Meta-Store.
    func fetchFromSteam() throws {
        guard recipe.source == .steam, let account = request.steamAccount, SteamTool.isAccountName(account),
              !SteamFetcher.needed(recipe: recipe, store: store, optionalNames: Set(request.optionalNames)).files.isEmpty else { return }
        let report = self.report, progress = self.progress
        try SteamFetcher(store: store, account: account).fetch(
            recipe: recipe, optionalNames: Set(request.optionalNames),
            progress: { progress(InstallProgress(step: .fetch, done: $0.done, total: $0.total)) },
            report: { report($0) })
    }

    /// Liegt dasselbe Spiel aus einer anderen Kaufquelle auf dem Gerät, wird nicht darüber installiert und nichts
    /// dazukopiert: Die beiden Fassungen haben eigene Dateien, und was die eine dort ließe, fände die andere vor.
    func refuseOtherSource(device: Device, bundle: String) throws {
        guard let foreign = request.otherSourceBuilds, !foreign.isEmpty, let wanted = recipe.source,
              let app = try? control.apps(device: device).first(where: { $0.bundleIdentifier == bundle }),
              let parts = app.bundleVersion?.split(separator: "."), parts.count == 2, let installed = Int(parts[0]),
              installed != recipe.versionCode, foreign.contains(installed) else { return }
        throw InstallError.otherSourceInstalled(recipe.title, wanted: wanted)
    }

    /// Lädt, was im Bestand fehlt. Vor dem ersten Abruf bei Meta wird der Besitz geprüft; es wird nie eine
    /// Datei angefragt, nur um zu sehen, ob Meta sie herausgibt.
    func fetch() async throws {
        try fetchFromSteam()
        let plan = FetchPlan.plan(recipe: recipe, selection: selection()) { store.state(of: $0, in: recipe) }
        let onlyDownload = request.downloadOnly ?? false
        let fromUser = plan.filter { $0.action == .needsUser }
        guard fromUser.isEmpty || onlyDownload else {
            throw InstallError.userFilesNeeded(names: fromUser.map(\.file.name), hint: fromUser.first?.file.source?.hint?.text)
        }
        // Ordnerbestände mit freier Adresse (etwa Valves Laufzeitumgebung für ein Linux-Spiel) holt das Programm
        // selbst; was danach noch fehlt, kann nur der Nutzer bereitstellen.
        let treeStore = TreeStore(store: store)
        let report = self.report
        for tree in treeStore.fetchable(recipe: recipe) {
            try await treeStore.fetch(tree, in: recipe) { report($0) }
        }
        let trees = treeStore.missing(recipe: recipe)
        guard trees.isEmpty || onlyDownload else { throw InstallError.missingTrees(trees.map(\.name), recipe: recipe.id) }
        // Beim reinen Laden bleibt offen, was nur der Nutzer hat. Gesagt wird es trotzdem – am Ende, wo man es liest.
        let open = fromUser.map(\.file.name) + trees.map(\.name)
        defer {
            if onlyDownload, !open.isEmpty {
                report(L("Still missing, and yours to provide before the game can be built: \(open.joined(separator: ", ")). The game's page says where they come from.",
                         "Es fehlt noch, und das stellst du selbst bereit, bevor das Spiel gebaut werden kann: \(open.joined(separator: ", ")). Auf der Seite des Spiels steht, woher es kommt."))
            }
        }
        // Eine 2D-App, deren APK schon im Bestand liegt: nichts weiter laden.
        if let apk = plan.first(where: { $0.file.role == "apk" && $0.action == .keep }) {
            try FlatApp.refuse(apk: store.url(for: apk.file, in: recipe), recipe: recipe, store: store)
        }
        let todo = plan.filter { $0.action != .keep && $0.action != .needsUser }
        let kept = plan.filter { $0.action == .keep }.count
        guard !todo.isEmpty else {
            report(kept == plan.count
                ? L("Files: \(plan.count) needed, all in the library.", "Dateien: \(plan.count) gebraucht, alle im Bestand.")
                : L("Files: \(plan.count) needed, \(kept) in the library, nothing to download.", "Dateien: \(plan.count) gebraucht, \(kept) im Bestand, nichts zu laden."))
            return
        }
        // Was dem Namen nach schon in einer anderen Fassung desselben Spiels liegt, wird nur geladen, wenn es sich
        // geändert hat (Fetcher.adopt) – gesagt, bevor es losgeht, damit „129 zu laden“ nicht nach 13 GB klingt.
        let elsewhere = todo.filter { $0.action == .download && $0.file.source == nil && $0.file.role != "apk"
                                      && !store.siblings(of: $0.file, in: recipe).isEmpty }.count
        report(L("Files: \(plan.count) needed, \(kept) in the library, \(todo.count) to download.",
                 "Dateien: \(plan.count) gebraucht, \(kept) im Bestand, \(todo.count) zu laden.")
               + (elsewhere > 0 ? L(" \(elsewhere) of them are in the library from another version of this game; each is taken from there if it is unchanged.",
                                    " \(elsewhere) davon liegen aus einer anderen Fassung dieses Spiels im Bestand; jede wird von dort übernommen, wenn sie unverändert ist.") : ""))

        var client = MetaClient(token: "unbenutzt")       // ohne Meta-Dateien wird er nie benutzt
        var token: String?
        if todo.contains(where: { $0.file.source == nil }) {
            token = try TokenStore().read(account: request.account)
            client = MetaClient(token: token ?? "")
            let user = try await client.me()
            if let app = recipe.store.appId {
                guard try await client.ownsApp(appId: app, userId: user) else { throw InstallError.notOwned(recipe.title) }
            }
        }
        var fetcher = Fetcher(client: client, store: store, gate: RequestGate(minInterval: .seconds(request.interval)))
        if let token, let tool = metaTool, (try? MetaTool(url: tool).verify()) != nil {
            fetcher.toolFallback = MetaToolDownload(tool: tool, token: token)
        }
        // Sobald das APK da ist, steht fest, ob es überhaupt 64-Bit-Code enthält. Wenn nicht, wird nichts weiter
        // geladen – bei République VR wären das 3,4 GB für ein Spiel gewesen, das nie starten kann.
        // Ebenso, ob es eine 2D-App ist (Spotify, WhatsApp): die kann nie laufen.
        let title = recipe.title, recipe = self.recipe, store = self.store
        fetcher.afterFile = { file, url in
            guard file.role == "apk" else { return }
            let found = ApkUnpacker.architectures(of: url)
            if ApkUnpacker.lacksArm64(found) { throw InstallError.wrongArchitecture(title, found.sorted()) }
            try FlatApp.refuse(apk: url, recipe: recipe, store: store)
        }
        let summary = try await fetcher.run(plan, recipe: recipe) { report("  " + $0) }
        report(L("Downloaded: \(summary.downloaded) files, \(summary.kept) were already there"
                 + (summary.adopted > 0 ? ", \(summary.adopted) unchanged ones taken from another version of the game." : "."),
                 "Geladen: \(summary.downloaded) Dateien, \(summary.kept) waren vorhanden"
                 + (summary.adopted > 0 ? ", \(summary.adopted) unveränderte aus einer anderen Fassung des Spiels übernommen." : ".")))
        if !summary.withheld.isEmpty {
            report(L("Without \(summary.withheld.count) add-on file(s) Meta doesn't deliver for this account: \(summary.withheld.joined(separator: ", ")). The game is installed without them. After buying the add-on, remove the game's files on its page and download again.",
                     "Ohne \(summary.withheld.count) Zusatzdatei(en), die Meta für dieses Konto nicht ausliefert: \(summary.withheld.joined(separator: ", ")). Das Spiel wird ohne sie installiert. Nach einem Kauf des Zusatzinhalts: die Dateien des Spiels auf seiner Seite entfernen und neu laden."))
        }
    }

    /// Bauen und installieren. Der Container muss existieren, bevor Daten kopiert werden; deshalb steht der
    /// Build vor dem Kopieren. Installieren über eine bestehende App erhält deren Daten.
    func build() async throws {
        guard let team = request.team else { throw InstallError.teamMissing }
        if request.resign == true { try buildInputs() } else { _ = try localFiles() }
        let (device, bundle, toolchain) = try target()
        let commit = toolchain.commit()
        report(L("Device: \(device.name) (visionOS \(device.osVersion)); app: \(bundle); toolchain: \(commit)",
                 "Gerät: \(device.name) (visionOS \(device.osVersion)); App: \(bundle); Toolchain: \(commit)"))
        // Vor allem anderen: Über die Fassung aus der anderen Kaufquelle wird nicht gebaut und nicht installiert.
        try refuseOtherSource(device: device, bundle: bundle)
        // Dasselbe für ein APK, das schon im Bestand lag: ohne 64-Bit-Code gibt es nichts zu bauen.
        if let apk = recipe.files.first(where: { $0.role == "apk" }) {
            let found = ApkUnpacker.architectures(of: store.url(for: apk, in: recipe))
            if ApkUnpacker.lacksArm64(found) { throw InstallError.wrongArchitecture(recipe.title, found.sorted()) }
            try FlatApp.refuse(apk: store.url(for: apk, in: recipe), recipe: recipe, store: store)
        }
        try await prepare(toolchain)
        // Ein Versuch mit einer App, die gar kein natives Programm ist, würde gebaut, installiert und als fertig
        // gemeldet – und könnte nie starten. Das sagt man besser hier.
        if toolchain.missingEntryLibrary(recipe: recipe) != nil { throw InstallError.notANativeApp(recipe.title) }
        // Eine Installation beendet die laufende App. Das soll niemandem mitten im Spiel passieren.
        if request.replaceRunning != true,
           let app = try? control.apps(device: device).first(where: { $0.bundleIdentifier == bundle }),
           let running = try? control.runningExecutables(device: device), DeviceControl.isRunning(app, executables: running) {
            throw InstallError.appRunning(recipe.title)
        }
        // Ein kostenloses Konto: Apples Grenze vorab prüfen, statt erst zu bauen und dann an ihr zu scheitern.
        // (`AVPPLAY_NO_FREE_PRECHECK=1` lässt die Vorabprüfung aus – um zu sehen, was Apple selbst dazu sagt.)
        if AppleTeams.isFree(team), ProcessInfo.processInfo.environment["AVPPLAY_NO_FREE_PRECHECK"] != "1",
           let apps = try? control.apps(device: device),
           let there = Installer.freeTeamBlock(bundle: bundle, apps: apps) {
            throw InstallError.freeTeamFull(recipe.title, installed: there)
        }
        // Ein neuer Bau verlängert die Signatur nur, wenn Xcode dafür ein neues Profil holt (siehe `SigningProfiles`).
        // Bei einem kostenlosen Team gilt das für jede Installation, sonst nur fürs Erneuern.
        let free = AppleTeams.isFree(team)
        if free || request.resign == true,
           SigningProfiles.removeStale(team: team, bundleId: bundle, fresherThan: SigningProfiles.renewBelow(free: free)) > 0 {
            report(L("Signing: a new profile is requested from Apple, so that the game opens for the full time again.",
                     "Signatur: Bei Apple wird ein neues Profil angefordert, damit das Spiel wieder die volle Zeit gilt."))
        }
        let log = store.directory(for: recipe).appendingPathComponent(".last-build.log")
        let started = Date()
        let experimental = request.experimental == true
        if experimental {
            report(toolchain.supportsExperimental
                   ? L("Experimental: the new audio implementation is on from the start in this build (it can be switched off in the game under Settings › Advanced › Test); with toolchain 507 also the one-head-pose-per-frame implementation, which newer toolchains use by default.",
                       "Experimentell: Die neue Audio-Implementierung ist in diesem Bau von Anfang an eingeschaltet (im Spiel abschaltbar unter Einstellungen › Erweitert › Test); mit Toolchain 507 auch die Implementierung mit einer Kopfpose pro Frame, die neuere Toolchains ohnehin benutzen.")
                   : L("Experimental: this toolchain cannot switch the new audio implementation on yet; the game is built as usual.",
                       "Experimentell: Diese Toolchain kann die neue Audio-Implementierung noch nicht einschalten; das Spiel wird wie üblich gebaut."))
        }
        let metalFX = request.metalFX == true
        if metalFX {
            report(toolchain.supportsMetalFX
                   ? L("MetalFX: upscaling is on from the start in this build. It sharpens the picture where the game's resolution is set below 100%, in every engine and path (Vulkan and GL, Meta's interface and OpenXR, with foveated rendering too); the metrics panel in the headset shows the resolution before and after it. In the game it can be switched off under Settings › Rendering.",
                       "MetalFX: Das Hochskalieren ist in diesem Bau von Anfang an eingeschaltet. Es schärft das Bild, wo die Auflösung des Spiels unter 100 % steht, in jeder Engine und auf jedem Pfad (Vulkan und GL, Metas Schnittstelle und OpenXR, auch mit Foveated Rendering); das Leistungs-Panel in der Brille zeigt die Auflösung davor und danach. Im Spiel abschaltbar unter Einstellungen › Rendering.")
                   : L("MetalFX: this toolchain cannot switch upscaling on from the start yet; the game is built as usual.",
                       "MetalFX: Diese Toolchain kann das Hochskalieren noch nicht von Anfang an einschalten; das Spiel wird wie üblich gebaut."))
            if toolchain.supportsMetalFX, let percent = request.resolution,
               MetalFXResolution.environmentValue(percent) != nil {
                let value = MetalFXResolution.clamped(percent)
                report(toolchain.supportsRenderScalePreset
                       ? L("MetalFX: the game starts at \(value)% resolution; what is set in the game (Settings › Rendering) counts from then on.",
                           "MetalFX: Das Spiel beginnt mit \(value) % Auflösung; was im Spiel eingestellt wird (Einstellungen › Rendering), gilt danach.")
                       : L("MetalFX: this toolchain cannot preset the resolution yet; the game starts at its usual one.",
                           "MetalFX: Diese Toolchain kann die Auflösung noch nicht vorbelegen; das Spiel beginnt mit seiner üblichen."))
            }
        }
        // Die XR-Vorhersage: aus, außer die Seite des Spiels schaltet sie ein. Eine ältere Toolchain sagt immer voraus.
        let xrPrediction = request.xrPrediction == true
        if !toolchain.supportsXRPrediction {
            if xrPrediction {
                report(L("XR prediction: this toolchain always predicts the head pose; the game is built as usual.",
                         "XR-Vorhersage: Diese Toolchain sagt die Kopfpose immer voraus; das Spiel wird wie üblich gebaut."))
            }
        } else if xrPrediction {
            report(L("XR prediction: on from the start in this build (in the game under Settings › Advanced › Test).",
                     "XR-Vorhersage: In diesem Bau von Anfang an eingeschaltet (im Spiel unter Einstellungen › Erweitert › Test)."))
        }
        try toolchain.buildAndInstall(recipe: recipe, team: team, device: device, bundleId: bundle, log: log,
                                      extraEnvironment: TreeStore(store: store).toolchainEnvironment(recipe: recipe),
                                      experimental: experimental, metalFX: metalFX,
                                      resolution: metalFX ? request.resolution : nil,
                                      xrPrediction: xrPrediction,
                                      displayName: request.displayName, displaySuffix: request.displaySuffix)
        report(String(format: L("Built and installed (%.0f s).", "Gebaut und installiert (%.0f s)."), Date().timeIntervalSince(started)))
        // Womit signiert wurde und bis wann: Daran erinnert die App rechtzeitig vor dem Ablauf.
        var record = SigningRecord(team: team, free: free, installed: Date(), expires: toolchain.signingExpiry(recipe: recipe),
                                   bundleId: bundle)
        record.displayName = request.displayName
        record.displaySuffix = request.displaySuffix
        // Ohne ausdrückliche Kennung ist es immer die eigentliche Installation; mit einer entscheidet `save`
        // (`SigningRecord.isLive`): Eine Testkopie wird es auch dann nicht, wenn das Spiel noch keinen Eintrag hat.
        record.save(store: store, recipe: recipe, live: request.live ?? (request.bundleId == nil ? true : nil))
        if free {
            let until = record.expires.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) }
            report(until.map { L("Signed with a free Apple team: the game opens until \($0). Install it again before then to renew it; its data stays.",
                                 "Mit einem kostenlosen Apple-Team signiert: Das Spiel lässt sich bis \($0) öffnen. Installiere es vorher erneut, um es zu erneuern; seine Daten bleiben.") }
                   ?? L("Signed with a free Apple team: the game opens for seven days. Install it again before then to renew it; its data stays.",
                        "Mit einem kostenlosen Apple-Team signiert: Das Spiel lässt sich sieben Tage lang öffnen. Installiere es vorher erneut, um es zu erneuern; seine Daten bleiben."))
        }
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
        if request.storeArt, !FileManager.default.fileExists(atPath: cover.path), let app = recipe.catalogAppId {
            if let image = await StoreArt().squareCover(appId: app) {
                try image.write(to: cover, options: .atomic)
                report(L("Icon: fetched the cover image from the store page.", "Icon: Titelbild von der Store-Seite geholt."))
            } else if let image = await CatalogClient.configured.cover(appId: app, square: true) {
                // Manche Store-Seiten zeigen öffentlich kein Bild (Richie's Plank Experience); für solche Spiele hält
                // der Katalogdienst des Projekts eins bereit.
                try image.write(to: cover, options: .atomic)
                report(L("Icon: the store page shows no cover image – fetched it from the project's catalogue.",
                         "Icon: die Store-Seite zeigt kein Titelbild – vom Katalog des Projekts geholt."))
            } else {
                report(L("Icon: no square cover image found on the store page – keeping the icon from the APK.",
                         "Icon: kein quadratisches Titelbild auf der Store-Seite gefunden – es bleibt beim Icon aus dem APK."))
            }
        }
        // Dasselbe im Querformat, für das Startfenster der App.
        let wide = StartHero.storeURL(store: store, recipe: recipe)
        if request.storeArt, !FileManager.default.fileExists(atPath: wide.path), let app = recipe.catalogAppId {
            if let image = await StoreArt().landscapeCover(appId: app) {
                try image.write(to: wide, options: .atomic)
                report(L("Start image: fetched the landscape cover image from the store page.",
                         "Startbild: Titelbild im Querformat von der Store-Seite geholt."))
            } else if let image = await CatalogClient.configured.cover(appId: app) {
                try image.write(to: wide, options: .atomic)
                report(L("Start image: the store page shows no cover image – fetched it from the project's catalogue.",
                         "Startbild: die Store-Seite zeigt kein Titelbild – vom Katalog des Projekts geholt."))
            }
        }
        try toolchain.prepare(recipe: recipe, store: store)
    }

    /// Ergänzend kopieren: nur was auf dem Gerät fehlt oder eine andere Größe hat.
    func stage() throws {
        let (device, bundle, toolchain) = try target()
        try refuseOtherSource(device: device, bundle: bundle)
        // Worüber kopiert wird, entscheidet macOS: am Kabel über das Kabel, sonst über das WLAN. Gesagt wird es hier,
        // weil es über Minuten oder Stunden entscheidet.
        if let via = device.transport {
            progress(InstallProgress(step: .stage, done: 0, total: 0, via: via))
            switch via {
            case .cable: report(L("Connection to the Vision Pro: USB cable.", "Verbindung zur Vision Pro: USB-Kabel."))
            case .wifi:
                report(L("Connection to the Vision Pro: Wi-Fi. With a USB cable on the Developer Strap, macOS copies over the cable instead, which is much faster for large games.",
                         "Verbindung zur Vision Pro: WLAN. Mit einem USB-Kabel am Developer Strap kopiert macOS stattdessen über das Kabel – bei großen Spielen deutlich schneller."))
            case .other(let raw): report(L("Connection to the Vision Pro: \(raw).", "Verbindung zur Vision Pro: \(raw)."))
            }
        }
        // Ein Entwurf lässt offen, wo die Haupt-Datendatei hingehört; jetzt, mit entpacktem APK, weiß es die Toolchain.
        var obb: String?
        var packageFolder: String?
        let local = try localFiles().map { entry -> (file: RecipeFile, url: URL, size: Int64) in
            // Ebenso der Ordner mit dem Paketnamen, wenn der Katalog den Namen nicht kannte.
            if DraftRecipe.needsPackage(entry.file.dest) {
                if packageFolder == nil {
                    guard let name = toolchain.packageName(recipe: recipe) else {
                        throw RecipeError.invalid(L("the game's package name is unknown, so there is no place for '\(entry.file.name)'",
                                                    "Der Paketname des Spiels ist unbekannt, also gibt es keinen Ort für '\(entry.file.name)'"))
                    }
                    packageFolder = DraftRecipe.packageFolder(package: name)
                }
                var file = entry.file
                file.dest = packageFolder
                return (file, entry.url, entry.size)
            }
            guard entry.file.dest == DraftRecipe.obbPlaceholder else { return entry }
            if obb == nil { obb = toolchain.obbDestination(recipe: recipe) ?? "android-files/obb" }
            var file = entry.file
            file.dest = obb
            return (file, entry.url, entry.size)
        }
        guard try control.apps(device: device).contains(where: { $0.bundleIdentifier == bundle }) else {
            throw InstallError.appNotInstalled(bundle)
        }
        var remote: [String: Int64] = [:]
        // Auch dort nachsehen, wo etwas Abgewähltes liegen könnte, das sich vom Gerät nehmen lässt.
        let clearable = recipe.files.filter { $0.clearable == true && !$0.required }
        for dir in Set((local.map(\.file) + clearable).compactMap { StagePlan.directory(for: $0) }) {
            for f in try control.files(device: device, bundle: bundle, subdirectory: dir) where !f.isDirectory {
                remote["\(dir)/\(f.relativePath)"] = f.size
            }
        }
        // Abgewähltes: von außen lässt sich dort nichts löschen, aber überschreiben. Eine leere Datei an derselben
        // Stelle gibt den Platz frei; das Programm des Spiels räumt sie beim nächsten Start weg.
        for gone in StagePlan.withdrawals(recipe: recipe, wanted: Set(local.map(\.file.name)), remote: remote) {
            let empty = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-empty-\(UUID().uuidString)")
            try Data().write(to: empty)
            defer { try? FileManager.default.removeItem(at: empty) }
            try control.copy(empty, to: device, bundle: bundle, destination: gone.destination)
            report(L("Taken off the device: \(gone.file.title?.text ?? gone.file.name) (\(Installer.gigabytes(gone.size)) freed).",
                     "Vom Gerät genommen: \(gone.file.title?.text ?? gone.file.name) (\(Installer.gigabytes(gone.size)) frei)."))
        }
        var items = StagePlan.plan(local: local, remote: remote)
        let staged = local.filter { StagePlan.destination(for: $0.file) != nil }.count
        // Für die Zeile „… liegen dort schon“: die Dateien des Rezepts, ohne was unten noch dazukommt.
        let recipeItems = items.count
        // Die Liste der Shader-Kombinationen, wo die Toolchain für das Spiel eine mitbringt: Aus ihr und den eigenen
        // Dateien des Spiels entsteht hier das Archiv, das die Brille vor dem Start übersetzt – damit ein Shader nicht
        // erst in dem Moment übersetzt wird, in dem das Spiel ihn zum ersten Mal braucht, und das Bild dafür stehen
        // bleibt. Scheitert das, wird trotzdem installiert; dann ist es wie bisher.
        do {
            if let list = try toolchain.pipelineList(recipe: recipe, gameFiles: store.directory(for: recipe)) {
                var there: [String: Int64] = [:]
                for f in (try? control.files(device: device, bundle: bundle, subdirectory: "Documents/klfz")) ?? [] where !f.isDirectory {
                    there[f.relativePath] = f.size
                }
                let name = "\(recipe.toolchain.target).foz"
                if let size = ContentStore.fileSize(list.archive), there[name] != size {
                    items.append(StageItem(source: list.archive, destination: "Documents/klfz/\(name)", size: size))
                    report(L("Shader list: \(list.summary). The Vision Pro compiles them before the game's next start – a few minutes once, with a progress bar.",
                             "Shader-Liste: \(list.summary). Die Vision Pro übersetzt sie vor dem nächsten Start des Spiels – einmalig einige Minuten, mit Fortschrittsanzeige."))
                }
                // Die Beschreibung seines Grafikgeräts schreibt das Spiel bei jedem Start selbst (device-info.json).
                // Vor dem allerersten Start gibt es die noch nicht; dafür kommt eine Ersatzbeschreibung mit, unter
                // dem Namen, unter dem die Brille eine solche sucht – sonst könnte sie erst vor dem zweiten Start
                // übersetzen.
                if let info = list.deviceInfo, let size = ContentStore.fileSize(info), there["device-info.default.json"] != size {
                    items.append(StageItem(source: info, destination: "Documents/klfz/device-info.default.json", size: size))
                }
            }
        } catch {
            report(L("The shader list was left out: \(error)", "Die Shader-Liste bleibt weg: \(error)"))
        }
        // Gemeint sind hier die Bäume eines Spiels, das kein APK ist; Datenordner eines APK-Spiels folgen weiter unten.
        let hasTrees = !TreeStore.toolchainTrees(of: recipe).isEmpty
        if staged > 0 || !hasTrees {
            let total = Installer.gigabytes(items.map(\.size).reduce(0, +))
            report(L("Data: \(staged) files belong on the device, \(staged - recipeItems) are already there, "
                     + "\(items.count) to copy (\(total)).",
                     "Daten: \(staged) Dateien gehören aufs Gerät, \(staged - recipeItems) liegen dort schon, "
                     + "\(items.count) zu kopieren (\(total))."))
        }
        let copyStart = Date()
        let copyTotal = items.map(\.size).reduce(0, +)
        var copied: Int64 = 0
        if copyTotal > 0 { progress(InstallProgress(step: .stage, done: 0, total: copyTotal)) }
        for (n, item) in items.enumerated() {
            // Eine große Datei braucht über das WLAN Minuten. Damit der Balken dabei nicht stillsteht, wird das Gerät
            // währenddessen gefragt, wie viel von ihr schon dort liegt.
            let watching = StopFlag()
            pollFileProgress(item, device: device, bundle: bundle, before: copied, total: copyTotal, until: watching)
            defer { watching.stop() }
            try copyWithRetry(item, to: device, bundle: bundle)
            watching.stop()
            copied += item.size
            progress(InstallProgress(step: .stage, done: copied, total: copyTotal))
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
            var env = TreeStore(store: store).toolchainEnvironment(recipe: recipe)
            let mirror = toolchain.mirrorDirectory(recipe: recipe, store: store)
            env["KL_LX_MIRROR"] = mirror.path
            // Nach dem Abgleich braucht das Abbild niemand mehr; bliebe es liegen, hielten seine Links den Platz von
            // Spieldateien fest, die im Bestand längst entfernt sind.
            defer {
                try? FileManager.default.removeItem(at: mirror)
                // Im Bestand hat das Abbild einen eigenen Ordner je Spiel; leer bleibt auch der nicht liegen.
                for parent in [mirror.deletingLastPathComponent(), mirror.deletingLastPathComponent().deletingLastPathComponent()]
                where parent.path.hasPrefix(store.root.path + "/") { rmdir(parent.path) }
            }
            let log = store.directory(for: recipe).appendingPathComponent(".last-sync.log")
            try? FileManager.default.removeItem(at: log)
            try toolchain.syncTrees(recipe: recipe, environment: env, device: device, bundleId: bundle, copy: false, log: log)
            let want = TreeStore.listing(of: mirror)
            let total = Installer.gigabytes(want.values.reduce(0, +))
            report(L("Game data: \(want.count) files (\(total)) belong on the device; "
                     + "only what is missing or has changed there will be transferred …",
                     "Spieldaten: \(want.count) Dateien (\(total)) gehören aufs Gerät; "
                     + "übertragen wird nur, was dort fehlt oder sich geändert hat …"))
            let started = Date()
            // Die Toolchain überträgt ordnerweise und sagt dazwischen nichts; wie viel schon drüben liegt, weiß das
            // Gerät. Solange die Übertragung läuft, wird es regelmäßig gefragt und der Stand als Fortschritt gemeldet.
            let totalBytes = want.values.reduce(0, +)
            let polling = StopFlag()
            defer { polling.stop() }
            pollTreeProgress(device: device, bundle: bundle, subdirectory: Installer.treeDestination, total: totalBytes, until: polling)
            // Bei stundenlangen Übertragungen reißt die Verbindung gelegentlich ab (das Gerät schläft ein, ein Socket
            // schließt). Der Abgleich ist wiederholbar – was schon drüben ist, lässt devicectl aus –, also geht es
            // nach einer Pause weiter, statt den Auftrag anzuhalten. Nur Abbrüche der Übertragung werden wiederholt;
            // ein anderer Fehler der Toolchain hält wie bisher an.
            let attempts = 6
            for attempt in 1...attempts {
                let mark = ContentStore.fileSize(log) ?? 0
                do {
                    try toolchain.syncTrees(recipe: recipe, environment: env, device: device, bundleId: bundle, copy: true, log: log)
                    break
                } catch {
                    guard attempt < attempts, Installer.isTransferDrop(Installer.text(of: log, from: mark)) else { throw error }
                    let pause = Double(attempt) * 15
                    report(L("  Connection to the Vision Pro lost – continuing in \(Int(pause)) s (attempt \(attempt + 1) of \(attempts)); what is already there is kept.",
                             "  Verbindung zur Vision Pro unterbrochen – weiter in \(Int(pause)) s (Versuch \(attempt + 1) von \(attempts)); was schon drüben ist, bleibt."))
                    Thread.sleep(forTimeInterval: pause)
                }
            }
            polling.stop()
            progress(InstallProgress(step: .stage, done: totalBytes, total: totalBytes))
            report(String(format: L("Game data synced (%.0f s).", "Spieldaten abgeglichen (%.0f s)."), Date().timeIntervalSince(started)))
        }

        try stageDataTrees(device: device, bundle: bundle)

        // Die eigenen Server des Nutzers, wenn das Spiel so eine Liste versteht.
        if recipe.servers != nil, try GameServerStore().push(recipe: recipe, device: device, bundle: bundle, control: control) {
            report(L("Server list copied to the game.", "Serverliste zum Spiel kopiert."))
        }

        if request.restoreSaves == true { restoreSaves(device: device, bundle: bundle) }

        // Assets aus dem APK: als Ordner, wenn Anzahl oder Gesamtgröße abweichen. Der entpackte Baum entsteht
        // beim Build; fehlt er (Kopieren ohne vorherigen Build mit dieser Toolchain), wird er hier angelegt.
        try toolchain.prepare(recipe: recipe, store: store)

        // Was ein Spiel außerdem als Dateien lesen will (die Qt-Plugins von Steam Link): als eigener kleiner Ordner.
        let plugins = toolchain.qtPlugins(recipe: recipe)
        if !plugins.isEmpty {
            let pluginDest = "Documents/\(recipe.toolchain.target)/qtplugins"
            let size: (URL) -> Int64 = { Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            let remote = try control.files(device: device, bundle: bundle, subdirectory: pluginDest, recursive: false).filter { !$0.isDirectory }
            if Dictionary(remote.map { (($0.relativePath as NSString).lastPathComponent, $0.size) }, uniquingKeysWith: { a, _ in a }) != Dictionary(uniqueKeysWithValues: plugins.map { ($0.lastPathComponent, size($0)) }) {
                let stage = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-\(UUID().uuidString)/qtplugins", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: stage.deletingLastPathComponent()) }
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                for file in plugins { try FileManager.default.copyItem(at: file, to: stage.appendingPathComponent(file.lastPathComponent)) }
                try control.copy(stage, to: device, bundle: bundle, destination: pluginDest)
                report(L("Plugins: \(plugins.count) files copied.", "Plugins: \(plugins.count) Dateien kopiert."))
            }
        }

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

    /// Spielt die zuletzt geholten Spielstände zurück, wenn das Spiel auf dem Gerät noch keine hat. Geht das nicht,
    /// ist die Installation deshalb nicht gescheitert: Es wird gesagt, und der Knopf auf der Seite des Spiels bleibt.
    func restoreSaves(device: Device, bundle: String) {
        let sync = SaveSync(store: store)
        guard let snapshot = sync.saves.snapshots(for: recipe).first else { return }
        do {
            let n = try sync.restore(snapshot, recipe: recipe, device: device, bundle: bundle, mode: .ifNoneThere)
            if n > 0 {
                let when = DateFormatter.localizedString(from: snapshot.taken, dateStyle: .medium, timeStyle: .short)
                report(n == 1 ? L("Saved games: one file from \(when) put back on the device.", "Spielstände: eine Datei vom \(when) aufs Gerät zurückgespielt.")
                              : L("Saved games: \(n) files from \(when) put back on the device.", "Spielstände: \(n) Dateien vom \(when) aufs Gerät zurückgespielt."))
            }
        } catch {
            report(L("Saved games could not be put back (\(Redaction.redact("\(error)"))). The game's page offers it again.",
                     "Die Spielstände ließen sich nicht zurückspielen (\(Redaction.redact("\(error)"))). Die Seite des Spiels bietet es erneut an."))
        }
    }

    /// Datenordner eines APK-Spiels (Rolle `data`): Jeder gehört als Ganzes an seinen Ort unter `Documents/`.
    ///
    /// Übertragen wird in einem Zug, als Ordner – Datei für Datei bräuchte bei einigen tausend Dateien Stunden. Dafür
    /// entsteht im Bestand ein Abbild aus Links, das nur enthält, was drüben fehlt; `devicectl` legt es über den
    /// Zielordner, und was dort sonst liegt, bleibt. Ist alles drüben, kommt eine leere Kenndatei dazu, deren Name
    /// die Fassung des Baums trägt: Von da an gilt der Ordner als vollständig, und es wird nur noch ergänzt, was fehlt.
    func stageDataTrees(device: Device, bundle: String) throws {
        let fm = FileManager.default
        let treeStore = TreeStore(store: store)
        for tree in TreeStore.dataTrees(of: recipe) {
            guard let dest = tree.dest else { continue }
            let directory = "Documents/\(dest)"
            let source = treeStore.url(for: tree, in: recipe)
            let local = TreeStore.listing(of: source)
            guard !local.isEmpty else { throw InstallError.missingTrees([tree.name], recipe: recipe.id) }
            var remote: [String: Int64] = [:]
            for f in try control.files(device: device, bundle: bundle, subdirectory: directory, recursive: true) where !f.isDirectory {
                remote[f.relativePath] = f.size
            }
            let stamp = tree.deviceStampName
            let settled = remote[stamp] != nil
            var needed = StagePlan.missing(ofTree: local, remote: remote, settled: settled)
            // Die rekursive Liste des Geräts ist bei großen Bäumen nicht immer vollständig. Bevor in einem Ordner, der
            // als vollständig gilt, etwas ersetzt wird, das womöglich nur in der Liste fehlt, wird dort einzeln nachgesehen.
            if settled, !needed.isEmpty {
                let parents = Set(needed.keys.map { ($0 as NSString).deletingLastPathComponent })
                if parents.count <= 40 {
                    for parent in parents {
                        let sub = parent.isEmpty ? directory : "\(directory)/\(parent)"
                        for f in try control.files(device: device, bundle: bundle, subdirectory: sub) where !f.isDirectory {
                            needed[parent.isEmpty ? f.relativePath : "\(parent)/\(f.relativePath)"] = nil
                        }
                    }
                }
            }
            let bytes = needed.values.reduce(0, +)
            let total = Installer.gigabytes(local.values.reduce(0, +))
            guard !needed.isEmpty else {
                if !settled { try markSettled(tree, directory: directory, device: device, bundle: bundle) }
                report(L("Game data “\(tree.name)”: \(local.count) files (\(total)) are already on the device.",
                         "Spieldaten „\(tree.name)“: \(local.count) Dateien (\(total)) liegen schon auf dem Gerät."))
                continue
            }
            report(L("Game data “\(tree.name)”: \(local.count) files (\(total)) belong on the device, \(needed.count) to copy (\(Installer.gigabytes(bytes))) …",
                     "Spieldaten „\(tree.name)“: \(local.count) Dateien (\(total)) gehören aufs Gerät, \(needed.count) zu kopieren (\(Installer.gigabytes(bytes))) …"))

            let mirror = store.directory(for: recipe).appendingPathComponent(".stage-\(tree.name)", isDirectory: true)
            try? fm.removeItem(at: mirror)
            defer { try? fm.removeItem(at: mirror) }
            for path in needed.keys.sorted() {
                let from = source.appendingPathComponent(path), to = mirror.appendingPathComponent(path)
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Ein Link kostet keinen Platz; wo er nicht geht, tut es eine Kopie (auf APFS ein Klon).
                do { try fm.linkItem(at: from, to: to) } catch { try fm.copyItem(at: from, to: to) }
            }
            let started = Date()
            let polling = StopFlag()
            defer { polling.stop() }
            progress(InstallProgress(step: .stage, done: 0, total: bytes))
            pollTreeProgress(device: device, bundle: bundle, subdirectory: directory, total: bytes,
                             baseline: remote.values.reduce(0, +), until: polling)
            try copyWithRetry(StageItem(source: mirror, destination: directory, size: bytes), to: device, bundle: bundle)
            polling.stop()
            progress(InstallProgress(step: .stage, done: bytes, total: bytes))
            if !settled { try markSettled(tree, directory: directory, device: device, bundle: bundle) }
            report(String(format: L("Game data “\(tree.name)” copied (%.0f s).", "Spieldaten „\(tree.name)“ kopiert (%.0f s)."),
                          Date().timeIntervalSince(started)))
        }
    }

    /// Legt die Kenndatei in den Zielordner: Dieser Baum liegt in dieser Fassung vollständig auf dem Gerät.
    func markSettled(_ tree: RecipeTree, directory: String, device: Device, bundle: String) throws {
        let note = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-stamp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: note) }
        try Data("AVP Play: \(recipe.id) \(tree.name)\n".utf8).write(to: note)
        try control.copy(note, to: device, bundle: bundle, destination: "\(directory)/\(tree.deviceStampName)")
    }

    /// Wo die Toolchain die Ordnerbestände auf dem Gerät ablegt (siehe stage_sync.py: `<container>/Documents/lx`).
    static let treeDestination = "Documents/lx"

    /// Fragt das Gerät während eines Ordnerabgleichs alle halbe Minute, wie viel unter einem Ordner liegt (abzüglich
    /// dessen, was dort schon vorher lag), und meldet das als Fortschritt – bis `until` gesetzt ist. Eine Abfrage, die während der Übertragung scheitert,
    /// wird übergangen; die nächste kommt ohnehin. Die rekursive Liste des Geräts kann bei großen Bäumen unvollständig
    /// sein; der Balken zeigt dann eher zu wenig als zu viel.
    func pollTreeProgress(device: Device, bundle: String, subdirectory: String, total: Int64, baseline: Int64 = 0,
                          every seconds: TimeInterval = 30, until stop: StopFlag) {
        guard total > 0 else { return }
        let control = self.control, progress = self.progress
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 5)
            while !stop.isSet {
                if let files = try? control.files(device: device, bundle: bundle, subdirectory: subdirectory, recursive: true) {
                    let done = max(0, files.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size } - baseline)
                    if !stop.isSet { progress(InstallProgress(step: .stage, done: min(done, total), total: total)) }
                }
                for _ in 0..<Int(seconds * 2) where !stop.isSet { Thread.sleep(forTimeInterval: 0.5) }
            }
        }
    }

    /// Ab dieser Größe wird während des Kopierens einer einzelnen Datei nachgefragt, wie weit sie ist.
    static let watchedFileSize: Int64 = 48 << 20

    /// Fragt das Gerät während des Kopierens einer großen Datei alle paar Sekunden, wie groß sie dort schon ist, und
    /// meldet das als Fortschritt – bis `until` gesetzt ist. Am Gerät gemessen (visionOS 27.2, 2026-10-11): die
    /// Datei steht von Anfang an in der Liste und wächst mit. Eine Abfrage, die scheitert, wird übergangen.
    func pollFileProgress(_ item: StageItem, device: Device, bundle: String, before: Int64, total: Int64,
                          every seconds: TimeInterval = 2, until stop: StopFlag) {
        guard item.size >= Installer.watchedFileSize, total > 0 else { return }
        let control = self.control, progress = self.progress
        let folder = (item.destination as NSString).deletingLastPathComponent, name = (item.destination as NSString).lastPathComponent
        Thread.detachNewThread {
            while !stop.isSet {
                for _ in 0..<Int(seconds * 4) where !stop.isSet { Thread.sleep(forTimeInterval: 0.25) }
                guard !stop.isSet, let files = try? control.files(device: device, bundle: bundle, subdirectory: folder),
                      let there = files.first(where: { $0.relativePath == name && !$0.isDirectory })?.size else { continue }
                // Nie ganz voll, solange die Datei nicht als fertig gemeldet ist – und nie rückwärts.
                let part = min(there, item.size - 1)
                if !stop.isSet, part > 0 { progress(InstallProgress(step: .stage, done: min(before + part, total), total: total)) }
            }
        }
    }

    /// Sagt der Ausschnitt eines Abgleich-Protokolls, dass die Übertragung abriss (und nicht, dass etwas anderes
    /// schiefging)? Die Toolchain markiert das selbst („run this again to resume“); daneben die Meldungen von
    /// devicectl, wie sie am Gerät beobachtet wurden.
    static func isTransferDrop(_ logText: String) -> Bool {
        ["run this again to resume", "socket was closed", "could not be transferred", "CoreDeviceError", "Connection reset"]
            .contains { logText.contains($0) }
    }

    /// Der Teil eines Protokolls ab einer Stelle – für die Beurteilung eines einzelnen Versuchs.
    static func text(of log: URL, from offset: Int64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return "" }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(max(offset, 0)))
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
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
    /// Für den Verlauf eines Auftrags: eine Stelle nach dem Komma unter 100 MB, darüber ganze MB.
    public static func megabytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1e6
        if bytes > 0, mb < 0.1 { return "< 0.1 MB" }
        return String(format: mb < 100 ? "%.1f MB" : "%.0f MB", mb)
    }
}

/// Ein Schalter, den ein Thread setzt und ein anderer liest.
public final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    public func stop() { lock.lock(); value = true; lock.unlock() }
}
