import Foundation

/// Eine Datei, die Metas Werkzeug für einen Build nennt.
public struct ListedFile: Sendable, Equatable {
    public let name: String
    public let id: String
    /// `APK`, `OBB` oder `ASSET`, wie das Werkzeug es schreibt.
    public let kind: String
    /// Die Größe, wie das Werkzeug sie rundet („2.4GB“) – zum Anzeigen, nicht zum Prüfen.
    public let sizeText: String
}

public enum ListingError: Error, CustomStringConvertible, Equatable {
    case refused(String)
    case nothingListed

    public var description: String {
        switch self {
        case .refused(let why):
            return L("Meta's tool did not list the files of this build: \(why)", "Metas Werkzeug hat die Dateien dieses Builds nicht aufgelistet: \(why)")
        case .nothingListed:
            return L("Meta's tool listed no files for this build.", "Metas Werkzeug hat für diesen Build keine Dateien genannt.")
        }
    }
}

/// Fragt Metas eigenes Werkzeug, aus welchen Dateien ein Build besteht.
///
/// Das ist der einzige dokumentierte Weg zu dieser Liste, und er hat zwei Eigenheiten, die hier bewusst in Kauf
/// genommen werden – der Nutzer hat ihm für genau diesen Zweck zugestimmt (Details eines Spiels öffnen):
///  - Das Werkzeug nimmt den Token nur als Argument. Für die Dauer des Aufrufs ist er damit für andere
///    Programme desselben Benutzers sichtbar. Er wird nie protokolliert, und die Ausgabe wird bereinigt.
///  - Das Werkzeug schreibt ein eigenes Protokoll in den temporären Ordner. Es bekommt dafür einen eigenen,
///    der nach dem Aufruf gelöscht wird.
/// Gefragt wird je Build höchstens einmal je Liste; das Ergebnis hält der Aufrufer fest.
public enum MetaListing {
    public enum Command: String, Sendable {
        /// APK und Haupt-OBB.
        case build = "download-quest-build"
        /// Die weiteren Dateien des Builds.
        case assets = "download-asset-file"
    }

    /// Liest die Zeilen des Werkzeugs: `  <Name>  <Größe>  [ART] <Kennung>`, als Text oder in JSON-Protokollzeilen.
    public static func parse(_ output: String) -> [ListedFile] {
        var files: [ListedFile] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            var line = String(raw)
            if line.hasPrefix("{"), let data = line.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let message = object["message"] as? String {
                line = message
            }
            guard line.hasPrefix(" "), let open = line.lastIndex(of: "["), let close = line[open...].firstIndex(of: "]") else { continue }
            let kind = String(line[line.index(after: open)..<close])
            let id = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            let head = line[..<open].trimmingCharacters(in: .whitespaces)
            // Name und Größe trennt eine Lücke von mindestens zwei Leerzeichen; der Name selbst darf einzelne enthalten.
            guard let gap = head.range(of: "  ", options: .backwards) else { continue }
            let name = head[..<gap.lowerBound].trimmingCharacters(in: .whitespaces)
            let size = head[gap.upperBound...].trimmingCharacters(in: .whitespaces)
            guard CatalogGame.isIdentifier(id), !name.isEmpty, !kind.isEmpty, kind.allSatisfy({ $0.isUppercase || $0 == "_" }),
                  Recipe.isSafeName(name) else { continue }
            files.append(ListedFile(name: name, id: id, kind: kind, sizeText: size))
        }
        return files
    }

    /// Ruft das Werkzeug auf. `tool` muss zuvor als Metas Werkzeug geprüft sein (`MetaTool.verify`).
    public static func list(_ command: Command, buildId: String, tool: URL, token: String) throws -> [ListedFile] {
        guard CatalogGame.isIdentifier(buildId), TokenStore.isPlausible(token) else { throw ListingError.refused("–") }
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("avpplay-list-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }

        let p = Process()
        p.executableURL = tool
        p.arguments = [command.rawValue, "-b", buildId, "--list", "--output-format", "json", "-t", token]
        p.currentDirectoryURL = scratch
        var env = ProcessInfo.processInfo.environment
        env["TMPDIR"] = scratch.path + "/"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = Redaction.redact(String(decoding: data, as: UTF8.self)).replacingOccurrences(of: token, with: "<REDACTED>")
        let files = parse(text)
        guard p.terminationStatus == 0 else {
            throw ListingError.refused(MetaListing.reason(in: text) ?? "status \(p.terminationStatus)")
        }
        if files.isEmpty, command == .build { throw ListingError.nothingListed }
        return files
    }

    /// Ob das Werkzeug den Build „nicht findet“ – so antwortet es einem Konto nach vielen Downloads auf jede
    /// Abfrage (Schritt 0, F61), auch für Spiele, die es Stunden zuvor noch auflistete.
    public static func isNotFound(_ error: Error) -> Bool {
        guard case ListingError.refused(let why) = error else { return false }
        return why.contains("Cannot find")
    }

    /// Alle Dateien eines Builds: zuerst Metas Werkzeug (APK und OBB, nach einer Pause die weiteren Dateien).
    /// Antwortet es „Cannot find …“, nennen Metas Build-Details die Dateien (`MetaClient.buildFiles`); nennen
    /// auch die nichts, bleibt es bei der Absage des Werkzeugs.
    public static func files(buildId: String, tool: URL, token: String, client: MetaClient,
                             say: @Sendable (String) async -> Void = { _ in }) async throws -> [ListedFile] {
        var files: [ListedFile]
        do {
            files = try list(.build, buildId: buildId, tool: tool, token: token)
        } catch where isNotFound(error) {
            await say(L("Meta's tool doesn't answer for this account (“Cannot find …”); asking Meta for the build's details instead …",
                        "Metas Werkzeug antwortet diesem Konto nicht („Cannot find …“); Meta wird stattdessen nach den Details des Builds gefragt …"))
            let details = (try? await client.buildFiles(buildId: buildId)) ?? []
            guard details.contains(where: { $0.kind == "APK" }) else { throw error }
            return details
        }
        try await Task.sleep(for: .seconds(5))
        // Weitere Dateien hat nicht jedes Spiel; sagt das Werkzeug dazu nichts oder lehnt ab, bleibt es bei APK und OBB.
        if let assets = try? list(.assets, buildId: buildId, tool: tool, token: token) { files += assets }
        return files
    }

    /// Der Satz, mit dem das Werkzeug ablehnt, soweit es einen sagt.
    static func reason(in output: String) -> String? {
        for raw in output.split(whereSeparator: \.isNewline).reversed() {
            var line = String(raw)
            if line.hasPrefix("{"), let data = line.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let message = object["message"] as? String {
                line = message
            }
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, !text.hasPrefix("Logs are written"), !text.hasPrefix("Total time") { return String(text.prefix(200)) }
        }
        return nil
    }
}

public enum ToolDownloadError: Error, CustomStringConvertible, Equatable {
    case refused(String)
    case missingFile(String)

    public var description: String {
        switch self {
        case .refused(let why):
            return L("Meta won't deliver this file (HTTP 404), and Meta's tool didn't download it either: \(why)",
                     "Meta liefert diese Datei nicht aus (HTTP 404), und auch Metas Werkzeug hat sie nicht geladen: \(why)")
        case .missingFile(let name):
            return L("Meta won't deliver \(name) (HTTP 404); Meta's tool finished, but the file wasn't among what it downloaded.",
                     "Meta liefert \(name) nicht aus (HTTP 404); Metas Werkzeug lief durch, aber die Datei war nicht unter dem, was es geladen hat.")
        }
    }
}

/// Lädt mit Metas Werkzeug statt über die direkte Adresse – der Ausweg, wenn die direkte Adresse eine Datei
/// des Spiels mit HTTP 404 verweigert, das Werkzeug sie aber herausgibt (First Encounters, 2026-10-15; vom
/// Nutzer so gewünscht). Wie beim Auflisten steht der Token dabei für die Dauer des Aufrufs in den
/// Prozessargumenten; er wird nie protokolliert, und das Werkzeug schreibt sein Protokoll in einen eigenen
/// Ordner, der mit dem Ladeordner gelöscht wird.
public struct MetaToolDownload: Sendable {
    public enum Command: Sendable, Equatable {
        /// APK und Haupt-OBB eines Builds. Die Kennung des Builds ist die seines APKs.
        case build(String)
        /// Eine weitere Datei des Builds.
        case asset(String)

        var arguments: [String] {
            switch self {
            case .build(let id): return ["download-quest-build", "-b", id]
            case .asset(let id): return ["download-asset-file", "--asset-file-id", id]
            }
        }
    }

    public let tool: URL
    let token: String

    /// `tool` muss zuvor als Metas Werkzeug geprüft sein (`MetaTool.verify`).
    public init(tool: URL, token: String) {
        self.tool = tool
        self.token = token
    }

    /// Lädt nach `folder`. Wie das Werkzeug die Dateien dort ablegt (das Haupt-OBB in einem eigenen Unterordner),
    /// bleibt ihm überlassen; gefunden werden sie mit `find`.
    public func fetch(_ command: Command, into folder: URL) async throws {
        let id: String
        switch command { case .build(let b): id = b; case .asset(let a): id = a }
        guard CatalogGame.isIdentifier(id), TokenStore.isPlausible(token) else { throw ToolDownloadError.refused("–") }
        let fm = FileManager.default
        let logs = folder.appendingPathComponent(".tool-tmp", isDirectory: true)
        try fm.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: logs) }

        let p = Process()
        p.executableURL = tool
        p.arguments = command.arguments + ["-d", folder.path, "--output-format", "json", "-t", token]
        p.currentDirectoryURL = logs
        var env = ProcessInfo.processInfo.environment
        env["TMPDIR"] = logs.path + "/"
        p.environment = env
        // Das Werkzeug meldet laufend Fortschritt; gelesen wird mit, damit es nie an einer vollen Leitung hängt,
        // behalten wird nur das Ende – darin steht, warum es abbricht.
        let tail = OutputTail()
        let out = Pipe()
        out.fileHandleForReading.readabilityHandler = { tail.append($0.availableData) }
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int32, Error>) in
                p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
                do { try p.run() } catch { p.terminationHandler = nil; c.resume(throwing: error) }
            }
        } onCancel: {
            p.terminate()
        }
        out.fileHandleForReading.readabilityHandler = nil
        tail.append(out.fileHandleForReading.readDataToEndOfFile())
        try Task.checkCancellation()
        guard status == 0 else {
            let text = Redaction.redact(tail.text).replacingOccurrences(of: token, with: "<REDACTED>")
            throw ToolDownloadError.refused(MetaListing.reason(in: text) ?? "status \(status)")
        }
    }

    /// Die geladene Datei dieses Namens irgendwo unter `folder`.
    public static func find(_ name: String, in folder: URL) -> URL? {
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return nil }
        for case let url as URL in walk where url.lastPathComponent == name {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { return url }
        }
        return nil
    }
}

/// Das Ende einer Ausgabe, höchstens 64 KB.
private final class OutputTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if data.count > 1 << 16 { data = data.suffix(1 << 16) }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Der Build, den Meta dem angemeldeten Konto für ein Spiel nennt, als Ausweg für einen Entwurf, dessen Build
/// Metas Werkzeug mit „Not entitled to download“ ablehnt. Der Katalog kann einen Build kennen, der diesem Konto
/// (noch) nicht ausgeliefert wird – HITMAN 3 VR: Reloaded stand dort mit 3645, das Konto bekam 3641.
public enum AccountBuild {
    /// Ob Metas Werkzeug einen Download abgelehnt hat, weil das Konto diesen Build nicht laden darf.
    public static func isNotEntitled(_ error: Error) -> Bool {
        guard case ToolDownloadError.refused(let why) = error else { return false }
        return why.localizedCaseInsensitiveContains("not entitled")
    }

    /// Der Build, der statt dem des Entwurfs zu laden ist: der neueste, den Metas Antwort für das Konto nennt.
    /// Nur für Entwürfe, und nur wenn deren Fassung nicht unter den genannten ist – sonst liegt die Absage an
    /// etwas anderem, und ein anderer Build hilft nicht.
    public static func replacement(for recipe: Recipe, accountBuilds: [CatalogBuild]) -> CatalogBuild? {
        guard DraftRecipe.appId(of: recipe.id) != nil, let newest = accountBuilds.first,
              !accountBuilds.contains(where: { $0.versionCode == recipe.versionCode }) else { return nil }
        return newest
    }

    /// Fragt Meta nach den Builds des Kontos (dieselbe eine Abfrage wie für Store-Updates) und schlägt, gibt es
    /// einen anderen als den des Entwurfs, dessen Dateien nach. `nil`: es gibt keinen anderen.
    public static func redraft(_ recipe: Recipe, tool: URL, token: String, client: MetaClient,
                               say: @Sendable (String) async -> Void = { _ in }) async throws -> Recipe? {
        guard let appId = recipe.store.appId else { return nil }
        _ = try await client.me()
        guard let build = replacement(for: recipe, accountBuilds: try await client.builds(appId: appId)) else { return nil }
        await say(L("Meta names build \(build.version) for your account; asking Meta's tool for its files …",
                    "Meta nennt deinem Konto Build \(build.version); Metas Werkzeug wird nach dessen Dateien gefragt …"))
        let files = try await MetaListing.files(buildId: build.buildId, tool: tool, token: token, client: client, say: say)
        return try DraftRecipe.forBuild(recipe, build: build, files: files)
    }
}

/// Ein Rezept für ein Spiel, das noch niemand geprüft hat: gebaut aus dem, was der Katalog und Metas Werkzeug
/// über den neuesten Build sagen. Es kennt weder genaue Größen noch Prüfsummen und ist entsprechend gekennzeichnet.
public enum DraftRecipe {
    /// Die Kennung eines solchen Rezepts – eindeutig je Store-App und nie die eines mitgelieferten Rezepts.
    public static func identifier(appId: String) -> String { "store-\(appId)" }

    /// Die App-Kennung hinter der Kennung eines Entwurfs; `nil`, wenn es keine solche ist.
    public static func appId(of identifier: String) -> String? {
        guard identifier.hasPrefix("store-") else { return nil }
        let id = String(identifier.dropFirst(6))
        return CatalogGame.isIdentifier(id) ? id : nil
    }

    /// Platzhalter für ein Spiel, dessen Dateien noch nicht nachgeschlagen sind: nur Name und Kennungen.
    public static func placeholder(game: CatalogGame) -> Recipe {
        Recipe(schema: Recipe.supportedSchema, id: identifier(appId: game.appId), title: game.title, package: game.package,
               versionName: game.build?.version ?? "", versionCode: game.build?.versionCode ?? 0, store: .init(appId: game.appId),
               toolchain: .init(target: game.target ?? "", minCommit: ""), files: [], addons: nil,
               status: .init(playability: game.status == "verified" ? "verified" : "untested", download: "unknown", notes: nil),
               icon: nil, trees: nil)
    }

    /// Der Name, unter dem die Toolchain ein Spiel versucht, das sie nicht kennt: `x` und die Kennung der Store-App.
    /// Er ist zugleich Ordner, APK-Name und – über die Bundle-ID – die Kennung der App auf dem Gerät.
    public static func genericTarget(appId: String) -> String { "x\(appId)" }

    public static func isGeneric(_ target: String) -> Bool {
        target.hasPrefix("x") && CatalogGame.isIdentifier(String(target.dropFirst()))
    }

    /// Steht als Ziel der Haupt-Datendatei im Entwurf. Wo ein Spiel sie sucht, hängt von seiner Engine ab, und
    /// die kennt erst die Toolchain, wenn das APK entpackt ist – deshalb wird der Ort beim Kopieren eingesetzt.
    public static let obbPlaceholder = "@obb"

    /// Steht als Ziel der weiteren Dateien, wenn der Katalog den Paketnamen des Spiels nicht kennt: der Ordner
    /// `Android/obb/<Paket>` lässt sich dann erst benennen, wenn das APK entpackt ist.
    public static let packageFolderPlaceholder = "@package-obb"

    /// Der Ordner, in dem eine Quest die weiteren Dateien eines Spiels ablegt.
    public static func packageFolder(package: String) -> String { "android-files/Android/obb/\(package)" }

    /// Ob ein Ziel noch auf den Paketnamen wartet – der Platzhalter, oder der Ordner ohne Namen aus einem
    /// Entwurf, der vor dem Platzhalter entstand.
    public static func needsPackage(_ dest: String?) -> Bool {
        dest == packageFolderPlaceholder || dest == packageFolder(package: "")
    }

    /// Derselbe Entwurf für einen anderen Namen in der Toolchain oder einen anderen Mindeststand. Ein Entwurf, der
    /// ohne Toolchain nachgeschlagen wurde (nur zum Laden), nennt noch keinen Mindeststand; er wird eingesetzt,
    /// sobald gebaut wird – ohne Meta noch einmal zu fragen.
    public static func retargeted(_ recipe: Recipe, target: String, minCommit: String) -> Recipe {
        var result = recipe
        let old = recipe.toolchain.target
        result.toolchain = .init(target: target, minCommit: minCommit)
        result.files = recipe.files.map { file in
            var file = file
            if file.role == "apk", file.localName == "\(old).apk" { file.localName = "\(target).apk" }
            return file
        }
        return result
    }

    /// - Parameter target: der Name des Spiels in der Toolchain – ein Eintrag ihrer Tabelle oder `genericTarget`.
    public static func make(game: CatalogGame, build: CatalogBuild, files: [ListedFile], target: String,
                            minCommit: String) throws -> Recipe {
        try make(appId: game.appId, title: game.title, package: game.package, build: build, files: files,
                 target: target, minCommit: minCommit)
    }

    /// Derselbe Entwurf für einen anderen Build desselben Spiels – Name, Paket und Toolchain bleiben.
    public static func forBuild(_ recipe: Recipe, build: CatalogBuild, files: [ListedFile]) throws -> Recipe {
        guard let appId = recipe.store.appId else { throw MetaError.missingAppId }
        return try make(appId: appId, title: recipe.title, package: recipe.package, build: build, files: files,
                        target: recipe.toolchain.target, minCommit: recipe.toolchain.minCommit)
    }

    static func make(appId: String, title: String, package: String, build: CatalogBuild, files: [ListedFile],
                     target: String, minCommit: String) throws -> Recipe {
        guard let apk = files.first(where: { $0.kind == "APK" }) else { throw ListingError.nothingListed }
        let androidObb = package.isEmpty ? packageFolderPlaceholder : packageFolder(package: package)
        var list = [RecipeFile(name: apk.name, role: "apk", id: apk.id, size: nil, sha256: nil, required: true, dest: "",
                               localName: "\(target).apk", locale: nil, source: nil)]
        var seen: Set<String> = [apk.name]
        for file in files where file.kind != "APK" && seen.insert(file.name).inserted {
            let isMain = file.kind == "OBB"
            // Weitere Dateien liegen auf einer Quest immer unter Android/obb/<Paket>; den Ort der Haupt-Datendatei
            // setzt die Toolchain ein.
            let dest = isMain ? obbPlaceholder : androidObb
            list.append(RecipeFile(name: file.name, role: isMain ? "main-obb" : "content-bundle", id: file.id, size: nil, sha256: nil,
                                   required: true, dest: dest, localName: nil, locale: nil, source: nil))
        }
        let recipe = Recipe(schema: Recipe.supportedSchema, id: identifier(appId: appId), title: title, package: package,
                            versionName: build.version, versionCode: build.versionCode, store: .init(appId: appId),
                            toolchain: .init(target: target, minCommit: minCommit), files: list, addons: nil,
                            status: .init(playability: "untested", download: "listed", notes: nil), icon: nil, trees: nil)
        try recipe.validate()
        return recipe
    }
}
