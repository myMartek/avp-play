import Foundation

/// Die Schlüssel-Wert-Tabellen, die SteamCMD für `app_info_print` und `package_info_print` ausgibt
/// (`"Schlüssel"  "Wert"` oder `"Schlüssel"` mit einem Block in geschweiften Klammern darunter).
public indirect enum SteamValue: Sendable, Equatable {
    case text(String)
    case table([String: SteamValue])

    public subscript(_ key: String) -> SteamValue? {
        if case .table(let t) = self { return t[key] }
        return nil
    }
    public var text: String? { if case .text(let s) = self { return s }; return nil }
    public var table: [String: SteamValue]? { if case .table(let t) = self { return t }; return nil }
}

enum SteamKeyValues {
    /// Die Blöcke einer Ausgabe je Kennung: nach einer Kopfzeile wie „AppID : 885000, change number …“ folgt
    /// `"885000"` und der Block. Was dazwischen an Meldungen des Werkzeugs steht, bleibt ungelesen.
    static func blocks(_ output: String, header: String) -> [String: SteamValue] {
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [String: SteamValue] = [:]
        var i = 0
        let prefix = "\(header) : "
        while i < lines.count {
            let line = lines[i]
            guard line.hasPrefix(prefix) else { i += 1; continue }
            let id = String(line.dropFirst(prefix.count).prefix { $0.isNumber })
            i += 1
            guard !id.isEmpty, i + 1 < lines.count, lines[i] == "\"\(id)\"", lines[i + 1] == "{" else { continue }
            let (table, next) = parseTable(lines, from: i + 2)
            result[id] = .table(table)
            i = next
        }
        return result
    }

    /// Liest Zeilen bis zur schließenden Klammer; gibt die Tabelle und die Zeile danach zurück.
    static func parseTable(_ lines: [String], from start: Int, depth: Int = 0) -> ([String: SteamValue], Int) {
        var table: [String: SteamValue] = [:]
        var i = start
        while i < lines.count {
            let line = lines[i]
            if line == "}" { return (table, i + 1) }
            let strings = quoted(line)
            if strings.count >= 2 {
                table[strings[0]] = .text(strings[1])
                i += 1
            } else if strings.count == 1, i + 1 < lines.count, lines[i + 1] == "{", depth < 32 {
                let (sub, next) = parseTable(lines, from: i + 2, depth: depth + 1)
                table[strings[0]] = .table(sub)
                i = next
            } else {
                i += 1
            }
        }
        return (table, i)
    }

    /// Die Zeichenketten einer Zeile in Anführungszeichen, mit `\"` und `\\` als Maskierung.
    static func quoted(_ line: String) -> [String] {
        var out: [String] = []
        var current: String?
        var escaped = false
        for ch in line {
            if var s = current {
                if escaped { s.append(ch); escaped = false; current = s }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { out.append(s); current = nil }
                else { s.append(ch); current = s }
            } else if ch == "\"" {
                current = ""
            }
        }
        return out
    }
}

/// Ein Spiel aus dem Steam-Konto, für das Steam eine Android-Fassung ausliefert – das APK, das Valve für sein eigenes
/// Headset verteilt. Nur solche kann AVP Play bauen.
public struct SteamAndroidApp: Codable, Sendable, Equatable {
    public var appId: String
    public var name: String
    /// Die Android-Depots des Spiels selbst (keine Zusatzinhalte), jedes mit seiner öffentlichen Fassung.
    public var depots: [SteamSource.Depot]
    /// Die APK-Namen aus den Startoptionen für Android, in Steams Reihenfolge.
    public var apks: [String]

    public init(appId: String, name: String, depots: [SteamSource.Depot], apks: [String]) {
        self.appId = appId
        self.name = name
        self.depots = depots
        self.apks = apks
    }

    public var bytes: Int64 { depots.compactMap(\.bytes).reduce(0, +) }
}

/// Liest aus SteamCMD, welche Spiele das Konto hat und welche davon eine Android-Fassung haben.
public enum SteamLibraryRead {
    /// Die Apps aus den aktiven Lizenzen (`licenses_print`) und die Pakete, deren Liste das Werkzeug gekürzt hat
    /// („… (196 in total)“) – deren Apps fragt `package_info_print` nach.
    static func licensed(_ output: String) -> (apps: Set<String>, truncated: [String]) {
        var apps = Set<String>()
        var truncated: [String] = []
        var package: String?
        var active = false
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("License packageID") {
                package = String(line.dropFirst("License packageID".count).trimmingCharacters(in: .whitespaces).prefix { $0.isNumber })
                active = false
                continue
            }
            if line.hasPrefix("- State") { active = line.contains("Active"); continue }
            guard line.hasPrefix("- Apps"), active, let colon = line.firstIndex(of: ":") else { continue }
            let body = line[line.index(after: colon)...]
            let list = body.prefix { $0 != "(" }
            for id in list.split(whereSeparator: { !$0.isNumber }) { apps.insert(String(id)) }
            if body.contains("..."), let package, !package.isEmpty { truncated.append(package) }
        }
        return (apps, truncated)
    }

    /// Die Apps eines Pakets aus `package_info_print` (`appids`).
    static func packageApps(_ blocks: [String: SteamValue]) -> Set<String> {
        var apps = Set<String>()
        for block in blocks.values {
            for value in block["appids"]?.table?.values ?? [:].values {
                if let id = value.text, isDigits(id) { apps.insert(id) }
            }
        }
        return apps
    }

    /// Aus den App-Daten die Spiele mit Android-Depot. Ein Depot zählt, wenn es Android nennt, keinem Zusatzinhalt
    /// gehört (`dlcappid`) und eine öffentliche Fassung hat.
    static func androidApps(_ blocks: [String: SteamValue]) -> [SteamAndroidApp] {
        var out: [SteamAndroidApp] = []
        for (appId, block) in blocks where isDigits(appId) {
            guard let common = block["common"], common["type"]?.text?.lowercased() == "game" else { continue }
            var depots: [SteamSource.Depot] = []
            for (depotId, depot) in block["depots"]?.table ?? [:] where isDigits(depotId) {
                guard oslist(depot["config"]?["oslist"]?.text).contains("android"), depot["dlcappid"] == nil,
                      let manifest = depot["manifests"]?["public"]?["gid"]?.text, isDigits(manifest) else { continue }
                let bytes = depot["manifests"]?["public"]?["size"]?.text.flatMap { Int64($0) }
                depots.append(SteamSource.Depot(id: depotId, manifest: manifest, bytes: bytes))
            }
            guard !depots.isEmpty else { continue }
            depots.sort { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
            let launches = (block["config"]?["launch"]?.table ?? [:]).sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }
            var apks: [String] = []
            for (_, launch) in launches where oslist(launch["config"]?["oslist"]?.text).contains("android") {
                if let exe = launch["executable"]?.text, exe.lowercased().hasSuffix(".apk"), Recipe.isSafeName(exe), !apks.contains(exe) { apks.append(exe) }
            }
            let name = common["name"]?.text.map { String($0.prefix(200)) } ?? appId
            out.append(SteamAndroidApp(appId: appId, name: name, depots: depots, apks: apks))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func oslist(_ s: String?) -> [String] {
        (s ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func isDigits(_ s: String) -> Bool { (1...24).contains(s.count) && s.allSatisfy { $0.isASCII && $0.isNumber } }
}

/// Fragt Valves Werkzeug mit der Anmeldung des Nutzers nach seinen Steam-Spielen mit Android-Fassung: erst die
/// Lizenzen, dann – für gekürzte Pakete – deren Apps, dann die App-Daten aller Apps in einem Lauf.
public struct SteamLibraryScan: Sendable {
    public let tool: SteamTool
    public let account: String

    public init(tool: SteamTool = SteamTool(), account: String) {
        self.tool = tool
        self.account = account
    }

    public func run(shouldStop: @escaping @Sendable () -> Bool = { false }) throws -> [SteamAndroidApp] {
        guard SteamTool.isAccountName(account) else { throw SteamError.badAccountName }
        try tool.verify()
        let login = ["+@NoPromptForPassword", "1", "+login", account]
        let licences = try tool.run(login + ["+licenses_print", "+quit"], shouldStop: shouldStop)
        guard licences.status == 0, !SteamRun.loginFailed(licences.output) else { throw SteamRun.failure(licences.output) }
        var (apps, truncated) = SteamLibraryRead.licensed(licences.output)
        // Ohne eine einzige Lizenz sieht die Antwort nicht aus wie erwartet: kein Ergebnis statt eines leeren.
        guard !apps.isEmpty else { throw SteamError.unclearOwnership }
        if !truncated.isEmpty {
            let packages = try tool.run(login + truncated.prefix(200).flatMap { ["+package_info_print", $0] } + ["+quit"], shouldStop: shouldStop)
            apps.formUnion(SteamLibraryRead.packageApps(SteamKeyValues.blocks(packages.output, header: "PackageID")))
        }
        var found: [SteamAndroidApp] = []
        let ids = apps.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
        for start in stride(from: 0, to: ids.count, by: 1000) {
            if shouldStop() { throw SteamError.stopped }
            let group = ids[start..<min(start + 1000, ids.count)]
            let info = try tool.run(login + group.flatMap { ["+app_info_print", $0] } + ["+quit"], shouldStop: shouldStop)
            guard info.status == 0, !SteamRun.loginFailed(info.output) else { throw SteamRun.failure(info.output) }
            found += SteamLibraryRead.androidApps(SteamKeyValues.blocks(info.output, header: "AppID"))
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Die zuletzt gelesenen Steam-Spiele mit Android-Fassung, im Bestand abgelegt.
public struct SteamLibrary: Codable, Sendable, Equatable {
    public var checked: Date
    public var apps: [SteamAndroidApp]
    public init(checked: Date, apps: [SteamAndroidApp]) {
        self.checked = checked
        self.apps = apps
    }

    /// Ein Lauf dauert mit vielen Spielen über eine Minute; einmal am Tag genügt. Eine Zeit in der Zukunft gilt als alt.
    public func isStale(now: Date = Date(), maxAge: TimeInterval = 24 * 3600) -> Bool {
        now.timeIntervalSince(checked) > maxAge || checked > now
    }
}

public struct SteamLibraryCache: Sendable {
    public let url: URL
    public init(store: ContentStore) { url = store.root.appendingPathComponent("steam-library.json") }

    public func load() -> SteamLibrary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.iso.decode(SteamLibrary.self, from: data)
    }

    public func save(_ library: SteamLibrary) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder.iso
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(library).write(to: url, options: .atomic)
    }

    public func clear() { try? FileManager.default.removeItem(at: url) }
}

public enum SteamDraftError: Error, CustomStringConvertible, Equatable {
    case noApk
    case unreadableApk(String)
    case duplicateName(String)
    case unsafeName(String)
    case tooManyFiles(Int)

    public var description: String {
        switch self {
        case .noApk:
            return L("Steam's Android depot of this game has no APK that the app can recognise.",
                     "Im Android-Depot dieses Spiels bei Steam liegt kein APK, das die App erkennt.")
        case .unreadableApk(let why):
            return L("The APK from Steam can't be read: \(why)", "Das APK aus Steam lässt sich nicht lesen: \(why)")
        case .duplicateName(let name):
            return L("The depot contains two files named \(name) in different folders; such a game can't be prepared automatically yet.",
                     "Das Depot enthält zwei Dateien namens \(name) in verschiedenen Ordnern; so ein Spiel lässt sich noch nicht automatisch vorbereiten.")
        case .unsafeName(let name):
            return L("The depot contains a file name the app does not accept: \(name)", "Das Depot enthält einen Dateinamen, den die App nicht annimmt: \(name)")
        case .tooManyFiles(let n):
            return L("The depot contains \(n) files – too many for a recipe.", "Das Depot enthält \(n) Dateien – zu viele für ein Rezept.")
        }
    }
}

/// Ein Rezept für ein Steam-Spiel mit Android-Fassung, das noch niemand geprüft hat. Anders als ein Entwurf aus dem
/// Meta-Store entsteht es aus den geladenen Dateien selbst: mit Größen und Prüfsummen, und jede Datei mit dem Depot
/// und der Fassung, aus der sie kommt. Danach installiert es der übliche Weg für Steam-Spiele.
public enum SteamDraft {
    public static func identifier(appId: String) -> String { "steam-\(appId)" }

    public static func appId(of identifier: String) -> String? {
        guard identifier.hasPrefix("steam-") else { return nil }
        let id = String(identifier.dropFirst(6))
        return SteamLibraryRead.isDigits(id) ? id : nil
    }

    /// Platzhalter für ein Spiel, dessen Dateien noch nicht von Steam geladen sind: nur Name und Kennung.
    public static func placeholder(app: SteamAndroidApp) -> Recipe {
        Recipe(schema: Recipe.supportedSchema, id: identifier(appId: app.appId), title: app.name, package: "",
               versionName: "", versionCode: 0, store: .init(appId: nil, steamAppId: app.appId),
               toolchain: .init(target: "", minCommit: ""), files: [], addons: nil,
               status: .init(playability: "untested", download: "unknown", notes: nil), icon: nil, trees: nil)
    }

    /// Eine Datei des Depots: ihr Weg darin und ihre Größe.
    public struct DepotFile: Sendable, Equatable {
        public var path: String
        public var size: Int64
        public init(path: String, size: Int64) {
            self.path = path
            self.size = size
        }
        var name: String { path.split(separator: "/").last.map(String.init) ?? path }
        var folder: String { path.split(separator: "/").dropLast().joined(separator: "/") }
    }

    /// Welche Datei das APK ist: die erste aus Steams Startoptionen, die im Depot liegt (eine „Shipping“-Fassung
    /// vor einer zum Testen), sonst das einzige APK im Depot.
    static func apk(in files: [DepotFile], launch: [String]) -> DepotFile? {
        let apks = files.filter { $0.name.lowercased().hasSuffix(".apk") }
        let ordered = launch.filter { $0.lowercased().contains("shipping") } + launch.filter { !$0.lowercased().contains("shipping") }
        for name in ordered { if let hit = apks.first(where: { $0.name == name }) { return hit } }
        return apks.count == 1 ? apks[0] : nil
    }

    /// Wohin eine Datei des Depots auf dem Gerät kommt. Die Haupt-Datendatei (`main.<Version>.<Paket>.obb`) setzt die
    /// Toolchain ein; was im Depot schon unter `Android/obb` oder `Android/data` liegt, bleibt dort; alles andere
    /// kommt, wie bei einer Quest, unter `Android/obb/<Paket>`, mit den Unterordnern aus dem Depot.
    static func placement(of file: DepotFile, package: String) -> (role: String, dest: String) {
        let lower = file.name.lowercased()
        if lower.hasPrefix("main."), lower.hasSuffix(".obb") { return ("main-obb", DraftRecipe.obbPlaceholder) }
        let folder = file.folder
        let lowerFolder = folder.lowercased()
        if lowerFolder.hasPrefix("android/obb/") || lowerFolder.hasPrefix("android/data/") || lowerFolder == "android/obb" {
            return ("content-bundle", "android-files/\(folder)")
        }
        let base = DraftRecipe.packageFolder(package: package)
        return ("content-bundle", folder.isEmpty ? base : "\(base)/\(folder)")
    }

    /// Das Rezept aus den Dateien des Depots. `sha256` rechnet die Prüfsumme einer Datei (im Test ersetzt).
    static func make(app: SteamAndroidApp, files: [DepotFile], package: String, versionCode: Int, versionName: String,
                     target: String, minCommit: String, sha256: (DepotFile) throws -> String) throws -> Recipe {
        guard files.count <= 20_000 else { throw SteamDraftError.tooManyFiles(files.count) }
        guard let apk = apk(in: files, launch: app.apks) else { throw SteamDraftError.noApk }
        let source = FileSource(kind: .user, url: nil,
                                hint: LocalizedText(en: "\(app.name) from your own Steam account – the Android build Steam ships for its own headset.",
                                                    de: "\(app.name) aus dem eigenen Steam-Konto – der Android-Stand, den Steam für sein eigenes Headset ausliefert."),
                                steam: SteamSource(app: app.appId, depots: app.depots, folder: nil), archive: nil)
        guard Recipe.isSafeName(apk.name) else { throw SteamDraftError.unsafeName(apk.name) }
        var list = [RecipeFile(name: apk.name, role: "apk", id: "", size: apk.size, sha256: try sha256(apk), required: true, dest: "",
                               localName: "\(target).apk", locale: nil, source: source)]
        var seen: Set<String> = [apk.name]
        for file in files where file != apk {
            // Weitere APKs (Testfassungen) gehören nicht zum Spiel.
            if file.name.lowercased().hasSuffix(".apk") { continue }
            guard Recipe.isSafeName(file.name) else { throw SteamDraftError.unsafeName(file.path) }
            guard seen.insert(file.name).inserted else { throw SteamDraftError.duplicateName(file.name) }
            let place = placement(of: file, package: package)
            list.append(RecipeFile(name: file.name, role: place.role, id: "", size: file.size, sha256: try sha256(file), required: true,
                                   dest: place.dest, localName: nil, locale: nil, source: source))
        }
        let recipe = Recipe(schema: Recipe.supportedSchema, id: identifier(appId: app.appId), title: app.name, package: package,
                            versionName: versionName, versionCode: versionCode, store: .init(appId: nil, steamAppId: app.appId),
                            toolchain: .init(target: target, minCommit: minCommit), files: list, addons: nil,
                            status: .init(playability: "untested", download: "steam", notes: nil), icon: nil, trees: nil)
        try recipe.validate()
        return recipe
    }

    /// Alle Dateien unter den Depot-Ordnern, mit Weg relativ zum jeweiligen Depot. Verweise und Steams eigene
    /// Verwaltungsdateien werden übergangen.
    static func listFiles(in folders: [URL]) -> [(file: DepotFile, url: URL)] {
        var out: [(DepotFile, URL)] = []
        for folder in folders {
            // Der Ordner kann hinter einem Verweis liegen (Depots auf der Platte des Bestands); verglichen wird aufgelöst.
            let root = folder.resolvingSymlinksInPath()
            let base = root.standardizedFileURL.path
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { continue }
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
                let path = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard path.hasPrefix(base + "/") else { continue }
                let relative = String(path.dropFirst(base.count + 1))
                if relative.hasPrefix(".DepotDownloader") || relative.hasPrefix("steamapps/") || relative == "steam_appid.txt"
                    || relative.split(separator: "/").last == ".DS_Store" { continue }
                out.append((DepotFile(path: relative, size: Int64(values?.fileSize ?? 0)), url))
            }
        }
        return out
    }
}

/// Lädt die Android-Fassung eines Steam-Spiels mit Valves Werkzeug, schreibt daraus den Entwurf und übernimmt die
/// Dateien in den Bestand. Steam wird vorher gefragt, ob das Konto das Spiel besitzt.
public struct SteamDraftMaker: Sendable {
    public let tool: SteamTool
    public let store: ContentStore
    public let account: String

    public init(tool: SteamTool = SteamTool(), store: ContentStore, account: String) {
        var tool = tool
        if tool.contentRoot == nil, !StoreLocation.sameVolume(tool.directory, store.root) {
            tool.contentRoot = store.root.appendingPathComponent(".steamcmd", isDirectory: true)
        }
        self.tool = tool
        self.store = store
        self.account = account
    }

    public func prepare(app: SteamAndroidApp, target: (String) -> String, minCommit: String,
                        shouldStop: @escaping @Sendable () -> Bool = { false },
                        progress: @escaping @Sendable (SteamProgress) -> Void = { _ in },
                        report: (String) -> Void = { _ in }) throws -> Recipe {
        guard SteamTool.isAccountName(account) else { throw SteamError.badAccountName }
        guard SteamLibraryRead.isDigits(app.appId), !app.depots.isEmpty,
              SteamSource(app: app.appId, depots: app.depots, folder: nil).isSane else { throw SteamError.badRecipe }
        try tool.verify()
        try tool.prepareContent()

        report(L("Asking Steam whether this account owns the game …", "Steam wird gefragt, ob das Spiel zu diesem Konto gehört …"))
        switch try SteamLicences(tool: tool, account: account).owned(apps: [app.appId], shouldStop: shouldStop)[app.appId] {
        case true?: break
        case false?: throw SteamError.notOwned(app.name)
        case nil: throw SteamError.unclearOwnership
        }

        let total = app.bytes
        let folders = app.depots.map { tool.contentDirectory(app: app.appId, depot: $0.id) }
        let onDisk = folders.map(SteamFetcher.size(of:)).reduce(0, +)
        let landing = tool.contentRoot ?? tool.directory
        try? FileManager.default.createDirectory(at: landing, withIntermediateDirectories: true)
        if let free = StoreLocation.freeBytes(at: landing), total - onDisk + 2_000_000_000 > free {
            throw SteamError.notEnoughSpace(needed: total - onDisk + 2_000_000_000, free: free)
        }

        report(L("Downloading from Steam: \(Installer.gigabytes(total)) …", "Von Steam wird geladen: \(Installer.gigabytes(total)) …"))
        let done = Flag()
        let meter = Thread {
            while !done.value {
                let have = folders.map(SteamFetcher.size(of:)).reduce(0, +)
                if total > 0 { progress(SteamProgress(done: min(have, total), total: total)) }
                Thread.sleep(forTimeInterval: 3)
            }
        }
        meter.start()
        defer { done.value = true }
        let download = try tool.run(["+@NoPromptForPassword", "1", "+login", account]
                                    + app.depots.flatMap { ["+download_depot", app.appId, $0.id, $0.manifest] } + ["+quit"],
                                    shouldStop: shouldStop)
        done.value = true
        if shouldStop() { throw SteamError.stopped }
        for depot in app.depots where !SteamRun.depotComplete(download.output, depot: depot.id) {
            if SteamRun.loginFailed(download.output) { throw SteamRun.failure(download.output) }
            throw SteamError.depotFailed(depot: depot.id, detail: SteamRun.failureLine(download.output))
        }

        report(L("Reading the APK and computing checksums …", "Das APK wird gelesen und die Prüfsummen werden gerechnet …"))
        let listed = SteamDraft.listFiles(in: folders)
        let files = listed.map(\.file)
        guard let apk = SteamDraft.apk(in: files, launch: app.apks), let apkURL = listed.first(where: { $0.file == apk })?.url else {
            throw SteamDraftError.noApk
        }
        let info: ApkUnpacker.Info
        do { info = try ApkUnpacker.manifest(of: apkURL) } catch { throw SteamDraftError.unreadableApk("\(error)") }
        guard let package = info.package, !package.isEmpty, let code = info.versionCode.flatMap({ Int($0) }) else {
            throw SteamDraftError.unreadableApk(L("no package name or version", "kein Paketname oder keine Fassung"))
        }
        let urls = Dictionary(listed.map { ($0.file.path, $0.url) }, uniquingKeysWith: { a, _ in a })
        let recipe = try SteamDraft.make(app: app, files: files, package: package, versionCode: code, versionName: info.versionName ?? "",
                                         target: target(app.appId), minCommit: minCommit) { file in
            guard let url = urls[file.path] else { throw SteamDraftError.noApk }
            return try Hashing.sha256(of: url)
        }

        report(L("Adding the files to the library …", "Die Dateien werden in den Bestand übernommen …"))
        let result = try Adopter(store: store).adopt(recipe: recipe, from: folders, maxDepth: 32)
        let missing = recipe.files.map(\.name).filter { !result.adopted.contains($0) }
        guard missing.isEmpty else { throw SteamError.notTheExpectedFiles(missing) }
        try? FileManager.default.removeItem(at: tool.contentDirectory(app: app.appId))
        return recipe
    }

    private final class Flag: @unchecked Sendable { var value = false }
}
