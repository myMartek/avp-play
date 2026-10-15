import AppKit
import AVPPlayCore

/// Stellt die Lage fest: Rezepte, Bestand, Gerät, Xcode, Toolchain. Fragt nur diesen Mac und das Gerät,
/// nie Meta. Läuft außerhalb des Hauptfadens, weil `devicectl` und `xcodebuild` Sekunden brauchen.
enum Probe {
    struct Snapshot: @unchecked Sendable {
        var games: [Game] = []
        var loadProblem: String?
        var device: Device?
        /// Alle gekoppelten, erreichbaren Headsets.
        var devices: [Device] = []
        var deviceProblem: String?
        var toolchainText: String?
        var toolPresent = false
        var xcodeText: String?
        var xcodeProblem: String?
        var teamCandidates: [Team] = []
        /// Freier Platz auf dem Laufwerk des Bestands.
        var freeBytes: Int64?
        var apps: [InstalledApp]?
        var toolchainRevision: Int?
        /// Was ein aktueller Bau von der experimentellen Einstellung tragen soll (`AppModel.experimentalExpected`).
        var experimentalExpected: Bool?
        /// Dasselbe für das MetalFX-Hochskalieren (`AppModel.metalFXExpected`).
        var metalFXExpected: Bool?
        /// Ob die neueste Toolchain die XR-Vorhersage als Option kennt (`Toolchain.supportsXRPrediction`); `nil` ohne
        /// Toolchain.
        var xrPredictionSupported: Bool?
        var toolchainChoices = ToolchainChoices()
        /// Der neueste Stand der Spielstände je Spiel, soweit einer auf dem Mac liegt.
        var saves: [String: SaveSnapshot] = [:]
    }

    /// Ein Entwicklerteam, wie Xcode es kennt.
    typealias Team = AppleTeam

    static func run(paths: Paths, bundlePrefix: String, preferredDevice: String? = nil) -> Snapshot {
        var s = Snapshot()

        let control = DeviceControl()
        var apps: [InstalledApp]?
        do {
            // Alle gekoppelten, erreichbaren Headsets. Bei genau einem ist die Wahl klar; bei mehreren gilt das
            // zuletzt gewählte, und ohne Wahl wird gefragt statt geraten.
            let usable = try control.devices().filter { $0.paired && $0.reachable }
            s.devices = usable
            let device = usable.first { $0.udid == preferredDevice } ?? (usable.count == 1 ? usable[0] : nil)
            if let device {
                s.device = device
                if !device.developerMode {
                    s.deviceProblem = L("Developer Mode is off on the Vision Pro (Settings › Privacy & Security › Developer Mode).", "Auf der Vision Pro ist der Entwicklermodus aus (Einstellungen › Datenschutz & Sicherheit › Entwicklermodus).")
                }
                apps = try? control.apps(device: device)
            } else if usable.isEmpty {
                s.deviceProblem = L("The Vision Pro is not reachable. Turn it on, put it on or unlock it, and connect it to the same Wi-Fi as this Mac.", "Die Vision Pro ist nicht erreichbar. Einschalten, aufsetzen oder entsperren und im selben WLAN wie dieser Mac anmelden.")
            } else {
                s.deviceProblem = L("Several Vision Pros are reachable. Choose the one to use under “Setup”.",
                                    "Es sind mehrere Vision Pros erreichbar. Wähle unter „Einrichtung“, welche benutzt werden soll.")
            }
        } catch {
            s.deviceProblem = "\(error)"
        }

        let toolchain = paths.toolchain()
        if let toolchain {
            s.toolchainText = toolchain.manifest != nil
                ? L("Version \(toolchain.version()) is installed.", "Version \(toolchain.version()) ist installiert.")
                : L("Development checkout \(toolchain.commit()) (not an installed package).", "Entwicklungsstand \(toolchain.commit()) (kein installiertes Paket).")
        }

        s.apps = apps
        s.toolchainRevision = toolchain?.appRevision()
        let experimental = AppModel.experimentalExpected(toolchain: toolchain)
        s.experimentalExpected = experimental
        let metalFX = AppModel.metalFXExpected(toolchain: toolchain)
        s.metalFXExpected = metalFX
        s.xrPredictionSupported = toolchain?.supportsXRPrediction
        let xrPrediction = AppModel.xrPredictionExpected(supported: s.xrPredictionSupported)
        OtherSources.use(recipes: paths.recipes)
        if let recipes = paths.recipes {
            do {
                // Weitere Fassungen, zu denen das Projekt ein eigenes Rezept führt (recipes/versions).
                let variants = RecipeStore(directory: recipes).loadVariants()
                // Rezepte für dasselbe Spiel aus einer anderen Kaufquelle (recipes/sources).
                let sources = RecipeStore(directory: recipes).loadSources()
                let revision = toolchain?.appRevision()
                // Wo für ein Spiel eine Toolchain gewählt ist, gilt die statt der neuesten.
                let choices = ToolchainChoices.load()
                s.toolchainChoices = choices
                func game(_ r: Recipe, draft: Bool, tested: Recipe? = nil) -> Game {
                    Probe.game(r, draft: draft, tested: tested, variants: variants, sources: sources, paths: paths, apps: apps,
                               toolchainRevision: revision, pin: choices.games[r.id], bundlePrefix: bundlePrefix,
                               experimental: experimental, metalFX: metalFX, xrPrediction: xrPrediction?(r.id))
                }
                let bundled = try RecipeStore(directory: recipes).loadAll()
                // Entwürfe für ungetestete Spiele, die schon nachgeschlagen wurden. Ein mitgeliefertes Rezept für
                // dieselbe Store-App geht vor.
                let shipped = Set(bundled.compactMap { $0.store.appId })
                let drafts = ((try? RecipeStore(directory: DataLocation.base.appendingPathComponent("drafts", isDirectory: true)).loadAll()) ?? [])
                    .filter { r in r.id.hasPrefix("store-") && !(r.store.appId.map(shipped.contains) ?? true) }
                // Wo der Nutzer die neueste Fassung aus dem Store gewählt hat, gilt deren Rezept statt des geprüften.
                let active = StoreUpdate.resolve(bundled, variants: variants, sources: sources,
                                                 drafts: DataLocation.base.appendingPathComponent("drafts", isDirectory: true))
                s.games = (zip(active, bundled).map { game($0, draft: false, tested: $1) } + drafts.map { game($0, draft: true) })
                    .sorted { $0.recipe.title.localizedCaseInsensitiveCompare($1.recipe.title) == .orderedAscending }
                let saved = paths.saves
                // Stände aus der Zeit, als sie immer bei den Daten des Programms lagen, ziehen neben den gewählten Ordner.
                if StoreLocation.isAvailable(paths.store.root) {
                    SaveStore.move(from: SaveStore.root(forStore: StoreLocation.standard()), to: saved.root)
                }
                for g in s.games { if let newest = saved.snapshots(for: g.recipe).first { s.saves[g.id] = newest } }
                StoreIndex.write(root: paths.store.root, entries: indexEntries(games: s.games, root: paths.store.root))
            } catch {
                s.loadProblem = L("The list of games could not be read: \(error)", "Die Spieleliste konnte nicht gelesen werden: \(error)")
            }
        } else {
            s.loadProblem = L("No list of games was found.", "Es wurde keine Spieleliste gefunden.")
        }

        s.toolPresent = (try? MetaTool(url: metaToolURL).verify()) != nil

        // Ohne Entwicklerordner nicht fragen: `xcrun` wäre dann nur der Platzhalter, der zum Installieren auffordert.
        let version = DeveloperTools.present ? capture(["/usr/bin/xcrun", "xcodebuild", "-version"]) : (status: Int32(1), out: "")
        if let first = version.out.split(separator: "\n").first, version.status == 0 {
            if capture(["/usr/bin/xcrun", "xcodebuild", "-showsdks"]).out.contains("xros") {
                s.xcodeText = L("\(first) with visionOS support.", "\(first) mit visionOS-Unterstützung.")
            } else {
                s.xcodeText = String(first)
                s.xcodeProblem = L("Xcode is missing the visionOS platform. Open Xcode › Settings › Components › download visionOS.", "In Xcode fehlt die visionOS-Plattform. Xcode öffnen › Einstellungen › Components › visionOS laden.")
            }
        } else {
            s.xcodeProblem = L("Xcode is not installed or has never been opened. Get Xcode from the App Store and open it once.", "Xcode ist nicht installiert oder noch nie geöffnet worden. Xcode aus dem App Store laden und einmal starten.")
        }

        s.teamCandidates = teams()
        // Nicht anlegen, wenn die Platte des Ordners fehlt: sonst entstünde derselbe Pfad leer auf dem Startlaufwerk.
        if StoreLocation.isAvailable(paths.store.root) {
            try? FileManager.default.createDirectory(at: paths.store.root, withIntermediateDirectories: true)
        }
        s.freeBytes = StoreLocation.freeBytes(at: paths.store.root)
        return s
    }

    /// Was im Verzeichnis des Ordners für Downloads steht: jeder Ordner dort mit dem Spiel, zu dem er gehört.
    /// Ein Spiel der Übersicht aus seinem geltenden Rezept: Stand im Bestand und auf dem Gerät, Titelbild, und was
    /// zur Wahl steht (weitere geprüfte Fassungen, eine andere Kaufquelle). Für sich aufrufbar, damit ein Wechsel
    /// der Kaufquelle nur dieses eine Spiel neu bestimmen muss und nicht alles.
    static func game(_ r: Recipe, draft: Bool, tested: Recipe?, variants: [Recipe], sources: [Recipe], paths: Paths,
                     apps: [InstalledApp]?, toolchainRevision: Int?, pin: ToolchainChoices.Pin? = nil, bundlePrefix: String,
                     experimental: Bool? = nil, metalFX: Bool? = nil, xrPrediction: Bool? = nil) -> Game {
        // Geprüft ist die Fassung ohne Wahl und jede weitere mit eigenem Rezept; alles andere ist eine
        // ungetestete aus dem Store, und dann nennt das Spiel die, die ohne Wahl gilt.
        let own = tested.map { t in variants.filter { $0.id == t.id && $0.versionCode != t.versionCode } } ?? []
        // Dasselbe Spiel aus einer anderen Kaufquelle: ein eigenes Rezept des Projekts, keine „Fassung aus dem
        // Store“ – und was unter den Versionscodes der anderen Quelle auf dem Gerät liegt, ist nicht dieses.
        let otherSources = tested.map { t in sources.filter { $0.id == t.id } } ?? []
        let switched = tested.map { $0.source != r.source } ?? false
        let family = (tested.map { [$0] } ?? []) + (tested.map { t in variants.filter { $0.id == t.id } } ?? []) + otherSources
        let foreign = family.filter { $0.source != r.source }.map(\.versionCode)
        let verified = switched || tested.map { $0.versionCode == r.versionCode } ?? true || own.contains { $0.versionCode == r.versionCode }
        var g = Game(recipe: r,
             status: GameStatus.of(recipe: r, store: paths.store, apps: apps, toolchainVersion: toolchainRevision, pin: pin,
                                    bundlePrefix: bundlePrefix, otherSourceBuilds: Set(foreign), experimental: experimental,
                                    metalFX: metalFX, xrPrediction: xrPrediction),
             // Das Titelbild gehört zum Spiel, nicht zur Kaufquelle: Fehlt es bei dieser, gilt das der anderen.
             cover: (StartHero.choose(recipe: r, store: paths.store) ?? tested.flatMap { StartHero.choose(recipe: $0, store: paths.store) })
                 .flatMap { NSImage(data: $0.image) },
             storeBytes: directorySize(paths.store.directory(for: r)), draft: draft,
             testedVersion: verified ? nil : tested?.versionName)
        if let tested, !otherSources.isEmpty, let shipped = tested.source {
            g.sources = [shipped] + otherSources.compactMap(\.source)
        }
        g.otherSourceBuilds = foreign
        if let tested, !switched {
            g.verifiedVersions = [GameVersion(versionCode: tested.versionCode, versionName: tested.versionName, kind: .verified, isDefault: true)]
                + own.map { GameVersion(versionCode: $0.versionCode, versionName: $0.versionName, kind: .verified, isDefault: false) }
        }
        return g
    }

    static func indexEntries(games: [Game], root: URL) -> [StoreIndex.Entry] {
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        return folders.map { url in
            let name = url.lastPathComponent
            if let game = games.first(where: { "\($0.recipe.id)-\($0.recipe.versionCode)" == name }) {
                return StoreIndex.Entry(folder: name, title: game.recipe.title, detail: L("Version \(game.recipe.versionName)", "Version \(game.recipe.versionName)"), bytes: game.storeBytes)
            }
            let size = directorySize(url)
            if let game = games.first(where: { name.hasPrefix($0.recipe.id + "-") }) {
                return StoreIndex.Entry(folder: name, title: game.recipe.title, detail: L("an earlier version, no longer needed", "eine frühere Fassung, wird nicht mehr gebraucht"), bytes: size)
            }
            return StoreIndex.Entry(folder: name, title: name, detail: L("not used by any game in the list", "von keinem Spiel der Liste gebraucht"), bytes: size)
        }
    }

    /// Belegter Platz eines Ordners; Verweise werden nicht verfolgt.
    static func directorySize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Wo Metas Werkzeug liegt: die eigene Kopie der App, sonst eine früher gewählte Datei. Der Ordner
    /// „Downloads“ wird hier nicht angefasst – macOS fragt beim ersten Zugriff um Erlaubnis, und diese Frage
    /// soll erst kommen, wenn der Nutzer das Werkzeug dort suchen lässt.
    static var metaToolURL: URL {
        if FileManager.default.fileExists(atPath: MetaTool.installedURL.path) { return MetaTool.installedURL }
        return UserDefaults.standard.string(forKey: "metaToolPath").map { URL(fileURLWithPath: $0) } ?? MetaTool.installedURL
    }

    /// Die Teams, mit denen Xcode auf diesem Mac angemeldet ist: Kennung, Name und ob es ein kostenloses Team
    /// ist. Gelesen wird nur diese Liste aus Xcodes Einstellungen, keine Kontodaten. Kennt Xcode keine Teams,
    /// bleiben die Kennungen aus den Entwicklerzertifikaten – ein Vorschlag, keine Prüfung.
    static func teams() -> [Team] {
        let found = AppleTeams.known()
        if !found.isEmpty { return found }
        return certificateTeams().map { Team(id: $0, name: L("Team \($0)", "Team \($0)"), free: false) }
    }

    /// Team-IDs aus den Entwicklerzertifikaten im Schlüsselbund (das Feld „OU“ des Zertifikats).
    static func certificateTeams() -> [String] {
        let pem = capture(["/usr/bin/security", "find-certificate", "-a", "-c", "Apple Development", "-p"]).out
        var found: [String] = []
        for block in pem.components(separatedBy: "-----END CERTIFICATE-----") where block.contains("BEGIN CERTIFICATE") {
            let subject = capture(["/usr/bin/openssl", "x509", "-noout", "-subject", "-nameopt", "multiline"],
                                  input: block + "-----END CERTIFICATE-----\n").out
            for line in subject.split(separator: "\n") where line.contains("organizationalUnitName") {
                if let id = line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces),
                   id.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil, !found.contains(id) {
                    found.append(id)
                }
            }
        }
        return found
    }

    static func capture(_ argv: [String], input: String? = nil) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let out = Pipe(), stdin = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        if input != nil { p.standardInput = stdin }
        guard (try? p.run()) != nil else { return (-1, "") }
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
