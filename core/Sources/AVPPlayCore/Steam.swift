import Foundation

public enum SteamError: Error, CustomStringConvertible, Equatable {
    case toolMissing
    /// Valves Werkzeug ist (noch) ein reines Intel-Programm, und diesem Mac fehlt Rosetta.
    case needsRosetta
    case wrongSigner(String)
    case toolDownloadFailed(String)
    case badAccountName
    case notSignedIn(String)
    case notOwned(String)
    case depotFailed(depot: String, detail: String)
    case notEnoughSpace(needed: Int64, free: Int64)
    case notTheExpectedFiles([String])
    case badRecipe
    case unclearOwnership
    case stopped

    public var description: String {
        switch self {
        case .needsRosetta:
            return L("Valve ships SteamCMD as an Intel program, and this Mac does not have Apple's Rosetta yet, which runs such programs. Install Rosetta under “Setup” (Steam Account), then try again.",
                     "Valve liefert SteamCMD als Intel-Programm aus, und diesem Mac fehlt noch Apples Rosetta, das solche Programme ausführt. Installiere Rosetta unter „Einrichtung“ (Steam-Konto) und versuche es dann noch einmal.")
        case .toolMissing:
            return L("Valve's tool SteamCMD is not set up yet (see “Setup”).", "Valves Werkzeug SteamCMD ist noch nicht eingerichtet (siehe „Einrichtung“).")
        case .wrongSigner(let who):
            return L("The program is not signed by Valve (\(who)). It will not be run.", "Das Programm ist nicht von Valve signiert (\(who)). Es wird nicht gestartet.")
        case .toolDownloadFailed(let why):
            return L("SteamCMD could not be downloaded from Valve: \(why)", "SteamCMD ließ sich nicht von Valve laden: \(why)")
        case .badAccountName:
            return L("That does not look like a Steam account name (the name you sign in with, not your profile name).",
                     "Das sieht nicht nach einem Steam-Kontonamen aus (der Name, mit dem du dich anmeldest, nicht dein Profilname).")
        case .notSignedIn(let detail):
            return L("Steam did not accept the stored sign-in. Sign in to Steam again under “Setup”.", "Steam hat die gemerkte Anmeldung nicht angenommen. Melde dich unter „Einrichtung“ neu bei Steam an.")
                + (detail.isEmpty ? "" : " (\(detail))")
        case .notOwned(let what):
            return L("\(what) is not in this Steam account. Nothing is downloaded.", "\(what) gehört nicht zu diesem Steam-Konto. Es wird nichts geladen.")
        case .depotFailed(let depot, let detail):
            return L("Steam did not deliver depot \(depot).", "Steam hat Depot \(depot) nicht ausgeliefert.") + (detail.isEmpty ? "" : " \(detail)")
        case .notEnoughSpace(let needed, let free):
            return L("Not enough free space on this Mac: \(Installer.gigabytes(needed)) needed, \(Installer.gigabytes(free)) free.",
                     "Auf diesem Mac ist zu wenig Platz: \(Installer.gigabytes(needed)) gebraucht, \(Installer.gigabytes(free)) frei.")
        case .notTheExpectedFiles(let names):
            return L("Steam delivered files, but not the ones this recipe was made for: \(names.joined(separator: ", ")). They were left where SteamCMD put them.",
                     "Steam hat Dateien geliefert, aber nicht die, für die dieses Rezept gemacht ist: \(names.joined(separator: ", ")). Sie liegen noch dort, wo SteamCMD sie abgelegt hat.")
        case .badRecipe:
            return L("The recipe's Steam entry is not usable.", "Der Steam-Eintrag des Rezepts ist nicht brauchbar.")
        case .unclearOwnership:
            return L("Steam's answer about ownership was not one this version understands. Nothing is downloaded.",
                     "Steams Antwort zum Besitz war keine, die diese Fassung versteht. Es wird nichts geladen.")
        case .stopped: return L("Stopped.", "Angehalten.")
        }
    }
}

/// SteamCMD, Valves eigenes Kommandozeilenwerkzeug. Es lädt, was einem Steam-Konto gehört – und nur das: Ob ein
/// Konto ein Spiel besitzt, entscheidet Valve, nicht dieses Programm.
///
/// Das Werkzeug wird nicht mitgeliefert. Es kommt auf Wunsch des Nutzers direkt von Valves Server in einen
/// eigenen Ordner, und es bekommt einen eigenen Benutzerordner: Dort merkt es sich die Anmeldung, getrennt vom
/// Steam des Nutzers. Vor jedem Start wird geprüft, dass das Programm von Valve signiert ist. (Die Bibliotheken
/// daneben lädt und prüft Valves Werkzeug selbst, wenn es sich aktualisiert; eine davon liefert Valve ohne
/// eigene Signatur aus. Deshalb gilt die Prüfung hier dem Programm.)
public struct SteamTool: Sendable {
    /// Team-ID von „Valve Corporation“ in der Signatur.
    public static let expectedTeam = "MXGJJ98X76"
    public static let archiveURL = URL(string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz")!

    public let directory: URL
    /// Der Benutzerordner, den das Werkzeug zu sehen bekommt. Darin liegt seine gemerkte Anmeldung.
    public let home: URL
    /// Wohin die geladenen Depots gehen, wenn nicht neben das Werkzeug. SteamCMD legt sie immer in seinen eigenen
    /// Ordner `steamapps`; liegt der Bestand auf einem anderen Laufwerk, müssten 73 GB für Half-Life: Alyx erst
    /// dorthin, wo das Werkzeug liegt, und dann noch einmal hinüber. Deshalb zeigt `steamapps` dann als Verweis
    /// auf diesen Ordner.
    public var contentRoot: URL?

    public init(directory: URL = DataLocation.base.appendingPathComponent("tools/steamcmd", isDirectory: true),
                home: URL = DataLocation.base.appendingPathComponent("steam", isDirectory: true), contentRoot: URL? = nil) {
        self.directory = directory
        self.home = home
        self.contentRoot = contentRoot
    }

    /// Richtet den Verweis für die Depots ein (siehe `contentRoot`). Liegt unter `steamapps` schon etwas, bleibt
    /// es, wie es ist – ein laufender oder abgebrochener Abruf wird nicht verlegt.
    func prepareContent() throws {
        guard let contentRoot else { return }
        let fm = FileManager.default
        let link = directory.appendingPathComponent("steamapps")
        try fm.createDirectory(at: contentRoot, withIntermediateDirectories: true)
        if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            if URL(fileURLWithPath: existing).standardizedFileURL.path == contentRoot.standardizedFileURL.path { return }
            try fm.removeItem(at: link)
        } else if fm.fileExists(atPath: link.path) {
            guard StoreMove.measure(link).files == 0 else { return }
            try fm.removeItem(at: link)
        }
        try fm.createSymbolicLink(at: link, withDestinationURL: contentRoot)
    }

    public var executable: URL { directory.appendingPathComponent("steamcmd") }
    public var isInstalled: Bool { FileManager.default.fileExists(atPath: executable.path) }

    /// Gestartet wird nur ein Programm mit gültiger Signatur von Valve.
    public func verify() throws {
        guard isInstalled else { throw SteamError.toolMissing }
        try SteamTool.verifySignature(of: executable)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw SteamError.toolMissing }
        if needsRosetta() { throw SteamError.needsRosetta }
    }

    /// Ob das Werkzeug, so wie es daliegt, auf diesem Mac nicht starten kann: Es hat keine Fassung für
    /// Apple-Chips (so kommt es von Valve, bis es sich einmal selbst aktualisiert hat), und Rosetta fehlt.
    public func needsRosetta(rosettaInstalled: Bool = Rosetta.isInstalled) -> Bool {
        isInstalled && !rosettaInstalled && Rosetta.hasArm64Slice(executable) == false
    }

    static func verifySignature(of file: URL) throws {
        guard Toolchain.status(["/usr/bin/codesign", "--verify", "--strict", file.path]) == 0 else {
            throw SteamError.wrongSigner(L("signature invalid or missing", "Signatur ungültig oder nicht vorhanden"))
        }
        let info = MetaTool.captureBoth(["/usr/bin/codesign", "-dv", "--verbose=2", file.path])
        let team = info.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }.map { String($0.dropFirst("TeamIdentifier=".count)) }
        guard team == expectedTeam else { throw SteamError.wrongSigner(L("team \(team ?? "unknown")", "Team \(team ?? "unbekannt")")) }
    }

    /// Lädt das Archiv von Valve in eine vorläufige Datei.
    public static func downloadArchive(session: URLSession = .shared) async throws -> URL {
        do {
            var request = URLRequest(url: archiveURL)
            request.timeoutInterval = 60
            let (file, response) = try await session.download(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw SteamError.toolDownloadFailed(L("the server answered \((response as? HTTPURLResponse)?.statusCode ?? 0)", "der Server antwortete mit \((response as? HTTPURLResponse)?.statusCode ?? 0)"))
            }
            let kept = FileManager.default.temporaryDirectory.appendingPathComponent("steamcmd-\(UUID().uuidString).tar.gz")
            try FileManager.default.moveItem(at: file, to: kept)
            return kept
        } catch let error as SteamError {
            throw error
        } catch {
            throw SteamError.toolDownloadFailed(error.localizedDescription)
        }
    }

    /// Packt das Archiv aus und richtet es ein – aber nur, wenn das Programm darin von Valve signiert ist.
    @discardableResult
    public static func install(archive: URL, as tool: SteamTool = SteamTool()) throws -> SteamTool {
        let fm = FileManager.default
        let fresh = tool.directory.deletingLastPathComponent().appendingPathComponent(".steamcmd.new", isDirectory: true)
        try? fm.removeItem(at: fresh)
        try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fresh) }
        guard Toolchain.status(["/usr/bin/tar", "-xzf", archive.path, "-C", fresh.path]) == 0 else {
            throw SteamError.toolDownloadFailed(L("the archive could not be unpacked", "das Archiv ließ sich nicht entpacken"))
        }
        try verifySignature(of: fresh.appendingPathComponent("steamcmd"))
        try? fm.removeItem(at: tool.directory)
        try fm.moveItem(at: fresh, to: tool.directory)
        return tool
    }

    /// Die Umgebung, in der das Werkzeug läuft: sein eigener Benutzerordner, seine Bibliotheken neben sich, und
    /// sonst nichts aus der Umgebung dieses Programms.
    var environment: [String: String] {
        ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
         "DYLD_LIBRARY_PATH": directory.path, "DYLD_FRAMEWORK_PATH": directory.path,
         "LANG": "en_US.UTF-8", "USER": NSUserName(), "LOGNAME": NSUserName(), "TMPDIR": NSTemporaryDirectory()]
    }

    func prepareHome() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
    }

    /// Hat das Werkzeug schon einmal mit einem Konto gearbeitet? (Ob Steam die Anmeldung noch annimmt, zeigt
    /// erst der nächste Lauf.)
    public var hasSession: Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/Steam/config/config.vdf").path)
    }

    /// Abmelden: der Ordner mit der gemerkten Anmeldung wird gelöscht.
    public func signOut() throws {
        if FileManager.default.fileExists(atPath: home.path) { try FileManager.default.removeItem(at: home) }
    }

    /// Wohin `download_depot` ein Depot legt.
    public func contentDirectory(app: String, depot: String? = nil) -> URL {
        let base = directory.appendingPathComponent("steamapps/content/app_\(app)", isDirectory: true)
        return depot.map { base.appendingPathComponent("depot_\($0)", isDirectory: true) } ?? base
    }

    /// Taugt der Text als Kontoname? Er wird zu einem Argument des Werkzeugs.
    public static func isAccountName(_ name: String) -> Bool {
        (2...64).contains(name.count) && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-@".contains($0)) }
            && !name.hasPrefix("-") && !name.hasPrefix("@")
    }

    /// Nimmt aus der Ausgabe des Werkzeugs, was auf das Konto zeigt (die Steam-Kennung), und Steuerzeichen.
    public static func clean(_ text: String) -> String {
        Redaction.redact(text)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[U:\d+:\d+\]"#, with: "[…]", options: .regularExpression)
            .replacingOccurrences(of: #"\b7656119\d{10}\b"#, with: "…", options: .regularExpression)
    }

    /// Lässt das Werkzeug ohne Rückfragen laufen. Es darf sich dabei selbst aktualisieren und neu starten.
    func run(_ arguments: [String], shouldStop: @escaping @Sendable () -> Bool = { false },
             onLine: (String) -> Void = { _ in }) throws -> (status: Int32, output: String) {
        try prepareHome()
        var all = ""
        var status: Int32 = 42
        // Status 42 heißt bei Valve: „aktualisiert, bitte noch einmal starten“.
        for _ in 0..<4 where status == 42 {
            try verify()
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = directory
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let watcher = Thread {
                while process.isRunning {
                    if shouldStop() { process.terminate(); return }
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
            watcher.start()
            var pending = Data()
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let end = pending.firstIndex(where: { $0 == 0x0a || $0 == 0x0d }) {
                    let line = SteamTool.clean(String(decoding: pending[pending.startIndex..<end], as: UTF8.self))
                    pending.removeSubrange(pending.startIndex...end)
                    if !line.trimmingCharacters(in: .whitespaces).isEmpty { all += line + "\n"; onLine(line) }
                }
            }
            if !pending.isEmpty { all += SteamTool.clean(String(decoding: pending, as: UTF8.self)) + "\n" }
            process.waitUntilExit()
            status = process.terminationStatus
            if shouldStop() { throw SteamError.stopped }
        }
        return (status, all)
    }
}

/// Die Anmeldung bei Steam. Sie läuft in Valves Werkzeug an einem eigenen Terminal: Kontoname als Argument,
/// Passwort und Steam-Guard-Code tippt der Nutzer in das Werkzeug. Dieses Programm sieht und speichert beides
/// nicht; das Werkzeug merkt sich die Anmeldung in seinem eigenen Ordner.
public enum SteamLogin {
    public static func run(tool: SteamTool = SteamTool(), account: String,
                           input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO) throws {
        guard SteamTool.isAccountName(account) else { throw SteamError.badAccountName }
        try tool.prepareHome()
        var said = ""
        var code: Int32 = 42
        for _ in 0..<4 where code == 42 {
            try tool.verify()
            said = ""
            code = try Pty.run(tool: tool.executable, arguments: ["+login", account, "+quit"], environment: tool.environment,
                               directory: tool.directory, input: input, output: output, transform: { bytes in
                                   let text = SteamTool.clean(String(decoding: bytes, as: UTF8.self))
                                   said += text
                                   return Array(text.utf8)
                               })
        }
        guard code == 0, !SteamRun.loginFailed(said) else {
            throw SteamError.notSignedIn(SteamRun.failureLine(said))
        }
    }
}

/// Liest, was SteamCMD sagt.
enum SteamRun {
    static func loginFailed(_ output: String) -> Bool {
        output.contains("FAILED") || output.contains("ERROR (") || output.contains("ERROR!")
            || output.lowercased().contains("cached credentials not found") || output.lowercased().contains("invalid password")
    }

    /// Die Zeile, in der das Werkzeug sagt, was nicht ging – für die Meldung an den Nutzer.
    static func failureLine(_ output: String) -> String {
        let line = output.split(whereSeparator: \.isNewline).last { $0.contains("FAILED") || $0.contains("ERROR") || $0.lowercased().contains("failed") }
        return line.map { String($0.trimmingCharacters(in: .whitespaces).prefix(200)) } ?? ""
    }

    enum Licence { case owned, notOwned, unclear }

    /// Was `licenses_for_app` über eine App sagt. Besitz zeigt das Werkzeug als Liste der Lizenzen
    /// („License packageID …“, „State : Active“), Nichtbesitz mit einem festen Satz. Alles andere ist unklar –
    /// und dann wird nichts angefordert.
    static func licence(_ output: String, app: String) -> Licence {
        if output.contains("No active license found for appID \(app)") { return .notOwned }
        let lines = output.split(whereSeparator: \.isNewline)
        let listed = lines.contains { $0.hasPrefix("License packageID") }
        let active = lines.contains { $0.contains("State") && $0.contains("Active") }
        return listed && active ? .owned : .unclear
    }

    static func depotComplete(_ output: String, depot: String) -> Bool {
        // „depot_1006“ darf nicht für Depot 100 gelten: nach der Kennung folgt keine weitere Ziffer.
        output.split(whereSeparator: \.isNewline).contains {
            $0.contains("Depot download complete") && $0.range(of: "depot_\(depot)(?![0-9])", options: .regularExpression) != nil
        }
    }
}

public struct SteamProgress: Sendable, Equatable {
    public var done: Int64
    public var total: Int64
}

/// Holt, was ein Rezept aus einem Steam-Kauf braucht: fragt Steam, ob das Konto das Spiel besitzt, lädt die
/// Depots in genau der Fassung des Rezepts und übernimmt daraus, was zu den Prüfsummen des Rezepts passt.
public struct SteamFetcher: Sendable {
    public let tool: SteamTool
    public let store: ContentStore
    public let account: String

    public init(tool: SteamTool = SteamTool(), store: ContentStore, account: String) {
        var tool = tool
        // Bestand auf einem anderen Laufwerk als das Werkzeug: die Depots gleich dorthin laden.
        if tool.contentRoot == nil, !StoreLocation.sameVolume(tool.directory, store.root) {
            tool.contentRoot = store.root.appendingPathComponent(".steamcmd", isDirectory: true)
        }
        self.tool = tool
        self.store = store
        self.account = account
    }

    /// Kennt das Rezept für irgendetwas einen Weg über Steam?
    public static func usesSteam(_ recipe: Recipe) -> Bool {
        recipe.files.contains { $0.source?.steam != nil } || (recipe.trees ?? []).contains { $0.source.steam != nil }
    }

    /// Was im Bestand fehlt und über Steam zu holen wäre. Wählbare Dateien gehören nur dazu, wenn sie gewählt sind –
    /// sonst käme etwa eine Sprachausgabe von über einem Gigabyte mit, nach der niemand gefragt hat.
    public static func needed(recipe: Recipe, store: ContentStore, optionalNames: Set<String> = []) -> (files: [RecipeFile], trees: [RecipeTree]) {
        let files = recipe.files.filter {
            $0.source?.steam != nil && ($0.required || optionalNames.contains($0.name))
                && !FileManager.default.fileExists(atPath: store.url(for: $0, in: recipe).path)
        }
        let trees = TreeStore(store: store).missing(recipe: recipe).filter { $0.source.steam != nil }
        return (files, trees)
    }

    /// - Returns: die Namen dessen, was in den Bestand übernommen wurde.
    @discardableResult
    public func fetch(recipe: Recipe, optionalNames: Set<String> = [], shouldStop: @escaping @Sendable () -> Bool = { false },
                      progress: @escaping @Sendable (SteamProgress) -> Void = { _ in },
                      report: (String) -> Void = { _ in }) throws -> [String] {
        guard SteamTool.isAccountName(account) else { throw SteamError.badAccountName }
        let want = SteamFetcher.needed(recipe: recipe, store: store, optionalNames: optionalNames)
        let sources = (want.files.compactMap { $0.source?.steam } + want.trees.compactMap { $0.source.steam })
            .reduce(into: [SteamSource]()) { if !$0.contains($1) { $0.append($1) } }
        guard !sources.isEmpty else {
            report(L("Nothing is missing that Steam could provide.", "Es fehlt nichts, was Steam liefern könnte."))
            return []
        }
        guard sources.allSatisfy(\.isSane) else { throw SteamError.badRecipe }
        try tool.verify()
        try tool.prepareContent()

        // Platz: die Depots liegen zuerst bei SteamCMD und werden dann in den Bestand übernommen (auf APFS ohne
        // zweite Kopie). Gerechnet wird mit dem, was Valve als Größe nennt, und zwei Gigabyte Luft.
        var depots: [(app: String, depot: SteamSource.Depot)] = []
        for source in sources { for depot in source.depots where !depots.contains(where: { $0.app == source.app && $0.depot.id == depot.id }) { depots.append((source.app, depot)) } }
        let total = depots.compactMap(\.depot.bytes).reduce(0, +)
        let onDisk = depots.map { SteamFetcher.size(of: tool.contentDirectory(app: $0.app, depot: $0.depot.id)) }.reduce(0, +)
        let landing = tool.contentRoot ?? tool.directory
        try? FileManager.default.createDirectory(at: landing, withIntermediateDirectories: true)
        if let free = StoreLocation.freeBytes(at: landing), total - onDisk + 2_000_000_000 > free {
            throw SteamError.notEnoughSpace(needed: total - onDisk + 2_000_000_000, free: free)
        }

        // 1. Besitz. Erst wenn Steam ihn bestätigt, wird etwas angefordert; geliefert wird ohnehin nur, was dem
        //    Konto gehört – das setzt Valve durch.
        let apps = sources.map(\.app).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        report(L("Asking Steam whether this account owns the game …", "Steam wird gefragt, ob das Spiel zu diesem Konto gehört …"))
        for app in apps {
            let answer = try tool.run(["+@NoPromptForPassword", "1", "+login", account, "+licenses_for_app", app, "+quit"], shouldStop: shouldStop)
            guard answer.status == 0, !SteamRun.loginFailed(answer.output) else {
                throw SteamError.notSignedIn(SteamRun.failureLine(answer.output))
            }
            switch SteamRun.licence(answer.output, app: app) {
            case .owned: break
            case .notOwned: throw SteamError.notOwned(recipe.title)
            case .unclear: throw SteamError.unclearOwnership
            }
        }
        report(L("Ownership confirmed by Steam.", "Besitz von Steam bestätigt."))

        // 2. Laden. SteamCMD meldet beim Depot-Download keinen Fortschritt; gemessen wird, was auf der Platte liegt.
        report(L("Downloading from Steam: \(depots.count) depot(s), \(Installer.gigabytes(total)) …", "Von Steam wird geladen: \(depots.count) Depot(s), \(Installer.gigabytes(total)) …"))
        let measuring = Measuring()
        let content = depots.map { tool.contentDirectory(app: $0.app, depot: $0.depot.id) }
        let meter = Thread {
            while !measuring.done {
                let done = content.map(SteamFetcher.size(of:)).reduce(0, +)
                if total > 0 { progress(SteamProgress(done: min(done, total), total: total)) }
                Thread.sleep(forTimeInterval: 3)
            }
        }
        meter.start()
        defer { measuring.done = true }
        let download = try tool.run(["+@NoPromptForPassword", "1", "+login", account]
                                    + depots.flatMap { ["+download_depot", $0.app, $0.depot.id, $0.depot.manifest] } + ["+quit"],
                                    shouldStop: shouldStop) { line in
            if line.contains("Downloading depot") || line.contains("Depot download") { report("  " + line.replacingOccurrences(of: tool.directory.path, with: "…")) }
        }
        measuring.done = true
        guard !SteamRun.loginFailed(download.output) || depots.allSatisfy({ SteamRun.depotComplete(download.output, depot: $0.depot.id) }) else {
            throw SteamError.notSignedIn(SteamRun.failureLine(download.output))
        }
        for entry in depots where !SteamRun.depotComplete(download.output, depot: entry.depot.id) {
            throw SteamError.depotFailed(depot: entry.depot.id, detail: SteamRun.failureLine(download.output))
        }
        if total > 0 { progress(SteamProgress(done: total, total: total)) }

        // 3. Übernehmen: nur, was nachweislich das aus dem Rezept ist.
        report(L("Checking what arrived against the recipe …", "Das Geladene wird mit dem Rezept verglichen …"))
        var adopted: [String] = []
        var wrong: [String] = []
        if !want.files.isEmpty {
            let folders = want.files.compactMap { $0.source?.steam }.flatMap { s in s.depots.map { tool.contentDirectory(app: s.app, depot: $0.id) } }
            let result = try Adopter(store: store).adopt(recipe: recipe, from: Array(Set(folders)), maxDepth: 6)
            adopted += result.adopted
            wrong += want.files.map(\.name).filter { name in !result.adopted.contains(name) }
        }
        for tree in want.trees {
            guard let source = tree.source.steam else { continue }
            let layers = source.depots.map { depot -> URL in
                let base = tool.contentDirectory(app: source.app, depot: depot.id)
                return source.folder.map { base.appendingPathComponent($0, isDirectory: true) } ?? base
            }
            if try TreeStore(store: store).assemble(tree, in: recipe, from: layers) { adopted.append(tree.name) } else { wrong.append(tree.name) }
        }
        guard wrong.isEmpty else { throw SteamError.notTheExpectedFiles(wrong) }

        // 4. Aufräumen: Was übernommen ist, braucht bei SteamCMD nicht noch einmal zu liegen.
        for app in apps { try? FileManager.default.removeItem(at: tool.contentDirectory(app: app)) }
        report(L("Added to the library: \(adopted.joined(separator: ", "))", "In den Bestand übernommen: \(adopted.joined(separator: ", "))"))
        return adopted
    }

    private final class Measuring: @unchecked Sendable { var done = false }

    /// Was unter einem Ordner auf der Platte liegt.
    static func size(of directory: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        var bytes: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true { bytes += Int64(values?.fileSize ?? 0) }
        }
        return bytes
    }
}

extension TreeStore {
    /// Setzt einen Ordnerbestand aus mehreren Schichten zusammen: die erste ganz, aus jeder weiteren nur, was noch
    /// nicht da ist. Die Schichten bleiben unverändert; auf APFS entstehen platzsparende Kopien (Klone). Der Bestand
    /// wird erst ersetzt, wenn alle Kenndateien des Rezepts stimmen.
    /// - Returns: ob der zusammengesetzte Baum der aus dem Rezept ist.
    public func assemble(_ tree: RecipeTree, in recipe: Recipe, from layers: [URL]) throws -> Bool {
        let fm = FileManager.default
        guard let first = layers.first, fm.fileExists(atPath: first.path) else { return false }
        try fm.createDirectory(at: store.directory(for: recipe), withIntermediateDirectories: true)
        let fresh = store.directory(for: recipe).appendingPathComponent(".\(tree.name).new", isDirectory: true)
        try? fm.removeItem(at: fresh)
        try fm.copyItem(at: first, to: fresh)
        for layer in layers.dropFirst() {
            guard let walker = fm.enumerator(atPath: layer.path) else { continue }
            for case let relative as String in walker {
                let target = fresh.appendingPathComponent(relative)
                if fm.fileExists(atPath: target.path) { continue }
                let source = layer.appendingPathComponent(relative)
                if (walker.fileAttributes?[.type] as? FileAttributeType) == .typeDirectory {
                    // Ein Ordner, den es noch nicht gibt, kommt als Ganzes; hineinzusteigen ist dann unnötig.
                    try fm.copyItem(at: source, to: target)
                    walker.skipDescendants()
                } else {
                    try fm.copyItem(at: source, to: target)
                }
            }
        }
        guard TreeStore.failingMarkers(of: tree, at: fresh).isEmpty else {
            try? fm.removeItem(at: fresh)
            return false
        }
        let target = url(for: tree, in: recipe)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: fresh, to: target)
        return true
    }
}
